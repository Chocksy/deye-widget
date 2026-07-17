import AppKit
import SwiftUI
import Combine

/// Menu bar item: shows SOC and a snapshot menu.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let poller: DataPoller
    private let settings: Settings
    private var cancellables = Set<AnyCancellable>()

    private var settingsWindow: NSWindow?
    private var sizeItems: [SizePreset: NSMenuItem] = [:]
    private var displayItems: [DisplayMode: NSMenuItem] = [:]

    // Menu items whose titles we update each poll.
    private let loadItem = NSMenuItem(title: "Load: —", action: nil, keyEquivalent: "")
    private let solarItem = NSMenuItem(title: "PV+MI: —", action: nil, keyEquivalent: "")
    private let gridItem = NSMenuItem(title: "Grid: —", action: nil, keyEquivalent: "")
    private let batteryItem = NSMenuItem(title: "Battery: —", action: nil, keyEquivalent: "")

    init(poller: DataPoller, settings: Settings) {
        self.poller = poller
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.attributedTitle = Self.title(soc: nil)
        }

        buildMenu()

        // React to every poll update.
        poller.$data
            .combineLatest(poller.$connected)
            .sink { [weak self] _, _ in self?.refreshUI() }
            .store(in: &cancellables)

        // Keep the Size preset checkmarks in sync when the scale changes (menu
        // or the Settings slider).
        settings.$scale
            .sink { [weak self] s in self?.refreshSizeChecks(scale: s) }
            .store(in: &cancellables)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(loadItem)
        menu.addItem(solarItem)
        menu.addItem(gridItem)
        menu.addItem(batteryItem)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        // Display submenu (Flow / Flow + Chart / Dashboard).
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (settings.displayMode == mode) ? .on : .off
            displayMenu.addItem(item)
            displayItems[mode] = item
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        // Size submenu — presets are shortcuts that set the free scale.
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for preset in SizePreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            sizeMenu.addItem(item)
            sizeItems[preset] = item
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        refreshSizeChecks(scale: settings.scale)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Build a menu-bar title: a `bolt.fill` SF Symbol + SOC, e.g. "⚡︎ 95 %".
    static func title(soc: Int?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        if let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "power")?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            attachment.image = img
        }
        result.append(NSAttributedString(attachment: attachment))
        let text = soc.map { " \($0)%" } ?? " --"
        result.append(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)]
        ))
        return result
    }

    private func refreshUI() {
        let d = poller.data
        if let button = statusItem.button {
            button.attributedTitle = Self.title(soc: poller.connected ? d.soc : nil)
        }
        loadItem.title = String(format: "Load: %d W", d.loadPower)
        solarItem.title = String(format: "PV+MI: %d W", d.solarTotal)
        let gridDir = d.gridImporting ? "import" : (d.gridExporting ? "export" : "idle")
        gridItem.title = String(format: "Grid: %d W (%@)", abs(d.gridPower), gridDir)
        let battDir = d.batteryCharging ? "charge" : (d.batteryDischarging ? "discharge" : "idle")
        batteryItem.title = String(format: "Battery: %d%%  %d W (%@)", d.soc, abs(d.batteryPower), battDir)
    }

    @objc private func refreshNow() {
        poller.refreshNow()
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = SizePreset(rawValue: raw) else { return }
        settings.scale = Double(preset.scale)   // WidgetWindow applies live
    }

    /// Check the preset whose scale matches the current value (none if custom).
    private func refreshSizeChecks(scale: Double) {
        for (p, item) in sizeItems {
            item.state = abs(Double(p.scale) - scale) < 0.005 ? .on : .off
        }
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DisplayMode(rawValue: raw) else { return }
        settings.displayMode = mode             // WidgetWindow applies live
        for (m, item) in displayItems {
            item.state = (m == mode) ? .on : .off
        }
    }

    @objc private func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(settings: settings) { [weak self] in
            self?.settingsWindow?.close()
            self?.settingsWindow = nil
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "DeyeWidget Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
