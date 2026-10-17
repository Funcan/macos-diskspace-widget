import AppKit
import Foundation

enum Preferences {
    private static let refreshIntervalKey = "refreshIntervalSeconds"
    static let defaultRefreshInterval: TimeInterval = 5 * 60

    static var refreshInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: refreshIntervalKey)
            return value > 0 ? value : defaultRefreshInterval
        }
        set {
            UserDefaults.standard.set(newValue, forKey: refreshIntervalKey)
        }
    }
}

final class PreferencesViewController: NSViewController {
    private static let refreshOptions: [(title: String, seconds: TimeInterval)] = [
        ("1 minute", 60),
        ("5 minutes", 5 * 60),
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour", 60 * 60),
    ]

    var onChange: (() -> Void)?

    private let refreshPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))

        let label = NSTextField(labelWithString: "Refresh every:")
        label.translatesAutoresizingMaskIntoConstraints = false

        refreshPopUp.addItems(withTitles: Self.refreshOptions.map(\.title))
        let current = Preferences.refreshInterval
        if let index = Self.refreshOptions.firstIndex(where: { $0.seconds == current }) {
            refreshPopUp.selectItem(at: index)
        } else {
            refreshPopUp.addItem(withTitle: "\(Int(current)) seconds")
            refreshPopUp.selectItem(at: refreshPopUp.numberOfItems - 1)
        }
        refreshPopUp.target = self
        refreshPopUp.action = #selector(refreshIntervalChanged)
        refreshPopUp.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        view.addSubview(refreshPopUp)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            refreshPopUp.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            refreshPopUp.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            refreshPopUp.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func refreshIntervalChanged() {
        let index = refreshPopUp.indexOfSelectedItem
        guard Self.refreshOptions.indices.contains(index) else { return }
        Preferences.refreshInterval = Self.refreshOptions[index].seconds
        onChange?()
    }
}
