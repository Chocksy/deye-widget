import Foundation
import SwiftUI

/// App version info, read from the bundle Info.plist. Falls back to "dev" when
/// running the bare SPM binary (no bundle).
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
    /// e.g. "1.1.0 (1)" or "dev".
    static var display: String {
        version == "dev" ? "dev" : "\(version) (\(build))"
    }
}

/// Widget size presets. Medium is the native design at scale 1.0.
enum SizePreset: String, CaseIterable {
    case small, medium, large

    var scale: CGFloat {
        switch self {
        case .small: return 0.72
        case .medium: return 1.0
        case .large: return 1.15
        }
    }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// Widget display mode. Flow is the compact 440-wide graph; Flow + Chart adds
/// the Power Profile pane; Dashboard shows big-number cards. Chart and Dashboard
/// are both 770 wide.
enum DisplayMode: String, CaseIterable {
    case flow, flowChart, dashboard

    var title: String {
        switch self {
        case .flow: return "Flow"
        case .flowChart: return "Flow + Chart"
        case .dashboard: return "Dashboard"
        }
    }

    var isWide: Bool { self != .flow }
}

/// UserDefaults-backed configuration with hardcoded fallbacks matching the
/// verified live logger.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let host = "host"
        static let port = "port"
        static let loggerSerial = "loggerSerial"
        static let loggerMAC = "loggerMAC"
        static let slaveId = "slaveId"
        static let pollInterval = "pollInterval"
        static let sizePreset = "sizePreset"    // legacy (migrated to scale)
        static let scale = "scale"
        static let showChart = "showChart"      // legacy (migrated to displayMode)
        static let displayMode = "displayMode"
        static let pinnedScreen = "pinnedScreen"
        static let pinnedDisplayID = "pinnedDisplayID"
        static let pinnedRelX = "pinnedRelX"
        static let pinnedRelY = "pinnedRelY"
    }

    /// Allowed free-scale range (60%–130%).
    static let scaleRange: ClosedRange<Double> = 0.6...1.3

    @Published var host: String {
        didSet { defaults.set(host, forKey: Keys.host) }
    }
    @Published var port: UInt16 {
        didSet { defaults.set(Int(port), forKey: Keys.port) }
    }
    @Published var loggerSerial: UInt32 {
        didSet { defaults.set(Int(loggerSerial), forKey: Keys.loggerSerial) }
    }
    /// Logger's WiFi-stick MAC, used to recognise it in a Solarman broadcast
    /// reply when its IP changes. Auto-populated on any successful broadcast
    /// discovery; seeded with the known stick's MAC.
    @Published var loggerMAC: String {
        didSet { defaults.set(loggerMAC, forKey: Keys.loggerMAC) }
    }
    @Published var slaveId: UInt8 {
        didSet { defaults.set(Int(slaveId), forKey: Keys.slaveId) }
    }
    @Published var pollInterval: Double {
        didSet { defaults.set(pollInterval, forKey: Keys.pollInterval) }
    }
    /// Free scale multiplier (raw, 0.6–1.3). Size-menu presets are shortcuts
    /// that set this; the Settings slider sets it directly. Live-applied.
    @Published var scale: Double {
        didSet {
            let clamped = min(max(scale, Settings.scaleRange.lowerBound), Settings.scaleRange.upperBound)
            if clamped != scale { scale = clamped; return }
            defaults.set(scale, forKey: Keys.scale)
        }
    }
    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }

    /// Pin-to-display. Empty name = free (unpinned). The window is kept on the
    /// screen with this localizedName; `pinnedDisplayID` is a secondary hint used
    /// only if the name no longer matches. `pinnedRelX/Y` are the window origin
    /// normalised within the screen's placeable area (0 = flush left/bottom,
    /// 1 = flush right/top, 0.5 = centered) so the position survives resolution
    /// changes and is independent of the window's own size.
    @Published var pinnedScreenName: String {
        didSet { defaults.set(pinnedScreenName, forKey: Keys.pinnedScreen) }
    }
    var pinnedDisplayID: Int {
        didSet { defaults.set(pinnedDisplayID, forKey: Keys.pinnedDisplayID) }
    }
    var pinnedRelX: Double {
        didSet { defaults.set(pinnedRelX, forKey: Keys.pinnedRelX) }
    }
    var pinnedRelY: Double {
        didSet { defaults.set(pinnedRelY, forKey: Keys.pinnedRelY) }
    }

    /// Whether the logger connection is configured. Until the user sets a host
    /// and logger serial (defaults are empty), the widget stays idle instead of
    /// hammering a wrong address.
    var isConfigured: Bool { !host.isEmpty && loggerSerial != 0 }

    private init() {
        // Bare-executable builds stored config under the "DeyeWidget" domain; the
        // .app bundle uses com.chocksy.deyewidget. Copy connection settings across
        // once so an existing install keeps working after upgrading to the bundle.
        Self.migrateLegacyDefaultsIfNeeded()

        // Neutral defaults — the user provides host + logger serial via Settings.
        host = defaults.string(forKey: Keys.host) ?? ""
        let p = defaults.integer(forKey: Keys.port)
        port = p > 0 ? UInt16(p) : 8899
        let s = defaults.object(forKey: Keys.loggerSerial) as? Int
        loggerSerial = s.map { UInt32($0) } ?? 0
        loggerMAC = defaults.string(forKey: Keys.loggerMAC) ?? "74:E9:D8:75:37:D6"
        let sl = defaults.integer(forKey: Keys.slaveId)
        slaveId = sl > 0 ? UInt8(sl) : 1
        let pi = defaults.double(forKey: Keys.pollInterval)
        pollInterval = pi > 0 ? pi : 5.0
        // Free scale: use the raw value if present, else migrate the legacy size
        // preset, else default to 100%.
        if defaults.object(forKey: Keys.scale) != nil {
            let raw = defaults.double(forKey: Keys.scale)
            scale = min(max(raw, Settings.scaleRange.lowerBound), Settings.scaleRange.upperBound)
        } else if let sp = (defaults.string(forKey: Keys.sizePreset)).flatMap({ SizePreset(rawValue: $0) }) {
            scale = Double(sp.scale)
        } else {
            scale = 1.0
        }
        // Migrate the old boolean showChart into the new three-way displayMode.
        if let raw = defaults.string(forKey: Keys.displayMode), let m = DisplayMode(rawValue: raw) {
            displayMode = m
        } else if let legacy = defaults.object(forKey: Keys.showChart) as? Bool {
            displayMode = legacy ? .flowChart : .flow
        } else {
            displayMode = .flowChart
        }
        pinnedScreenName = defaults.string(forKey: Keys.pinnedScreen) ?? ""
        pinnedDisplayID = defaults.integer(forKey: Keys.pinnedDisplayID)
        pinnedRelX = defaults.object(forKey: Keys.pinnedRelX) as? Double ?? 1.0
        pinnedRelY = defaults.object(forKey: Keys.pinnedRelY) as? Double ?? 0.5
    }

    /// One-time copy of settings from the legacy "DeyeWidget" defaults domain
    /// (used by the bare executable) into the current domain. No-op when the
    /// current domain is already configured, when no legacy config exists, or
    /// when running as the bare executable (legacy == current domain).
    private static func migrateLegacyDefaultsIfNeeded() {
        let std = UserDefaults.standard
        if !(std.string(forKey: Keys.host) ?? "").isEmpty { return }
        guard let legacy = UserDefaults(suiteName: "DeyeWidget"),
              let legacyHost = legacy.string(forKey: Keys.host), !legacyHost.isEmpty else { return }

        std.set(legacyHost, forKey: Keys.host)
        if let s = legacy.object(forKey: Keys.loggerSerial) as? Int { std.set(s, forKey: Keys.loggerSerial) }
        if let mac = legacy.string(forKey: Keys.loggerMAC) { std.set(mac, forKey: Keys.loggerMAC) }
        let p = legacy.integer(forKey: Keys.port); if p > 0 { std.set(p, forKey: Keys.port) }
        let sl = legacy.integer(forKey: Keys.slaveId); if sl > 0 { std.set(sl, forKey: Keys.slaveId) }
        let pi = legacy.double(forKey: Keys.pollInterval); if pi > 0 { std.set(pi, forKey: Keys.pollInterval) }
        if let sp = legacy.string(forKey: Keys.sizePreset) { std.set(sp, forKey: Keys.sizePreset) }
        if legacy.object(forKey: Keys.scale) != nil { std.set(legacy.double(forKey: Keys.scale), forKey: Keys.scale) }
        if let dm = legacy.string(forKey: Keys.displayMode) { std.set(dm, forKey: Keys.displayMode) }
        if let show = legacy.object(forKey: Keys.showChart) as? Bool { std.set(show, forKey: Keys.showChart) }
    }
}

/// Small SwiftUI form shown in a normal window.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    var onDone: () -> Void

    @State private var hostText: String = ""
    @State private var portText: String = ""
    @State private var serialText: String = ""
    @State private var slaveText: String = ""
    @State private var intervalText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DeyeWidget Settings")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Host / IP").gridColumnAlignment(.trailing)
                    TextField("192.168.1.100", text: $hostText)
                        .frame(width: 200)
                }
                GridRow {
                    Text("Port")
                    TextField("8899", text: $portText)
                        .frame(width: 200)
                }
                GridRow {
                    Text("Logger serial")
                    TextField("10-digit serial on the stick", text: $serialText)
                        .frame(width: 200)
                }
                GridRow {
                    Text("Modbus slave id")
                    TextField("1", text: $slaveText)
                        .frame(width: 200)
                }
                GridRow {
                    Text("Poll interval (s)")
                    TextField("5", text: $intervalText)
                        .frame(width: 200)
                }
                GridRow {
                    Text("Scale")
                    HStack(spacing: 8) {
                        Slider(value: $settings.scale,
                               in: Settings.scaleRange, step: 0.05)
                        Text("\(Int((settings.scale * 100).rounded()))%")
                            .font(.system(.body, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(width: 200)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Text("Version \(AppInfo.display)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { onDone() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear(perform: load)
    }

    private func load() {
        hostText = settings.host
        portText = String(settings.port)
        serialText = String(settings.loggerSerial)
        slaveText = String(settings.slaveId)
        intervalText = String(settings.pollInterval)
    }

    private func save() {
        if !hostText.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.host = hostText.trimmingCharacters(in: .whitespaces)
        }
        if let p = UInt16(portText) { settings.port = p }
        if let s = UInt32(serialText) { settings.loggerSerial = s }
        if let sl = UInt8(slaveText) { settings.slaveId = sl }
        if let pi = Double(intervalText), pi >= 1 { settings.pollInterval = pi }
        onDone()
    }
}
