import Foundation

struct ScanSnapshot {
    let files: Int
    let bytes: UInt64
    let elapsed: TimeInterval
    let filesPerSecond: Int
}

final class FileSystemScanner {
    var onProgress: ((ScanSnapshot) -> Void)?
    var onPaused: ((ScanSnapshot) -> Void)?
    var onCompleted: ((ScanSnapshot) -> Void)?

    private let scanQueue = DispatchQueue(label: "MacDiskMonitor.AnalysisScan", qos: .utility)
    private let scanStateLock = NSLock()
    private let statWorkerCount = 8
    private let statBatchSize = 256

    private var scanRequested = false
    private var scanWorkerActive = false
    private var scanEnumerator: FileManager.DirectoryEnumerator?
    private var scannedFiles: Int = 0
    private var scannedBytes: UInt64 = 0
    private var scanActiveStartDate: Date?
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
            scannedFiles = 0
            scannedBytes = 0
            resetScanTiming()
            markScanResumed()
        }

        var processedSinceUpdate = 0

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

            let (batchFiles, batchBytes) = processBatch(batch)
            scanStateLock.withLock {
                scannedFiles += batchFiles
                scannedBytes += batchBytes
            }

            processedSinceUpdate += batch.count
            if processedSinceUpdate >= 500 {
                processedSinceUpdate = 0
                emitProgress(currentSnapshot())
            }
        }

        setScanWorkerActive(false)
        emitPaused(currentSnapshot(forceZeroRate: true))
    }

    private func processBatch(_ entries: [String]) -> (files: Int, bytes: UInt64) {
        let workers = min(statWorkerCount, max(1, entries.count))
        var fileCounts = Array(repeating: 0, count: workers)
        var byteCounts = Array(repeating: UInt64(0), count: workers)

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let fileManager = FileManager()
            var localFiles = 0
            var localBytes: UInt64 = 0
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
        return (totalFiles, totalBytes)
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
        return ScanSnapshot(files: scannedFiles, bytes: scannedBytes, elapsed: elapsed, filesPerSecond: rate)
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
