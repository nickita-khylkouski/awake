import AppKit
import Carbon
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement
import SwiftUI

private let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/awake/state.json")
private let closedLidMarkerURL = stateURL.deletingLastPathComponent().appendingPathComponent("closed-lid-active")

private struct CommandResult {
    let status: Int32
    let output: String
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) -> CommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    } catch {
        return CommandResult(status: -1, output: error.localizedDescription)
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func fourCC(_ value: String) -> OSType {
    value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
}

private func formatRemaining(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(ceil(seconds)))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

final class WakeAssertion {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0

    var isActive: Bool { systemID != 0 }

    func start(keepDisplayOn: Bool) throws {
        var newSystemID: IOPMAssertionID = 0
        let reason = "Awake is preventing idle system sleep" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &newSystemID
        )
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "Awake", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "macOS refused the wake assertion."])
        }
        var newDisplayID: IOPMAssertionID = 0
        if keepDisplayOn {
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Awake is keeping the display on" as CFString,
                &newDisplayID
            )
            guard displayResult == kIOReturnSuccess else {
                IOPMAssertionRelease(newSystemID)
                throw NSError(domain: "Awake", code: Int(displayResult), userInfo: [NSLocalizedDescriptionKey: "macOS refused the display assertion."])
            }
        }
        stop()
        systemID = newSystemID
        displayID = newDisplayID
    }

    func stop() {
        if displayID != 0 { IOPMAssertionRelease(displayID); displayID = 0 }
        if systemID != 0 { IOPMAssertionRelease(systemID); systemID = 0 }
    }

    deinit { stop() }
}

final class ClosedLidController {
    private let markerURL = closedLidMarkerURL
    private var permissionPath: String { "/etc/sudoers.d/awake-\(getuid())" }
    private let helperPath = "/Library/PrivilegedHelperTools/com.awake/awake-power"
    private var owner: String { String(getuid()) }
    private var cachedSetupComplete: Bool?
    var ownsSetting: Bool { FileManager.default.fileExists(atPath: markerURL.path) }
    private(set) var isActive = false
    var setupComplete: Bool {
        if let cachedSetupComplete { return cachedSetupComplete }
        let verified = FileManager.default.fileExists(atPath: permissionPath) &&
        FileManager.default.isExecutableFile(atPath: helperPath) && helperMatchesBundle &&
        !legacyPermissionPresent && permissionAvailable()
        cachedSetupComplete = verified
        return verified
    }
    var legacyPermissionPresent: Bool {
        FileManager.default.fileExists(atPath: "/etc/sudoers.d/pmset") ||
        FileManager.default.fileExists(atPath: "/etc/sudoers.d/powermetrics")
    }
    private var helperMatchesBundle: Bool {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("awake-power") else { return false }
        let expected = run("/usr/bin/shasum", ["-a", "256", bundled.path]).output.split(whereSeparator: { $0.isWhitespace }).first
        let installed = run("/usr/bin/shasum", ["-a", "256", helperPath]).output.split(whereSeparator: { $0.isWhitespace }).first
        return expected != nil && expected == installed
    }
    lazy var isSupportedMac: Bool = run("/usr/sbin/system_profiler", ["SPHardwareDataType"]).output.contains("MacBook")

    func permissionAvailable() -> Bool {
        run("/usr/bin/sudo", ["-n", "-l", helperPath, "on", owner]).status == 0 &&
        run("/usr/bin/sudo", ["-n", "-l", helperPath, "off", owner]).status == 0
    }

    func installPermission() -> Bool {
        let username = NSUserName()
        guard username.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return false }
        guard let bundledHelper = Bundle.main.resourceURL?.appendingPathComponent("awake-power"),
              FileManager.default.isReadableFile(atPath: bundledHelper.path) else { return false }
        let hashOutput = run("/usr/bin/shasum", ["-a", "256", bundledHelper.path]).output
        guard let helperHash = hashOutput.split(whereSeparator: { $0.isWhitespace }).first,
              helperHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return false }
        let helperSource = shellQuote(bundledHelper.path)
        let rule = "\(username) ALL=(root) NOPASSWD: \(helperPath) on \(owner), \(helperPath) off \(owner)"
        let oldPmset = "\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset"
        let oldMetrics = "\(username) ALL=(ALL) NOPASSWD: /usr/bin/powermetrics"
        let shell = "umask 077; helperTemporary=$(/usr/bin/mktemp /private/tmp/awake-power.XXXXXX) || exit 1; trap '/bin/rm -f \"$helperTemporary\" \"$temporary\"' EXIT; /bin/cp \(helperSource) \"$helperTemporary\"; /usr/sbin/chown root:wheel \"$helperTemporary\"; /bin/chmod 700 \"$helperTemporary\"; [ \"$(/usr/bin/shasum -a 256 \"$helperTemporary\" | /usr/bin/awk '{print $1}')\" = '\(helperHash)' ] || exit 1; /bin/mkdir -p /Library/PrivilegedHelperTools/com.awake; /usr/sbin/chown root:wheel /Library/PrivilegedHelperTools/com.awake; /bin/chmod 755 /Library/PrivilegedHelperTools/com.awake; for directory in /Library /Library/PrivilegedHelperTools /Library/PrivilegedHelperTools/com.awake; do [ \"$(/usr/bin/stat -f %u \"$directory\")\" = 0 ] || exit 1; mode=$(/usr/bin/stat -f %Lp \"$directory\"); [ $((0$mode & 022)) -eq 0 ] || exit 1; done; /usr/bin/install -o root -g wheel -m 755 \"$helperTemporary\" '\(helperPath)' || exit 1; temporary=$(/usr/bin/mktemp /private/tmp/awake-sudoers.XXXXXX) || exit 1; /usr/bin/printf '%s\\n' '\(rule)' > \"$temporary\" && /usr/sbin/visudo -cf \"$temporary\" && /usr/bin/install -o root -g wheel -m 440 \"$temporary\" '\(permissionPath)' || exit 1; if [ -f /etc/sudoers.d/pmset ] && [ \"$(/bin/cat /etc/sudoers.d/pmset)\" = '\(oldPmset)' ]; then /bin/rm -f /etc/sudoers.d/pmset; fi; if [ -f /etc/sudoers.d/powermetrics ] && [ \"$(/bin/cat /etc/sudoers.d/powermetrics)\" = '\(oldMetrics)' ]; then /bin/rm -f /etc/sudoers.d/powermetrics; fi"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        guard run("/usr/bin/osascript", ["-e", script]).status == 0 else { return false }
        cachedSetupComplete = nil
        return setupComplete
    }

    func removeLegacyPermission() -> Bool {
        let username = NSUserName()
        guard username.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return false }
        let oldPmset = "\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset"
        let oldMetrics = "\(username) ALL=(ALL) NOPASSWD: /usr/bin/powermetrics"
        let shell = "if [ -f /etc/sudoers.d/pmset ] && [ \"$(/bin/cat /etc/sudoers.d/pmset)\" = '\(oldPmset)' ]; then /bin/rm -f /etc/sudoers.d/pmset; fi; if [ -f /etc/sudoers.d/powermetrics ] && [ \"$(/bin/cat /etc/sudoers.d/powermetrics)\" = '\(oldMetrics)' ]; then /bin/rm -f /etc/sudoers.d/powermetrics; fi"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"]).status == 0 else { return false }
        cachedSetupComplete = nil
        return !legacyPermissionPresent
    }

    func recoverInterruptedSession() {
        guard ownsSetting else { return }
        _ = disable()
    }

    func enable() -> Bool {
        if ownsSetting {
            guard validMarker else { return false }
            isActive = run("/usr/bin/sudo", ["-n", helperPath, "on", owner]).status == 0
            return isActive
        }
        do {
            try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("owned".utf8).write(to: markerURL, options: .atomic)
        } catch { return false }
        guard run("/usr/bin/sudo", ["-n", helperPath, "on", owner]).status == 0 else { return false }
        isActive = true
        return true
    }

    @discardableResult
    func disable() -> Bool {
        guard ownsSetting else { return true }
        guard validMarker else { return false }
        guard run("/usr/bin/sudo", ["-n", helperPath, "off", owner]).status == 0 else { return false }
        try? FileManager.default.removeItem(at: markerURL)
        isActive = false
        return true
    }

    func disableWithAuthorization() -> Bool {
        guard ownsSetting else { return true }
        guard validMarker else { return false }
        guard let bundledHelper = Bundle.main.resourceURL?.appendingPathComponent("awake-power"),
              FileManager.default.isReadableFile(atPath: bundledHelper.path) else { return false }
        let hashOutput = run("/usr/bin/shasum", ["-a", "256", bundledHelper.path]).output
        guard let helperHash = hashOutput.split(whereSeparator: { $0.isWhitespace }).first,
              helperHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return false }
        let source = shellQuote(bundledHelper.path)
        let shell = "umask 077; helperTemporary=$(/usr/bin/mktemp /private/tmp/awake-power.XXXXXX) || exit 1; trap '/bin/rm -f \"$helperTemporary\"' EXIT; /bin/cp \(source) \"$helperTemporary\"; /usr/sbin/chown root:wheel \"$helperTemporary\"; /bin/chmod 700 \"$helperTemporary\"; [ \"$(/usr/bin/shasum -a 256 \"$helperTemporary\" | /usr/bin/awk '{print $1}')\" = '\(helperHash)' ] || exit 1; /bin/mkdir -p /Library/PrivilegedHelperTools/com.awake; /usr/sbin/chown root:wheel /Library/PrivilegedHelperTools/com.awake; /bin/chmod 755 /Library/PrivilegedHelperTools/com.awake; for directory in /Library /Library/PrivilegedHelperTools /Library/PrivilegedHelperTools/com.awake; do [ \"$(/usr/bin/stat -f %u \"$directory\")\" = 0 ] || exit 1; mode=$(/usr/bin/stat -f %Lp \"$directory\"); [ $((0$mode & 022)) -eq 0 ] || exit 1; done; /usr/bin/install -o root -g wheel -m 755 \"$helperTemporary\" '\(helperPath)' && '\(helperPath)' off '\(owner)'"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        guard run("/usr/bin/osascript", ["-e", script]).status == 0 else { return false }
        try? FileManager.default.removeItem(at: markerURL)
        isActive = false
        return true
    }

    private var validMarker: Bool {
        (try? String(contentsOf: markerURL, encoding: .utf8)) == "owned"
    }
}

final class BlackoutWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class BlackoutView: NSView {
    var restore: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { restore?() }
        else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) { restore?() }
    override func accessibilityPerformPress() -> Bool { restore?(); return true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Screen blackout active. Press Escape or click to restore." }
}

final class BlackoutController {
    private(set) var isActive = false
    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var previousApplication: NSRunningApplication?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func toggle() { isActive ? hide() : show() }

    func show() {
        guard !isActive else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        isActive = true
        rebuildWindows()
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.hide()
                return nil
            }
            return event
        }
    }

    func hide() {
        guard isActive else { return }
        isActive = false
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        NSCursor.unhide()
        previousApplication?.activate(options: [.activateIgnoringOtherApps])
        previousApplication = nil
    }

    @objc private func screensChanged() {
        if isActive { rebuildWindows() }
    }

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = BlackoutWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.backgroundColor = .black
            window.isOpaque = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.setFrame(screen.frame, display: true)
            let content = BlackoutView(frame: screen.frame)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            content.restore = { [weak self] in self?.hide() }
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(content)
            return window
        }
    }

    deinit { hide() }
}

final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let identifier: EventHotKeyID
    private(set) var isRegistered = false

    init(keyCode: UInt32 = UInt32(kVK_ANSI_1), modifiers: UInt32 = UInt32(optionKey), id: UInt32 = 1, action: @escaping () -> Void) {
        self.action = action
        self.identifier = EventHotKeyID(signature: fourCC("AWAK"), id: id)
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, pointer in
                guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
                var received = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &received
                )
                guard status == noErr, received.signature == hotKey.identifier.signature, received.id == hotKey.identifier.id else {
                    return OSStatus(eventNotHandledErr)
                }
                hotKey.action()
                return noErr
            },
            1,
            &event,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        isRegistered = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference) == noErr
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct AwakePanelView: View {
    let active: Bool
    let restorationPending: Bool
    let statusText: String
    let battery: BatterySnapshot?
    let batteryError: String?
    let duration: Int?
    let keepDisplayOn: Bool
    let keepWorkingWithLidClosed: Bool
    let supportsClosedLid: Bool
    let closedLidNeedsSetup: Bool
    let blackoutActive: Bool
    let launchAtLogin: Bool
    let toggleSession: () -> Void
    let setDuration: (Int) -> Void
    let toggleDisplay: () -> Void
    let toggleClosedLid: () -> Void
    let toggleBlackout: () -> Void
    let toggleLogin: () -> Void
    let restoreNormalSleep: () -> Void
    let showAbout: () -> Void
    let quit: () -> Void

    private var accent: Color { Color(nsColor: .systemOrange) }
    private var blocked: Bool { battery?.isCritical == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Awake", systemImage: "sun.max.fill")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(active ? accent : Color.secondary).frame(width: 6, height: 6)
                    Text(active ? "ON" : "OFF").font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(active ? accent.opacity(0.12) : Color.secondary.opacity(0.08), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(blocked ? "Time to recharge." : (active ? "Your Mac stays awake." : "Let your Mac rest."))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .tracking(-0.6)
                Text(statusText)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .monospacedDigit()
                Button(action: toggleSession) {
                    HStack(spacing: 8) {
                        Image(systemName: "power")
                        Text(active ? "Turn off" : "Keep awake").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .background(blocked ? Color.secondary : Color.primary, in: RoundedRectangle(cornerRadius: 11))
                    .contentShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .disabled(blocked && !active)
                .padding(.top, 5)
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("KEEP AWAKE FOR").font(.system(size: 10, weight: .semibold)).tracking(1)
                    Spacer()
                    Menu("More") {
                        Button("15 minutes") { setDuration(900) }
                        Button("4 hours") { setDuration(14400) }
                        Button("8 hours") { setDuration(28800) }
                    }.menuStyle(.borderlessButton).fixedSize()
                }.foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    durationButton("30 min", seconds: 1800)
                    durationButton("1 hour", seconds: 3600)
                    durationButton("2 hours", seconds: 7200)
                    durationButton("Forever", seconds: 0)
                }
            }.disabled(blocked)

            VStack(spacing: 15) {
                option("Keep display on", detail: "Otherwise, the screen can sleep.", symbol: "display", value: keepDisplayOn, action: toggleDisplay)
                if supportsClosedLid {
                    Divider()
                    if closedLidNeedsSetup {
                        Button(action: toggleClosedLid) {
                            HStack {
                                Image(systemName: "laptopcomputer").frame(width: 22)
                                Text("Set up closed-lid mode")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }.buttonStyle(.plain)
                    } else {
                        option("Keep working with lid closed", detail: "Keep your Mac on a ventilated surface.", symbol: "laptopcomputer", value: keepWorkingWithLidClosed, action: toggleClosedLid)
                    }
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: blocked ? "battery.0percent" : "battery.25percent")
                        .foregroundStyle(blocked ? Color.red : accent)
                    Text("Auto-sleep at 5%").fontWeight(.medium)
                    Spacer()
                    Text(battery.map { "\($0.percent)%" } ?? "—").monospacedDigit()
                }.font(.system(size: 12))
                Text(batteryError ?? (blocked ? "Connect power before starting another session." : (battery?.onBattery == true ? "On battery · protection is always on." : (battery == nil ? "Battery reading unavailable." : "On power · sleeps at 5% when unplugged."))))
                    .font(.system(size: 11)).foregroundStyle(batteryError == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                if restorationPending {
                    Button("Restore normal sleep", action: restoreNormalSleep)
                        .font(.caption).buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 2)

            Divider()
            HStack {
                Button(action: toggleBlackout) {
                    Label(blackoutActive ? "Restore screens" : "Black out screens", systemImage: "eye.slash")
                }.buttonStyle(.plain)
                Spacer()
                Menu {
                    Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { _ in toggleLogin() }))
                    Button("About Awake", action: showAbout)
                    Divider()
                    Button("Quit Awake", action: quit)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 16))
                        .accessibilityLabel("Settings and quit")
                }.menuStyle(.borderlessButton).fixedSize()
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
    }

    private func durationButton(_ label: String, seconds: Int) -> some View {
        let selected = active && (seconds == 0 ? duration == nil : duration == seconds)
        return Button { setDuration(seconds) } label: {
            Text(label).font(.system(size: 11, weight: selected ? .semibold : .medium))
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(selected ? accent.opacity(0.15) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? accent.opacity(0.6) : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "")
    }

    private func option(_ title: String, detail: String, symbol: String, value: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22)
            Toggle(isOn: Binding(get: { value }, set: { _ in action() })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let assertion = WakeAssertion()
    private let closedLid = ClosedLidController()
    private let blackout = BlackoutController()
    private var hotKey: GlobalHotKey?
    private var panelHotKey: GlobalHotKey?
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let quickMenu = NSMenu()
    private var panelController: NSHostingController<AwakePanelView>?
    private var standalonePanel: NSPanel?
    private var standaloneController: NSHostingController<AwakePanelView>?
    private var timer: Timer?
    private var batteryTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private var battery: BatterySnapshot?
    private let batteryProtection = BatteryProtection()
    private var pendingCommands: [AwakeCommand] = []
    private var isReady = false
    private var sessionDuration: Int?
    private var deadline: Date?
    private var menuIsOpen = false
    private weak var activeStatusMenuItem: NSMenuItem?
    private var keepDisplayOn = UserDefaults.standard.bool(forKey: "keepDisplayOn")
    private var keepWorkingWithLidClosed = UserDefaults.standard.object(forKey: "keepWorkingWithLidClosed") as? Bool ?? true
    private var restorationPending: Bool {
        closedLid.ownsSetting && (!assertion.isActive || !keepWorkingWithLidClosed)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let appMenu = NSMenu()
        appMenu.addItem(item("Open Awake", #selector(openControls), key: "o"))
        appMenu.addItem(item("About Awake", #selector(showAbout)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Awake", #selector(quit), key: "q"))
        let rootMenu = NSMenu()
        let appEntry = NSMenuItem(title: "Awake", action: nil, keyEquivalent: "")
        appEntry.submenu = appMenu
        rootMenu.addItem(appEntry)
        NSApp.mainMenu = rootMenu
        if !UserDefaults.standard.bool(forKey: "didMigrateStatusItemName") {
            for legacyName in ["com.awake.menubar.primary", "com.awake.menubar.statusitem", "com.awake.statusitem"] {
                UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(legacyName)")
                UserDefaults.standard.removeObject(forKey: "NSStatusItem Visible \(legacyName)")
            }
            UserDefaults.standard.set(true, forKey: "didMigrateStatusItemName")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "com.awake"
        statusItem.isVisible = true
        statusItem.behavior = []
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageOnly
        quickMenu.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 570)
        updateUI()
        DispatchQueue.main.async { [weak self] in self?.finishLaunching() }
    }

    private func finishLaunching() {
        closedLid.recoverInterruptedSession()
        if closedLid.isSupportedMac && !closedLid.setupComplete {
            keepWorkingWithLidClosed = false
            UserDefaults.standard.set(false, forKey: "keepWorkingWithLidClosed")
        }
        hotKey = GlobalHotKey { [weak self] in self?.toggleBlackout() }
        panelHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(controlKey | shiftKey),
            id: 2
        ) { [weak self] in self?.toggleStandalonePanel() }
        updateUI()
        writeState()
        if restorationPending { handleRestoreFailure() }
        installBatteryProtection()
        isReady = true
        let commands = pendingCommands
        pendingCommands.removeAll()
        commands.forEach(handleCommand)
        DispatchQueue.main.async { [weak self] in self?.offerLegacyCleanupIfNeeded() }
        if closedLid.isSupportedMac && !closedLid.setupComplete && !UserDefaults.standard.bool(forKey: "didPresentPanelOnboarding") {
            UserDefaults.standard.set(true, forKey: "didPresentPanelOnboarding")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showStandalonePanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.isVisible = true
        showStandalonePanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        batteryTimer?.invalidate()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        deadline = nil
        assertion.stop()
        closedLid.disable()
        blackout.hide()
        writeState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuildMenu(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        updateUI()
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            if let button = statusItem.button {
                quickMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            }
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        popover.isShown ? popover.performClose(nil) : showPanel()
    }

    private func toggleStandalonePanel() {
        if standalonePanel?.isVisible == true { standalonePanel?.orderOut(nil) }
        else { showStandalonePanel() }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        updatePanel()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openControls() { showStandalonePanel() }

    private func showStandalonePanel() {
        statusItem.isVisible = true
        popover.performClose(nil)
        let view = makePanelView()
        let controller: NSHostingController<AwakePanelView>
        if let standaloneController {
            standaloneController.rootView = view
            controller = standaloneController
        } else {
            controller = NSHostingController(rootView: view)
            standaloneController = controller
        }
        let panel: NSPanel
        if let standalonePanel {
            panel = standalonePanel
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 570),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "Awake"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentViewController = controller
            self.standalonePanel = panel
        }
        panel.setContentSize(controller.view.fittingSize)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updatePanel() {
        let view = makePanelView()
        if let panelController {
            panelController.rootView = view
        } else {
            let controller = NSHostingController(rootView: view)
            panelController = controller
            popover.contentViewController = controller
        }
        if standalonePanel?.isVisible == true {
            standaloneController?.rootView = view
            if let controller = standaloneController { standalonePanel?.setContentSize(controller.view.fittingSize) }
        }
    }

    private func makePanelView() -> AwakePanelView {
        let active = assertion.isActive
        let status = battery?.isCritical == true
            ? "Awake is off to protect your battery."
            : restorationPending
            ? "Normal sleep needs restoring"
            : deadline.map { "\(formatRemaining($0.timeIntervalSinceNow)) remaining" } ?? (active ? "No timer set. Turn off whenever you’re done." : "Start a session whenever you need more time.")
        let loginEnabled: Bool
        if #available(macOS 13.0, *) { loginEnabled = SMAppService.mainApp.status == .enabled }
        else { loginEnabled = false }
        return AwakePanelView(
            active: active,
            restorationPending: restorationPending,
            statusText: status,
            battery: battery,
            batteryError: batteryProtection.error,
            duration: sessionDuration,
            keepDisplayOn: keepDisplayOn,
            keepWorkingWithLidClosed: keepWorkingWithLidClosed,
            supportsClosedLid: closedLid.isSupportedMac,
            closedLidNeedsSetup: closedLid.isSupportedMac && !closedLid.setupComplete,
            blackoutActive: blackout.isActive,
            launchAtLogin: loginEnabled,
            toggleSession: { [weak self] in
                guard let self else { return }
                if self.assertion.isActive { self.stop() }
                else { _ = self.start(until: nil) }
            },
            setDuration: { [weak self] seconds in _ = self?.start(until: seconds == 0 ? nil : Date().addingTimeInterval(TimeInterval(seconds))) },
            toggleDisplay: { [weak self] in self?.toggleDisplay() },
            toggleClosedLid: { [weak self] in self?.toggleClosedLid() },
            toggleBlackout: { [weak self] in self?.toggleBlackout() },
            toggleLogin: { [weak self] in
                if #available(macOS 13.0, *) { self?.toggleLogin() }
            },
            restoreNormalSleep: { [weak self] in self?.restoreNormalSleep() },
            showAbout: { [weak self] in self?.showAbout() },
            quit: { [weak self] in self?.quit() }
        )
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if assertion.isActive {
            let label = deadline.map { "Awake for \(formatRemaining($0.timeIntervalSinceNow))" } ?? "Awake indefinitely"
            let status = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            status.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Active")
            activeStatusMenuItem = status
            menu.addItem(status)
            menu.addItem(item("Stop", #selector(stopSession), key: "s"))
            let setTimer = NSMenuItem(title: "Set Timer", action: nil, keyEquivalent: "")
            setTimer.submenu = durationMenu(extends: false)
            menu.addItem(setTimer)
            if deadline != nil {
                let extend = NSMenuItem(title: "Extend", action: nil, keyEquivalent: "")
                extend.submenu = durationMenu(extends: true)
                menu.addItem(extend)
            }
        } else {
            activeStatusMenuItem = nil
            menu.addItem(item("Start Indefinitely", #selector(startIndefinitely), key: "i"))
            menu.addItem(.separator())
            for (title, seconds) in durations {
                let entry = item(title, #selector(startDuration(_:)))
                entry.tag = seconds
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let display = item("Keep Display On", #selector(toggleDisplay))
        display.state = keepDisplayOn ? .on : .off
        menu.addItem(display)

        if closedLid.isSupportedMac {
            let closedLidItem = item("Keep Working with Lid Closed", #selector(toggleClosedLid))
            closedLidItem.state = keepWorkingWithLidClosed ? .on : .off
            menu.addItem(closedLidItem)
        }

        if restorationPending {
            let warning = item("Normal Sleep Needs Restoring", #selector(restoreNormalSleep))
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            menu.addItem(warning)
        }

        let blackoutItem = item(blackout.isActive ? "Restore Screens" : "Black Out Screens", #selector(toggleBlackout))
        if hotKey?.isRegistered == true {
            blackoutItem.keyEquivalent = "1"
            blackoutItem.keyEquivalentModifierMask = [.option]
        }
        menu.addItem(blackoutItem)

        if #available(macOS 13.0, *) {
            let login = item("Launch at Login", #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())
        menu.addItem(item("About Awake", #selector(showAbout)))
        menu.addItem(item("Quit Awake", #selector(quit), key: "q"))
    }

    private let durations = [
        ("For 15 Minutes", 15 * 60),
        ("For 30 Minutes", 30 * 60),
        ("For 1 Hour", 60 * 60),
        ("For 2 Hours", 2 * 60 * 60),
        ("For 4 Hours", 4 * 60 * 60),
        ("For 8 Hours", 8 * 60 * 60)
    ]

    private func durationMenu(extends: Bool) -> NSMenu {
        let menu = NSMenu()
        for (title, seconds) in durations {
            let label = title.replacingOccurrences(of: "For ", with: extends ? "By " : "")
            let action = extends ? #selector(extendDuration(_:)) : #selector(startDuration(_:))
            let entry = item(label, action)
            entry.tag = seconds
            menu.addItem(entry)
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func startIndefinitely() { start(until: nil) }
    @objc private func startDuration(_ sender: NSMenuItem) { start(until: Date().addingTimeInterval(TimeInterval(sender.tag))) }
    @objc private func extendDuration(_ sender: NSMenuItem) {
        let base = max(deadline ?? Date(), Date())
        start(until: base.addingTimeInterval(TimeInterval(sender.tag)))
    }
    @objc private func stopSession() { stop() }

    @discardableResult
    private func start(until: Date?) -> Bool {
        refreshBattery()
        guard battery?.isCritical != true else { showStandalonePanel(); return false }
        if let until, until <= Date() { stop(); return false }
        let wasActive = assertion.isActive
        if keepWorkingWithLidClosed && !closedLid.setupComplete {
            keepWorkingWithLidClosed = false
            UserDefaults.standard.set(false, forKey: "keepWorkingWithLidClosed")
            DispatchQueue.main.async { [weak self] in self?.showStandalonePanel() }
        }
        if keepWorkingWithLidClosed && !closedLid.enable() {
            keepWorkingWithLidClosed = false
            UserDefaults.standard.set(false, forKey: "keepWorkingWithLidClosed")
            showClosedLidError()
        }
        do {
            try assertion.start(keepDisplayOn: keepDisplayOn)
            deadline = until
            sessionDuration = until.map { Int($0.timeIntervalSinceNow.rounded()) }
            scheduleTimer()
            updateUI()
            writeState()
            return true
        } catch {
            if !wasActive { closedLid.disable() }
            let alert = NSAlert(error: error)
            alert.messageText = "Awake could not start"
            alert.runModal()
            return false
        }
    }

    private func stop(showRestoreError: Bool = true) {
        assertion.stop()
        deadline = nil
        sessionDuration = nil
        timer?.invalidate()
        timer = nil
        if !closedLid.disable() && showRestoreError { handleRestoreFailure() }
        updateUI()
        writeState()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard deadline != nil else { timer = nil; return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let deadline = self.deadline, deadline <= Date() { self.stop() }
            else { self.updateUI() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    @objc private func toggleDisplay() {
        let previous = keepDisplayOn
        keepDisplayOn.toggle()
        UserDefaults.standard.set(keepDisplayOn, forKey: "keepDisplayOn")
        if assertion.isActive && !start(until: deadline) {
            keepDisplayOn = previous
            UserDefaults.standard.set(keepDisplayOn, forKey: "keepDisplayOn")
            updateUI()
            writeState()
        }
        else { updateUI(); writeState() }
    }

    @objc private func toggleClosedLid() {
        if keepWorkingWithLidClosed {
            keepWorkingWithLidClosed = false
            if !closedLid.disable() { handleRestoreFailure() }
        } else {
            guard closedLid.setupComplete || offerClosedLidSetup() else { return }
            keepWorkingWithLidClosed = true
            if assertion.isActive && !closedLid.enable() {
                keepWorkingWithLidClosed = false
                showClosedLidError()
            }
        }
        UserDefaults.standard.set(keepWorkingWithLidClosed, forKey: "keepWorkingWithLidClosed")
        updateUI()
        writeState()
    }

    private func offerLegacyCleanupIfNeeded() {
        guard closedLid.legacyPermissionPresent else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove old Awake permissions"
        alert.informativeText = "A previous Awake version installed broad power and temperature permissions. They are no longer needed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { _ = closedLid.removeLegacyPermission() }
    }

    private func offerClosedLidSetup() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow closed-lid mode"
        alert.informativeText = "Awake will install a narrow system permission that can only turn closed-lid sleep on or off. Your previous setting is restored when the session ends. If Awake is interrupted, it restores the setting next time it opens. Keep the Mac ventilated and never put it in a bag while this mode is on."
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let installed = closedLid.installPermission()
        if !installed { showClosedLidError() }
        return installed
    }

    private func showClosedLidError() {
        let alert = NSAlert()
        alert.messageText = "Closed-lid mode is not available"
        alert.informativeText = "Administrator approval was not completed. You can try again from the Awake menu."
        alert.runModal()
    }

    @objc private func restoreNormalSleep() {
        if !closedLid.disable() { handleRestoreFailure() }
        updateUI()
        writeState()
    }

    private func handleRestoreFailure() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Normal sleep could not be restored"
        alert.informativeText = "The saved permission is unavailable. Restore the previous setting with administrator approval. Keep this Mac ventilated and do not put it in a bag while the lid is closed."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn && !closedLid.disableWithAuthorization() {
            let failure = NSAlert()
            failure.messageText = "Normal sleep still needs restoring"
            failure.informativeText = "Awake will keep the recovery record and retry next time it opens."
            failure.runModal()
        }
        updateUI()
        writeState()
    }

    @objc private func toggleBlackout() {
        blackout.toggle()
        updateUI()
        writeState()
    }

    @available(macOS 13.0, *)
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            DispatchQueue.main.async { [weak self] in self?.updateUI() }
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Awake"
        alert.icon = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Awake")
        let shortcut = hotKey?.isRegistered == true ? "Press Option-1 or Escape to restore them." : "Press Escape or click to restore them."
        let panelShortcut = panelHotKey?.isRegistered == true ? "Press Control-Shift-A to open the control panel.\n\n" : ""
        alert.informativeText = "When Awake is on, it prevents idle sleep and can keep a MacBook working with its lid closed. A timer turns Awake off and restores normal sleep at zero. On battery power, Awake requests sleep at 5% or below, even with no active session.\n\n\(panelShortcut)Screen blackout covers every display. \(shortcut)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        stop()
        blackout.hide()
        NSApp.terminate(nil)
    }

    private func updateUI() {
        let active = assertion.isActive
        let symbol = restorationPending ? "exclamationmark.triangle.fill" : (active ? "sun.max.fill" : "moon.zzz.fill")
        let description = restorationPending ? "Normal sleep needs restoring" : (active ? "Awake is on" : "Awake is off")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.image?.size = NSSize(width: 17, height: 17)
        statusItem.button?.title = ""
        let stateTooltip = restorationPending ? "Normal sleep needs restoring" : (deadline.map { "\(formatRemaining($0.timeIntervalSinceNow)) remaining" } ?? (active ? "On" : "Off"))
        statusItem.button?.toolTip = "Awake: \(stateTooltip)\nLeft-click: controls  Right-click: quick menu\nControl-Shift-A: open controls  Option-1: blackout"
        statusItem.button?.setAccessibilityLabel("Awake")
        statusItem.button?.setAccessibilityValue(restorationPending ? "Normal sleep needs restoring" : (deadline.map { "\(formatRemaining($0.timeIntervalSinceNow)) remaining" } ?? (active ? "On indefinitely" : "Off")))
        if menuIsOpen && active {
            activeStatusMenuItem?.title = deadline.map { "Awake for \(formatRemaining($0.timeIntervalSinceNow))" } ?? "Awake indefinitely"
        }
        if popover.isShown || standalonePanel?.isVisible == true { updatePanel() }
    }

    private func writeState() {
        let state: [String: Any?] = [
            "active": assertion.isActive,
            "keepDisplayOn": keepDisplayOn,
            "keepWorkingWithLidClosed": keepWorkingWithLidClosed,
            "closedLidActive": closedLid.isActive,
            "restoreFailed": restorationPending,
            "timerEndsAt": deadline?.timeIntervalSince1970,
            "blackout": blackout.isActive,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "batteryPercent": battery?.percent,
            "onBattery": battery?.onBattery,
            "autoSleepPercent": 5,
            "batterySleepRequested": batteryProtection.sleepRequested,
            "batteryError": batteryProtection.error
        ]
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: state.compactMapValues { $0 }, options: [.sortedKeys])
            try data.write(to: stateURL, options: .atomic)
        } catch { }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for command in urls.compactMap(AwakeCommand.init(url:)) {
            if isReady { handleCommand(command) }
            else { pendingCommands.append(command) }
        }
    }

    private func handleCommand(_ command: AwakeCommand) {
        switch command {
        case let .start(seconds, display):
            if let display {
                keepDisplayOn = display
                UserDefaults.standard.set(display, forKey: "keepDisplayOn")
            }
            start(until: seconds.map { Date().addingTimeInterval($0) })
        case .toggle:
            if assertion.isActive { stop() }
            else { start(until: nil) }
        case .stop: stop()
        case .blackout: if !blackout.isActive { toggleBlackout() }
        case .show: if blackout.isActive { toggleBlackout() }
        case .menu: showStandalonePanel()
        case .about: showAbout()
        }
    }

    private func installBatteryProtection() {
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().refreshBattery()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        // A fallback also retries a refused sleep request. No process watching.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshBattery() }
        if let batteryTimer { RunLoop.main.add(batteryTimer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        refreshBattery()
    }

    @objc private func didWake() {
        if let deadline, deadline <= Date() { stop(showRestoreError: false) }
        statusItem.isVisible = true
        refreshBattery()
    }

    private func refreshBattery() {
        battery = readBattery()
        batteryProtection.evaluate(battery, prepare: { [self] in
            stop(showRestoreError: false)
            blackout.hide()
            return !closedLid.ownsSetting
        }, sleep: {
            let connection = IOPMFindPowerManagement(0)
            guard connection != 0 else { return kIOReturnNotReady }
            defer { IOServiceClose(connection) }
            return IOPMSleepSystem(connection)
        })
        updateUI()
        writeState()
    }

    private func readBattery() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool != false,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  let state = description[kIOPSPowerSourceStateKey] as? String,
                  state == kIOPSBatteryPowerValue || state == kIOPSACPowerValue else { continue }
            return BatterySnapshot(current: current, maximum: maximum, onBattery: state == kIOPSBatteryPowerValue)
        }
        return nil
    }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
