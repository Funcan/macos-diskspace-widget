import AppKit
import Foundation

final class AnalysisViewController: NSViewController {
    private enum ScanPhase {
        case notStarted
        case running
        case paused
        case completed
    }

    private let canvasView = FilesystemIcicleView()
    private let statusLabel = NSTextField(labelWithString: "Ready to scan")
    private let toggleButton = NSButton(title: "Start", target: nil, action: nil)
    private let scanner = FileSystemScanner()
    private var scanPhase: ScanPhase = .notStarted {
        didSet {
            toggleButton.title = buttonTitle(for: scanPhase)
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 680))

        canvasView.wantsLayer = true
        canvasView.layer?.borderColor = NSColor.separatorColor.cgColor
        canvasView.layer?.borderWidth = 1
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.rootNodes = demoIcicleData()

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

        scanner.onProgress = { [weak self] snapshot in
            self?.scanPhase = .running
            self?.canvasView.rootNodes = snapshot.icicleNodes
            self?.statusLabel.stringValue = self?.makeStatus(prefix: "Scanning", snapshot: snapshot) ?? ""
        }
        scanner.onPaused = { [weak self] snapshot in
            self?.scanPhase = .paused
            self?.canvasView.rootNodes = snapshot.icicleNodes
            self?.statusLabel.stringValue = self?.makeStatus(prefix: "Paused", snapshot: snapshot) ?? ""
        }
        scanner.onCompleted = { [weak self] snapshot in
            guard let self else { return }
            scanPhase = .completed
            canvasView.rootNodes = snapshot.icicleNodes
            statusLabel.stringValue = makeStatus(prefix: "Scan complete", snapshot: snapshot)
        }
    }

    @objc private func toggleAnalysis() {
        if scanPhase == .running {
            scanner.pause()
            scanPhase = .paused
            return
        }

        if !hasFullDiskAccess() {
            showFullDiskAccessInstructions()
            return
        }

        scanner.startOrResume()
        scanPhase = .running
        let snapshot = scanner.currentSnapshot()
        canvasView.rootNodes = snapshot.icicleNodes
        statusLabel.stringValue = makeStatus(prefix: "Scanning", snapshot: snapshot)
    }

    private func buttonTitle(for phase: ScanPhase) -> String {
        switch phase {
        case .notStarted:
            "Start"
        case .running:
            "Pause"
        case .paused:
            "Resume"
        case .completed:
            "Rescan"
        }
    }

    private func makeStatus(prefix: String, snapshot: ScanSnapshot) -> String {
        "\(prefix): \(snapshot.files) files, \(formatBytes(snapshot.bytes)) | \(formatDuration(snapshot.elapsed)) | \(snapshot.filesPerSecond) files/s"
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

    private func demoIcicleData() -> [IcicleNode] {
        let rootSize = initialRootFilesystemSize()

        return [
            IcicleNode(
                name: "/",
                path: "/",
                size: rootSize,
                isFullyScanned: false,
                children: []
            ),
        ]
    }

    private func initialRootFilesystemSize() -> UInt64 {
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
