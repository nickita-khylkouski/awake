import AppKit
import Carbon
import IOKit.pwr_mgt
import ServiceManagement
import SwiftUI

private let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/awake/state.json")
private let commandURL = stateURL.deletingLastPathComponent().appendingPathComponent("command")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: restorationPending ? "exclamationmark.triangle.fill" : (active ? "bolt.fill" : "moon.fill"))
                    .font(.system(size: 23, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Awake").font(.headline)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button(action: toggleSession) {
                Label(active ? "Turn Awake Off" : "Keep Mac Awake", systemImage: active ? "power" : "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            if restorationPending {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Normal sleep needs restoring").font(.subheadline.weight(.semibold))
                    Text("Awake kept the recovery record. Restore the previous system setting now.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Restore Normal Sleep", action: restoreNormalSleep).buttonStyle(.bordered)
                }
                .padding(11)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            } else if closedLidNeedsSetup {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Closed-lid mode needs setup").font(.subheadline.weight(.semibold))
                    Text("Approve one narrow system permission to keep a MacBook working when its lid is closed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up Closed-Lid Mode", action: toggleClosedLid)
                        .buttonStyle(.bordered)
                }
                .padding(11)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(active ? "Replace with a timer" : "Start a timer")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    timerButton("15m", 15 * 60)
                    timerButton("30m", 30 * 60)
                    timerButton("1h", 60 * 60)
                    timerButton("2h", 2 * 60 * 60)
                    timerButton("4h", 4 * 60 * 60)
                    timerButton("8h", 8 * 60 * 60)
                }
            }

            Divider()

            Toggle("Keep Display On", isOn: Binding(get: { keepDisplayOn }, set: { _ in toggleDisplay() }))
            if supportsClosedLid && !closedLidNeedsSetup {
                Toggle("Keep Working with Lid Closed", isOn: Binding(get: { keepWorkingWithLidClosed }, set: { _ in toggleClosedLid() }))
            }

            Button(action: toggleBlackout) {
                Label(blackoutActive ? "Restore Screens" : "Black Out Screens", systemImage: blackoutActive ? "eye.fill" : "eye.slash.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: { _ in toggleLogin() }))

            Divider()

            HStack {
                Button("About", action: showAbout).buttonStyle(.plain)
                Spacer()
                Button("Quit", action: quit).buttonStyle(.plain)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 330, height: 460, alignment: .top)
    }

    private func timerButton(_ label: String, _ seconds: Int) -> some View {
        Button(label) { setDuration(seconds) }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
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
    private var commandTimer: Timer?
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
        popover.contentSize = NSSize(width: 330, height: 460)
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
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.processCommand()
        }
        if let commandTimer { RunLoop.main.add(commandTimer, forMode: .common) }
        DispatchQueue.main.async { [weak self] in self?.offerLegacyCleanupIfNeeded() }
        if closedLid.isSupportedMac && !closedLid.setupComplete && !UserDefaults.standard.bool(forKey: "didPresentPanelOnboarding") {
            UserDefaults.standard.set(true, forKey: "didPresentPanelOnboarding")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showStandalonePanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStandalonePanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
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

    private func showStandalonePanel() {
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
                contentRect: NSRect(x: 0, y: 0, width: 330, height: 460),
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
        panel.center()
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
        if standalonePanel?.isVisible == true { standaloneController?.rootView = view }
    }

    private func makePanelView() -> AwakePanelView {
        let active = assertion.isActive
        let status = restorationPending
            ? "Normal sleep needs restoring"
            : deadline.map { "\(formatRemaining($0.timeIntervalSinceNow)) remaining" } ?? (active ? "On indefinitely" : "Normal sleep allowed")
        let loginEnabled: Bool
        if #available(macOS 13.0, *) { loginEnabled = SMAppService.mainApp.status == .enabled }
        else { loginEnabled = false }
        return AwakePanelView(
            active: active,
            restorationPending: restorationPending,
            statusText: status,
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
            setDuration: { [weak self] seconds in _ = self?.start(until: Date().addingTimeInterval(TimeInterval(seconds))) },
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
        alert.informativeText = "When Awake is on, it prevents idle sleep and can keep a MacBook working with its lid closed. A timer turns Awake off and restores normal sleep at zero.\n\n\(panelShortcut)Screen blackout covers every display. \(shortcut)"
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
        let symbol = restorationPending ? "exclamationmark.triangle.fill" : (active ? "bolt.fill" : "moon.fill")
        let description = restorationPending ? "Normal sleep needs restoring" : (active ? "Awake is on" : "Awake is off")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
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
            "blackout": blackout.isActive
        ]
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: state.compactMapValues { $0 }, options: [.sortedKeys])
            try data.write(to: stateURL, options: .atomic)
        } catch { }
    }

    private func processCommand() {
        let claimedURL = commandURL.appendingPathExtension(UUID().uuidString)
        do { try FileManager.default.moveItem(at: commandURL, to: claimedURL) }
        catch { return }
        defer { try? FileManager.default.removeItem(at: claimedURL) }
        guard let value = try? String(contentsOf: claimedURL, encoding: .utf8) else { return }
        let parts = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let command = parts.first else { return }
        let arguments = stride(from: 1, to: parts.count - 1, by: 2).reduce(into: [String: String]()) {
            $0[parts[$1]] = parts[$1 + 1]
        }
        switch command {
        case "start":
            if let display = arguments["display"] { keepDisplayOn = display == "1"; UserDefaults.standard.set(keepDisplayOn, forKey: "keepDisplayOn") }
            if let seconds = arguments["seconds"].flatMap(Double.init), seconds > 0 { start(until: Date().addingTimeInterval(seconds)) }
            else { start(until: nil) }
        case "toggle":
            if assertion.isActive { stop() }
            else { start(until: nil) }
        case "stop": stop()
        case "blackout": if !blackout.isActive { toggleBlackout() }
        case "show": if blackout.isActive { toggleBlackout() }
        case "toggle-blackout": toggleBlackout()
        case "menu": showStandalonePanel()
        case "about": showAbout()
        default: break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
