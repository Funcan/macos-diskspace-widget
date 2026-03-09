import Foundation

struct ScanSnapshot {
    let files: Int
    let bytes: UInt64
    let elapsed: TimeInterval
    let filesPerSecond: Int
    let icicleNodes: [IcicleNode]
}

final class FileSystemScanner {
    var onProgress: ((ScanSnapshot) -> Void)?
    var onPaused: ((ScanSnapshot) -> Void)?
    var onCompleted: ((ScanSnapshot) -> Void)?

    private let scanQueue = DispatchQueue(label: "MacDiskMonitor.AnalysisScan", qos: .utility)
    private let scanStateLock = NSLock()
    private let statWorkerCount = 8
    private let statBatchSize = 256
    private let progressUpdateInterval: TimeInterval = 0.25
    private let depthCutoffPercent = 0.05

    private var scanRequested = false
    private var scanWorkerActive = false
    private var scanEnumerator: FileManager.DirectoryEnumerator?
    private var rootTreeNode = MutableTreeNode(name: "/", path: "/")
    private var scannedFiles: Int = 0
    private var scannedBytes: UInt64 = 0
    private var scanActiveStartDate: Date?
    private var lastProgressEmitDate: Date?
    private var accumulatedScanDuration: TimeInterval = 0
    private var displayedFilesPerSecond: Int = 0
    private var lastRateSampleDate: Date?
    private var lastRateSampleFileCount: Int = 0

    func startOrResume() {
        setScanRequested(true)
        markScanResumed()

        let shouldStartWorker: Bool = scanStateLock.withLock {
            if scanWorkerActive {
                return false
            }
            scanWorkerActive = true
            return true
        }

        guard shouldStartWorker else { return }

        scanQueue.async { [weak self] in
            self?.scanLoop()
        }
    }

    func pause() {
        setScanRequested(false)
        markScanPaused()
    }

    func currentSnapshot(forceZeroRate: Bool = false) -> ScanSnapshot {
        scanStateLock.withLock {
            makeSnapshotLocked(forceZeroRate: forceZeroRate)
        }
    }

    private func scanLoop() {
        let fileManager = FileManager.default

        if scanEnumerator == nil {
            scanEnumerator = fileManager.enumerator(atPath: "/")
            rootTreeNode = MutableTreeNode(name: "/", path: "/")
            scannedFiles = 0
            scannedBytes = 0
            resetScanTiming()
            markScanResumed()
        }
        if lastProgressEmitDate == nil {
            lastProgressEmitDate = Date()
        }

        while isScanRequested() {
            guard let firstEntry = scanEnumerator?.nextObject() as? String else {
                scanEnumerator = nil
                setScanRequested(false)
                setScanWorkerActive(false)
                markScanPaused()

                emitCompleted(currentSnapshot())
                return
            }

            var batch: [String] = [firstEntry]
            while isScanRequested(), batch.count < statBatchSize {
                guard let nextEntry = scanEnumerator?.nextObject() as? String else {
                    break
                }
                batch.append(nextEntry)
            }

            let batchResult = processBatch(batch)
            scanStateLock.withLock {
                scannedFiles += batchResult.files
                scannedBytes += batchResult.bytes
                applyFileContributions(batchResult.fileContributions)
            }

            let now = Date()
            if let lastEmit = lastProgressEmitDate, now.timeIntervalSince(lastEmit) >= progressUpdateInterval {
                lastProgressEmitDate = now
                emitProgress(currentSnapshot())
            }
        }

        setScanWorkerActive(false)
        emitPaused(currentSnapshot(forceZeroRate: true))
    }

    private func processBatch(_ entries: [String]) -> BatchResult {
        let workers = min(statWorkerCount, max(1, entries.count))
        var fileCounts = Array(repeating: 0, count: workers)
        var byteCounts = Array(repeating: UInt64(0), count: workers)
        var fileContributions = Array(repeating: [(String, UInt64)](), count: workers)

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let fileManager = FileManager()
            var localFiles = 0
            var localBytes: UInt64 = 0
            var localContributions: [(String, UInt64)] = []
            var index = worker

            while index < entries.count {
                let fullPath = "/\(entries[index])"
                do {
                    let attributes = try fileManager.attributesOfItem(atPath: fullPath)
                    if
                        let type = attributes[.type] as? FileAttributeType,
                        type == .typeRegular,
                        let size = attributes[.size] as? NSNumber
                    {
                        localFiles += 1
                        localBytes += size.uint64Value
                        localContributions.append((entries[index], size.uint64Value))
                    }
                } catch {
                    // Best-effort scan: skip paths we cannot stat.
                }

                index += workers
            }

            fileCounts[worker] = localFiles
            byteCounts[worker] = localBytes
            fileContributions[worker] = localContributions
        }

        let totalFiles = fileCounts.reduce(0, +)
        let totalBytes = byteCounts.reduce(0, +)
        let allContributions = fileContributions.flatMap { $0 }
        return BatchResult(files: totalFiles, bytes: totalBytes, fileContributions: allContributions)
    }

    private func isScanRequested() -> Bool {
        scanStateLock.withLock { scanRequested }
    }

    private func setScanRequested(_ requested: Bool) {
        scanStateLock.withLock {
            scanRequested = requested
        }
    }

    private func setScanWorkerActive(_ active: Bool) {
        scanStateLock.withLock {
            scanWorkerActive = active
        }
    }

    private func resetScanTiming() {
        scanStateLock.withLock {
            scanActiveStartDate = nil
            lastProgressEmitDate = nil
            accumulatedScanDuration = 0
            displayedFilesPerSecond = 0
            lastRateSampleDate = nil
            lastRateSampleFileCount = scannedFiles
        }
    }

    private func markScanResumed() {
        scanStateLock.withLock {
            if scanActiveStartDate == nil {
                scanActiveStartDate = Date()
            }
            lastRateSampleDate = Date()
            lastRateSampleFileCount = scannedFiles
        }
    }

    private func markScanPaused() {
        scanStateLock.withLock {
            guard let startDate = scanActiveStartDate else { return }
            accumulatedScanDuration += Date().timeIntervalSince(startDate)
            scanActiveStartDate = nil
            displayedFilesPerSecond = 0
            lastRateSampleDate = nil
            lastRateSampleFileCount = scannedFiles
        }
    }

    private func makeSnapshotLocked(forceZeroRate: Bool) -> ScanSnapshot {
        let elapsed = elapsedScanDurationLocked()
        let rate = sampledFilesPerSecondLocked(forceZero: forceZeroRate)
        let nodes = buildIcicleNodesLocked()
        return ScanSnapshot(files: scannedFiles, bytes: scannedBytes, elapsed: elapsed, filesPerSecond: rate, icicleNodes: nodes)
    }

    private func applyFileContributions(_ contributions: [(String, UInt64)]) {
        for (relativePath, bytes) in contributions {
            addFile(path: relativePath, size: bytes)
        }
    }

    private func addFile(path relativePath: String, size: UInt64) {
        guard size > 0 else { return }

        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }

        rootTreeNode.size += size
        var current = rootTreeNode
        for (index, component) in components.enumerated() {
            let childPath = current.path == "/" ? "/\(component)" : "\(current.path)/\(component)"
            let child = current.children[component] ?? {
                let node = MutableTreeNode(name: component, path: childPath)
                current.children[component] = node
                return node
            }()

            child.size += size
            current = child

            if index == components.count - 1 {
                current.isLeafFile = true
            }
        }
    }

    private func buildIcicleNodesLocked() -> [IcicleNode] {
        let topNodes = sortedChildren(of: rootTreeNode)
        guard !topNodes.isEmpty else { return [] }

        let maxDepth = maxDisplayDepth(topNodes: topNodes)
        return topNodes.map { buildIcicleNode(from: $0, currentDepth: 1, maxDepth: maxDepth) }
    }

    private func maxDisplayDepth(topNodes: [MutableTreeNode]) -> Int {
        let scannedTotal = rootTreeNode.size
        guard scannedTotal > 0 else {
            return 2
        }

        let threshold = UInt64(Double(scannedTotal) * depthCutoffPercent)
        var depth = 1
        var currentRow = topNodes

        while !currentRow.isEmpty {
            if currentRow.allSatisfy({ $0.size < threshold }) {
                break
            }

            let nextRow = currentRow.flatMap { sortedChildren(of: $0) }
            if nextRow.isEmpty {
                break
            }

            depth += 1
            currentRow = nextRow
        }

        return depth
    }

    private func buildIcicleNode(from node: MutableTreeNode, currentDepth: Int, maxDepth: Int) -> IcicleNode {
        let children: [IcicleNode] = if currentDepth < maxDepth {
            sortedChildren(of: node).map { buildIcicleNode(from: $0, currentDepth: currentDepth + 1, maxDepth: maxDepth) }
        } else {
            []
        }

        return IcicleNode(name: node.name, path: node.path, size: node.size, children: children)
    }

    private func sortedChildren(of node: MutableTreeNode) -> [MutableTreeNode] {
        node.children.values
            .filter { $0.size > 0 }
            .sorted {
                if $0.size == $1.size {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.size > $1.size
            }
    }

    private func elapsedScanDurationLocked() -> TimeInterval {
        let runningDuration: TimeInterval = if let startDate = scanActiveStartDate {
            Date().timeIntervalSince(startDate)
        } else {
            0
        }
        return accumulatedScanDuration + runningDuration
    }

    private func sampledFilesPerSecondLocked(forceZero: Bool) -> Int {
        if forceZero {
            displayedFilesPerSecond = 0
            return 0
        }

        let now = Date()
        if let lastSampleDate = lastRateSampleDate {
            let delta = now.timeIntervalSince(lastSampleDate)
            if delta >= 1 {
                let fileDelta = scannedFiles - lastRateSampleFileCount
                let sampledRate = delta > 0 ? Double(fileDelta) / delta : 0
                displayedFilesPerSecond = max(0, Int(sampledRate.rounded()))
                lastRateSampleDate = now
                lastRateSampleFileCount = scannedFiles
            }
        } else {
            lastRateSampleDate = now
            lastRateSampleFileCount = scannedFiles
            displayedFilesPerSecond = 0
        }

        return displayedFilesPerSecond
    }

    private func emitProgress(_ snapshot: ScanSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(snapshot)
        }
    }

    private func emitPaused(_ snapshot: ScanSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.onPaused?(snapshot)
        }
    }

    private func emitCompleted(_ snapshot: ScanSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.onCompleted?(snapshot)
        }
    }
}

private struct BatchResult {
    let files: Int
    let bytes: UInt64
    let fileContributions: [(String, UInt64)]
}

private final class MutableTreeNode {
    let name: String
    let path: String
    var size: UInt64 = 0
    var isLeafFile = false
    var children: [String: MutableTreeNode] = [:]

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
