import AppKit
import Foundation

enum Preferences {
    private static let refreshIntervalKey = "refreshIntervalSeconds"
    private static let warningPercentKey = "warningPercent"
    private static let errorPercentKey = "errorPercent"

    private static let defaults: [String: Any] = [
        refreshIntervalKey: 5 * 60.0,
        warningPercentKey: 80,
        errorPercentKey: 90,
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
    private let warningField = NSTextField()
    private let warningStepper = NSStepper()
    private let errorField = NSTextField()
    private let errorStepper = NSStepper()

    override func loadView() {
        refreshPopUp.target = self
        refreshPopUp.action = #selector(refreshIntervalChanged)

        configurePercentControls(field: warningField, stepper: warningStepper)
        configurePercentControls(field: errorField, stepper: errorStepper)

        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))

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

        view = NSView()
        view.addSubview(grid)
        view.addSubview(resetButton)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            resetButton.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            resetButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            resetButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
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
}
