import AppKit
import Foundation

final class DiskMonitorApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        statusItem.button?.image = NSImage(
            systemSymbolName: "internaldrive",
            accessibilityDescription: "Disk usage"
        )
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        updateStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
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
