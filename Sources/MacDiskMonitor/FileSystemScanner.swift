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
    private let approximateSeedDepth = 3
    private let approximateSeedMaxChildrenPerParent = 200
    private let maxTrackedDepth: Int

    private var scanRequested = false
    private var scanWorkerActive = false
    private var rootTreeNode = MutableTreeNode(name: "/", path: "/")
    private var directoryStack: [ScanTask] = []
    private var canonicalDirectoryPathByID: [FileIdentity: String] = [:]
    private var visitedFileIDs: Set<FileIdentity> = []
    private var scannedFiles: Int = 0
    private var scannedBytes: UInt64 = 0
    private var scanActiveStartDate: Date?
    private var lastProgressEmitDate: Date?
    private var accumulatedScanDuration: TimeInterval = 0
    private var displayedFilesPerSecond: Int = 0
    private var lastRateSampleDate: Date?
    private var lastRateSampleFileCount: Int = 0

    init(maxTrackedDepth: Int = 9) {
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
            rootTreeNode.approximateSize = loadRootFilesystemTotalSize()
            seedApproximateTree()
            canonicalDirectoryPathByID = [:]
            visitedFileIDs = []
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
            emitProgress(currentSnapshot())
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

        if !markDirectoryVisited(path: task.url.path) {
            pruneDuplicateNode(task.representedNode)
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

        if task.depth == 0, task.url.path == "/" {
            processInitialTopLevelDirectories(childDirectories, rootTask: task)
            return
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

        // Push in reverse traversal order so pop() gives depth-first traversal.
        for childDirectory in orderedChildDirectories(for: task, from: childDirectories).reversed() {
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
    }

    private func pruneDuplicateNode(_ node: MutableTreeNode?) {
        guard let node, let parent = node.parent else {
            node?.isFullyScanned = true
            return
        }

        parent.children.removeValue(forKey: node.name)
    }

    private func processInitialTopLevelDirectories(_ childDirectories: [URL], rootTask: ScanTask) {
        if rootTask.representedNode != nil {
            pushTask(
                ScanTask(
                    kind: .finalize,
                    url: rootTask.url,
                    targetNode: rootTask.targetNode,
                    representedNode: rootTask.representedNode,
                    depth: rootTask.depth
                )
            )
        }

        let ordered = orderedChildDirectories(for: rootTask, from: childDirectories)
        let childTasks: [ScanTask] = ordered.map { childDirectory in
            let childNode = rootTask.targetNode.childNode(named: childDirectory.lastPathComponent)
            return ScanTask(
                kind: .scan,
                url: childDirectory,
                targetNode: childNode,
                representedNode: childNode,
                depth: 1
            )
        }

        guard !childTasks.isEmpty else { return }

        // Prioritize /Users, then fan out one thread per remaining top-level directory.
        processTask(childTasks[0])
        let remaining = Array(childTasks.dropFirst())
        if !remaining.isEmpty {
            DispatchQueue.concurrentPerform(iterations: remaining.count) { index in
                processTask(remaining[index])
            }
        }
    }

    private func orderedChildDirectories(for task: ScanTask, from directories: [URL]) -> [URL] {
        let sorted = directories.sorted { isPathPreferred($0.path, over: $1.path) }

        // Prioritize /Users early in the root traversal so user data appears quickly.
        if task.depth == 0, task.url.path == "/" {
            let users = sorted.filter { $0.lastPathComponent == "Users" }
            let others = sorted.filter { $0.lastPathComponent != "Users" }
            return users + others
        }

        return sorted
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
                        let size = attributes[.size] as? NSNumber,
                        markFileVisited(attributes: attributes)
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
                if values.isSymbolicLink == true {
                    continue
                }

                let isDirectory = values.isDirectory == true
                let isRegularFile = values.isRegularFile == true
                if !isDirectory, !isRegularFile {
                    continue
                }

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

    private func markDirectoryVisited(path: String) -> Bool {
        guard let identity = fileIdentity(path: path) else {
            return true
        }

        return scanStateLock.withLock {
            if let canonicalPath = canonicalDirectoryPathByID[identity] {
                return canonicalPath == path
            }

            canonicalDirectoryPathByID[identity] = path
            return true
        }
    }

    private func isPathPreferred(_ lhs: String, over rhs: String) -> Bool {
        let lhsInUsers = lhs.hasPrefix("/Users/") || lhs == "/Users"
        let rhsInUsers = rhs.hasPrefix("/Users/") || rhs == "/Users"
        if lhsInUsers != rhsInUsers {
            return lhsInUsers
        }

        let lhsInData = isDataAliasPath(lhs)
        let rhsInData = isDataAliasPath(rhs)
        if lhsInData != rhsInData {
            return !lhsInData
        }

        if lhs.count != rhs.count {
            return lhs.count < rhs.count
        }

        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private func isDataAliasPath(_ path: String) -> Bool {
        path.hasPrefix("/System/Volumes/Data/") || path.hasPrefix("/Data/") || path == "/Data"
    }

    private func markFileVisited(attributes: [FileAttributeKey: Any]) -> Bool {
        guard let identity = fileIdentity(attributes: attributes) else {
            return true
        }

        return scanStateLock.withLock {
            visitedFileIDs.insert(identity).inserted
        }
    }

    private func fileIdentity(path: String) -> FileIdentity? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return fileIdentity(attributes: attributes)
        } catch {
            return nil
        }
    }

    private func fileIdentity(attributes: [FileAttributeKey: Any]) -> FileIdentity? {
        guard
            let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        else {
            return nil
        }

        return FileIdentity(deviceID: systemNumber, inode: fileNumber)
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

    private func seedApproximateTree() {
        var queue: [(node: MutableTreeNode, url: URL, depth: Int)] = [
            (node: rootTreeNode, url: URL(fileURLWithPath: "/", isDirectory: true), depth: 0),
        ]

        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1

            if current.depth >= approximateSeedDepth {
                continue
            }

            let childDirectories = listDirectoryEntries(at: current.url)
                .filter(\.isDirectory)
                .sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
                .prefix(approximateSeedMaxChildrenPerParent)

            guard !childDirectories.isEmpty else { continue }

            let parentEstimate = effectiveSize(for: current.node)
            guard parentEstimate > 0 else { continue }

            let share = max(1, parentEstimate / UInt64(childDirectories.count))
            for childDirectory in childDirectories {
                let childNode = current.node.childNode(named: childDirectory.url.lastPathComponent)
                childNode.approximateSize = max(childNode.approximateSize ?? 0, share)
                queue.append((node: childNode, url: childDirectory.url, depth: current.depth + 1))
            }
        }
    }

    private func loadRootFilesystemTotalSize() -> UInt64 {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
            if let total = (attributes[.systemSize] as? NSNumber)?.uint64Value, total > 0 {
                return total
            }
        } catch {
            return 1
        }

        return 1
    }

    private func effectiveSize(for node: MutableTreeNode) -> UInt64 {
        if node.isFullyScanned {
            return node.size
        }
        return max(node.size, node.approximateSize ?? 0)
    }

    private func buildIcicleNodesLocked() -> [IcicleNode] {
        let topNodes = sortedChildren(of: rootTreeNode)
        guard !topNodes.isEmpty else { return [] }

        let maxDepth = maxDisplayDepth(topNodes: topNodes)
        return topNodes.map { buildIcicleNode(from: $0, currentDepth: 1, maxDepth: maxDepth) }
    }

    private func maxDisplayDepth(topNodes: [MutableTreeNode]) -> Int {
        let scannedTotal = effectiveSize(for: rootTreeNode)
        guard scannedTotal > 0 else {
            return 2
        }

        let threshold = UInt64(Double(scannedTotal) * depthCutoffPercent)
        var depth = 1
        var currentRow = topNodes

        while !currentRow.isEmpty {
            if currentRow.allSatisfy({ effectiveSize(for: $0) < threshold }) {
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

        return IcicleNode(
            name: node.name,
            path: node.path,
            size: effectiveSize(for: node),
            isFullyScanned: node.isFullyScanned,
            children: children
        )
    }

    private func sortedChildren(of node: MutableTreeNode) -> [MutableTreeNode] {
        node.children.values
            .filter { effectiveSize(for: $0) > 0 }
            .sorted {
                let lhsSize = effectiveSize(for: $0)
                let rhsSize = effectiveSize(for: $1)
                if lhsSize == rhsSize {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return lhsSize > rhsSize
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

private struct FileIdentity: Hashable {
    let deviceID: UInt64
    let inode: UInt64
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
    var approximateSize: UInt64?
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
