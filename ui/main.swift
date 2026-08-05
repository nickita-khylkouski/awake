import AppKit
import Carbon
import IOKit.pwr_mgt
import ServiceManagement

private let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/awake/state.json")
private let commandURL = stateURL.deletingLastPathComponent().appendingPathComponent("command")

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
    private let blackout = BlackoutController()
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var commandTimer: Timer?
    private var deadline: Date?
    private var menuIsOpen = false
    private weak var activeStatusMenuItem: NSMenuItem?
    private var keepDisplayOn = UserDefaults.standard.bool(forKey: "keepDisplayOn")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        hotKey = GlobalHotKey { [weak self] in self?.toggleBlackout() }
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.processCommand()
        }
        if let commandTimer { RunLoop.main.add(commandTimer, forMode: .common) }
        updateUI()
        writeState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        assertion.stop()
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
            let entry = item(label, #selector(extendDuration(_:)))
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
        do {
            try assertion.start(keepDisplayOn: keepDisplayOn)
            deadline = until
            scheduleTimer()
            updateUI()
            writeState()
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Awake could not start"
            alert.runModal()
            return false
        }
    }

    private func stop() {
        assertion.stop()
        deadline = nil
        timer?.invalidate()
        timer = nil
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
        alert.informativeText = "When Awake is on, it prevents your Mac from sleeping automatically. A timer turns Awake off when it reaches zero. Awake cannot prevent sleep when you close a MacBook lid.\n\nScreen blackout covers every display. \(shortcut)"
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
        let symbol = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: active ? "Awake is on" : "Awake is off")
        statusItem.button?.toolTip = deadline.map { "Awake: \(formatRemaining($0.timeIntervalSinceNow)) remaining" } ?? (active ? "Awake: On" : "Awake: Off")
        statusItem.button?.setAccessibilityLabel("Awake")
        statusItem.button?.setAccessibilityValue(deadline.map { "\(formatRemaining($0.timeIntervalSinceNow)) remaining" } ?? (active ? "On indefinitely" : "Off"))
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
