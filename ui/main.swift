import AppKit
import SwiftUI
import Combine
import UserNotifications
import ApplicationServices
import IOKit.ps
import Carbon

// MARK: - Constants

func resolveAwakeCommandPath() -> String {
    let fallback = NSString("~/.local/bin/awake").expandingTildeInPath
    if let resourceURL = Bundle.main.resourceURL {
        let bundled = resourceURL.appendingPathComponent("bin/awake").path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
    }
    let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
    let sibling = bundleDir.appendingPathComponent("awake").path
    if FileManager.default.isExecutableFile(atPath: sibling) {
        return sibling
    }
    return fallback
}

let AWAKE_CMD = resolveAwakeCommandPath()
let STATE_FILE = "/tmp/awake-state"
let PID_FILE = "/tmp/awake.pid"
let FOR_PID_FILE = "/tmp/awake-for.pid"
let FOR_END_FILE = "/tmp/awake-for-end"
let DISPLAY_SLEEP_FILE = "/tmp/awake-display-sleep"
let LAUNCH_AGENT_PATH = NSString("~/Library/LaunchAgents/com.awake.daemon.plist").expandingTildeInPath
let HOOK_STALE_SECONDS: TimeInterval = 120
let LOG_MAX_LINES = 200
let CPU_TEMP_HISTORY_PATH = NSString("~/.config/awake/cpu-temp-history.json").expandingTildeInPath
let CPU_TEMP_HISTORY_WINDOW: TimeInterval = 12 * 60 * 60
let CPU_TEMP_SAMPLE_INTERVAL: TimeInterval = 60
let ONBOARDING_STATE_PATH = NSString("~/.config/awake/onboarding-completed.json").expandingTildeInPath
let ONBOARDING_VERSION = 2

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
    let (ok, _, err) = runCommandCapture(executable, args, timeout: timeout)
    return (ok, err)
}

func runCommandCapture(_ executable: String, _ args: [String] = [], timeout: TimeInterval = 15) -> (Bool, String, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do {
        try proc.run()
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if proc.isRunning { proc.terminate() }
        }
        proc.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus == 0, outStr, errStr)
    } catch {
        return (false, "", error.localizedDescription)
    }
}

@discardableResult
func runLaunchCtl(_ args: [String], timeout: TimeInterval = 10) -> Bool {
    let candidates = ["/bin/launchctl", "/usr/bin/launchctl"]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return runCommandCapture(path, args, timeout: timeout).0
    }
    return false
}

func shellEscape(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func appleScriptStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

func hasMenuBarControlAccess() -> Bool {
    AXIsProcessTrusted()
}

func requestMenuBarControlAccessPrompt() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
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

struct CPUTemperaturePayload: Decodable {
    let available: Bool
    let value: Double?
    let unit: String
    let sampledAt: TimeInterval
    let source: String
    let label: String
    let detail: String
    let reason: String?
}

struct SetupSnapshot: Decodable {
    let sleepControlConfigured: Bool
    let temperatureConfigured: Bool
    let claudeDetected: Bool
    let claudeConfigured: Bool
    let codexDetected: Bool
    let codexConfigured: Bool
    let powerState: String?
    let daemonRunning: Bool?
    let timerActive: Bool?
    let leaseCount: Int?
    let ruleCount: Int?
    let defaultMode: String?
    let effectiveLeaseId: String?
    let effectiveMode: String?
    let effectiveResolvedMode: String?
    let effectiveReason: String?
    let whyAwake: String?
    let restorePlan: String?
    let batteryPercent: Int?
    let batteryCharging: Bool?
    let leases: [LeaseSnapshot]?
    let rules: [RuleSnapshot]?
    let warnings: [String]?
}

struct LeaseSnapshot: Decodable, Identifiable {
    let id: String
    let type: String
    let mode: String
    let resolvedMode: String
    let reason: String
    let priority: Int
    let startedAt: TimeInterval
    let expiresAt: Int?
    let source: String
}

struct RuleSnapshot: Decodable, Identifiable {
    let id: String
    let type: String
    let value: String
    let mode: String
    let reason: String
    let priority: Int
}

struct CPUTemperaturePoint: Codable, Identifiable, Equatable {
    let timestamp: TimeInterval
    let value: Double

    var id: TimeInterval { timestamp }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case requiredSetup
    case recommendedSetup
    case optionalSetup
    case ready

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .requiredSetup: return "Required Setup"
        case .recommendedSetup: return "Recommended"
        case .optionalSetup: return "Optional"
        case .ready: return "Ready"
        }
    }
}

enum AwakeAudience: String, CaseIterable, Identifiable {
    case ai = "ai"
    case personal = "personal"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai: return "AI coding agents"
        case .personal: return "Personal use"
        }
    }

    var shortTitle: String {
        switch self {
        case .ai: return "AI user"
        case .personal: return "Personal user"
        }
    }

    var detail: String {
        switch self {
        case .ai:
            return "Show daemon, agent detection, hooks, and automatic protection for coding workflows."
        case .personal:
            return "Keep Awake focused on manual sessions, timers, and simple Mac sleep control."
        }
    }
}

struct OnboardingCompletionRecord: Codable {
    let version: Int
    let completedAt: TimeInterval
    let sleepControlConfiguredAtCompletion: Bool
    let automaticProtectionEnabled: Bool
    let chosenDefaultMode: String
    let usageProfile: String?
}

func loadOnboardingCompletionRecord() -> OnboardingCompletionRecord? {
    guard let data = FileManager.default.contents(atPath: ONBOARDING_STATE_PATH) else { return nil }
    return try? JSONDecoder().decode(OnboardingCompletionRecord.self, from: data)
}

func saveOnboardingCompletionRecord(_ record: OnboardingCompletionRecord) {
    let url = URL(fileURLWithPath: ONBOARDING_STATE_PATH)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(record) else { return }
    try? data.write(to: url, options: [.atomic])
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

enum PowerSettingsSource: String, CaseIterable, Identifiable {
    case battery
    case ac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: return "Battery"
        case .ac: return "Power Adapter"
        }
    }
}

enum SettingKind {
    case minutes([Int])
    case boolean
    case hibernate([Int])
}

struct SettingDefinition: Identifiable {
    let key: String
    let title: String
    let subtitle: String
    let kind: SettingKind
    let isAdvanced: Bool
    let help: String

    var id: String { key }
}

let sleepSettingDefinitions: [SettingDefinition] = [
    .init(key: "sleep", title: "System sleep after", subtitle: "Idle system sleep timer", kind: .minutes([0, 1, 2, 5, 10, 15, 30, 60, 120, 180]), isAdvanced: false, help: "How long the whole Mac waits before sleeping when Awake is not overriding it.\n\nExample: set 15m if you want your laptop to sleep after 15 minutes of inactivity during normal use."),
    .init(key: "displaysleep", title: "Display sleep after", subtitle: "Turn display off after inactivity", kind: .minutes([0, 1, 2, 5, 10, 15, 30, 60, 120]), isAdvanced: false, help: "How long before only the screen turns off.\n\nExample: 5m means the display goes dark after 5 minutes, while the Mac may keep running longer if system sleep is set later."),
    .init(key: "disksleep", title: "Disk sleep after", subtitle: "Spindown timer for disks", kind: .minutes([0, 1, 2, 5, 10, 15, 30, 60]), isAdvanced: false, help: "Controls when disks can spin down during inactivity.\n\nExample: keep this at 10m if you want normal power savings, or 0/Never if disk wake-ups annoy you."),
    .init(key: "womp", title: "Wake for network access", subtitle: "Wake on network magic packet", kind: .boolean, isAdvanced: false, help: "Lets the Mac wake for network access.\n\nExample: turn this on if you want SSH, remote desktop, or Wake-on-LAN style workflows to work while the machine is sleeping."),
    .init(key: "powernap", title: "Power Nap", subtitle: "Background maintenance while sleeping", kind: .boolean, isAdvanced: false, help: "Allows some background work while sleeping.\n\nExample: keep it on if you want mail or cloud maintenance to keep happening, turn it off for stricter battery saving."),
    .init(key: "lessbright", title: "Dim display on battery", subtitle: "Slightly reduce brightness when unplugged", kind: .boolean, isAdvanced: false, help: "Automatically reduces display brightness on battery.\n\nExample: turn this on if you want a little extra battery life without changing your full brightness manually."),
    .init(key: "lidwake", title: "Wake on lid open", subtitle: "Wake the Mac when the lid opens", kind: .boolean, isAdvanced: false, help: "Wakes the Mac when you reopen the lid.\n\nExample: leave this on for normal laptop behavior unless you specifically want the machine to stay asleep until you press a key."),
    .init(key: "acwake", title: "Wake on power change", subtitle: "Wake when power source changes", kind: .boolean, isAdvanced: false, help: "Wakes the Mac when power source changes.\n\nExample: plugging in your charger can wake the machine if this is enabled."),
    .init(key: "ttyskeepawake", title: "TTY keeps awake", subtitle: "Prevent idle sleep while terminals are active", kind: .boolean, isAdvanced: true, help: "Prevents idle sleep while terminal sessions are considered active.\n\nExample: useful if you do long SSH sessions or run terminal-heavy workflows and want them to count as activity."),
    .init(key: "proximitywake", title: "Proximity wake", subtitle: "Wake based on nearby Apple devices", kind: .boolean, isAdvanced: true, help: "Allows nearby Apple devices on the same account to influence wake behavior.\n\nExample: your Mac may wake when your phone or watch comes nearby."),
    .init(key: "standby", title: "Standby", subtitle: "Allow deeper sleep after sleeping for a while", kind: .boolean, isAdvanced: true, help: "After normal sleep, macOS can transition into a deeper low-power state.\n\nExample: keep it on for battery savings during long idle periods; Awake overrides this while active."),
    .init(key: "autopoweroff", title: "Autopoweroff", subtitle: "Enter lower-power chipset sleep", kind: .boolean, isAdvanced: true, help: "Lets macOS move into an even lower-power sleep state after some time.\n\nExample: helpful for overnight battery saving, but it can mean slower wake after very long sleeps."),
    .init(key: "hibernatemode", title: "Hibernate mode", subtitle: "Low-level sleep mode", kind: .hibernate([0, 3, 25]), isAdvanced: true, help: "Low-level memory sleep policy.\n\nExample: 3 is the common portable default, 0 is lighter sleep, 25 is deeper hibernation with slower wake. Only change this if you know why."),
]

private let settingDefinitionsByKey = Dictionary(uniqueKeysWithValues: sleepSettingDefinitions.map { ($0.key, $0) })

struct PowerSettingsSnapshot: Decodable {
    let effective: [String: [String: Int]]
    let baseline: [String: [String: Int]]
    let overrideActive: Bool
    let disablesleep: Int
    let baselineDisablesleep: Int
    let managedKeys: [String]
    let advancedKeys: [String]
    let availableSources: [String]
}

func formatMinutes(_ value: Int) -> String {
    if value == 0 { return "Never" }
    if value < 60 { return "\(value)m" }
    if value % 60 == 0 { return "\(value / 60)h" }
    return "\(value)m"
}

func formatSettingValue(_ key: String, value: Int) -> String {
    guard let def = settingDefinitionsByKey[key] else { return "\(value)" }
    switch def.kind {
    case .minutes:
        return formatMinutes(value)
    case .boolean:
        return value == 0 ? "Off" : "On"
    case .hibernate:
        return "\(value)"
    }
}

func formatModeLabel(_ mode: String) -> String {
    switch mode {
    case "running": return "Keep Running"
    case "presenting": return "Keep Presenting"
    case "agent-safe": return "Agent Safe"
    default: return mode
    }
}

func truncateForMenu(_ value: String, limit: Int = 90) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(limit - 1)) + "…"
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
    @Published var menuBarControlConfigured: Bool = hasMenuBarControlAccess()
    @Published var selectedSettingsSource: PowerSettingsSource = .battery
    @Published var availableSettingsSources: [PowerSettingsSource] = []
    @Published var effectivePowerSettings: [String: [String: Int]] = [:]
    @Published var baselinePowerSettings: [String: [String: Int]] = [:]
    @Published var awakeOverrideActive: Bool = false
    @Published var effectiveDisablesleep: Int = 0
    @Published var baselineDisablesleep: Int = 0
    @Published var pendingPowerSettingKeys: Set<String> = []
    @Published var cpuTempCurrent: Double?
    @Published var cpuTempStatus: String = "Checking CPU temperature..."
    @Published var cpuTempHistory: [CPUTemperaturePoint] = []
    @Published var cpuTempNeedsSetup: Bool = false
    @Published var cpuTempLabel: String = "Temperature"
    @Published var cpuTempDetail: String = "Last 12 hours"
    @Published var sleepControlConfigured: Bool = false
    @Published var temperatureConfigured: Bool = false
    @Published var claudeDetected: Bool = false
    @Published var claudeConfigured: Bool = false
    @Published var codexDetected: Bool = false
    @Published var codexConfigured: Bool = false
    @Published var showOnboarding: Bool = false
    @Published var audience: AwakeAudience = .ai
    @Published var defaultMode: String = "running"
    @Published var effectiveMode: String = ""
    @Published var effectiveResolvedMode: String = ""
    @Published var effectiveReason: String = ""
    @Published var whyAwakeText: String = "Normal sleep. No active leases."
    @Published var restorePlanText: String = ""
    @Published var leaseCount: Int = 0
    @Published var ruleCount: Int = 0
    @Published var activeLeases: [LeaseSnapshot] = []
    @Published var configuredRules: [RuleSnapshot] = []
    @Published var warnings: [String] = []

    private var prevState: [String: String] = [:]
    private var timer: AnyCancellable?
    private var isFirstRefresh = true
    private let powerMonitor = PowerMonitor()
    private var lastTempFetchAt: Date?
    private var tempFetchInFlight = false
    private var onboardingEvaluated = false

    var onStateChange: ((String) -> Void)?
    var onMenuDataUpdate: ((MenuSnapshot) -> Void)?

    var appliedModeLabel: String {
        if !isNosleep {
            return "Normal Sleep"
        }
        if !effectiveResolvedMode.isEmpty {
            return formatModeLabel(effectiveResolvedMode)
        }
        if !effectiveMode.isEmpty {
            return formatModeLabel(effectiveMode)
        }
        return formatModeLabel(defaultMode)
    }

    var showsAIFeatures: Bool {
        audience == .ai
    }

    init() {
        allowDisplaySleep = FileManager.default.fileExists(atPath: DISPLAY_SLEEP_FILE)
        launchAgentInstalled = isLaunchAgentInstalled()
        menuBarControlConfigured = hasMenuBarControlAccess()
        isOnAC = PowerMonitor.isOnAC()
        loadCpuTemperatureHistory()
        if let record = loadOnboardingCompletionRecord(),
           let profile = record.usageProfile.flatMap(AwakeAudience.init(rawValue:)) {
            audience = profile
        }

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
        maybeRefreshCpuTemperature()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let state = readFile(STATE_FILE) ?? "unknown"
            let agents = countAgents()
            let hookResult = countActiveHooks()
            let battery = getBattery()
            let isDaemon = pidAlive(PID_FILE)
            let isTimer = pidAlive(FOR_PID_FILE)
            let uptimeVal = getUptime()
            let settingsSnapshot = self.fetchPowerSettingsSnapshot()
            let setupSnapshot = self.fetchSetupSnapshot()

            DispatchQueue.main.async {
                self.applyRefresh(
                    state: state, agents: agents, hookResult: hookResult,
                    battery: battery, isDaemon: isDaemon, isTimer: isTimer,
                    uptimeVal: uptimeVal, settingsSnapshot: settingsSnapshot, setupSnapshot: setupSnapshot
                )
            }
        }
    }

    private func fetchPowerSettingsSnapshot() -> PowerSettingsSnapshot? {
        let (ok, output, _) = runCommandCapture(AWAKE_CMD, ["settings", "dump"], timeout: 10)
        guard ok, let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PowerSettingsSnapshot.self, from: data)
    }

    private func fetchSetupSnapshot() -> SetupSnapshot? {
        let (ok, output, _) = runCommandCapture(AWAKE_CMD, ["setup", "status-json"], timeout: 10)
        guard ok, let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SetupSnapshot.self, from: data)
    }

    private func maybeRefreshCpuTemperature() {
        if tempFetchInFlight { return }
        if let last = lastTempFetchAt, Date().timeIntervalSince(last) < CPU_TEMP_SAMPLE_INTERVAL {
            return
        }
        tempFetchInFlight = true
        lastTempFetchAt = Date()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (ok, output, err) = runCommandCapture(AWAKE_CMD, ["temp", "json"], timeout: 12)
            DispatchQueue.main.async {
                guard let self else { return }
                self.tempFetchInFlight = false
                guard ok, let data = output.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(CPUTemperaturePayload.self, from: data) else {
                    self.cpuTempCurrent = nil
                    self.cpuTempStatus = err.isEmpty ? "CPU temperature unavailable" : err
                    return
                }
                self.applyCpuTemperaturePayload(payload)
            }
        }
    }

    private func applyCpuTemperaturePayload(_ payload: CPUTemperaturePayload) {
        cpuTempLabel = payload.label
        cpuTempDetail = payload.detail
        if payload.available, let value = payload.value {
            cpuTempCurrent = value
            cpuTempStatus = "\(Int(round(value)))°C now"
            cpuTempNeedsSetup = false

            let point = CPUTemperaturePoint(timestamp: payload.sampledAt, value: value)
            pruneCpuTemperatureHistory(now: payload.sampledAt)
            if let last = cpuTempHistory.last, point.timestamp - last.timestamp < CPU_TEMP_SAMPLE_INTERVAL {
                cpuTempHistory[cpuTempHistory.count - 1] = point
            } else {
                cpuTempHistory.append(point)
            }
            saveCpuTemperatureHistory()
        } else {
            cpuTempCurrent = nil
            cpuTempStatus = payload.reason ?? "CPU temperature unavailable"
            cpuTempNeedsSetup = (payload.reason ?? "").contains("/usr/bin/powermetrics")
            pruneCpuTemperatureHistory(now: Date().timeIntervalSince1970)
        }
    }

    func enableCpuTemperatureAccess() {
        requestPrivilegedSudoersInstall(
            commandPath: "/usr/bin/powermetrics",
            sudoersName: "powermetrics",
            successLog: "CPU temperature access enabled",
            failurePrefix: "CPU temperature setup failed"
        ) { [weak self] in
            self?.lastTempFetchAt = nil
            self?.maybeRefreshCpuTemperature()
        }
    }

    func enableSleepControlAccess() {
        requestPrivilegedSudoersInstall(
            commandPath: "/usr/bin/pmset",
            sudoersName: "pmset",
            successLog: "Sleep control access enabled",
            failurePrefix: "Sleep control setup failed"
        ) { [weak self] in
            self?.refreshAsync()
        }
    }

    private func requestPrivilegedSudoersInstall(
        commandPath: String,
        sudoersName: String,
        successLog: String,
        failurePrefix: String,
        onSuccess: @escaping () -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        busySince = Date()
        addLog("Requesting \(sudoersName) access...")

        let username = NSUserName()
        let sudoersLine = "\(username) ALL=(ALL) NOPASSWD: \(commandPath)"
        let shellScript = """
        tmp=$(/usr/bin/mktemp /private/tmp/awake-\(sudoersName).XXXXXX) && /usr/bin/printf '%s\\n' \(shellEscape(sudoersLine)) > "$tmp" && /usr/sbin/visudo -cf "$tmp" >/dev/null && /usr/sbin/chown root:wheel "$tmp" && /bin/chmod 440 "$tmp" && /bin/mkdir -p /etc/sudoers.d && /bin/rm -f /etc/sudoers.d/\(sudoersName).* && /bin/mv "$tmp" /etc/sudoers.d/\(sudoersName)
        """
        let appleScript = "do shell script \(appleScriptStringLiteral(shellScript)) with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, _, err) = runCommandCapture("/usr/bin/osascript", ["-e", appleScript], timeout: 30)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.busySince = nil
                if ok {
                    self.addLog(successLog, color: .green)
                    onSuccess()
                } else {
                    self.addLog("\(failurePrefix): \(err.prefix(120))", color: .red)
                }
            }
        }
    }

    func installClaudeIntegration() {
        runAction("Installing Claude integration", AWAKE_CMD, ["setup", "claude"])
    }

    func installCodexIntegration() {
        runAction("Installing Codex integration", AWAKE_CMD, ["setup", "codex"])
    }

    func finishOnboarding() {
        let record = OnboardingCompletionRecord(
            version: ONBOARDING_VERSION,
            completedAt: Date().timeIntervalSince1970,
            sleepControlConfiguredAtCompletion: sleepControlConfigured,
            automaticProtectionEnabled: launchAgentInstalled,
            chosenDefaultMode: defaultMode,
            usageProfile: audience.rawValue
        )
        saveOnboardingCompletionRecord(record)
        showOnboarding = false
    }

    func reopenOnboarding() {
        showOnboarding = true
    }

    func setAudience(_ newAudience: AwakeAudience) {
        audience = newAudience
        if newAudience == .personal && defaultMode == "agent-safe" {
            defaultMode = "running"
            setDefaultMode("running")
        }
        if onboardingEvaluated && !showOnboarding {
            persistOnboardingProfile()
        }
    }

    private func persistOnboardingProfile() {
        let record = OnboardingCompletionRecord(
            version: ONBOARDING_VERSION,
            completedAt: Date().timeIntervalSince1970,
            sleepControlConfiguredAtCompletion: sleepControlConfigured,
            automaticProtectionEnabled: launchAgentInstalled,
            chosenDefaultMode: defaultMode,
            usageProfile: audience.rawValue
        )
        saveOnboardingCompletionRecord(record)
    }

    private func loadCpuTemperatureHistory() {
        guard let data = FileManager.default.contents(atPath: CPU_TEMP_HISTORY_PATH),
              let history = try? JSONDecoder().decode([CPUTemperaturePoint].self, from: data) else {
            cpuTempHistory = []
            return
        }
        cpuTempHistory = history
        pruneCpuTemperatureHistory(now: Date().timeIntervalSince1970)
    }

    private func saveCpuTemperatureHistory() {
        pruneCpuTemperatureHistory(now: Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: CPU_TEMP_HISTORY_PATH)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cpuTempHistory) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func pruneCpuTemperatureHistory(now: TimeInterval) {
        let cutoff = now - CPU_TEMP_HISTORY_WINDOW
        cpuTempHistory = cpuTempHistory.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
    }

    private func applyRefresh(
        state: String, agents: [String: Int], hookResult: HookResult,
        battery: BatteryInfo, isDaemon: Bool, isTimer: Bool, uptimeVal: TimeInterval?,
        settingsSnapshot: PowerSettingsSnapshot?, setupSnapshot: SetupSnapshot?
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

        if let settingsSnapshot {
            applyPowerSettingsSnapshot(settingsSnapshot)
        }
        if let setupSnapshot {
            applySetupSnapshot(setupSnapshot)
        }
        menuBarControlConfigured = hasMenuBarControlAccess()

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
        snap.modeText = appliedModeLabel
        snap.whyText = truncateForMenu(whyAwakeText)
        snap.warningCount = warnings.count
        snap.showsAIFeatures = showsAIFeatures
        onMenuDataUpdate?(snap)
    }

    private func applySetupSnapshot(_ snapshot: SetupSnapshot) {
        sleepControlConfigured = snapshot.sleepControlConfigured
        temperatureConfigured = snapshot.temperatureConfigured
        claudeDetected = snapshot.claudeDetected
        claudeConfigured = snapshot.claudeConfigured
        codexDetected = snapshot.codexDetected
        codexConfigured = snapshot.codexConfigured
        defaultMode = snapshot.defaultMode ?? defaultMode
        effectiveMode = snapshot.effectiveMode ?? ""
        effectiveResolvedMode = snapshot.effectiveResolvedMode ?? ""
        effectiveReason = snapshot.effectiveReason ?? ""
        whyAwakeText = snapshot.whyAwake ?? whyAwakeText
        restorePlanText = snapshot.restorePlan ?? ""
        leaseCount = snapshot.leaseCount ?? 0
        ruleCount = snapshot.ruleCount ?? 0
        activeLeases = snapshot.leases ?? []
        configuredRules = snapshot.rules ?? []
        warnings = snapshot.warnings ?? []
        cpuTempNeedsSetup = !temperatureConfigured && cpuTempNeedsSetup

        if !onboardingEvaluated {
            onboardingEvaluated = true
            showOnboarding = needsOnboarding
        }
    }

    func setDefaultMode(_ mode: String) {
        runAction("Setting mode to \(formatModeLabel(mode))", AWAKE_CMD, ["mode", "set", mode])
    }

    var needsOnboarding: Bool {
        guard let record = loadOnboardingCompletionRecord() else { return true }
        guard record.version >= ONBOARDING_VERSION else { return true }
        guard let profile = record.usageProfile, AwakeAudience(rawValue: profile) != nil else { return true }
        return false
    }

    private func applyPowerSettingsSnapshot(_ snapshot: PowerSettingsSnapshot) {
        effectivePowerSettings = snapshot.effective
        baselinePowerSettings = snapshot.baseline
        awakeOverrideActive = snapshot.overrideActive
        effectiveDisablesleep = snapshot.disablesleep
        baselineDisablesleep = snapshot.baselineDisablesleep

        let sources = snapshot.availableSources.compactMap { PowerSettingsSource(rawValue: $0) }
        if !sources.isEmpty {
            availableSettingsSources = sources
            if !sources.contains(selectedSettingsSource) {
                selectedSettingsSource = sources[0]
            }
        }
    }

    func valueForSelectedSource(_ key: String) -> Int {
        baselinePowerSettings[selectedSettingsSource.rawValue]?[key]
            ?? effectivePowerSettings[selectedSettingsSource.rawValue]?[key]
            ?? 0
    }

    func effectiveValueForSelectedSource(_ key: String) -> Int? {
        effectivePowerSettings[selectedSettingsSource.rawValue]?[key]
    }

    func isApplyingSetting(_ key: String) -> Bool {
        pendingPowerSettingKeys.contains("\(selectedSettingsSource.rawValue):\(key)")
    }

    func updatePowerSetting(_ key: String, _ value: Int) {
        let source = selectedSettingsSource.rawValue
        let sourceTitle = selectedSettingsSource.title
        let token = "\(source):\(key)"
        let previousBaseline = baselinePowerSettings[source]?[key] ?? effectivePowerSettings[source]?[key] ?? 0

        if previousBaseline == value {
            return
        }

        var sourceValues = baselinePowerSettings[source] ?? effectivePowerSettings[source] ?? [:]
        sourceValues[key] = value
        baselinePowerSettings[source] = sourceValues
        if !awakeOverrideActive {
            effectivePowerSettings[source] = sourceValues
        }
        pendingPowerSettingKeys.insert(token)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, _, err) = runCommandCapture(AWAKE_CMD, ["settings", "apply", source, key, "\(value)"], timeout: 20)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingPowerSettingKeys.remove(token)
                if ok {
                    self.addLog(
                        self.awakeOverrideActive
                            ? "\(sourceTitle): saved \(key) baseline (\(formatSettingValue(key, value: value)))"
                            : "\(sourceTitle): \(key) -> \(formatSettingValue(key, value: value))",
                        color: .green
                    )
                } else {
                    var revertedSourceValues = self.baselinePowerSettings[source] ?? [:]
                    revertedSourceValues[key] = previousBaseline
                    self.baselinePowerSettings[source] = revertedSourceValues
                    if !self.awakeOverrideActive {
                        self.effectivePowerSettings[source] = revertedSourceValues
                    }
                    self.addLog("Failed to save \(key): \(err.prefix(120))", color: .red)
                }
                self.refreshAsync()
            }
        }
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
        runAction("Cancelling timer", AWAKE_CMD, ["cancel-timer"])
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

    func enableMenuBarControl() {
        requestMenuBarControlAccessPrompt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.menuBarControlConfigured = hasMenuBarControlAccess()
            if self.menuBarControlConfigured {
                self.addLog("Menu bar control access enabled", color: .green)
                AppDelegate.shared?.promoteStatusItemToVisibleEdge(promptIfNeeded: false)
            } else {
                self.addLog("Menu bar control access still pending approval", color: .orange)
            }
        }
    }

    func promoteMenuBarIcon() {
        AppDelegate.shared?.promoteStatusItemToVisibleEdge(promptIfNeeded: true)
        addLog("Trying to move Awake icon toward the visible end of the menu bar", color: .blue)
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
    var help: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(1.5)
            if let help, !help.isEmpty {
                InfoPopoverButton(text: help)
            }
        }
        .padding(.bottom, 4)
    }
}

struct InfoPopoverButton: View {
    let text: String
    @State private var isPinned = false
    @State private var isHovered = false

    var body: some View {
        let isPresented = isPinned || isHovered

        Button(action: { isPinned.toggle() }) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.8))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .popover(isPresented: .constant(isPresented), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("About This")
                    .font(.system(size: 12, weight: .semibold))
                Text(text)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 260, alignment: .leading)
            .padding(12)
        }
    }
}

struct TemperatureSparkline: View {
    let samples: [CPUTemperaturePoint]
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let plotted = plottedSamples(in: geo.size)
            let points = plotted.map(\.point)
            let hovered = nearestPlottedSample(to: hoverX, in: plotted)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.05))

                Path { path in
                    let y1 = geo.size.height * 0.28
                    let y2 = geo.size.height * 0.72
                    path.move(to: CGPoint(x: 0, y: y1))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y1))
                    path.move(to: CGPoint(x: 0, y: y2))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y2))
                }
                .stroke(Color.secondary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                if points.count >= 2 {
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                        path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        path.addLine(to: CGPoint(x: points.first!.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.red.opacity(0.12), Color.orange.opacity(0.08), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(
                        LinearGradient(
                            colors: [Color.green, Color.yellow, Color.orange, Color.red.opacity(0.85)],
                            startPoint: .bottom,
                            endPoint: .top
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )

                    if let hovered {
                        Path { path in
                            path.move(to: CGPoint(x: hovered.point.x, y: 0))
                            path.addLine(to: CGPoint(x: hovered.point.x, y: geo.size.height))
                        }
                        .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Color.orange, lineWidth: 2))
                            .frame(width: 9, height: 9)
                            .position(hovered.point)

                        hoverBadge(for: hovered.sample, point: hovered.point, size: geo.size)
                    } else {
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Color.orange, lineWidth: 2))
                            .frame(width: 8, height: 8)
                            .position(points.last!)
                    }
                } else {
                    Text("Waiting for CPU temperature history")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hoverX = location.x
                case .ended:
                    hoverX = nil
                }
            }
        }
    }

    @ViewBuilder
    private func hoverBadge(for sample: CPUTemperaturePoint, point: CGPoint, size: CGSize) -> some View {
        let badgeWidth: CGFloat = 86
        let horizontalOffset: CGFloat = 56
        let verticalOffset: CGFloat = 26
        let placeRight = point.x <= (size.width - badgeWidth - 24)
        let placeAbove = point.y >= 26
        let rawX = point.x + (placeRight ? horizontalOffset : -horizontalOffset)
        let rawY = point.y + (placeAbove ? -verticalOffset : verticalOffset)
        let anchorX = min(max(rawX, badgeWidth / 2), max(size.width - (badgeWidth / 2), badgeWidth / 2))
        let anchorY = min(max(rawY, 18), max(size.height - 18, 18))

        VStack(alignment: .leading, spacing: 2) {
            Text(hoverTimeString(sample.timestamp))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text("\(Int(round(sample.value)))°C")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .position(x: anchorX, y: anchorY)
    }

    private func hoverTimeString(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private func nearestPlottedSample(to hoverX: CGFloat?, in plotted: [(sample: CPUTemperaturePoint, point: CGPoint)]) -> (sample: CPUTemperaturePoint, point: CGPoint)? {
        guard let hoverX, !plotted.isEmpty else { return nil }
        return plotted.min(by: { abs($0.point.x - hoverX) < abs($1.point.x - hoverX) })
    }

    private func plottedSamples(in size: CGSize) -> [(sample: CPUTemperaturePoint, point: CGPoint)] {
        guard !samples.isEmpty else { return [] }
        let cutoff = Date().timeIntervalSince1970 - CPU_TEMP_HISTORY_WINDOW
        let filtered = samples.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
        guard !filtered.isEmpty else { return [] }

        let minValue = filtered.map(\.value).min() ?? 0
        let maxValue = filtered.map(\.value).max() ?? 0
        let valueSpan = max(maxValue - minValue, 4)
        let minY = minValue - 1
        let maxY = minY + valueSpan + 2
        let minTime = filtered.first!.timestamp
        let maxTime = max(filtered.last!.timestamp, minTime + 1)
        let chartWidth = max(size.width - 2, 1)
        let chartHeight = max(size.height - 2, 1)

        return filtered.map { sample in
            let x = ((sample.timestamp - minTime) / (maxTime - minTime)) * chartWidth + 1
            let normalized = (sample.value - minY) / (maxY - minY)
            let y = chartHeight - (normalized * chartHeight) + 1
            return (sample: sample, point: CGPoint(x: x, y: y))
        }
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
    @State private var showSettings = false
    @State private var showAdvancedSettings = false
    @State private var showPowerSettings = false

    var body: some View {
        Group {
            if vm.showOnboarding {
                onboardingView
            } else {
                mainView
            }
        }
        .frame(width: 360, height: 700)
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

    private var mainView: some View {
        VStack(spacing: 0) {
            heroSection
                .padding(16)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    controlsSection.padding(16)
                    if vm.showsAIFeatures {
                        Divider().padding(.horizontal, 16)
                        whySection.padding(16)
                    }
                    Divider().padding(.horizontal, 16)
                    statusSection.padding(16)
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
    }

    private var onboardingView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set Up Awake")
                        .font(.system(size: 22, weight: .bold))
                    Text("Choose how you plan to use Awake, then finish the first-run setup so it can keep your Mac from sleeping when you need it.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("How will you use Awake?")
                        .font(.system(size: 13, weight: .semibold))

                    ForEach(AwakeAudience.allCases) { option in
                        onboardingAudienceCard(option)
                    }
                }

                onboardingStep(
                    title: "Allow sleep control",
                    detail: "Required. Lets Awake prevent sleep, including lid-close sleep.",
                    status: vm.sleepControlConfigured ? "Ready" : "Needs admin approval",
                    ready: vm.sleepControlConfigured,
                    actionTitle: "Enable",
                    action: vm.enableSleepControlAccess
                )

                Text("Optional")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                onboardingStep(
                    title: "Allow thermal readings",
                    detail: "Optional. Lets Awake show the thermal graph and current temperature in the status section.",
                    status: vm.temperatureConfigured ? "Ready" : "Optional admin approval",
                    ready: vm.temperatureConfigured,
                    actionTitle: "Enable",
                    action: vm.enableCpuTemperatureAccess
                )

                if vm.showsAIFeatures {
                    onboardingStep(
                        title: "Start automatic agent protection",
                        detail: "Optional. Launches the Awake daemon automatically when you sign in so coding-agent protection is always available.",
                        status: vm.launchAgentInstalled ? "Enabled" : "Disabled",
                        ready: vm.launchAgentInstalled,
                        actionTitle: "Enable",
                        action: vm.toggleLaunchAgent
                    )
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Personal mode hides daemon, hooks, and agent diagnostics so the app stays focused on manual keep-awake sessions.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.blue.opacity(0.14), lineWidth: 1)
                    )
                }

                onboardingStep(
                    title: "Allow menu bar control",
                    detail: "Optional. Lets Awake try to move its own menu bar icon toward the visible end of the menu bar, similar to manually Command-dragging it.",
                    status: vm.menuBarControlConfigured ? "Enabled" : "Optional Accessibility approval",
                    ready: vm.menuBarControlConfigured,
                    actionTitle: "Enable",
                    action: vm.enableMenuBarControl
                )

                HStack(spacing: 10) {
                    Button(vm.sleepControlConfigured ? "Open Awake" : "Continue anyway") {
                        vm.finishOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(vm.isBusy)

                    Button("Refresh checks") {
                        vm.refreshAsync()
                    }
                    .buttonStyle(.bordered)
                        .disabled(vm.isBusy)
                }

                Text("You can reopen this setup screen later from Settings if you want to enable the optional pieces.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text("If the menu bar ever feels crowded, reopen Awake from the Dock or with Ctrl+Shift+A.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func onboardingAudienceCard(_ option: AwakeAudience) -> some View {
        Button(action: { vm.setAudience(option) }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: vm.audience == option ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(vm.audience == option ? .green : .secondary)
                    .font(.system(size: 18))

                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(option.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(vm.audience == option ? Color.green.opacity(0.22) : Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func onboardingStep(
        title: String,
        detail: String,
        status: String,
        ready: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ready ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundColor(ready ? .green : .orange)
                    .font(.system(size: 18))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            HStack {
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ready ? .green : .secondary)
                Spacer()
                if !ready {
                    Button(actionTitle) { action() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.green)
                        .disabled(vm.isBusy)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ready ? Color.green.opacity(0.22) : Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Hero

    private var heroSection: some View {
        HStack(spacing: 14) {
            Button(action: {
                if vm.isNosleep {
                    vm.nosleepOff()
                } else {
                    vm.nosleepOn()
                }
            }) {
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
            }
            .buttonStyle(.plain)
            .disabled(vm.isBusy)
            .help(vm.isNosleep ? "Click to switch to Sleep OK" : "Click to turn Awake on")
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
                    if vm.showsAIFeatures && vm.agentsActive {
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
                    if vm.showsAIFeatures && vm.daemonRunning { TagBadge(text: "daemon", color: .green) }
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
            SectionLabel(
                text: "Status",
                help: "Live state for Awake.\n\nExample: if you see `Nosleep active · codex(1)`, Awake is currently overriding your normal sleep settings because it detected an agent session."
            )

            cpuTemperatureCard
                .padding(.bottom, 8)

            if vm.showsAIFeatures {
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
            }

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

    private var cpuTemperatureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(vm.cpuTempLabel)
                            .font(.system(size: 12, weight: .semibold))
                        InfoPopoverButton(text: "Live thermal reading with a rolling 12-hour history.\n\nAwake prefers CPU temperature from macOS powermetrics when available. If this Mac does not expose CPU temperature there, Awake falls back to NVMe/SSD SMART temperature instead.\n\nExample: if the graph ramps up while agents are running with the lid closed, you can spot sustained heat instead of only seeing the current number.")
                    }
                    Text("\(vm.cpuTempDetail) • last 12 hours")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(vm.cpuTempCurrent.map { "\(Int(round($0)))°C" } ?? "N/A")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(vm.cpuTempCurrent == nil ? .secondary : .primary)
                    Text(vm.cpuTempCurrent == nil ? vm.cpuTempStatus : "now")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            TemperatureSparkline(samples: vm.cpuTempHistory)
                .frame(height: 72)

            if vm.cpuTempCurrent == nil {
                HStack(alignment: .center, spacing: 10) {
                    Text(vm.cpuTempStatus)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    if vm.cpuTempNeedsSetup {
                        Button("Enable") {
                            vm.enableCpuTemperatureAccess()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.green)
                        .disabled(vm.isBusy)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.14), lineWidth: 1)
        )
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(
                text: "Controls",
                help: "Immediate actions that change sleep behavior right now.\n\nExample: `Nosleep ON` temporarily overpowers your normal Mac sleep timers, while `Sleep OK` restores your saved baseline behavior."
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Mac awake (even on close)")
                            .font(.system(size: 13, weight: .semibold))
                        Text(vm.isNosleep
                            ? "Awake is overriding normal sleep and lid-close sleep"
                            : "Your Mac is following normal sleep behavior")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { vm.isNosleep },
                        set: { enabled in
                            if enabled {
                                vm.nosleepOn()
                            } else {
                                vm.nosleepOff()
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(vm.isBusy)
                }

                HStack(spacing: 8) {
                    Label("Normal Sleep", systemImage: "moon.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(vm.isNosleep ? .secondary : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(vm.isNosleep ? Color.secondary.opacity(0.10) : Color.secondary.opacity(0.16))
                        )

                    Label("Awake Override", systemImage: "bolt.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(vm.isNosleep ? .green : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(vm.isNosleep ? Color.green.opacity(0.14) : Color.secondary.opacity(0.10))
                        )

                    Spacer()
                }
            }

            HStack(spacing: 6) {
                Text("Sleep in")
                    .font(.system(size: 13, weight: .semibold))

                Picker("", selection: $vm.selectedDuration) {
                    ForEach(DurationOption.allCases, id: \.self) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .labelsHidden()
                .frame(width: 72)

                Button("Start timer") { vm.awakeFor() }
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

            if vm.showsAIFeatures {
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

                Divider()
            }

            Button(role: .destructive, action: { vm.sleepNow() }) {
                Label("Sleep Now", systemImage: "power.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            HStack(spacing: 6) {
                Text("Default mode")
                    .font(.system(size: 12, weight: .medium))
                InfoPopoverButton(text: vm.showsAIFeatures
                    ? "Used for daemon sessions, timers, and `awake run` commands.\n\nKeep Running is the default because it keeps the Mac awake without forcing the display to stay on.\n\nAgent Safe chooses automatically based on display-sleep settings. Keep Presenting keeps both the Mac and the display awake."
                    : "Used for timers and `awake run` commands.\n\nKeep Running keeps the Mac awake without forcing the display to stay on. Keep Presenting keeps both the Mac and the display awake.")

                Picker("", selection: Binding(
                    get: { vm.defaultMode },
                    set: { vm.setDefaultMode($0) }
                )) {
                    Text("Keep Running").tag("running")
                    if vm.showsAIFeatures {
                        Text("Agent Safe").tag("agent-safe")
                    }
                    Text("Keep Presenting").tag("presenting")
                }
                .labelsHidden()
                .frame(width: 170)

                Spacer()
            }

            Text(vm.showsAIFeatures
                ? "Applies when Awake starts automatically or through timers and commands."
                : "Applies to timers and command-based Awake sessions.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Use Awake as")
                            .font(.system(size: 12, weight: .medium))

                        Picker("", selection: Binding(
                            get: { vm.audience },
                            set: { vm.setAudience($0) }
                        )) {
                            ForEach(AwakeAudience.allCases) { option in
                                Text(option.shortTitle).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 150, alignment: .leading)

                        Spacer()
                    }

                    Text(vm.showsAIFeatures
                        ? "Shows daemon, agent, and automatic protection controls."
                        : "Hides daemon, hooks, and most AI diagnostics to keep the app simpler.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

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

                    if vm.showsAIFeatures {
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

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Dock icon")
                            .font(.system(size: 12))
                        Text("Always visible so Awake stays easy to reopen")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        TagBadge(text: "always on", color: .green)
                    }

                    Button("Open setup guide") {
                        vm.reopenOnboarding()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Move top icon forward") {
                        vm.promoteMenuBarIcon()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Divider()

                    DisclosureGroup(isExpanded: $showPowerSettings) {
                        if !vm.availableSettingsSources.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Text("Source")
                                        .font(.system(size: 12, weight: .medium))

                                    Picker("", selection: $vm.selectedSettingsSource) {
                                        ForEach(vm.availableSettingsSources) { source in
                                            Text(source.title).tag(source)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(width: 170, alignment: .leading)

                                    Spacer()
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(sleepSettingDefinitions.filter { !$0.isAdvanced }) { setting in
                                        settingRow(setting)
                                    }
                                }

                                DisclosureGroup(isExpanded: $showAdvancedSettings) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(sleepSettingDefinitions.filter(\.isAdvanced)) { setting in
                                            settingRow(setting)
                                        }
                                    }
                                    .padding(.top, 6)
                                } label: {
                                    Text("Advanced")
                                        .font(.system(size: 12, weight: .medium))
                                }

                                if vm.awakeOverrideActive {
                                    Text("Awake is currently overriding live sleep behavior. Changes here update the baseline immediately and will be restored when Awake turns off.")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Changes apply immediately, like macOS System Settings.")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, 8)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Power settings")
                                    .font(.system(size: 12))
                                Text(vm.awakeOverrideActive
                                    ? "Editing baseline while Awake override is active"
                                    : "Baseline sleep behavior for this Mac")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if vm.awakeOverrideActive {
                                TagBadge(text: "override", color: .orange)
                            }
                            InfoPopoverButton(text: "These are your baseline Mac sleep settings.\n\nExample: if `System sleep after` is 15m and Awake is inactive, macOS will sleep normally after 15 minutes. If Awake is active, Awake temporarily overpowers that until it turns off.\n\nLike macOS System Settings, changes here apply immediately.")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showPowerSettings.toggle()
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    SectionLabel(
                        text: "Settings",
                        help: "Persistent settings for how your Mac behaves when Awake is not actively overriding sleep.\n\nExample: set `Display sleep after` to 5m here, then Awake can temporarily ignore that while an agent is running."
                    )
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    showSettings.toggle()
                }
            }
        }
    }

    private var whySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(
                text: "Why Awake",
                help: "The reason Awake is currently preventing sleep.\n\nExample: a daemon agent lease, a manual timer, or a running command can all hold the Mac awake at the same time. Awake resolves that to one effective mode and shows the active owners here."
            )

            VStack(alignment: .leading, spacing: 8) {
                StatRow(
                    label: "Effective mode",
                    value: vm.appliedModeLabel,
                    valueColor: vm.isNosleep ? .green : .secondary,
                    mono: false
                )

                Text(vm.whyAwakeText)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !vm.restorePlanText.isEmpty {
                    Text(vm.restorePlanText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    TagBadge(text: "\(vm.leaseCount) leases", color: vm.leaseCount > 0 ? .green : .secondary)
                    TagBadge(text: "\(vm.ruleCount) rules", color: vm.ruleCount > 0 ? .orange : .secondary)
                }

                if !vm.warnings.isEmpty {
                    ForEach(vm.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }

                if !vm.activeLeases.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.activeLeases.sorted(by: { lhs, rhs in
                            if lhs.priority == rhs.priority { return lhs.startedAt > rhs.startedAt }
                            return lhs.priority > rhs.priority
                        })) { lease in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(lease.id) • \(formatModeLabel(lease.mode))")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(lease.reason)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if !vm.configuredRules.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Configured rules")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        ForEach(vm.configuredRules.prefix(4)) { rule in
                            Text("\(rule.type)=\(rule.value) → \(formatModeLabel(rule.mode))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.14), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func settingRow(_ setting: SettingDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(setting.title)
                            .font(.system(size: 12))
                        InfoPopoverButton(text: setting.help)
                    }
                    Text(setting.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                settingControl(for: setting)
            }

            if let effective = vm.effectiveValueForSelectedSource(setting.key) {
                let baseline = vm.valueForSelectedSource(setting.key)
                if vm.awakeOverrideActive && effective != baseline {
                    Text("Effective now: \(formatSettingValue(setting.key, value: effective))")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }

            if vm.isApplyingSetting(setting.key) {
                Text("Saving...")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func settingControl(for setting: SettingDefinition) -> some View {
        switch setting.kind {
        case .boolean:
            Picker("", selection: Binding(
                get: { vm.valueForSelectedSource(setting.key) },
                set: { vm.updatePowerSetting(setting.key, $0) }
            )) {
                Text("Off").tag(0)
                Text("On").tag(1)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 92)
            .disabled(vm.isApplyingSetting(setting.key))

        case .minutes(let options):
            Picker("", selection: Binding(
                get: { vm.valueForSelectedSource(setting.key) },
                set: { vm.updatePowerSetting(setting.key, $0) }
            )) {
                ForEach(options, id: \.self) { value in
                    Text(formatMinutes(value)).tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 110)
            .disabled(vm.isApplyingSetting(setting.key))

        case .hibernate(let options):
            Picker("", selection: Binding(
                get: { vm.valueForSelectedSource(setting.key) },
                set: { vm.updatePowerSetting(setting.key, $0) }
            )) {
                ForEach(options, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 90)
            .disabled(vm.isApplyingSetting(setting.key))
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(
                    text: "Log",
                    help: "Recent Awake events in chronological order.\n\nExample: use this to confirm whether a timer restored `Sleep OK`, whether the daemon detected agents, or whether baseline settings were applied."
                )
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

    override func resignMain() {
        super.resignMain()
        orderOut(nil)
    }

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
        hidesOnDeactivate = true
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
    var modeText: String = ""
    var whyText: String = ""
    var warningCount: Int = 0
    var showsAIFeatures: Bool = true
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    var statusItem: NSStatusItem!
    var panel: AwakePanel!
    var hasPositioned = false
    private var iconTimer: AnyCancellable?
    var cachedMenu = MenuSnapshot()
    private var pendingPromotionWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        applyDockIconVisibility()

        // Status bar item — compact by default, but wide enough to show uptime while awake.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.autosaveName = "com.awake.statusitem"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "awake")
            button.image?.size = NSSize(width: 14, height: 14)
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
            button.title = ""
            // Left-click = toggle Awake, Right-click = open panel
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Awake\nLeft-click: toggle awake\nRight-click: open panel\nHotkey: Ctrl+Shift+A"
        }

        // No menu assigned — we show it programmatically on right-click

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
        scheduleStatusItemPromotion()
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw) else { return }
        handleAutomationURL(url)
    }

    private func handleAutomationURL(_ url: URL) {
        let action = url.host ?? url.pathComponents.dropFirst().first ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        switch action {
        case "open", "panel":
            DispatchQueue.main.async { self.showPanel() }
        case "toggle":
            let isNosleep = (readFile(STATE_FILE) ?? "").hasPrefix("nosleep")
            DispatchQueue.global(qos: .userInitiated).async {
                runCommand(AWAKE_CMD, [isNosleep ? "yessleep" : "on"])
            }
        case "timer":
            let duration = queryValue("duration")
                ?? queryValue("minutes").map { "\($0)m" }
                ?? queryValue("hours").map { "\($0)h" }
            guard let duration else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                runCommand(AWAKE_CMD, ["for", duration])
            }
        case "mode":
            guard let mode = queryValue("name") ?? queryValue("mode") else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                runCommand(AWAKE_CMD, ["mode", "set", mode])
            }
        case "sleep":
            DispatchQueue.global(qos: .userInitiated).async {
                runCommand(AWAKE_CMD, ["sleep"], timeout: 10)
            }
        default:
            break
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applyDockIconVisibility() {
        NSApp.setActivationPolicy(.regular)
    }

    func scheduleStatusItemPromotion() {
        pendingPromotionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.promoteStatusItemToVisibleEdge(promptIfNeeded: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.promoteStatusItemToVisibleEdge(promptIfNeeded: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
                self?.promoteStatusItemToVisibleEdge(promptIfNeeded: false)
            }
        }
        pendingPromotionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: workItem)
    }

    func promoteStatusItemToVisibleEdge(promptIfNeeded: Bool) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        guard hasMenuBarControlAccess() else {
            if promptIfNeeded {
                requestMenuBarControlAccessPrompt()
            }
            return
        }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let startPoint = CGPoint(x: screenRect.midX, y: screenRect.midY)

        guard let screen = buttonWindow.screen ?? NSScreen.screens.first(where: { $0.frame.contains(startPoint) }) else {
            return
        }

        let targetXs: [CGFloat] = [
            screen.frame.maxX - 170,
            screen.frame.maxX - 240,
            screen.frame.maxX - 320
        ]

        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            let originalCursor = NSEvent.mouseLocation

            func postMouse(_ type: CGEventType, point: CGPoint, flags: CGEventFlags) {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                    return
                }
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }

            func postKey(_ down: Bool) {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: down) else { return }
                event.flags = down ? .maskCommand : []
                event.post(tap: .cghidEventTap)
            }

            for targetX in targetXs {
                let endPoint = CGPoint(x: targetX, y: startPoint.y)
                postKey(true)
                usleep(12_000)
                CGWarpMouseCursorPosition(startPoint)
                usleep(12_000)
                postMouse(.mouseMoved, point: startPoint, flags: .maskCommand)
                postMouse(.leftMouseDown, point: startPoint, flags: .maskCommand)

                let steps = 24
                for step in 1...steps {
                    let progress = CGFloat(step) / CGFloat(steps)
                    let point = CGPoint(
                        x: startPoint.x + ((endPoint.x - startPoint.x) * progress),
                        y: startPoint.y
                    )
                    CGWarpMouseCursorPosition(point)
                    postMouse(.leftMouseDragged, point: point, flags: .maskCommand)
                    usleep(10_000)
                }

                CGWarpMouseCursorPosition(endPoint)
                postMouse(.leftMouseUp, point: endPoint, flags: .maskCommand)
                usleep(12_000)
                postKey(false)
                usleep(120_000)
            }

            CGWarpMouseCursorPosition(originalCursor)
        }
    }

    // MARK: - Status Item Click Handler

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showPanel()
        } else {
            toggleAwakeFromStatusItem()
        }
    }

    private func toggleAwakeFromStatusItem() {
        let state = readFile(STATE_FILE) ?? "unknown"
        let isNosleep = state.hasPrefix("nosleep")
        let command: String
        if isNosleep {
            command = "yessleep"
        } else if FileManager.default.fileExists(atPath: DISPLAY_SLEEP_FILE) {
            command = "nosleep-display"
        } else {
            command = "nosleep"
        }

        DispatchQueue.global(qos: .userInitiated).async {
            runCommand(AWAKE_CMD, [command])
            DispatchQueue.main.async { [weak self] in self?.refreshIcon() }
        }
    }

    // MARK: - Icon & Uptime Refresh

    func refreshIcon() {
        let state = readFile(STATE_FILE) ?? "unknown"
        let isNosleep = state.hasPrefix("nosleep")
        guard let button = statusItem.button else { return }
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]

        if isNosleep {
            let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "nosleep")
            img?.isTemplate = false
            button.image = img
            button.image?.size = NSSize(width: 13, height: 13)
            button.contentTintColor = .systemGreen
            let uptimeText = getUptime().map { formatDuration(Int($0)) } ?? ""
            button.title = ""
            button.attributedTitle = NSAttributedString(
                string: uptimeText.isEmpty ? "" : " \(uptimeText)",
                attributes: textAttributes
            )
            let uptimeSuffix = uptimeText.isEmpty ? "" : " (\(uptimeText))"
            button.toolTip = "Awake\nNosleep active\(uptimeSuffix)\nLeft-click: toggle awake\nRight-click: open panel\nHotkey: Ctrl+Shift+A"
        } else {
            let img = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "sleep ok")
            img?.isTemplate = true
            button.image = img
            button.image?.size = NSSize(width: 13, height: 13)
            button.contentTintColor = nil
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "", attributes: textAttributes)
            button.toolTip = "Awake\nNormal sleep\nLeft-click: toggle awake\nRight-click: open panel\nHotkey: Ctrl+Shift+A"
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

        menu.addItem(NSMenuItem(title: "Open Panel", action: #selector(showPanelAction), keyEquivalent: "p"))
        menu.addItem(NSMenuItem.separator())

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

        if s.showsAIFeatures && !s.agents.isEmpty {
            let agentStr = s.agents.sorted(by: { $0.key < $1.key }).map { "\($0.key)(\($0.value))" }.joined(separator: " ")
            let agentItem = NSMenuItem(title: "  Agents: \(agentStr)", action: nil, keyEquivalent: "")
            agentItem.isEnabled = false
            menu.addItem(agentItem)
        }

        if s.showsAIFeatures && s.hookCount > 0 {
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

        if !s.modeText.isEmpty {
            let modeItem = NSMenuItem(title: "  Mode: \(s.modeText)", action: nil, keyEquivalent: "")
            modeItem.isEnabled = false
            menu.addItem(modeItem)
        }

        if !s.whyText.isEmpty {
            let whyItem = NSMenuItem(title: "  Why: \(s.whyText)", action: nil, keyEquivalent: "")
            whyItem.isEnabled = false
            menu.addItem(whyItem)
        }

        if s.showsAIFeatures && s.warningCount > 0 {
            let warningItem = NSMenuItem(title: "  Warnings: \(s.warningCount)", action: nil, keyEquivalent: "")
            warningItem.isEnabled = false
            menu.addItem(warningItem)
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
        let timerParent = NSMenuItem(title: "Sleep in", action: nil, keyEquivalent: "")
        timerParent.submenu = timerMenu
        menu.addItem(timerParent)

        if s.showsAIFeatures {
            if s.isDaemon {
                menu.addItem(NSMenuItem(title: "Stop Daemon", action: #selector(menuStopDaemon), keyEquivalent: ""))
            } else {
                menu.addItem(NSMenuItem(title: "Start Daemon", action: #selector(menuStartDaemon), keyEquivalent: ""))
            }
        }

        menu.addItem(NSMenuItem.separator())
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
        DispatchQueue.global(qos: .userInitiated).async { runCommand(AWAKE_CMD, ["cancel-timer"]) }
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
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
