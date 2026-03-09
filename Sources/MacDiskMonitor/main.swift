import AppKit
import Foundation

final class AnalysisViewController: NSViewController {
    private let canvasView = NSView()
    private let statusLabel = NSTextField(labelWithString: "Ready to scan")
    private let toggleButton = NSButton(title: "Start", target: nil, action: nil)
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
    private var isRunning = false {
        didSet {
            toggleButton.title = isRunning ? "Pause" : "Start"
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 680))

        // Placeholder drawing surface for the interactive results viewer.
        canvasView.wantsLayer = true
        canvasView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        canvasView.layer?.borderColor = NSColor.separatorColor.cgColor
        canvasView.layer?.borderWidth = 1
        canvasView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.alignment = .center
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.bezelStyle = .rounded
        toggleButton.setButtonType(.momentaryPushIn)
        toggleButton.target = self
        toggleButton.action = #selector(toggleAnalysis)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(canvasView)
        view.addSubview(statusLabel)
        view.addSubview(toggleButton)

        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            canvasView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -14),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: toggleButton.topAnchor, constant: -10),

            toggleButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            toggleButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 140),
            toggleButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @objc private func toggleAnalysis() {
        if !isRunning, !hasFullDiskAccess() {
            showFullDiskAccessInstructions()
            return
        }

        isRunning.toggle()

        if isRunning {
            markScanResumed()
            statusLabel.stringValue = makeStatus(prefix: "Scanning")
            startOrResumeScan()
        } else {
            markScanPaused()
            pauseScan()
        }
    }

    private func startOrResumeScan() {
        setScanRequested(true)

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

    private func pauseScan() {
        setScanRequested(false)
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

                let summary = makeStatus(prefix: "Scan complete")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    isRunning = false
                    statusLabel.stringValue = summary
                }
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
            scannedFiles += batchFiles
            scannedBytes += batchBytes

            processedSinceUpdate += batch.count
            if processedSinceUpdate >= 500 {
                processedSinceUpdate = 0
                let progress = makeStatus(prefix: "Scanning")
                DispatchQueue.main.async { [weak self] in
                    self?.statusLabel.stringValue = progress
                }
            }
        }

        setScanWorkerActive(false)
        let paused = makeStatus(prefix: "Paused", forceZeroRate: true)
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.stringValue = paused
        }
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

    private func elapsedScanDuration() -> TimeInterval {
        scanStateLock.withLock {
            let runningDuration: TimeInterval = if let startDate = scanActiveStartDate {
                Date().timeIntervalSince(startDate)
            } else {
                0
            }
            return accumulatedScanDuration + runningDuration
        }
    }

    private func makeStatus(prefix: String, forceZeroRate: Bool = false) -> String {
        let elapsed = elapsedScanDuration()
        let rate = sampledFilesPerSecond(forceZero: forceZeroRate)
        return "\(prefix): \(scannedFiles) files, \(formatBytes(scannedBytes)) | \(formatDuration(elapsed)) | \(rate) files/s"
    }

    private func sampledFilesPerSecond(forceZero: Bool) -> Int {
        scanStateLock.withLock {
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
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func hasFullDiskAccess() -> Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let probePaths = [
            "\(homeDir)/Library/Mail",
            "\(homeDir)/Library/Messages",
            "\(homeDir)/Library/Safari",
            "\(homeDir)/Library/Application Support/com.apple.TCC/TCC.db",
        ]

        for path in probePaths where FileManager.default.fileExists(atPath: path) {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path)

                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    _ = try FileManager.default.contentsOfDirectory(atPath: path)
                } else {
                    _ = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                }
            } catch {
                return false
            }
        }

        return true
    }

    private func showFullDiskAccessInstructions() {
        let executablePath = ProcessInfo.processInfo.arguments.first ?? "this app"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Full Disk Access Required"
        alert.informativeText = "Disk analysis needs Full Disk Access before it can scan protected locations.\n\n" +
            "To grant it:\n" +
            "1. Open System Settings > Privacy & Security > Full Disk Access\n" +
            "2. Add this executable if needed:\n\(executablePath)\n" +
            "3. Turn it on, then reopen this app and click Start again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

final class DiskMonitorApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var timer: Timer?
    private var analysisWindowController: NSWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        statusItem.button?.image = NSImage(
            systemSymbolName: "internaldrive",
            accessibilityDescription: "Disk usage"
        )
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleStatusItemClick)
        statusItem.button?.sendAction(on: [.rightMouseUp])

        statusMenu = NSMenu()
        statusMenu.addItem(NSMenuItem(title: "Analyse", action: #selector(showAnalysisWindow), keyEquivalent: ""))
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        updateStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    @objc private func handleStatusItemClick() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return }
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showAnalysisWindow() {
        if analysisWindowController == nil {
            let contentViewController = AnalysisViewController()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Disk Analysis"
            window.contentViewController = contentViewController
            analysisWindowController = NSWindowController(window: window)
        }

        analysisWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateStatus() {
        guard let button = statusItem.button else { return }

        do {
            let percentUsed = try diskUsagePercent(forPath: "/")
            let title = "\(percentUsed)%"
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: color(for: percentUsed),
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                ]
            )
        } catch {
            button.attributedTitle = NSAttributedString(
                string: "ERR",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                ]
            )
        }
    }

    private func diskUsagePercent(forPath path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
        guard
            let total = (attributes[.systemSize] as? NSNumber)?.doubleValue,
            let free = (attributes[.systemFreeSize] as? NSNumber)?.doubleValue,
            total > 0
        else {
            throw NSError(domain: "DiskMonitor", code: 1)
        }

        let used = total - free
        let percent = (used / total) * 100
        return Int(percent.rounded())
    }

    private func color(for percentUsed: Int) -> NSColor {
        if percentUsed >= 90 {
            return .systemRed
        }
        if percentUsed >= 80 {
            return .systemYellow
        }
        return .labelColor
    }
}

let app = NSApplication.shared
let delegate = DiskMonitorApp()
app.delegate = delegate
app.run()
