//
//  SensorsModule.swift
//  TNV Support
//
//  Temperature & fans module: a menu bar readout of CPU temperature and/or
//  fan speed, with a menu listing every group and fan. Read-only - it never
//  changes fan behaviour.
//

import AppKit

final class SensorsModule: NSObject, AppModule, NSMenuDelegate {

    private enum MenuBarDisplay: String, CaseIterable {
        case temperature
        case fan
        case both
        case iconOnly

        var title: String {
            switch self {
            case .temperature: return "CPU temperature"
            case .fan: return "Fan speed"
            case .both: return "CPU temperature and fan speed"
            case .iconOnly: return "Icon only"
            }
        }
    }

    private weak var context: ModuleContext?
    private var statusItem: NSStatusItem?
    private let reader = SensorReader()
    private var poller: Timer?
    private var snapshot: SensorSnapshot?
    /// Menu rows whose titles follow the latest snapshot while the menu is open.
    private var liveRows: [(item: NSMenuItem, title: (SensorSnapshot) -> String)] = []

    private let pollInterval: TimeInterval = 3
    private let displayDefaultsKey = "sensors.menuBarDisplay"

    #if arch(arm64)
    private let appleSilicon = true
    #else
    private let appleSilicon = false
    #endif

    private var display: MenuBarDisplay {
        get {
            UserDefaults.standard.string(forKey: displayDefaultsKey)
                .flatMap(MenuBarDisplay.init(rawValue:)) ?? .temperature
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: displayDefaultsKey) }
    }

    // MARK: - AppModule

    func start(context: ModuleContext) {
        self.context = context

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self
        // Readout rows have no action but should not render greyed out.
        menu.autoenablesItems = false
        item.menu = menu

        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        refreshStatusItem()

        poll()
        let poller = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Common modes so readings keep updating while a menu is open.
        RunLoop.main.add(poller, forMode: .common)
        self.poller = poller
    }

    func stop(completion: @escaping () -> Void) {
        poller?.invalidate()
        poller = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        completion()
    }

    // MARK: - Sampling

    private func poll() {
        reader.read { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    private func apply(_ snapshot: SensorSnapshot) {
        guard statusItem != nil else { return }
        self.snapshot = snapshot
        refreshStatusItem()
        for row in liveRows {
            row.item.title = row.title(snapshot)
        }
    }

    private var cpuSummary: GroupSummary? {
        guard let snapshot else { return nil }
        return SensorCatalog.summarize(snapshot.temperatures, appleSilicon: appleSilicon)[.cpu]
    }

    // MARK: - Status item rendering

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }

        let symbol = display == .fan ? "fan" : "thermometer.medium"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Temperature and fans")
        image?.isTemplate = true
        button.image = image

        let temperature = cpuSummary.map { formatTemperature($0.average, unit: false) } ?? "--°"
        let fan = fastestFan.map { "\(formatRPM($0.rpm)) rpm" } ?? "--"

        switch display {
        case .temperature: button.title = " \(temperature)"
        case .fan: button.title = " \(fan)"
        case .both: button.title = " \(temperature) · \(fan)"
        case .iconOnly: button.title = ""
        }

        var tooltip: [String] = []
        if let cpu = cpuSummary { tooltip.append("CPU \(formatTemperature(cpu.average))") }
        if let fan = fastestFan { tooltip.append("Fan \(formatRPM(fan.rpm)) rpm") }
        button.toolTip = tooltip.isEmpty ? "Temperature & Fans" : tooltip.joined(separator: " · ")
    }

    private var fastestFan: FanReading? {
        snapshot?.fans.max { $0.rpm < $1.rpm }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        liveRows.removeAll()

        if let snapshot {
            addReadings(snapshot, to: menu)
        } else {
            menu.addItem(disabledItem("Reading sensors…"))
        }

        menu.addItem(.separator())
        menu.addItem(displaySubmenuItem())

        for item in context?.appMenuItems() ?? [] {
            menu.addItem(item)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        liveRows.removeAll()
    }

    private func addReadings(_ snapshot: SensorSnapshot, to menu: NSMenu) {
        guard snapshot.isAvailable else {
            menu.addItem(disabledItem("Sensors are unavailable on this Mac"))
            return
        }

        menu.addItem(disabledItem("Temperature"))
        let summaries = SensorCatalog.summarize(snapshot.temperatures, appleSilicon: appleSilicon)
        let groups = SensorGroup.allCases.filter { $0 != .other && summaries[$0] != nil }
        if groups.isEmpty {
            menu.addItem(disabledItem("No temperature sensors found"))
        }
        for group in groups {
            addLiveRow(to: menu) { [weak self] snapshot in
                guard let self else { return "" }
                let summary = SensorCatalog.summarize(snapshot.temperatures, appleSilicon: self.appleSilicon)[group]
                return self.temperatureRowTitle(group, summary)
            }
        }

        menu.addItem(.separator())
        menu.addItem(disabledItem("Fans"))
        if snapshot.fans.isEmpty {
            menu.addItem(disabledItem("No fans detected"))
        }
        for fan in snapshot.fans {
            let index = fan.index
            addLiveRow(to: menu) { [weak self] snapshot in
                guard let self else { return "" }
                return self.fanRowTitle(index, snapshot.fans.first { $0.index == index })
            }
        }

        if !snapshot.temperatures.isEmpty {
            menu.addItem(.separator())
            menu.addItem(allSensorsSubmenuItem(snapshot))
        }
    }

    private func addLiveRow(to menu: NSMenu, title: @escaping (SensorSnapshot) -> String) {
        guard let snapshot else { return }
        let item = NSMenuItem(title: title(snapshot), action: nil, keyEquivalent: "")
        item.indentationLevel = 1
        menu.addItem(item)
        liveRows.append((item, title))
    }

    private func temperatureRowTitle(_ group: SensorGroup, _ summary: GroupSummary?) -> String {
        guard let summary else { return "\(group.title): --" }
        let average = formatTemperature(summary.average)
        guard summary.sensorCount > 1 else { return "\(group.title): \(average)" }
        return "\(group.title): \(average)   (max \(formatTemperature(summary.maximum)))"
    }

    private func fanRowTitle(_ index: Int, _ fan: FanReading?) -> String {
        let name = "Fan \(index + 1)"
        guard let fan else { return "\(name): --" }
        var title = "\(name): \(formatRPM(fan.rpm)) rpm"
        if let minRPM = fan.minRPM, let maxRPM = fan.maxRPM, maxRPM > 0 {
            title += "   (\(formatRPM(minRPM))–\(formatRPM(maxRPM)))"
        }
        return title
    }

    /// Raw readings by SMC key, for checking what this Mac exposes.
    private func allSensorsSubmenuItem(_ snapshot: SensorSnapshot) -> NSMenuItem {
        let parent = NSMenuItem(title: "All sensors", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for reading in snapshot.temperatures {
            let group = SensorCatalog.group(forKey: reading.key, appleSilicon: appleSilicon)
            submenu.addItem(NSMenuItem(title: "\(reading.key)  \(formatTemperature(reading.celsius))  \(group.title)",
                                       action: nil, keyEquivalent: ""))
        }
        parent.submenu = submenu
        return parent
    }

    private func displaySubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Show in menu bar", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = display
        for (index, option) in MenuBarDisplay.allCases.enumerated() {
            let item = NSMenuItem(title: option.title, action: #selector(menuSetDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = (option == current) ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func menuSetDisplay(_ sender: NSMenuItem) {
        let options = MenuBarDisplay.allCases
        guard options.indices.contains(sender.tag) else { return }
        display = options[sender.tag]
        refreshStatusItem()
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Formatting

    private func formatTemperature(_ celsius: Double, unit: Bool = true) -> String {
        "\(Int(celsius.rounded()))°\(unit ? "C" : "")"
    }

    private func formatRPM(_ rpm: Double) -> String {
        String(Int(rpm.rounded()))
    }
}
