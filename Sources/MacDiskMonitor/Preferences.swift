import AppKit
import Foundation

enum Preferences {
    private static let refreshIntervalKey = "refreshIntervalSeconds"
    private static let warningPercentKey = "warningPercent"
    private static let errorPercentKey = "errorPercent"
    private static let priorityScanPathsKey = "priorityScanPaths"

    private static let defaults: [String: Any] = [
        refreshIntervalKey: 5 * 60.0,
        warningPercentKey: 80,
        errorPercentKey: 90,
        priorityScanPathsKey: [
            "/private/tmp",
            "~/Library/Containers/com.docker.docker",
            "~/Downloads",
            "~/Library/Logs/Homebrew",
            "~/Library/Caches/Homebrew",
        ],
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: defaults)
    }

    static func resetToDefaults() {
        for key in defaults.keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static var refreshInterval: TimeInterval {
        get { UserDefaults.standard.double(forKey: refreshIntervalKey) }
        set { UserDefaults.standard.set(newValue, forKey: refreshIntervalKey) }
    }

    static var warningPercent: Int {
        get { UserDefaults.standard.integer(forKey: warningPercentKey) }
        set { UserDefaults.standard.set(newValue, forKey: warningPercentKey) }
    }

    static var errorPercent: Int {
        get { UserDefaults.standard.integer(forKey: errorPercentKey) }
        set { UserDefaults.standard.set(newValue, forKey: errorPercentKey) }
    }

    static var priorityScanPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: priorityScanPathsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: priorityScanPathsKey) }
    }
}

final class PreferencesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let refreshOptions: [(title: String, seconds: TimeInterval)] = [
        ("1 minute", 60),
        ("5 minutes", 5 * 60),
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour", 60 * 60),
    ]

    var onChange: (() -> Void)?

    private let refreshPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let warningField = NSTextField()
    private let warningStepper = NSStepper()
    private let errorField = NSTextField()
    private let errorStepper = NSStepper()
    private let pathsTable = NSTableView()
    private let pathsButtons = NSSegmentedControl(
        images: [NSImage(named: NSImage.addTemplateName)!, NSImage(named: NSImage.removeTemplateName)!],
        trackingMode: .momentary,
        target: nil,
        action: nil
    )
    private var paths: [String] = []

    override func loadView() {
        refreshPopUp.target = self
        refreshPopUp.action = #selector(refreshIntervalChanged)

        configurePercentControls(field: warningField, stepper: warningStepper)
        configurePercentControls(field: errorField, stepper: errorStepper)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.resizingMask = .autoresizingMask
        pathsTable.addTableColumn(column)
        pathsTable.headerView = nil
        pathsTable.usesAlternatingRowBackgroundColors = true
        pathsTable.dataSource = self
        pathsTable.delegate = self

        let pathsScrollView = NSScrollView()
        pathsScrollView.documentView = pathsTable
        pathsScrollView.hasVerticalScroller = true
        pathsScrollView.borderType = .bezelBorder
        pathsScrollView.translatesAutoresizingMaskIntoConstraints = false

        pathsButtons.target = self
        pathsButtons.action = #selector(pathsButtonClicked)
        pathsButtons.translatesAutoresizingMaskIntoConstraints = false

        let pathsLabel = NSTextField(labelWithString: "Analyse these folders first:")
        pathsLabel.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))
        let restartButton = NSButton(title: "Restart", target: self, action: #selector(restart))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Refresh every:"), refreshPopUp],
            [NSTextField(labelWithString: "Warning percentage:"), percentRow(field: warningField, stepper: warningStepper)],
            [NSTextField(labelWithString: "Error percentage:"), percentRow(field: errorField, stepper: errorStepper)],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        resetButton.translatesAutoresizingMaskIntoConstraints = false
        restartButton.translatesAutoresizingMaskIntoConstraints = false

        view = NSView()
        view.addSubview(grid)
        view.addSubview(pathsLabel)
        view.addSubview(pathsScrollView)
        view.addSubview(pathsButtons)
        view.addSubview(resetButton)
        view.addSubview(restartButton)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            pathsLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            pathsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            pathsScrollView.topAnchor.constraint(equalTo: pathsLabel.bottomAnchor, constant: 6),
            pathsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            pathsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            pathsScrollView.heightAnchor.constraint(equalToConstant: 140),

            pathsButtons.topAnchor.constraint(equalTo: pathsScrollView.bottomAnchor, constant: 6),
            pathsButtons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            resetButton.topAnchor.constraint(equalTo: pathsButtons.bottomAnchor, constant: 20),
            resetButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            resetButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            restartButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            restartButton.centerYAnchor.constraint(equalTo: resetButton.centerYAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
        ])

        loadValues()
    }

    private func configurePercentControls(field: NSTextField, stepper: NSStepper) {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 100
        field.formatter = formatter
        field.alignment = .right
        field.target = self
        field.action = #selector(percentFieldChanged)
        field.widthAnchor.constraint(equalToConstant: 50).isActive = true

        stepper.minValue = 1
        stepper.maxValue = 100
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(percentStepperChanged)
    }

    private func percentRow(field: NSTextField, stepper: NSStepper) -> NSView {
        let row = NSStackView(views: [field, stepper, NSTextField(labelWithString: "%")])
        row.spacing = 4
        return row
    }

    private func loadValues() {
        refreshPopUp.removeAllItems()
        refreshPopUp.addItems(withTitles: Self.refreshOptions.map(\.title))
        let current = Preferences.refreshInterval
        if let index = Self.refreshOptions.firstIndex(where: { $0.seconds == current }) {
            refreshPopUp.selectItem(at: index)
        } else {
            refreshPopUp.addItem(withTitle: "\(Int(current)) seconds")
            refreshPopUp.selectItem(at: refreshPopUp.numberOfItems - 1)
        }

        warningField.integerValue = Preferences.warningPercent
        warningStepper.integerValue = Preferences.warningPercent
        errorField.integerValue = Preferences.errorPercent
        errorStepper.integerValue = Preferences.errorPercent

        paths = Preferences.priorityScanPaths
        pathsTable.reloadData()
    }

    func numberOfRows(in _: NSTableView) -> Int {
        paths.count
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(string: paths[row])
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingMiddle
        field.target = self
        field.action = #selector(pathEdited)
        return field
    }

    @objc private func pathEdited(_ sender: NSTextField) {
        let row = pathsTable.row(for: sender)
        guard paths.indices.contains(row) else { return }
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            paths.remove(at: row)
            pathsTable.reloadData()
        } else {
            paths[row] = value
        }
        Preferences.priorityScanPaths = paths
    }

    @objc private func pathsButtonClicked() {
        if pathsButtons.selectedSegment == 0 {
            addPath()
        } else {
            removeSelectedPath()
        }
    }

    private func addPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return }

        paths += panel.urls.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        Preferences.priorityScanPaths = paths
        pathsTable.reloadData()
    }

    private func removeSelectedPath() {
        let row = pathsTable.selectedRow
        guard paths.indices.contains(row) else { return }
        paths.remove(at: row)
        Preferences.priorityScanPaths = paths
        pathsTable.reloadData()
    }

    @objc private func refreshIntervalChanged() {
        let index = refreshPopUp.indexOfSelectedItem
        guard Self.refreshOptions.indices.contains(index) else { return }
        Preferences.refreshInterval = Self.refreshOptions[index].seconds
        onChange?()
    }

    @objc private func percentFieldChanged(_ sender: NSTextField) {
        savePercent(sender.integerValue, isWarning: sender === warningField)
    }

    @objc private func percentStepperChanged(_ sender: NSStepper) {
        savePercent(sender.integerValue, isWarning: sender === warningStepper)
    }

    private func savePercent(_ value: Int, isWarning: Bool) {
        if isWarning {
            Preferences.warningPercent = value
            warningField.integerValue = value
            warningStepper.integerValue = value
            if value > Preferences.errorPercent {
                Preferences.errorPercent = value
                errorField.integerValue = value
                errorStepper.integerValue = value
            }
        } else {
            Preferences.errorPercent = value
            errorField.integerValue = value
            errorStepper.integerValue = value
            if value < Preferences.warningPercent {
                Preferences.warningPercent = value
                warningField.integerValue = value
                warningStepper.integerValue = value
            }
        }
        onChange?()
    }

    @objc private func resetToDefaults() {
        Preferences.resetToDefaults()
        loadValues()
        onChange?()
    }

    /// Relaunches the current executable so a freshly installed binary or newly
    /// granted Full Disk Access takes effect. The helper shell waits for this
    /// process to exit before exec'ing, and runs in its own session (SETSID) so
    /// launchd doesn't kill it along with our process group when we terminate.
    @objc private func restart() {
        guard let executablePath = Bundle.main.executablePath else { return }

        let args = ["/bin/sh", "-c", "sleep 1; exec \"$0\"", executablePath]
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", nil, &attr, argv, environ)
        guard result == 0 else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Restart Failed"
            alert.informativeText = String(cString: strerror(result))
            alert.runModal()
            return
        }

        NSApp.terminate(nil)
    }
}
