import AppKit
import Carbon
import IOKit.pwr_mgt
import ServiceManagement

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
    var ownsSetting: Bool { FileManager.default.fileExists(atPath: markerURL.path) }
    private(set) var isActive = false
    var setupComplete: Bool {
        FileManager.default.fileExists(atPath: permissionPath) &&
        FileManager.default.isExecutableFile(atPath: helperPath) && helperMatchesBundle &&
        !legacyPermissionPresent && permissionAvailable()
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
        return run("/usr/bin/osascript", ["-e", script]).status == 0 && setupComplete
    }

    func removeLegacyPermission() -> Bool {
        let username = NSUserName()
        guard username.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return false }
        let oldPmset = "\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset"
        let oldMetrics = "\(username) ALL=(ALL) NOPASSWD: /usr/bin/powermetrics"
        let shell = "if [ -f /etc/sudoers.d/pmset ] && [ \"$(/bin/cat /etc/sudoers.d/pmset)\" = '\(oldPmset)' ]; then /bin/rm -f /etc/sudoers.d/pmset; fi; if [ -f /etc/sudoers.d/powermetrics ] && [ \"$(/bin/cat /etc/sudoers.d/powermetrics)\" = '\(oldMetrics)' ]; then /bin/rm -f /etc/sudoers.d/powermetrics; fi"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"]).status == 0 && !legacyPermissionPresent
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
    private(set) var isRegistered = false

    init(action: @escaping () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, pointer in
                guard let pointer else { return noErr }
                Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue().action()
                return noErr
            },
            1,
            &event,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        let identifier = EventHotKeyID(signature: fourCC("AWAK"), id: 1)
        isRegistered = RegisterEventHotKey(UInt32(kVK_ANSI_1), UInt32(optionKey), identifier, GetApplicationEventTarget(), 0, &reference) == noErr
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let assertion = WakeAssertion()
    private let closedLid = ClosedLidController()
    private let blackout = BlackoutController()
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem!
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
        NSApp.setActivationPolicy(.accessory)
        closedLid.recoverInterruptedSession()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        hotKey = GlobalHotKey { [weak self] in self?.toggleBlackout() }
        updateUI()
        writeState()
        if restorationPending { handleRestoreFailure() }
        if !closedLid.isSupportedMac { offerLegacyCleanupIfNeeded() }
        showOnboardingIfNeeded()
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.processCommand()
        }
        if let commandTimer { RunLoop.main.add(commandTimer, forMode: .common) }
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
        ("For 2 Hours", 2 * 60 * 60)
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
            if !offerClosedLidSetup() {
                keepWorkingWithLidClosed = false
                UserDefaults.standard.set(false, forKey: "keepWorkingWithLidClosed")
            }
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
            else { self.updateUI(); self.writeState() }
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

    private func showOnboardingIfNeeded() {
        guard closedLid.isSupportedMac else {
            keepWorkingWithLidClosed = false
            UserDefaults.standard.set(false, forKey: "keepWorkingWithLidClosed")
            UserDefaults.standard.set(true, forKey: "onboardingComplete")
            return
        }
        guard !UserDefaults.standard.bool(forKey: "onboardingComplete") else { return }
        NSApp.activate(ignoringOtherApps: true)
        let ready = closedLid.setupComplete
        let alert = NSAlert()
        alert.messageText = "Keep working with the lid closed"
        alert.informativeText = "Awake installs a narrow system permission to toggle closed-lid sleep without asking for a password each time. It restores your previous setting when Awake stops. If Awake is force-quit or loses power, it restores the setting next time it opens. Keep a closed MacBook ventilated and never put it in a bag while this mode is on."
        alert.icon = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Administrator approval")
        alert.addButton(withTitle: ready ? "Continue" : "Set Up")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            if ready || closedLid.installPermission() {
                keepWorkingWithLidClosed = true
                UserDefaults.standard.set(true, forKey: "keepWorkingWithLidClosed")
                UserDefaults.standard.set(true, forKey: "onboardingComplete")
            } else {
                keepWorkingWithLidClosed = false
                UserDefaults.standard.set(false, forKey: "keepWorkingWithLidClosed")
                UserDefaults.standard.set(true, forKey: "onboardingComplete")
                showClosedLidError()
            }
        } else {
            keepWorkingWithLidClosed = false
            UserDefaults.standard.set(false, forKey: "keepWorkingWithLidClosed")
            if closedLid.legacyPermissionPresent {
                let cleanup = NSAlert()
                cleanup.messageText = "Remove old Awake permissions"
                cleanup.informativeText = "A previous Awake version installed broad power and temperature permissions. They are no longer needed and should be removed."
                cleanup.addButton(withTitle: "Remove")
                cleanup.addButton(withTitle: "Later")
                if cleanup.runModal() == .alertFirstButtonReturn { _ = closedLid.removeLegacyPermission() }
            }
            UserDefaults.standard.set(!closedLid.legacyPermissionPresent, forKey: "onboardingComplete")
        }
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
        alert.informativeText = "When Awake is on, it prevents idle sleep and can keep a MacBook working with its lid closed. A timer turns Awake off and restores normal sleep at zero.\n\nScreen blackout covers every display. \(shortcut)"
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
        let symbol = restorationPending ? "exclamationmark.triangle.fill" : (active ? "cup.and.saucer.fill" : "cup.and.saucer")
        let description = restorationPending ? "Normal sleep needs restoring" : (active ? "Awake is on" : "Awake is off")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        statusItem.button?.toolTip = restorationPending ? "Awake: Normal sleep needs restoring" : (deadline.map { "Awake: \(formatRemaining($0.timeIntervalSinceNow)) remaining" } ?? (active ? "Awake: On" : "Awake: Off"))
        statusItem.button?.setAccessibilityLabel("Awake")
        statusItem.button?.setAccessibilityValue(restorationPending ? "Normal sleep needs restoring" : (deadline.map { "\(formatRemaining($0.timeIntervalSinceNow)) remaining" } ?? (active ? "On indefinitely" : "Off")))
        if menuIsOpen && active {
            activeStatusMenuItem?.title = deadline.map { "Awake for \(formatRemaining($0.timeIntervalSinceNow))" } ?? "Awake indefinitely"
        } else if let menu = statusItem.menu {
            rebuildMenu(menu)
        }
    }

    private func writeState() {
        let state: [String: Any?] = [
            "active": assertion.isActive,
            "keepDisplayOn": keepDisplayOn,
            "keepWorkingWithLidClosed": keepWorkingWithLidClosed,
            "closedLidActive": closedLid.isActive,
            "restoreFailed": restorationPending,
            "timerEndsAt": deadline?.timeIntervalSince1970,
            "remainingSeconds": deadline.map { max(0, Int($0.timeIntervalSinceNow.rounded(.up))) },
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
        case "menu": statusItem.button?.performClick(nil)
        case "about": showAbout()
        default: break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
