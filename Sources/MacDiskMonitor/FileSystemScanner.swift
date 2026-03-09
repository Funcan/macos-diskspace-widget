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

    private let scanQueue = DispatchQueue(label: "MacDiskMonitor.AnalysisScan",
                                          qos: .utility)
    private let scanStateLock = NSLock()
    private let statWorkerCount = 8
    private let progressUpdateInterval: TimeInterval = 0.25
    private let depthCutoffPercent = 0.05
    private let maxTrackedDepth: Int

    private var scanRequested = false
    private var scanWorkerActive = false
    private var rootTreeNode = MutableTreeNode(name: "/", path: "/")
    private var directoryStack: [ScanTask] = []
    private var scannedFiles: Int = 0
    private var scannedBytes: UInt64 = 0
    private var scanActiveStartDate: Date?
    private var lastProgressEmitDate: Date?
    private var accumulatedScanDuration: TimeInterval = 0
    private var displayedFilesPerSecond: Int = 0
    private var lastRateSampleDate: Date?
    private var lastRateSampleFileCount: Int = 0

    init(maxTrackedDepth: Int = 12) {
        self.maxTrackedDepth = max(1, maxTrackedDepth)
    }

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
        if directoryStack.isEmpty {
            rootTreeNode = MutableTreeNode(name: "/", path: "/")
            scannedFiles = 0
            scannedBytes = 0
            directoryStack = [
                ScanTask(
                    kind: .scan,
                    url: URL(fileURLWithPath: "/", isDirectory: true),
                    targetNode: rootTreeNode,
                    representedNode: rootTreeNode,
                    depth: 0
                ),
            ]
            resetScanTiming()
            markScanResumed()
        }

        if lastProgressEmitDate == nil {
            lastProgressEmitDate = Date()
        }

        while isScanRequested() {
            guard let task = popNextTask() else {
                setScanRequested(false)
                setScanWorkerActive(false)
                markScanPaused()

                emitCompleted(currentSnapshot())
                return
            }

            processTask(task)
            scanStateLock.withLock {
                compactSmallLeafIfNeeded(task.representedNode)
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

    private func processTask(_ task: ScanTask) {
        if task.kind == .finalize {
            task.representedNode?.isFullyScanned = true
            return
        }

        let entries = listDirectoryEntries(at: task.url)
        guard !entries.isEmpty else {
            task.representedNode?.isFullyScanned = true
            return
        }

        var filePaths: [String] = []
        var childDirectories: [URL] = []

        for entry in entries {
            if entry.isDirectory {
                childDirectories.append(entry.url)
            } else if entry.isRegularFile {
                filePaths.append(entry.url.path)
            }
        }

        let batchResult = processFiles(filePaths)
        scanStateLock.withLock {
            scannedFiles += batchResult.files
            scannedBytes += batchResult.bytes
            addBytes(batchResult.bytes, to: task.targetNode)
        }

        // Push in reverse lexical order so pop() gives depth-first lexical traversal.
        for childDirectory in childDirectories.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedDescending }) {
            let childDepth = task.depth + 1
            if childDepth <= maxTrackedDepth {
                let childNode = task.targetNode.childNode(named: childDirectory.lastPathComponent)
                pushTask(
                    ScanTask(
                        kind: .scan,
                        url: childDirectory,
                        targetNode: childNode,
                        representedNode: childNode,
                        depth: childDepth
                    )
                )
            } else {
                // Past max depth, keep scanning but fold into nearest represented ancestor.
                pushTask(
                    ScanTask(
                        kind: .scan,
                        url: childDirectory,
                        targetNode: task.targetNode,
                        representedNode: nil,
                        depth: childDepth
                    )
                )
            }
        }

        if task.representedNode != nil {
            pushTask(
                ScanTask(
                    kind: .finalize,
                    url: task.url,
                    targetNode: task.targetNode,
                    representedNode: task.representedNode,
                    depth: task.depth
                )
            )
        }
    }

    private func processFiles(_ filePaths: [String]) -> BatchResult {
        guard !filePaths.isEmpty else {
            return BatchResult(files: 0, bytes: 0)
        }

        let workers = min(statWorkerCount, max(1, filePaths.count))
        var fileCounts = Array(repeating: 0, count: workers)
        var byteCounts = Array(repeating: UInt64(0), count: workers)

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let fileManager = FileManager()
            var localFiles = 0
            var localBytes: UInt64 = 0
            var index = worker

            while index < filePaths.count {
                let fullPath = filePaths[index]
                do {
                    let attributes = try fileManager.attributesOfItem(atPath: fullPath)
                    if
                        let type = attributes[.type] as? FileAttributeType,
                        type == .typeRegular,
                        let size = attributes[.size] as? NSNumber
                    {
                        localFiles += 1
                        localBytes += size.uint64Value
                    }
                } catch {
                    // Best-effort scan: skip paths we cannot stat.
                }

                index += workers
            }

            fileCounts[worker] = localFiles
            byteCounts[worker] = localBytes
        }

        let totalFiles = fileCounts.reduce(0, +)
        let totalBytes = byteCounts.reduce(0, +)
        return BatchResult(files: totalFiles, bytes: totalBytes)
    }

    private func listDirectoryEntries(at url: URL) -> [DirectoryEntry] {
        do {
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsPackageDescendants]
            )

            var results: [DirectoryEntry] = []
            results.reserveCapacity(urls.count)

            for entryURL in urls {
                guard let values = try? entryURL.resourceValues(forKeys: resourceKeys) else { continue }
                if values.isSymbolicLink == true { continue }

                let isDirectory = values.isDirectory == true
                let isRegularFile = values.isRegularFile == true
                if !isDirectory, !isRegularFile { continue }

                results.append(DirectoryEntry(url: entryURL, isDirectory: isDirectory, isRegularFile: isRegularFile))
            }

            return results
        } catch {
            return []
        }
    }

    private func addBytes(_ bytes: UInt64, to node: MutableTreeNode) {
        guard bytes > 0 else { return }
        var current: MutableTreeNode? = node
        while let node = current {
            node.size += bytes
            current = node.parent
        }
    }

    private func compactSmallLeafIfNeeded(_ node: MutableTreeNode?) {
        guard
            let node,
            node.isFullyScanned,
            node.children.isEmpty,
            let parent = node.parent
        else {
            return
        }

        let threshold = UInt64(Double(rootTreeNode.size) * depthCutoffPercent)
        guard threshold > 0, node.size < threshold else { return }

        parent.children.removeValue(forKey: node.name)
    }

    private func popNextTask() -> ScanTask? {
        scanStateLock.withLock {
            directoryStack.popLast()
        }
    }

    private func pushTask(_ task: ScanTask) {
        scanStateLock.withLock {
            directoryStack.append(task)
        }
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

// swiftlint:enable type_body_length

private struct BatchResult {
    let files: Int
    let bytes: UInt64
}

private struct DirectoryEntry {
    let url: URL
    let isDirectory: Bool
    let isRegularFile: Bool
}

private struct ScanTask {
    enum Kind {
        case scan
        case finalize
    }

    let kind: Kind
    let url: URL
    let targetNode: MutableTreeNode
    let representedNode: MutableTreeNode?
    let depth: Int
}

private final class MutableTreeNode {
    let name: String
    var path: String
    weak var parent: MutableTreeNode?
    var size: UInt64 = 0
    var isFullyScanned = false
    var children: [String: MutableTreeNode] = [:]

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    func childNode(named name: String) -> MutableTreeNode {
        if let existing = children[name] {
            return existing
        }

        let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
        let node = MutableTreeNode(name: name, path: childPath)
        node.parent = self
        children[name] = node
        return node
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
