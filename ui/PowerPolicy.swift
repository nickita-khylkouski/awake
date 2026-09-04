import Foundation

struct BatterySnapshot: Equatable {
    let percent: Int
    let onBattery: Bool

    init?(current: Int, maximum: Int, onBattery: Bool) {
        guard maximum > 0, current >= 0, current <= maximum else { return nil }
        percent = Int((Double(current) * 100 / Double(maximum)).rounded(.down))
        self.onBattery = onBattery
    }

    var isCritical: Bool { onBattery && percent <= 5 }
}

/// One sleep request per low-battery episode. A deliberate wake must not create
/// a sleep loop; reconnecting power or recovering above 5% arms protection again.
final class BatteryProtection {
    private(set) var sleepRequested = false
    private(set) var error: String?

    func evaluate(_ battery: BatterySnapshot?, prepare: () -> Bool, sleep: () -> Int32) {
        guard let battery else { return }
        guard battery.isCritical else {
            sleepRequested = false
            error = nil
            return
        }
        guard !sleepRequested else { return }
        guard prepare() else {
            error = "Closed-lid sleep needs restoring. Awake will retry."
            return
        }
        let result = sleep()
        sleepRequested = result == 0
        error = sleepRequested ? nil : "macOS could not sleep (\(result)). Awake will retry."
    }
}

enum AwakeCommand: Equatable {
    case start(seconds: Double?, display: Bool?)
    case toggle, stop, blackout, show, menu, controls, about

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "awake", components.user == nil, components.password == nil,
              components.port == nil, components.path.isEmpty, components.fragment == nil,
              let host = components.host else { return nil }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return nil }
        if host == "start" {
            guard items.allSatisfy({ ["seconds", "display"].contains($0.name) && $0.value != nil }) else { return nil }
            var seconds: Double?
            var display: Bool?
            for item in items {
                if item.name == "seconds" {
                    guard let value = Double(item.value!), value.isFinite, value > 0, value <= 365 * 86400 else { return nil }
                    seconds = value
                } else {
                    guard item.value == "0" || item.value == "1" else { return nil }
                    display = item.value == "1"
                }
            }
            self = .start(seconds: seconds, display: display)
            return
        }
        guard items.isEmpty else { return nil }
        switch host {
        case "toggle": self = .toggle
        case "stop": self = .stop
        case "blackout": self = .blackout
        case "show": self = .show
        case "menu": self = .menu
        case "controls": self = .controls
        case "about": self = .about
        default: return nil
        }
    }
}
