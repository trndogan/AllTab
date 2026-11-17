import AppKit
import Carbon

// MARK: - Backup shortcuts that survive Secure Keyboard Entry
//
// While another app has Secure Keyboard Entry on (a password field in Chrome, a passcode screen in
// Telegram, Terminal's "Secure Keyboard Entry"), macOS stops sending keystrokes to event taps. AllTab's
// tap then sees nothing: Cmd+Tab falls through to the system switcher, the screenshot shortcut is dead,
// and restarting AllTab does not help because the lock belongs to the other app. Hot keys registered
// with RegisterEventHotKey are still delivered in that state, so the same shortcuts are registered there
// too. Normally the event tap swallows these keys first and the hot keys never fire.

enum CarbonKeys {
    private static var handler: EventHandlerRef?
    private static var refs: [String: (ref: EventHotKeyRef, id: UInt32)] = [:]
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    /// When the event tap last handled one of these keys; a hot key arriving right after is the same press.
    static var tapHandledAt: TimeInterval = 0

    /// CGEventFlags → Carbon modifier mask
    static func mods(_ f: CGEventFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.maskCommand) { m |= UInt32(cmdKey) }
        if f.contains(.maskShift) { m |= UInt32(shiftKey) }
        if f.contains(.maskAlternate) { m |= UInt32(optionKey) }
        if f.contains(.maskControl) { m |= UInt32(controlKey) }
        return m
    }

    private static func install() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let n = id.id
            DispatchQueue.main.async { CarbonKeys.fire(n) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private static func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        if ProcessInfo.processInfo.systemUptime - tapHandledAt < 0.3 { return }   // the tap already did it
        dlog("hotkey yedek yol #\(id)")
        action()
    }

    /// Registers (or with nil removes) a named hot key.
    static func set(_ name: String, key: UInt32, mods: UInt32, _ action: (() -> Void)?) {
        if let old = refs.removeValue(forKey: name) {
            UnregisterEventHotKey(old.ref)
            actions[old.id] = nil
        }
        guard let action else { return }
        install()
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key, mods, EventHotKeyID(signature: OSType(0x416C5442), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        dlog("hotkey \(name) key=\(key) mods=\(mods) status=\(status)")
        guard status == noErr, let ref else { return }
        refs[name] = (ref, id)
        actions[id] = action
    }
}

// MARK: - macOS's own app switcher

/// macOS's Cmd+Tab and Cmd+Shift+Tab app switcher. Turned off while AllTab uses Cmd+Tab, so the backup
/// hot key gets the keys when the event tap cannot; turned back on when AllTab quits or the shortcut
/// changes. This lives in the window server only, a logout restores it anyway.
enum SystemSwitcher {
    private typealias SetFn = @convention(c) (Int32, Bool) -> CGError
    private static let setEnabled: SetFn? = SkyLight.sym("CGSSetSymbolicHotKeyEnabled")
    private static var current: Bool?
    private static var signals: [DispatchSourceSignal] = []

    static func set(enabled: Bool) {
        guard current != enabled else { return }
        current = enabled
        for hotKey: Int32 in [1, 2] {   // 1 = Cmd+Tab, 2 = Cmd+Shift+Tab
            let r = setEnabled?(hotKey, enabled)
            dlog("system switcher \(hotKey) enabled=\(enabled) result=\(r.map { "\($0.rawValue)" } ?? "yok")")
        }
        if !enabled { restoreOnSignals() }
    }

    /// `pkill` / logout send SIGTERM, which skips applicationWillTerminate: give macOS its Cmd+Tab back first.
    private static func restoreOnSignals() {
        guard signals.isEmpty else { return }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { set(enabled: true); exit(0) }
            src.resume()
            signals.append(src)
        }
    }
}

// MARK: - Registering the backups

extension HotkeyTap {
    /// Same shortcuts as the event tap: the switcher (Tab and Shift+Tab with the chosen modifier), the
    /// screenshot shortcut, and Esc while the switcher is open. Called at launch and whenever one changes.
    func registerBackup() {
        let s = switcher, hk = Hotkey.current
        let m = CarbonKeys.mods(hk.flag)
        CarbonKeys.set("next", key: 48, mods: m) { s.visible ? s.step(1) : s.show() }
        CarbonKeys.set("prev", key: 48, mods: m | UInt32(shiftKey)) { s.visible ? s.step(-1) : s.show() }
        CarbonKeys.set("shot", key: UInt32(ShotHotkey.keyCode), mods: CarbonKeys.mods(CGEventFlags(rawValue: ShotHotkey.modifiers)),
                       ShotHotkey.enabled ? { if !s.visible { onScreenshotHotkey?() } } : nil)
        SystemSwitcher.set(enabled: hk != .cmd)
    }

    /// Esc is only claimed while the switcher is open (the modifier is still held then).
    func switcherVisibility(_ open: Bool) {
        let s = switcher
        CarbonKeys.set("esc", key: 53, mods: CarbonKeys.mods(Hotkey.current.flag), open ? { s.cancel() } : nil)
    }
}
