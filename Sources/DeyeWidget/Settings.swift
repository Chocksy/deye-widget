import Foundation
import SwiftUI

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
        static let slaveId = "slaveId"
        static let pollInterval = "pollInterval"
        static let sizePreset = "sizePreset"
        static let showChart = "showChart"
    }

    @Published var host: String {
        didSet { defaults.set(host, forKey: Keys.host) }
    }
    @Published var port: UInt16 {
        didSet { defaults.set(Int(port), forKey: Keys.port) }
    }
    @Published var loggerSerial: UInt32 {
        didSet { defaults.set(Int(loggerSerial), forKey: Keys.loggerSerial) }
    }
    @Published var slaveId: UInt8 {
        didSet { defaults.set(Int(slaveId), forKey: Keys.slaveId) }
    }
    @Published var pollInterval: Double {
        didSet { defaults.set(pollInterval, forKey: Keys.pollInterval) }
    }
    @Published var sizePreset: SizePreset {
        didSet { defaults.set(sizePreset.rawValue, forKey: Keys.sizePreset) }
    }
    @Published var showChart: Bool {
        didSet { defaults.set(showChart, forKey: Keys.showChart) }
    }

    /// Whether the logger connection is configured. Until the user sets a host
    /// and logger serial (defaults are empty), the widget stays idle instead of
    /// hammering a wrong address.
    var isConfigured: Bool { !host.isEmpty && loggerSerial != 0 }

    private init() {
        // Neutral defaults — the user provides host + logger serial via Settings.
        host = defaults.string(forKey: Keys.host) ?? ""
        let p = defaults.integer(forKey: Keys.port)
        port = p > 0 ? UInt16(p) : 8899
        let s = defaults.object(forKey: Keys.loggerSerial) as? Int
        loggerSerial = s.map { UInt32($0) } ?? 0
        let sl = defaults.integer(forKey: Keys.slaveId)
        slaveId = sl > 0 ? UInt8(sl) : 1
        let pi = defaults.double(forKey: Keys.pollInterval)
        pollInterval = pi > 0 ? pi : 5.0
        sizePreset = (defaults.string(forKey: Keys.sizePreset)).flatMap { SizePreset(rawValue: $0) } ?? .medium
        showChart = (defaults.object(forKey: Keys.showChart) as? Bool) ?? true
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
            }
            .textFieldStyle(.roundedBorder)

            HStack {
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
