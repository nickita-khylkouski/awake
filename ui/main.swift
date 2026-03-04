import AppKit
import SwiftUI
import Combine
import UserNotifications
import IOKit.ps

// MARK: - Constants

let AWAKE_CMD = NSString("~/.local/bin/awake").expandingTildeInPath
let STATE_FILE = "/tmp/awake-state"
let PID_FILE = "/tmp/awake.pid"
let FOR_PID_FILE = "/tmp/awake-for.pid"
let FOR_END_FILE = "/tmp/awake-for-end"
let DISPLAY_SLEEP_FILE = "/tmp/awake-display-sleep"
let LAUNCH_AGENT_PATH = NSString("~/Library/LaunchAgents/com.awake.daemon.plist").expandingTildeInPath
let HOOK_STALE_SECONDS: TimeInterval = 120
let LOG_MAX_LINES = 200

let AGENTS: [String] = {
    if let env = ProcessInfo.processInfo.environment["AWAKE_AGENTS"] {
        return env.split(separator: " ").map(String.init)
    }
    return ["claude", "codex", "aider", "copilot", "amp", "opencode"]
}()

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

private let batteryRegex = try! NSRegularExpression(pattern: #"(\d+)%"#)

// MARK: - Helpers

func readFile(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

func pidAlive(_ path: String) -> Bool {
    guard let contents = readFile(path), let pid = Int32(contents) else { return false }
    return kill(pid, 0) == 0
}

func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    return m > 0 ? "\(h)h\(m)m" : "\(h)h"
}

@discardableResult
func runCommand(_ executable: String, _ args: [String] = [], timeout: TimeInterval = 15) -> (Bool, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    proc.standardOutput = FileHandle.nullDevice
    let errPipe = Pipe()
    proc.standardError = errPipe
    do {
        try proc.run()
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if proc.isRunning { proc.terminate() }
        }
        proc.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus == 0, errStr)
    } catch {
        return (false, error.localizedDescription)
    }
}

func pgrepCount(_ name: String) -> Int {
    let proc = Process()
    let pipe = Pipe()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-x", name]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").filter { !$0.isEmpty }.count
    } catch {
        return 0
    }
}

struct BatteryInfo {
    var percent: Int?
    var charging: Bool
}

func getBattery() -> BatteryInfo {
    let proc = Process()
    let pipe = Pipe()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    proc.arguments = ["-g", "batt"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let range = NSRange(output.startIndex..., in: output)
        var pct: Int? = nil
        if let match = batteryRegex.firstMatch(in: output, range: range),
           let pctRange = Range(match.range(at: 1), in: output) {
            pct = Int(output[pctRange])
        }
        let charging = output.contains("InternalBattery") && !output.contains("discharging")
        return BatteryInfo(percent: pct, charging: charging)
    } catch {
        return BatteryInfo(percent: nil, charging: false)
    }
}

struct HookResult {
    var active: Int
    var activeIds: [String]
    var removedNames: [String]
}

func countActiveHooks() -> HookResult {
    let fm = FileManager.default
    let now = Date()
    var active = 0
    var activeIds: [String] = []
    var removed: [String] = []
    let prefixes = ["awake-claude-", "awake-codex-"]
    let skipExtensions = Set(["png", "log"])

    do {
        let allFiles = try fm.contentsOfDirectory(atPath: "/tmp")
        for file in allFiles {
            guard prefixes.contains(where: { file.hasPrefix($0) }) else { continue }
            guard !skipExtensions.contains(where: { file.hasSuffix(".\($0)") }) else { continue }
            let fullPath = "/tmp/\(file)"
            do {
                let attrs = try fm.attributesOfItem(atPath: fullPath)
                if let mtime = attrs[.modificationDate] as? Date {
                    var sid = file
                    for p in prefixes { sid = sid.replacingOccurrences(of: p, with: "") }
                    let shortId = String(sid.prefix(8))
                    let age = now.timeIntervalSince(mtime)
                    if age < HOOK_STALE_SECONDS {
                        active += 1
                        let ageSec = Int(age)
                        activeIds.append("\(shortId) (\(ageSec)s)")
                    } else {
                        removed.append(shortId)
                        try fm.removeItem(atPath: fullPath)
                    }
                }
            } catch { /* skip */ }
        }
    } catch { /* /tmp read failed */ }
    return HookResult(active: active, activeIds: activeIds, removedNames: removed)
}

func countAgents() -> [String: Int] {
    var counts: [String: Int] = [:]
    for agent in AGENTS {
        let n = pgrepCount(agent)
        if n > 0 { counts[agent] = n }
    }
    return counts
}

func getUptime() -> TimeInterval? {
    guard let state = readFile(STATE_FILE), state.hasPrefix("nosleep") else { return nil }
    do {
        let attrs = try FileManager.default.attributesOfItem(atPath: STATE_FILE)
        if let mtime = attrs[.modificationDate] as? Date {
            return Date().timeIntervalSince(mtime)
        }
    } catch {}
    return nil
}

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let time: String
    let message: String
    let color: Color

    init(_ message: String, color: Color = .secondary) {
        self.time = timeFormatter.string(from: Date())
        self.message = message
        self.color = color
    }
}

// MARK: - Notification Manager

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private var authorized = false

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { self.authorized = granted }
        }
    }

    func send(_ title: String, _ body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner, .sound])
    }
}

// MARK: - Power Monitor

private func powerSourceCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context = context else { return }
    let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
    let isAC = PowerMonitor.isOnAC()
    DispatchQueue.main.async { monitor.onPowerChange?(isAC) }
}

class PowerMonitor {
    var onPowerChange: ((Bool) -> Void)?
    private var runLoopSource: Unmanaged<CFRunLoopSource>?

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        runLoopSource = IOPSNotificationCreateRunLoopSource(powerSourceCallback, ctx)
        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src.takeUnretainedValue(), .defaultMode)
        }
    }

    static func isOnAC() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              !sources.isEmpty,
              let desc = IOPSGetPowerSourceDescription(snapshot, sources[0] as CFTypeRef)?
                  .takeUnretainedValue() as? [String: Any],
              let state = desc[kIOPSPowerSourceStateKey as String] as? String else {
            return true
        }
        return state == (kIOPSACPowerValue as String)
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src.takeUnretainedValue(), .defaultMode)
            runLoopSource = nil
        }
    }
}

// MARK: - LaunchAgent Helpers

func isLaunchAgentInstalled() -> Bool {
    FileManager.default.fileExists(atPath: LAUNCH_AGENT_PATH)
}

func installLaunchAgent() -> Bool {
    let dir = NSString("~/Library/LaunchAgents").expandingTildeInPath
    let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.awake.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>\(AWAKE_CMD)</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
"""
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try plist.write(toFile: LAUNCH_AGENT_PATH, atomically: true, encoding: .utf8)
        return true
    } catch {
        return false
    }
}

func removeLaunchAgent() -> Bool {
    do {
        try FileManager.default.removeItem(atPath: LAUNCH_AGENT_PATH)
        return true
    } catch {
        return false
    }
}

// MARK: - Duration Option

enum DurationOption: String, CaseIterable {
    case m15 = "15m"
    case m30 = "30m"
    case h1 = "1h"
    case h2 = "2h"
    case h4 = "4h"
    case h8 = "8h"
}

// MARK: - ViewModel

class AwakeViewModel: ObservableObject {
    @Published var powerState: String = "unknown"
    @Published var isNosleep: Bool = false
    @Published var uptime: String = ""
    @Published var agentsText: String = "..."
    @Published var hookCount: Int = 0
    @Published var hookSessionIds: [String] = []
    @Published var agentsActive: Bool = false
    @Published var daemonRunning: Bool = false
    @Published var timerActive: Bool = false
    @Published var timerText: String = ""
    @Published var batteryPercent: Double = 0
    @Published var batteryText: String = "N/A"
    @Published var batteryCharging: Bool = false
    @Published var batteryLow: Bool = false
    @Published var hasBattery: Bool = false
    @Published var logEntries: [LogEntry] = []
    @Published var selectedDuration: DurationOption = .m30
    @Published var isBusy: Bool = false
    private var busySince: Date?
    @Published var allowDisplaySleep: Bool = false
    @Published var isOnAC: Bool = true
    @Published var launchAgentInstalled: Bool = false

    private var prevState: [String: String] = [:]
    private var timer: AnyCancellable?
    private var isFirstRefresh = true
    private let powerMonitor = PowerMonitor()

    var onStateChange: ((String) -> Void)?
    var onMenuDataUpdate: ((MenuSnapshot) -> Void)?

    init() {
        allowDisplaySleep = FileManager.default.fileExists(atPath: DISPLAY_SLEEP_FILE)
        launchAgentInstalled = isLaunchAgentInstalled()
        isOnAC = PowerMonitor.isOnAC()

        NotificationManager.shared.setup()

        powerMonitor.onPowerChange = { [weak self] onAC in
            guard let self = self else { return }
            self.isOnAC = onAC
            self.addLog(onAC ? "AC connected" : "On battery", color: onAC ? .green : .orange)
            NotificationManager.shared.send("awake", onAC ? "Power adapter connected" : "Running on battery")
        }
        powerMonitor.start()

        timer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshAsync() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshAsync()
        }
    }

    func addLog(_ message: String, color: Color = .secondary) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logEntries.append(LogEntry(message, color: color))
            if self.logEntries.count > LOG_MAX_LINES {
                self.logEntries.removeFirst(self.logEntries.count - LOG_MAX_LINES)
            }
        }
    }

    func refreshAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let state = readFile(STATE_FILE) ?? "unknown"
            let agents = countAgents()
            let hookResult = countActiveHooks()
            let battery = getBattery()
            let isDaemon = pidAlive(PID_FILE)
            let isTimer = pidAlive(FOR_PID_FILE)
            let uptimeVal = getUptime()

            DispatchQueue.main.async {
                self.applyRefresh(
                    state: state, agents: agents, hookResult: hookResult,
                    battery: battery, isDaemon: isDaemon, isTimer: isTimer,
                    uptimeVal: uptimeVal
                )
            }
        }
    }

    private func applyRefresh(
        state: String, agents: [String: Int], hookResult: HookResult,
        battery: BatteryInfo, isDaemon: Bool, isTimer: Bool, uptimeVal: TimeInterval?
    ) {
        // Safety: auto-reset isBusy if stuck for >20s
        if isBusy, let since = busySince, Date().timeIntervalSince(since) > 20 {
            isBusy = false
            busySince = nil
            logEntries.append(LogEntry("Action timed out (auto-reset)", color: .orange))
        }

        for sid in hookResult.removedNames {
            logEntries.append(LogEntry("Cleaned stale: \(sid)", color: .orange))
        }

        let agentDesc = agents.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
        let newState: [String: String] = [
            "power": state, "agents": agentDesc,
            "hooks": "\(hookResult.active)", "daemon": isDaemon ? "1" : "0",
            "timer": isTimer ? "1" : "0", "battery": "\(battery.percent ?? -1)",
            "charging": battery.charging ? "1" : "0",
        ]

        if isFirstRefresh {
            logEntries.append(LogEntry("Power: \(state)"))
            if !agents.isEmpty {
                logEntries.append(LogEntry("Agents: \(agents.map { "\($0.key)(\($0.value))" }.joined(separator: ", "))"))
            }
            logEntries.append(LogEntry("Daemon: \(isDaemon ? "running" : "stopped")"))
            if let pct = battery.percent {
                logEntries.append(LogEntry("Battery: \(pct)% \(battery.charging ? "charging" : "")"))
            }
            logEntries.append(LogEntry("Power source: \(isOnAC ? "AC" : "battery")"))
            isFirstRefresh = false
        } else {
            if prevState["power"] != newState["power"] {
                logEntries.append(LogEntry("Power: \(prevState["power"] ?? "?") -> \(state)",
                    color: state.hasPrefix("nosleep") ? .green : .orange))
                NotificationManager.shared.send("awake",
                    state.hasPrefix("nosleep") ? "Nosleep activated" : "Normal sleep restored")
            }
            if prevState["agents"] != newState["agents"] {
                let hadAgents = !(prevState["agents"]?.isEmpty ?? true)
                let hasAgents = !agents.isEmpty
                if agents.isEmpty {
                    logEntries.append(LogEntry("Agents: none", color: .secondary))
                } else {
                    logEntries.append(LogEntry("Agents: \(agents.map { "\($0.key)(\($0.value))" }.joined(separator: ", "))"))
                }
                if !hadAgents && hasAgents {
                    NotificationManager.shared.send("awake", "Agents detected: \(agentDesc)")
                } else if hadAgents && !hasAgents {
                    NotificationManager.shared.send("awake", "All agents stopped")
                }
            }
            if prevState["hooks"] != newState["hooks"] {
                logEntries.append(LogEntry("Hooks: \(prevState["hooks"] ?? "0") -> \(hookResult.active)"))
            }
            if prevState["daemon"] != newState["daemon"] {
                logEntries.append(LogEntry(isDaemon ? "Daemon started" : "Daemon stopped",
                    color: isDaemon ? .green : .red))
                NotificationManager.shared.send("awake",
                    isDaemon ? "Daemon started" : "Daemon stopped")
            }
            if prevState["battery"] != newState["battery"], let pct = battery.percent,
               pct <= 15 && !battery.charging {
                logEntries.append(LogEntry("Battery LOW: \(pct)%", color: .red))
                NotificationManager.shared.send("awake", "Battery low: \(pct)%. Plug in soon.")
            }
        }
        if logEntries.count > LOG_MAX_LINES {
            logEntries.removeFirst(logEntries.count - LOG_MAX_LINES)
        }

        prevState = newState
        powerState = state
        isNosleep = state.hasPrefix("nosleep")

        if let u = uptimeVal {
            uptime = formatDuration(Int(u))
        } else {
            uptime = ""
        }

        if agents.isEmpty {
            agentsText = "none"
            agentsActive = false
        } else {
            let parts = agents.sorted(by: { $0.key < $1.key }).map { "\($0.key) (\($0.value))" }
            agentsText = parts.joined(separator: ", ")
            agentsActive = true
        }
        hookCount = hookResult.active
        hookSessionIds = hookResult.activeIds
        daemonRunning = isDaemon
        timerActive = isTimer

        if isTimer, let endStr = readFile(FOR_END_FILE), let endEpoch = Int(endStr) {
            let remaining = endEpoch - Int(Date().timeIntervalSince1970)
            timerText = remaining > 0 ? formatDuration(remaining) : "expiring..."
        } else if isTimer {
            timerText = "active"
        } else {
            timerText = ""
        }

        if let pct = battery.percent {
            hasBattery = true
            batteryPercent = Double(pct)
            batteryCharging = battery.charging
            batteryText = "\(pct)%\(battery.charging ? " charging" : "")"
            batteryLow = pct <= 15 && !battery.charging
        } else {
            hasBattery = false
            batteryText = "N/A"
        }

        onStateChange?(state)

        // Push cached snapshot for instant menu bar menu
        var snap = MenuSnapshot()
        snap.state = state
        snap.isNosleep = state.hasPrefix("nosleep")
        snap.uptimeStr = uptimeVal.map { formatDuration(Int($0)) } ?? ""
        snap.agents = agents
        snap.hookCount = hookResult.active
        snap.hookSessionIds = hookResult.activeIds
        snap.batteryPercent = battery.percent
        snap.batteryCharging = battery.charging
        snap.isDaemon = isDaemon
        snap.isTimer = isTimer
        if isTimer, let endStr = readFile(FOR_END_FILE), let endEpoch = Int(endStr) {
            let remaining = endEpoch - Int(Date().timeIntervalSince1970)
            snap.timerText = remaining > 0 ? formatDuration(remaining) + " left" : "expiring..."
        } else if isTimer {
            snap.timerText = "active"
        }
        onMenuDataUpdate?(snap)
    }

    // MARK: - Actions

    func runAction(_ label: String, _ executable: String, _ args: [String] = []) {
        guard !isBusy else {
            addLog("Busy, skipping: \(label)", color: .orange)
            return
        }
        isBusy = true
        busySince = Date()
        addLog("\(label)...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, err) = runCommand(executable, args)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isBusy = false
                self.busySince = nil
                if ok {
                    self.addLog("\(label) done", color: .green)
                } else {
                    self.addLog("\(label) FAILED: \(err.prefix(80))", color: .red)
                }
                self.refreshAsync()
            }
        }
    }

    func nosleepOn() {
        if allowDisplaySleep {
            runAction("Nosleep ON (display sleep OK)", AWAKE_CMD, ["nosleep-display"])
        } else {
            runAction("Nosleep ON", AWAKE_CMD, ["nosleep"])
        }
    }

    func nosleepOff() { runAction("Nosleep OFF", AWAKE_CMD, ["yessleep"]) }

    func awakeFor() {
        runAction("Awake for \(selectedDuration.rawValue)", AWAKE_CMD, ["for", selectedDuration.rawValue])
    }

    func cancelTimer() {
        if let pidStr = readFile(FOR_PID_FILE), let pid = Int32(pidStr) {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(atPath: FOR_PID_FILE)
        try? FileManager.default.removeItem(atPath: FOR_END_FILE)
        addLog("Timer cancelled")
        refreshAsync()
    }

    func startDaemon() { runAction("Starting daemon", AWAKE_CMD, ["start"]) }
    func stopDaemon() { runAction("Stopping daemon", AWAKE_CMD, ["stop"]) }

    func sleepNow() {
        addLog("Sleep now!", color: .red)
        NotificationManager.shared.send("awake", "Going to sleep now")
        DispatchQueue.global(qos: .userInitiated).async {
            runCommand(AWAKE_CMD, ["sleep"], timeout: 10)
        }
    }

    func toggleDisplaySleep() {
        guard !isBusy else {
            addLog("Busy, try again", color: .orange)
            return
        }
        allowDisplaySleep.toggle()
        if allowDisplaySleep {
            try? "1".write(toFile: DISPLAY_SLEEP_FILE, atomically: true, encoding: .utf8)
            addLog("Display sleep: allowed", color: .blue)
            if isNosleep {
                runAction("Switching to display-sleep mode", AWAKE_CMD, ["nosleep-display"])
            }
        } else {
            try? FileManager.default.removeItem(atPath: DISPLAY_SLEEP_FILE)
            addLog("Display sleep: disabled", color: .blue)
            if isNosleep {
                runAction("Switching to full nosleep", AWAKE_CMD, ["nosleep"])
            }
        }
    }

    func toggleLaunchAgent() {
        if launchAgentInstalled {
            if removeLaunchAgent() {
                launchAgentInstalled = false
                addLog("Launch agent removed", color: .orange)
            } else {
                addLog("Failed to remove launch agent", color: .red)
            }
        } else {
            if installLaunchAgent() {
                launchAgentInstalled = true
                addLog("Launch agent installed", color: .green)
                NotificationManager.shared.send("awake", "Will start automatically on login")
            } else {
                addLog("Failed to install launch agent", color: .red)
            }
        }
    }
}

// MARK: - Theme (clean light)

private enum AW {
    static let bg = Color(nsColor: .windowBackgroundColor)
    static let cardBg = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let logBg = Color(red: 0.97, green: 0.97, blue: 0.98)
}

// MARK: - Pulsing Ring

struct PulsingRing: View {
    @State private var phase = false
    var color: Color

    var body: some View {
        Circle()
            .stroke(color.opacity(0.25), lineWidth: 1.5)
            .scaleEffect(phase ? 1.5 : 1)
            .opacity(phase ? 0 : 0.6)
            .onAppear {
                withAnimation(.easeOut(duration: 2.5).repeatForever(autoreverses: false)) {
                    phase = true
                }
            }
    }
}

// MARK: - Section Header

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(1.5)
            .padding(.bottom, 4)
    }
}

// MARK: - Stat Row

struct StatRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var mono: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundColor(valueColor)
        }
        .padding(.vertical, 2.5)
    }
}

// MARK: - Badge

struct TagBadge: View {
    let text: String
    var color: Color = .green

    var body: some View {
        Text(text.lowercased())
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var vm = AwakeViewModel()

    var body: some View {
        VStack(spacing: 0) {
            heroSection
                .padding(16)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    statusSection.padding(16)
                    Divider().padding(.horizontal, 16)
                    controlsSection.padding(16)
                    Divider().padding(.horizontal, 16)
                    settingsSection.padding(16)
                    Divider().padding(.horizontal, 16)
                    logSection.padding(16)

                    HStack {
                        Text("\u{2303}\u{21E7}A to toggle")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 340, height: 580)
        .background(AW.bg)
        .preferredColorScheme(.light)
        .onAppear {
            vm.onStateChange = { state in
                AppDelegate.shared?.updateIcon(state: state)
            }
            vm.onMenuDataUpdate = { snap in
                AppDelegate.shared?.cachedMenu = snap
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(vm.isNosleep ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
                    .frame(width: 48, height: 48)

                if vm.isNosleep {
                    PulsingRing(color: .green)
                        .frame(width: 48, height: 48)
                }

                Image(systemName: vm.isNosleep ? "bolt.fill" : "moon.zzz.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(vm.isNosleep ? .green : .secondary.opacity(0.5))
            }
            .animation(.easeInOut(duration: 0.4), value: vm.isNosleep)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.isNosleep
                    ? (vm.allowDisplaySleep ? "Nosleep (display off)" : "Nosleep active")
                    : "Normal sleep")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                HStack(spacing: 6) {
                    if !vm.uptime.isEmpty {
                        Text(vm.uptime)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if vm.agentsActive {
                        Text("\u{2022} \(vm.agentsText)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: vm.isOnAC ? "bolt.fill" : "battery.50")
                        .font(.system(size: 10))
                    Text(vm.isOnAC ? "AC" : "Battery")
                        .font(.system(size: 10))
                }
                .foregroundColor(vm.isOnAC ? .green : .orange)

                HStack(spacing: 4) {
                    if vm.daemonRunning { TagBadge(text: "daemon", color: .green) }
                    if vm.timerActive { TagBadge(text: "timer", color: .orange) }
                    if vm.batteryLow { TagBadge(text: "low", color: .red) }
                }

                if vm.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: "Status")

            StatRow(
                label: "Agents",
                value: vm.agentsText,
                valueColor: vm.agentsActive ? .green : .secondary
            )

            HStack(spacing: 6) {
                Text("Hooks").font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Text(vm.hookCount > 0 ? "\(vm.hookCount) active" : "none")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(vm.hookCount > 0 ? .green : .secondary)
            }
            .padding(.vertical, 2.5)

            if !vm.hookSessionIds.isEmpty {
                ForEach(vm.hookSessionIds, id: \.self) { sid in
                    Text(sid)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 14)
                }
            }

            StatRow(
                label: "Daemon",
                value: vm.daemonRunning ? "running" : "stopped",
                valueColor: vm.daemonRunning ? .green : .secondary
            )

            if vm.timerActive {
                StatRow(label: "Timer", value: vm.timerText, valueColor: .orange)
            }

            if vm.hasBattery {
                HStack(spacing: 8) {
                    Text("Battery").font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    if vm.batteryCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.green)
                    }
                    ProgressView(value: vm.batteryPercent, total: 100)
                        .frame(width: 50)
                        .tint(vm.batteryLow ? .red : (vm.batteryCharging ? .green : .blue))
                    Text(vm.batteryText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(vm.batteryLow ? .red : .primary)
                }
                .padding(.vertical, 2.5)
            } else {
                StatRow(label: "Power", value: "AC (desktop)", valueColor: .green)
            }
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Controls")

            HStack(spacing: 8) {
                Button(action: { vm.nosleepOn() }) {
                    Label("Nosleep ON", systemImage: "bolt.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.regular)
                .disabled(vm.isNosleep || vm.isBusy)

                Button(action: { vm.nosleepOff() }) {
                    Label("Sleep OK", systemImage: "moon.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!vm.isNosleep || vm.isBusy)
            }

            HStack(spacing: 6) {
                Picker("", selection: $vm.selectedDuration) {
                    ForEach(DurationOption.allCases, id: \.self) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .labelsHidden()
                .frame(width: 72)

                Button("Start") { vm.awakeFor() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.isBusy)

                Button("Cancel") { vm.cancelTimer() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!vm.timerActive)

                Spacer()
            }

            Divider()

            HStack(spacing: 8) {
                Button(action: { vm.startDaemon() }) {
                    Label("Start Daemon", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.daemonRunning || vm.isBusy)

                Button(action: { vm.stopDaemon() }) {
                    Label("Stop Daemon", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!vm.daemonRunning || vm.isBusy)
            }

            Button(role: .destructive, action: { vm.sleepNow() }) {
                Label("Sleep Now", systemImage: "power.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Settings")

            Toggle(isOn: Binding(
                get: { vm.allowDisplaySleep },
                set: { _ in vm.toggleDisplaySleep() }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow display sleep")
                        .font(.system(size: 12))
                    Text("Screen off, system stays awake")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(.green)

            Toggle(isOn: Binding(
                get: { vm.launchAgentInstalled },
                set: { _ in vm.toggleLaunchAgent() }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start at login")
                        .font(.system(size: 12))
                    Text("Auto-start daemon on login")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(.green)
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "Log")
                Spacer()
                Text("\(vm.logEntries.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.logEntries) { entry in
                            HStack(spacing: 0) {
                                Text(entry.time)
                                    .foregroundStyle(.tertiary)
                                Text("  ")
                                Text(entry.message)
                                    .foregroundColor(entry.color)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            .padding(.vertical, 1.5)
                            .padding(.horizontal, 10)
                            .id(entry.id)
                            .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(minHeight: 80, maxHeight: 150)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AW.logBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AW.border, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: vm.logEntries.count) {
                    if let last = vm.logEntries.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Floating Panel

class AwakePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "awake"
        isFloatingPanel = true
        level = .init(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        isMovableByWindowBackground = true
        isOpaque = true
        hasShadow = true
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        minSize = NSSize(width: 300, height: 440)
        maxSize = NSSize(width: 480, height: 800)
        standardWindowButton(.miniaturizeButton)?.isHidden = true
    }
}

// MARK: - Menu Snapshot (cached for instant menu open)

struct MenuSnapshot {
    var state: String = "unknown"
    var isNosleep: Bool = false
    var uptimeStr: String = ""
    var agents: [String: Int] = [:]
    var hookCount: Int = 0
    var hookSessionIds: [String] = []
    var batteryPercent: Int? = nil
    var batteryCharging: Bool = false
    var isDaemon: Bool = false
    var isTimer: Bool = false
    var timerText: String = ""
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    var statusItem: NSStatusItem!
    var panel: AwakePanel!
    var hasPositioned = false
    private var iconTimer: AnyCancellable?
    var cachedMenu = MenuSnapshot()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Status bar item — SF Symbol icon + uptime text
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.autosaveName = "com.awake.statusitem"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "awake")
            button.image?.size = NSSize(width: 14, height: 14)
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
            button.title = ""
            // Left-click = toggle nosleep, Right-click = menu
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // No menu assigned — we show it programmatically on right-click

        // Switch to accessory after macOS registers the status item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            NSApp.setActivationPolicy(.accessory)
        }

        // Floating panel
        let panelRect = NSRect(x: 0, y: 0, width: 340, height: 580)
        panel = AwakePanel(contentRect: panelRect)
        panel.contentViewController = NSHostingController(rootView: ContentView())
        panel.appearance = NSAppearance(named: .aqua)

        // Global hotkey: Ctrl+Shift+A
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.control, .shift]) && event.keyCode == 0 {
                DispatchQueue.main.async { self?.togglePanel(nil) }
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains([.control, .shift]) && event.keyCode == 0 {
                DispatchQueue.main.async { self?.togglePanel(nil) }
                return nil
            }
            if flags == .command && event.keyCode == 13 {
                if self?.panel.isVisible == true {
                    self?.panel.orderOut(nil)
                    return nil
                }
            }
            return event
        }

        // Periodic icon + uptime refresh (every 30s — lightweight)
        iconTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshIcon() }

        // Initial icon update + show panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshIcon()
            self?.showPanel()
        }
    }

    // MARK: - Status Item Click Handler

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            // Left-click: toggle nosleep on/off
            if cachedMenu.isNosleep {
                DispatchQueue.global(qos: .userInitiated).async {
                    runCommand(AWAKE_CMD, ["yessleep"])
                    DispatchQueue.main.async { [weak self] in self?.refreshIcon() }
                }
            } else {
                let displaySleep = FileManager.default.fileExists(atPath: DISPLAY_SLEEP_FILE)
                DispatchQueue.global(qos: .userInitiated).async {
                    runCommand(AWAKE_CMD, [displaySleep ? "nosleep-display" : "nosleep"])
                    DispatchQueue.main.async { [weak self] in self?.refreshIcon() }
                }
            }
        }
    }

    // MARK: - Icon & Uptime Refresh

    func refreshIcon() {
        let state = readFile(STATE_FILE) ?? "unknown"
        let isNosleep = state.hasPrefix("nosleep")
        guard let button = statusItem.button else { return }

        if isNosleep {
            let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "nosleep")
            img?.isTemplate = false
            button.image = img
            button.image?.size = NSSize(width: 13, height: 13)
            button.contentTintColor = .systemGreen
            // Show uptime next to icon
            if let u = getUptime() {
                button.title = " \(formatDuration(Int(u)))"
            } else {
                button.title = ""
            }
        } else {
            let img = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "sleep ok")
            img?.isTemplate = true
            button.image = img
            button.image?.size = NSSize(width: 13, height: 13)
            button.contentTintColor = nil
            button.title = ""
        }
    }

    func updateIcon(state: String) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshIcon()
        }
    }

    // MARK: - Right-Click Menu

    func showStatusMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // After menu closes, remove it so left-click works as toggle again
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let s = cachedMenu  // Read from cache — no I/O, instant

        // --- Status header ---
        let statusText = s.isNosleep ? "Nosleep \(s.uptimeStr)" : "Normal sleep"
        let headerItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: s.isNosleep ? NSColor.systemGreen : NSColor.secondaryLabelColor
        ]
        headerItem.attributedTitle = NSAttributedString(string: statusText, attributes: attrs)
        menu.addItem(headerItem)

        if !s.agents.isEmpty {
            let agentStr = s.agents.sorted(by: { $0.key < $1.key }).map { "\($0.key)(\($0.value))" }.joined(separator: " ")
            let agentItem = NSMenuItem(title: "  Agents: \(agentStr)", action: nil, keyEquivalent: "")
            agentItem.isEnabled = false
            menu.addItem(agentItem)
        }

        if s.hookCount > 0 {
            let hookItem = NSMenuItem(title: "  Hooks: \(s.hookCount) active", action: nil, keyEquivalent: "")
            hookItem.isEnabled = false
            menu.addItem(hookItem)
            for sid in s.hookSessionIds {
                let sidItem = NSMenuItem(title: "    \(sid)", action: nil, keyEquivalent: "")
                sidItem.isEnabled = false
                let sidAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
                sidItem.attributedTitle = NSAttributedString(string: "    \(sid)", attributes: sidAttrs)
                menu.addItem(sidItem)
            }
        }

        if let pct = s.batteryPercent {
            let battStr = "\(pct)%\(s.batteryCharging ? " \u{26A1}" : "")"
            let battItem = NSMenuItem(title: "  Battery: \(battStr)", action: nil, keyEquivalent: "")
            battItem.isEnabled = false
            menu.addItem(battItem)
        }

        if s.isTimer {
            let timerItem = NSMenuItem(title: "  Timer: \(s.timerText)", action: nil, keyEquivalent: "")
            timerItem.isEnabled = false
            menu.addItem(timerItem)
        }

        menu.addItem(NSMenuItem.separator())

        // --- Quick controls ---
        if s.isNosleep {
            menu.addItem(NSMenuItem(title: "Sleep OK", action: #selector(menuSleepOK), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Nosleep ON", action: #selector(menuNosleepOn), keyEquivalent: ""))
        }

        let timerMenu = NSMenu()
        for dur in ["15m", "30m", "1h", "2h", "4h", "8h"] {
            let item = NSMenuItem(title: dur, action: #selector(menuTimerStart(_:)), keyEquivalent: "")
            item.representedObject = dur
            timerMenu.addItem(item)
        }
        if s.isTimer {
            timerMenu.addItem(NSMenuItem.separator())
            timerMenu.addItem(NSMenuItem(title: "Cancel Timer", action: #selector(menuTimerCancel), keyEquivalent: ""))
        }
        let timerParent = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        timerParent.submenu = timerMenu
        menu.addItem(timerParent)

        if s.isDaemon {
            menu.addItem(NSMenuItem(title: "Stop Daemon", action: #selector(menuStopDaemon), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Start Daemon", action: #selector(menuStartDaemon), keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Panel", action: #selector(showPanelAction), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Sleep Now", action: #selector(menuSleepNow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        return menu
    }

    // MARK: - Menu Actions

    @objc func menuNosleepOn() {
        let displaySleep = FileManager.default.fileExists(atPath: DISPLAY_SLEEP_FILE)
        DispatchQueue.global(qos: .userInitiated).async {
            runCommand(AWAKE_CMD, [displaySleep ? "nosleep-display" : "nosleep"])
            DispatchQueue.main.async { [weak self] in self?.refreshIcon() }
        }
    }

    @objc func menuSleepOK() {
        DispatchQueue.global(qos: .userInitiated).async {
            runCommand(AWAKE_CMD, ["yessleep"])
            DispatchQueue.main.async { [weak self] in self?.refreshIcon() }
        }
    }

    @objc func menuTimerStart(_ sender: NSMenuItem) {
        guard let dur = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async { runCommand(AWAKE_CMD, ["for", dur]) }
    }

    @objc func menuTimerCancel() {
        if let pidStr = readFile(FOR_PID_FILE), let pid = Int32(pidStr) {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(atPath: FOR_PID_FILE)
        try? FileManager.default.removeItem(atPath: FOR_END_FILE)
    }

    @objc func menuStartDaemon() {
        DispatchQueue.global(qos: .userInitiated).async { runCommand(AWAKE_CMD, ["start"]) }
    }

    @objc func menuStopDaemon() {
        DispatchQueue.global(qos: .userInitiated).async { runCommand(AWAKE_CMD, ["stop"]) }
    }

    @objc func menuSleepNow() {
        DispatchQueue.global(qos: .userInitiated).async {
            runCommand(AWAKE_CMD, ["sleep"], timeout: 10)
        }
    }

    @objc func togglePanel(_ sender: Any?) {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    @objc func showPanelAction() { showPanel() }

    @objc func quitApp() { NSApp.terminate(nil) }

    func showPanel() {
        if !hasPositioned {
            if let button = statusItem.button,
               let buttonWindow = button.window {
                let buttonRect = button.convert(button.bounds, to: nil)
                let screenRect = buttonWindow.convertToScreen(buttonRect)
                let x = screenRect.midX - panel.frame.width / 2
                let y = screenRect.minY - panel.frame.height - 4
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                if let screen = NSScreen.main {
                    let vis = screen.visibleFrame
                    let x = vis.maxX - panel.frame.width - 12
                    let y = vis.maxY - panel.frame.height - 4
                    panel.setFrameOrigin(NSPoint(x: x, y: y))
                }
            }
            hasPositioned = true
        }
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.regular)  // Start as regular so macOS registers the status item
let delegate = AppDelegate()
app.delegate = delegate
app.run()
