// AllTab – Windows-style Alt+Tab / Cmd+Tab window switcher for macOS
// Lists every window: hidden, minimized and other-Space ones too. No dependencies.
// License: MIT

import AppKit
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement
import IOKit.pwr_mgt

// MARK: - Localization (English by default, Turkish when the system language is Turkish)

enum L {
    static let isTurkish = Locale.preferredLanguages.first?.lowercased().hasPrefix("tr") == true
    static func t(_ en: String, _ tr: String) -> String { isTurkish ? tr : en }
}

// MARK: - Özel (private) API'ler
// AX pencere kimliği ve SkyLight ile pencereyi öne getirme. Yalnızca dlsym ile bağlanır,
// bulunamazsa uygulama yine çalışır (yalnızca AX/activate kullanılır).

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> CGError
typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SkyLight {
    static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let setFront: SetFrontFn? = sym("_SLPSSetFrontProcessWithOptions")
    static let postEvent: PostEventFn? = sym("SLPSPostEventRecordTo")
    static let psnForPid: PSNFn? = sym("GetProcessForPID")
    private static let mainConnection: (@convention(c) () -> Int32)? = sym("CGSMainConnectionID")
    private static let spacesForWindows: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?)? = sym("CGSCopySpacesForWindows")

    /// The desktops (Spaces, full screen ones included) a window is on; nil when it cannot be asked.
    /// Minimized windows and the windows of a hidden app still belong to their desktop: a window on none
    /// was put away by its own app (Chrome keeps such windows) and cannot be shown from outside.
    static func spaces(of id: CGWindowID) -> [UInt64]? {
        guard let conn = mainConnection, let copy = spacesForWindows,
              let list = copy(conn(), 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return list.map { $0.uint64Value }
    }

    static func sym<T>(_ name: String) -> T? {
        let p = handle.flatMap { dlsym($0, name) } ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        guard let p else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// Pencereyi uygulamanın "key" penceresi yapıp uygulamayı öne getirir (AltTab/yabai yöntemi).
    static func bringToFront(pid: pid_t, window: CGWindowID) {
        var psn = ProcessSerialNumber()
        guard psnForPid?(pid, &psn) == noErr else { return }
        _ = setFront?(&psn, window, 0x200)
        if let post = postEvent {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xF8
            bytes[0x3a] = 0x10
            withUnsafeBytes(of: UInt32(window)) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
            for i in 0x20..<0x30 { bytes[i] = 0xFF }
            bytes[0x08] = 0x01; _ = post(&psn, bytes)
            bytes[0x08] = 0x02; _ = post(&psn, bytes)
        }
    }
}

// MARK: - Erişilebilirlik yardımcıları

func axValue(_ e: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
}

/// Bir uygulamanın AX pencerelerini CGWindowID ile eşler. Not: AX yalnızca geçerli masaüstündeki
/// pencereleri döndürür, başka masaüstündekiler burada bulunmaz.
func axWindows(of pid: pid_t) -> [CGWindowID: AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var out: [CGWindowID: AXUIElement] = [:]
    for w in (axValue(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(w, &id) == .success, id != 0 { out[id] = w; AXWindowCache.put(id, w) }
    }
    return out
}

/// Accessibility elements of windows seen before, by window id. Accessibility only lists the windows of the
/// current desktop, so a window that has since gone to another desktop or to full screen (a YouTube video
/// in full screen) is reached through the element remembered from when it was here.
enum AXWindowCache {
    private static var map: [CGWindowID: AXUIElement] = [:]
    private static let lock = NSLock()

    static func put(_ id: CGWindowID, _ el: AXUIElement) { lock.lock(); map[id] = el; lock.unlock() }
    static func get(_ id: CGWindowID) -> AXUIElement? { lock.lock(); defer { lock.unlock() }; return map[id] }
    /// Forgets the windows that no longer exist.
    static func keep(_ ids: Set<CGWindowID>) { lock.lock(); map = map.filter { ids.contains($0.key) }; lock.unlock() }
}

/// Is the window on the screen right now (on the current desktop, not minimized)?
func isOnScreen(_ id: CGWindowID) -> Bool {
    let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first
    return (info?[kCGWindowIsOnscreen as String] as? Bool) == true
}

func axRaise(_ el: AXUIElement) {
    AXUIElementSetMessagingTimeout(el, 0.5)
    if (axValue(el, kAXMinimizedAttribute) as? Bool) == true {
        AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
}

/// Başka masaüstündeki pencerenin AX öğesi kAXWindows listesinde yoktur. AltTab yöntemi: uygulamanın
/// AX öğe kimlikleri sırayla denenir, aranan pencere kimliğini taşıyan pencere öğesi bulunur.
/// Browsers number thousands of elements (Chrome's windows sit near 1800), so the scan goes far but stops
/// after a second, a hung app cannot hold it. Runs off the main thread.
func axWindowByScan(pid: pid_t, id: CGWindowID) -> AXUIElement? {
    if let el = AXWindowCache.get(id) { return el }
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
    let deadline = Date().addingTimeInterval(1)
    for n in UInt64(0)..<20000 {
        if n % 256 == 0, Date() > deadline { break }
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: n) { Data($0) })
        guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
        AXUIElementSetMessagingTimeout(el, 0.1)
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(el, &wid) == .success, wid == id,
           (axValue(el, kAXRoleAttribute) as? String) == (kAXWindowRole as String) {
            AXWindowCache.put(id, el)
            return el
        }
    }
    return nil
}

/// Pencereyi kendi kapat düğmesine basarak kapatır; uygulama kaydetmeyi sorarsa pencere açık kalır.
/// Kapat düğmesi bulunamazsa false döner. Kayıt sorusu çıkınca AXPress uzun süre dönmeyebilir,
/// bu yüzden arka plan kuyruğundan çağrılır.
func axClose(_ w: WindowInfo) -> Bool {
    guard let el = w.ax ?? axWindows(of: w.pid)[w.id] ?? axWindowByScan(pid: w.pid, id: w.id),
          let button = axValue(el, kAXCloseButtonAttribute) else { return false }
    AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    return true
}

// MARK: - Pencere modeli

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let app: NSRunningApplication
    var title: String
    let bounds: CGRect
    let onScreen: Bool
    var minimized = false
    var ax: AXUIElement?

    var label: String { title.isEmpty ? (app.localizedName ?? "") : title }
    var state: String? {
        if minimized { return L.t("minimized", "simge durumunda") }
        if app.isHidden { return L.t("hidden", "gizli") }
        if !onScreen { return L.t("other desktop", "başka masaüstü") }
        return nil
    }
}

enum WindowList {
    static let minWidth: CGFloat = 100, minHeight: CGFloat = 50

    /// Normal uygulamaların gerçek pencerelerini son kullanım sırasına göre döndürür.
    static func fetch(mru: [CGWindowID]) -> [WindowInfo] {
        let me = getpid()
        let infos = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let apps = Dictionary(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })

        var list: [WindowInfo] = []
        for w in infos {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let app = apps[pid],
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let bw = b["Width"], let bh = b["Height"], bw >= minWidth, bh >= minHeight,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            list.append(WindowInfo(id: id, pid: pid, app: app,
                                   title: w[kCGWindowName as String] as? String ?? "",
                                   bounds: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: bw, height: bh),
                                   onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) == true))
        }

        // AX bilgisi: simge durumu, başlık (Ekran Kaydı izni yokken CG başlık vermez) ve
        // ekran dışı yardımcı pencerelerin elenmesi.
        var axCache: [pid_t: [CGWindowID: AXUIElement]] = [:]
        func ax(_ w: WindowInfo) -> AXUIElement? {
            if axCache[w.pid] == nil { axCache[w.pid] = axWindows(of: w.pid) }
            return axCache[w.pid]?[w.id]
        }
        list = list.compactMap { w in
            var w = w
            if !w.onScreen || w.title.isEmpty, let el = ax(w) {
                w.ax = el
                w.minimized = (axValue(el, kAXMinimizedAttribute) as? Bool) == true
                if w.title.isEmpty, let t = axValue(el, kAXTitleAttribute) as? String { w.title = t }
            }
            // Başlıksız, simge durumunda olmayan, gizli olmayan ekran dışı pencere: yardımcı/çöp pencere
            if !w.onScreen && w.title.isEmpty && !w.minimized && !w.app.isHidden { return nil }
            // No title anywhere and Accessibility does not show it as an ordinary window, or it is a thin
            // strip: a helper part of the app, not something to switch to (Chrome's toolbar strip in full
            // screen and while a debugger banner is up, its bubbles and popups).
            if w.title.isEmpty && !w.minimized {
                let sub = w.ax.flatMap { axValue($0, kAXSubroleAttribute) as? String }
                if !(sub == (kAXStandardWindowSubrole as String) || sub == (kAXDialogSubrole as String)) || w.bounds.height < 120 { return nil }
            }
            // On no desktop at all: the app put the window away itself, nothing can bring it up from outside,
            // a click on it would do nothing.
            if !w.onScreen && !w.minimized && !w.app.isHidden, SkyLight.spaces(of: w.id)?.isEmpty == true { return nil }
            return w
        }
        AXWindowCache.keep(Set(infos.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }))

        // AllTab's own windows (Settings): it is a menu bar app, so they are read from AppKit, not from the
        // window server or Accessibility (asking our own process through Accessibility would wait on ourselves).
        for win in NSApp.windows where (win.isVisible || win.isMiniaturized) && win.level == .normal
            && !(win is NSPanel) && !win.title.isEmpty {
            var info = WindowInfo(id: CGWindowID(win.windowNumber), pid: me, app: .current, title: win.title,
                                  bounds: win.frame, onScreen: win.isVisible && win.isOnActiveSpace)
            info.minimized = win.isMiniaturized
            list.append(info)
        }

        // Sıralama: son kullanılan önce, sonra CG z-sırası (önden arkaya)
        let order = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return list.enumerated().sorted { a, b in
            (order[a.element.id] ?? mru.count + a.offset) < (order[b.element.id] ?? mru.count + b.offset)
        }.map { $0.element }
    }
}

// MARK: - Son kullanılan pencere takibi

final class FocusTracker {
    private(set) var mru: [CGWindowID] = []
    private var observer: AXObserver?
    private var observedPid: pid_t = 0

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier == getpid() {   // our own Settings window: AppKit knows which one is key
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if let k = NSApp.keyWindow, !(k is NSPanel) { self?.touch(CGWindowID(k.windowNumber)) }
                }
                return
            }
            self?.watch(app.processIdentifier)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.touchFocused(of: app.processIdentifier) }
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            watch(front.processIdentifier)
            touchFocused(of: front.processIdentifier)
        }
    }

    func touch(_ id: CGWindowID) {
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        if mru.count > 200 { mru.removeLast() }
    }

    private func touchFocused(of pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let w = axValue(app, kAXFocusedWindowAttribute) else { return }
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(w as! AXUIElement, &id) == .success, id != 0 {
            touch(id)
            AXWindowCache.put(id, w as! AXUIElement)
        }
    }

    /// Aktif uygulamanın odak penceresi değişimlerini izler (tek gözlemci, uygulama değişince taşınır).
    private func watch(_ pid: pid_t) {
        guard pid != observedPid else { return }
        if let o = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            observer = nil
        }
        var o: AXObserver?
        let cb: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(element, &id) == .success, id != 0 {
                me.touch(id)
                AXWindowCache.put(id, element)
            }
        }
        guard AXObserverCreate(pid, cb, &o) == .success, let o else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(o, appEl, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(o, appEl, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observer = o
        observedPid = pid
    }
}

// MARK: - Pencereyi öne getirme

var debugLog = false
/// With --debug: appends to ~/Library/Logs/AllTab.log
func dlog(_ msg: String) {
    guard debugLog else { return }
    let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
    let line = "\(df.string(from: Date())) \(msg)\n"
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/AllTab.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

/// Pencereyi öne getirir: AltTab/yabai yöntemi (SkyLight "user generated" ön plan + AX raise).
/// AllTab never activates itself; with no windows of its own macOS would hand focus
/// bir önceki uygulamaya iade eder ("gidip geri dönme" hatası).
/// Her geçişe sıra numarası: gecikmeli adımlar yalnızca hala en son geçiş buysa çalışır,
/// yoksa hızlı art arda geçişlerde eski geçişin adımı yenisini geri alır.
private var activationGeneration = 0

func activate(_ w: WindowInfo) {
    // AllTab's own window: AppKit brings it forward
    if w.pid == getpid() {
        guard let win = NSApp.window(withWindowNumber: Int(w.id)) else { return }
        if win.isMiniaturized { win.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        return
    }
    activationGeneration += 1
    let gen = activationGeneration
    let app = w.app
    if app.isHidden { app.unhide() }
    // The window's own Accessibility element matters for a window on another desktop or in full screen:
    // bringing only the app forward does not leave the current desktop when the app already has a window
    // here (Chrome with a YouTube video in full screen), raising the window itself does.
    let ax = w.ax ?? axWindows(of: w.pid)[w.id] ?? AXWindowCache.get(w.id)
    dlog("activate#\(gen) \(app.localizedName ?? "?") #\(w.id) onScreen=\(w.onScreen) min=\(w.minimized) ax=\(ax != nil) onde=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    SkyLight.bringToFront(pid: w.pid, window: w.id)
    if let ax { axRaise(ax) }
    else if !w.onScreen {
        // Never seen on this desktop: find its element in the background, then raise it
        DispatchQueue.global(qos: .userInteractive).async {
            let el = axWindowByScan(pid: w.pid, id: w.id)
            DispatchQueue.main.async {
                dlog("activate#\(gen) tarama: bulundu=\(el != nil)")
                guard gen == activationGeneration, let el else { return }
                SkyLight.bringToFront(pid: w.pid, window: w.id)
                axRaise(el)
            }
        }
    }
    // Başka masaüstündeki pencere: masaüstü değiştikten sonra hala görünmüyorsa bir kez daha öne al
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
        guard gen == activationGeneration else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let shown = isOnScreen(w.id)
        dlog("activate#\(gen) +0.45s onde=\(front?.localizedName ?? "?") ekranda=\(shown)")
        if front?.processIdentifier != w.pid || !shown {
            SkyLight.bringToFront(pid: w.pid, window: w.id)
            if let el = axWindows(of: w.pid)[w.id] ?? AXWindowCache.get(w.id) { axRaise(el) }
        }
    }
}

// MARK: - Küçük resim yakalama

func isBlank(_ img: CGImage) -> Bool {
    let n = 8
    var px = [UInt8](repeating: 0, count: n * n * 4)
    guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
    var alpha = 0, lo = 255, hi = 0
    for i in 0..<(n * n) {
        alpha += Int(px[i * 4 + 3])
        let v = (Int(px[i * 4]) + Int(px[i * 4 + 1]) + Int(px[i * 4 + 2])) / 3
        lo = min(lo, v); hi = max(hi, v)
    }
    return alpha < 10 * n * n || (hi - lo) < 3
}

// MARK: - Izgara görünümü

final class GridView: NSView {
    weak var switcher: Switcher?
    var cols = 1
    var cell = CGSize(width: 232, height: 176)
    var gap: CGFloat = 10
    var pad: CGFloat = 16
    /// Vertical list: one row per window (icon, title, ×), no thumbnails. Filled top to bottom, then the
    /// next column only when there are more windows than fit on the screen.
    var list = false
    var rowsPerCol = 1

    override var isFlipped: Bool { true }

    func rect(_ i: Int) -> CGRect {
        let col = list ? i / rowsPerCol : i % cols
        let row = list ? i % rowsPerCol : i / cols
        return CGRect(x: pad + CGFloat(col) * (cell.width + gap),
                      y: pad + CGFloat(row) * (cell.height + gap),
                      width: cell.width, height: cell.height)
    }

    func index(at p: CGPoint) -> Int? {
        guard let n = switcher?.windows.count else { return nil }
        return (0..<n).first { rect($0).contains(p) }
    }

    // The mouse position never changes the selection, only a click opens a window.
    // Hover is tracked for one thing: the × (close) button on the selected cell and the one under the mouse.
    private enum Part { case cell, close }
    private(set) var hover: Int?
    private var hoverPart = Part.cell

    private static let para: NSParagraphStyle = {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p
    }()
    private static let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: para]
    private static let stateAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.white.withAlphaComponent(0.7), .paragraphStyle: para]
    // Vertical list: window title on top, app name under it
    private static let rowTitleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para]
    private static let rowAppAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.white.withAlphaComponent(0.55), .paragraphStyle: para]

    /// × button in the top right corner of a cell (list: at the right end of the row).
    func closeRect(_ i: Int) -> CGRect {
        let r = rect(i)
        return CGRect(x: r.maxX - (list ? 33 : 27), y: list ? r.midY - 9.5 : r.minY + 7, width: 19, height: 19)
    }
    private func onClose(_ p: CGPoint, _ i: Int) -> Bool { closeRect(i).insetBy(dx: -4, dy: -4).contains(p) }

    /// State badge (hidden / minimized / other desktop) in the bottom left corner (list: left of the ×).
    private func badgeRect(_ i: Int, _ text: String) -> CGRect {
        let r = rect(i)
        let size = (text as NSString).size(withAttributes: Self.stateAttrs)
        if list { return CGRect(x: r.maxX - 44 - (size.width + 12), y: r.midY - 8.5, width: size.width + 12, height: 17) }
        return CGRect(x: r.minX + 10, y: r.maxY - 18, width: size.width + 10, height: 15)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseMoved(with e: NSEvent) { setHover(convert(e.locationInWindow, from: nil)) }
    override func mouseEntered(with e: NSEvent) { setHover(convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { setHover(nil); switcher?.onMouseLeft?() }

    private func setHover(_ p: CGPoint?) {
        var h: Int?, part = Part.cell
        if let p, let i = index(at: p) {
            h = i
            part = onClose(p, i) ? .close : .cell
        }
        guard h != hover || part != hoverPart else { return }
        hover = h; hoverPart = part
        needsDisplay = true
    }

    /// The panel opened or its cells moved: no mouse event comes, so read the mouse position ourselves.
    func syncHover() {
        setHover(window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) })
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let s = switcher, let i = index(at: p) else { return }
        if onClose(p, i) { s.closeWindow(at: i); return }
        s.selected = i
        s.commit()
    }

    override func draw(_ dirty: NSRect) {
        guard let s = switcher else { return }

        for (i, w) in s.windows.enumerated() {
            let r = rect(i)
            let radius: CGFloat = list ? 10 : 8
            let path = NSBezierPath(roundedRect: list ? r.insetBy(dx: 0.75, dy: 0.75) : r, xRadius: radius, yRadius: radius)
            if i == s.selected {
                NSColor.white.withAlphaComponent(list ? 0.17 : 0.2).setFill(); path.fill()
                NSColor.white.withAlphaComponent(list ? 0.5 : 0.85).setStroke(); path.lineWidth = list ? 1 : 1.5; path.stroke()
            } else if !list || i == hover {
                NSColor.white.withAlphaComponent(list ? 0.07 : 0.06).setFill(); path.fill()
            }
            let icon = w.app.icon
            let closable = i == s.selected || i == hover

            // Dikey liste satırı: simge, pencere adı ve altında uygulama adı, durum rozeti, ×
            if list {
                let iconSize = min(32, r.height - 12)
                icon?.draw(in: CGRect(x: r.minX + 12, y: r.midY - iconSize / 2, width: iconSize, height: iconSize), from: .zero,
                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                let textX = r.minX + 12 + iconSize + 12
                var right = r.maxX - 44
                if let st = w.state { let b = badgeRect(i, st); drawBadge(b, st); right = b.minX - 10 }
                let appName = w.app.localizedName ?? ""
                // Two lines when the row is tall enough and the title is not just the app name
                if r.height >= 42, !w.title.isEmpty, w.title != appName {
                    (w.title as NSString).draw(in: CGRect(x: textX, y: r.midY - 17, width: right - textX, height: 18), withAttributes: Self.rowTitleAttrs)
                    (appName as NSString).draw(in: CGRect(x: textX, y: r.midY + 2, width: right - textX, height: 15), withAttributes: Self.rowAppAttrs)
                } else {
                    (w.label as NSString).draw(in: CGRect(x: textX, y: r.midY - 9, width: right - textX, height: 18), withAttributes: Self.rowTitleAttrs)
                }
                if closable { drawClose(i) }
                continue
            }

            // Başlık satırı: simge + başlık
            icon?.draw(in: CGRect(x: r.minX + 10, y: r.minY + 9, width: 16, height: 16), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            (w.label as NSString).draw(in: CGRect(x: r.minX + 31, y: r.minY + 8, width: r.width - (closable ? 64 : 41), height: 18), withAttributes: Self.titleAttrs)

            // Kapat düğmesi (×): seçili hücrede ve farenin altındaki hücrede
            if closable { drawClose(i) }

            // Küçük resim alanı
            let area = CGRect(x: r.minX + 10, y: r.minY + 32, width: r.width - 20, height: r.height - 44)
            if let cg = s.thumbs[w.id] {
                let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
                let k = min(area.width / iw, area.height / ih)
                let dr = CGRect(x: area.midX - iw * k / 2, y: area.midY - ih * k / 2, width: iw * k, height: ih * k)
                NSImage(cgImage: cg, size: .zero).draw(in: dr, from: .zero, operation: .sourceOver, fraction: 1,
                                                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSColor.black.withAlphaComponent(0.35).setStroke()
                NSBezierPath(rect: dr.insetBy(dx: -0.5, dy: -0.5)).stroke()
            } else {
                let sz = min(72, area.height * 0.6)
                icon?.draw(in: CGRect(x: area.midX - sz / 2, y: area.midY - sz / 2, width: sz, height: sz), from: .zero,
                           operation: .sourceOver, fraction: 0.95, respectFlipped: true, hints: nil)
            }

            // Durum rozeti (gizli / simge durumunda / başka masaüstü)
            if let st = w.state { drawBadge(badgeRect(i, st), st) }
        }
    }

    private func drawBadge(_ badge: CGRect, _ text: String) {
        NSColor.black.withAlphaComponent(list ? 0.35 : 0.5).setFill()
        let radius = list ? badge.height / 2 : 4
        NSBezierPath(roundedRect: badge, xRadius: radius, yRadius: radius).fill()
        (text as NSString).draw(in: badge.insetBy(dx: list ? 6 : 5, dy: 0).offsetBy(dx: 0, dy: list ? 1.5 : 1), withAttributes: Self.stateAttrs)
    }

    private func drawClose(_ i: Int) {
        let c = closeRect(i)
        let hot = hoverPart == .close && i == hover
        (hot ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.45)).setFill()
        NSBezierPath(ovalIn: c).fill()
        let m = c.insetBy(dx: 6.5, dy: 6.5)
        let x = NSBezierPath()
        x.move(to: CGPoint(x: m.minX, y: m.minY)); x.line(to: CGPoint(x: m.maxX, y: m.maxY))
        x.move(to: CGPoint(x: m.maxX, y: m.minY)); x.line(to: CGPoint(x: m.minX, y: m.maxY))
        x.lineWidth = 1.5; x.lineCapStyle = .round
        NSColor.white.withAlphaComponent(hot ? 1 : 0.85).setStroke(); x.stroke()
    }
}

// MARK: - Değiştirici

final class Switcher {
    /// .switcher: the Alt-Tab list in the middle of the screen. .dock: one app's windows above its Dock icon.
    enum Mode { case switcher, dock }
    let mode: Mode
    let tracker: FocusTracker
    let panel: NSPanel
    let grid = GridView()
    var windows: [WindowInfo] = []
    var selected = 0
    private(set) var visible = false
    var thumbs: [CGWindowID: CGImage] = [:]
    /// Test için: açıkken tuş bırakma ile kapanmaz
    var holdOpen = false
    private var generation = 0
    /// Panel açıldığı andaki sıra: pencere kapatılınca kalanlar yer değiştirmez
    private var shownOrder: [CGWindowID: Int] = [:]
    /// Kapatılması istenen pencereler ve gizli tutulacakları son an (kapanmazsa listeye geri döner)
    private var closing: [CGWindowID: Date] = [:]
    /// Dock mode: the app whose windows are listed and its Dock icon (Cocoa screen coordinates)
    private(set) var dockApp: NSRunningApplication?
    private var anchor: CGRect = .zero
    /// Called with true when the panel opens, false when it closes
    var onVisibility: [(Bool) -> Void] = []
    /// The mouse left the cells (Dock mode closes the preview then)
    var onMouseLeft: (() -> Void)?
    /// Switcher mode: watches the modifier while the panel is open, in case its release never reaches the tap
    private var releaseWatch: Timer?

    init(mode: Mode = .switcher, tracker: FocusTracker? = nil) {
        self.mode = mode
        self.tracker = tracker ?? FocusTracker()
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        grid.switcher = self
        grid.autoresizingMask = [.width, .height]
        effect.addSubview(grid)
        panel.contentView = effect
    }

    /// Arrow keys: ↑↓ move one row, ←→ one column (grid: across, list: to the next column of rows)
    var rowStep: Int { grid.list ? 1 : grid.cols }
    var colStep: Int { grid.list ? grid.rowsPerCol : 1 }

    func show() {
        let list = WindowList.fetch(mru: tracker.mru)
        guard !list.isEmpty else { return }
        present(list, selected: list.count > 1 ? 1 : 0)
        // The modifier's release normally arrives as a flagsChanged event; when another app's Secure Keyboard
        // Entry hides it from the tap, this still notices the release and switches.
        releaseWatch?.invalidate()
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.visible, !self.holdOpen else { return }
            if !CGEventSource.flagsState(.combinedSessionState).contains(Hotkey.current.flag) { self.commit() }
        }
    }

    /// Dock mode: lists the app's windows above its icon. Nothing is selected, the mouse picks.
    func showDock(_ app: NSRunningApplication, anchor: CGRect) {
        let list = WindowList.fetch(mru: tracker.mru).filter { $0.pid == app.processIdentifier }
        guard !list.isEmpty else { cancel(); return }
        if visible, dockApp == app, self.anchor == anchor { return }
        dockApp = app
        self.anchor = anchor
        present(list, selected: -1)
    }

    private func present(_ list: [WindowInfo], selected sel: Int) {
        windows = list
        let ids = Set(windows.map { $0.id })
        thumbs = thumbs.filter { ids.contains($0.key) }
        selected = sel
        shownOrder = Dictionary(windows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        closing = [:]
        layout()
        grid.needsDisplay = true
        panel.orderFrontRegardless()
        let wasVisible = visible
        visible = true
        generation += 1
        grid.syncHover()
        captureThumbs(generation)
        if !wasVisible { onVisibility.forEach { $0(true) } }
    }

    // MARK: Pencere kapatma (panel açık kalır)

    func closeSelectedWindow() { closeWindow(at: selected) }

    /// Pencereyi kapatır. Hücre hemen kaybolur; uygulama kaydetmeyi sorduğu için pencere kapanmazsa geri gelir.
    func closeWindow(at i: Int) {
        guard visible, windows.indices.contains(i) else { return }
        let w = windows[i]
        dlog("close \(w.app.localizedName ?? "?") #\(w.id) / \(w.title)")
        if w.pid == getpid() {   // AllTab's own window
            NSApp.window(withWindowNumber: Int(w.id))?.performClose(nil)
            drop([w.id], recheckAfter: 0.3)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if !axClose(w) { DispatchQueue.main.async { NSSound.beep() } }
        }
        drop([w.id], recheckAfter: 1.2)
    }

    func drop(_ ids: [CGWindowID], recheckAfter delay: TimeInterval) {
        let until = Date().addingTimeInterval(delay)
        for id in ids { closing[id] = until }
        windows.removeAll { ids.contains($0.id) }
        relayout()
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in
            guard let self, self.visible, self.generation == gen else { return }
            self.refresh()
        }
    }

    /// Listeyi yeniden okur: kapanan pencereler düşer, kapanmayanlar eski yerine döner, seçim korunur.
    private func refresh() {
        let now = Date()
        closing = closing.filter { $0.value > now }
        let keep = windows.indices.contains(selected) ? windows[selected].id : nil
        let fresh = WindowList.fetch(mru: tracker.mru)
            .filter { closing[$0.id] == nil && (mode == .switcher || $0.pid == dockApp?.processIdentifier) }
        let last = shownOrder.count
        windows = fresh.enumerated().sorted {
            (shownOrder[$0.element.id] ?? last + $0.offset) < (shownOrder[$1.element.id] ?? last + $1.offset)
        }.map { $0.element }
        if let k = windows.firstIndex(where: { $0.id == keep }) { selected = k }
        relayout()
    }

    private func relayout() {
        guard !windows.isEmpty else { hide(); return }
        selected = min(selected, windows.count - 1)
        layout()
        grid.needsDisplay = true
        grid.syncHover()
    }

    func step(_ d: Int) {
        guard !windows.isEmpty else { return }
        let n = windows.count
        selected = ((selected + d) % n + n) % n
        grid.needsDisplay = true
    }

    func cancel() { hide() }

    func commit() {
        guard visible, windows.indices.contains(selected) else { hide(); return }
        let w = windows[selected]
        hide()
        dlog("commit secili=\(selected) \(w.app.localizedName ?? "?") / \(w.title)")
        tracker.touch(w.id)
        activate(w)
    }

    private func hide() {
        releaseWatch?.invalidate(); releaseWatch = nil
        let wasVisible = visible
        visible = false
        dockApp = nil
        panel.orderOut(nil)
        generation += 1
        if wasVisible { onVisibility.forEach { $0(false) } }
    }

    /// Alt-Tab: fare hangi ekrandaysa ortasında. Dock: simgenin hemen üstünde (yan Dock'ta yanında).
    /// Hücre boyutu ekrana sığacak şekilde küçülür.
    private func layout() {
        let point = mode == .dock ? CGPoint(x: anchor.midX, y: anchor.midY) : NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let n = windows.count
        let dock = mode == .dock
        if !dock && SwitcherStyle.current == .list { layoutList(screen); return }
        grid.list = false; grid.gap = 10; grid.pad = 16
        let pad = grid.pad, gap = grid.gap
        let maxW = screen.visibleFrame.width * (dock ? 0.9 : 0.92), maxH = screen.visibleFrame.height * (dock ? 0.55 : 0.85)
        var cw: CGFloat = dock ? 200 : 232, ch: CGFloat = dock ? 152 : 176
        var cols = 1, rows = 1
        func measure() {
            cols = max(1, min(n, Int((maxW - 2 * pad + gap) / (cw + gap))))
            rows = Int(ceil(Double(n) / Double(cols)))
        }
        measure()
        while CGFloat(rows) * (ch + gap) - gap + 2 * pad > maxH, cw > 110 {
            cw *= 0.88; ch *= 0.88; measure()
        }
        grid.cols = cols
        grid.cell = CGSize(width: cw, height: ch)
        let w = CGFloat(cols) * (cw + gap) - gap + 2 * pad
        let h = CGFloat(rows) * (ch + gap) - gap + 2 * pad
        let f = screen.frame
        let frame = dock ? dockFrame(w, h, screen) : CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
        panel.setFrame(frame, display: false)
        grid.frame = panel.contentView!.bounds
    }

    /// Vertical list in the middle of the screen: rows get a little shorter when there are many windows,
    /// and a second column only appears when they still do not fit.
    private func layoutList(_ screen: NSScreen) {
        let n = windows.count
        grid.list = true; grid.gap = 4; grid.pad = 12
        let pad = grid.pad, gap = grid.gap
        let v = screen.visibleFrame
        let maxH = v.height * 0.85, maxW = v.width * 0.92
        var rh: CGFloat = 52
        func fit() -> Int { max(1, Int((maxH - 2 * pad + gap) / (rh + gap))) }
        while n > fit(), rh > 34 { rh -= 2 }
        let cols = Int(ceil(Double(n) / Double(fit())))
        let perCol = Int(ceil(Double(n) / Double(cols)))
        let cw = min(580, (maxW - 2 * pad - CGFloat(cols - 1) * gap) / CGFloat(cols))
        grid.cols = cols; grid.rowsPerCol = perCol
        grid.cell = CGSize(width: cw, height: rh)
        let w = CGFloat(cols) * (cw + gap) - gap + 2 * pad
        let h = CGFloat(perCol) * (rh + gap) - gap + 2 * pad
        let f = screen.frame
        panel.setFrame(CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: false)
        grid.frame = panel.contentView!.bounds
    }

    /// Next to the Dock icon, on the side away from the screen edge the Dock sits on, kept on screen.
    private func dockFrame(_ w: CGFloat, _ h: CGFloat, _ screen: NSScreen) -> CGRect {
        let f = screen.frame, v = screen.visibleFrame, a = anchor
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, v.minX + 8), v.maxX - 8 - w) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, v.minY + 8), v.maxY - 8 - h) }
        let bottom = a.minY - f.minY, left = a.minX - f.minX, right = f.maxX - a.maxX
        if bottom <= min(left, right) {
            return CGRect(x: clampX(a.midX - w / 2), y: min(max(a.maxY, v.minY) + 6, v.maxY - 8 - h), width: w, height: h)
        }
        if left < right { return CGRect(x: max(a.maxX, v.minX) + 6, y: clampY(a.midY - h / 2), width: w, height: h) }
        return CGRect(x: min(a.minX, v.maxX) - 6 - w, y: clampY(a.midY - h / 2), width: w, height: h)
    }

    /// Küçük resimler yalnızca panel açıkken ve eşzamansız çekilir, gelmeyenler simge olarak kalır.
    private func captureThumbs(_ gen: Int) {
        // Without Screen Recording, SCShareableContent makes macOS show its "record screen and audio" dialog
        // on every Cmd+Tab. Never touch ScreenCaptureKit unless the permission is already there.
        guard Permissions.screenRecording, !grid.list else { return }   // the list shows no thumbnails
        let targets = windows
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, _ in
            guard let content else { return }
            let byId = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            for w in targets {
                guard let sc = byId[w.id] else { continue }
                let cfg = SCStreamConfiguration()
                let fw = max(sc.frame.width, 1), fh = max(sc.frame.height, 1)
                let k = min(2, 560 / fw)
                cfg.width = Int(fw * k); cfg.height = Int(fh * k)
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                cfg.captureResolution = .automatic
                let filter = SCContentFilter(desktopIndependentWindow: sc)
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in
                    guard let img, !isBlank(img) else { return }
                    DispatchQueue.main.async {
                        guard let self, self.generation == gen, self.visible else { return }
                        self.thumbs[w.id] = img
                        self.grid.needsDisplay = true
                    }
                }
            }
        }
    }
}

// MARK: - Kısayol seçimi

enum Hotkey: String, CaseIterable {
    case cmd, alt, ctrl
    static var current: Hotkey {
        get { Hotkey(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .cmd }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey") }
    }
    var flag: CGEventFlags {
        switch self { case .cmd: return .maskCommand; case .alt: return .maskAlternate; case .ctrl: return .maskControl }
    }
    var title: String {
        switch self { case .cmd: return "⌘ Command + Tab"; case .alt: return "⌥ Option (Alt) + Tab"; case .ctrl: return "⌃ Control + Tab" }
    }
}

// MARK: - Görünüm

enum SwitcherStyle: String, CaseIterable {
    case grid, list
    static var current: SwitcherStyle {
        get { SwitcherStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .grid }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "style") }
    }
    var title: String {
        switch self {
        case .grid: return L.t("Side by side, with thumbnails", "Yan yana, küçük resimli")
        case .list: return L.t("Vertical list, plain", "Dikey liste, sade")
        }
    }
}

// MARK: - Klavye yakalama (event tap)

var onScreenshotHotkey: (() -> Void)?

final class HotkeyTap {
    let switcher: Switcher
    private var tap: CFMachPort?
    private var retry: Timer?

    init(_ s: Switcher) {
        switcher = s
        registerBackup()
        NotificationCenter.default.addObserver(forName: ShotHotkey.changed, object: nil, queue: .main) { [weak self] _ in
            self?.registerBackup()
        }
        s.onVisibility.append { [weak self] open in self?.switcherVisibility(open) }
        if !start() {
            // Uyarı çıkarma; izin verilene kadar 2 sn'de bir sessizce yeniden dene
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if self?.start() == true { t.invalidate() }
            }
        }
    }

    private func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: tapCallback, userInfo: refcon) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    /// true dönerse olay yutulur (diğer uygulamalara gitmez).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let s = switcher
        let flags = event.flags
        let hk = Hotkey.current
        let mod = flags.contains(hk.flag)
        if type == .flagsChanged {
            if s.visible && !mod && !s.holdOpen { s.commit() }
            return false
        }
        guard type == .keyDown else { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if ShotHotkey.recording { ShotHotkey.record(key, flags); return true }
        if ShotHotkey.enabled, !s.visible, ShotHotkey.matches(key, flags) {
            CarbonKeys.tapHandledAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { onScreenshotHotkey?() }
            return true
        }
        let allMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let others = allMods.subtracting(hk.flag)
        if key == 48, mod, flags.intersection(others).isEmpty {          // Tab
            CarbonKeys.tapHandledAt = ProcessInfo.processInfo.systemUptime
            if !s.visible { s.show() } else { s.step(flags.contains(.maskShift) ? -1 : 1) }
            return true
        }
        guard s.visible else { return false }
        CarbonKeys.tapHandledAt = ProcessInfo.processInfo.systemUptime
        switch key {
        case 53: s.cancel()                 // Esc
        case 36, 76: s.commit()             // Return / Enter
        case 123: s.step(-s.colStep)        // ←
        case 124: s.step(s.colStep)         // →
        case 126: s.step(-s.rowStep)        // ↑
        case 125: s.step(s.rowStep)         // ↓
        default:
            // W closes the selected window. A held key never repeats the action,
            // and real keys never act on the debug hook's panel (holdOpen).
            guard !s.holdOpen, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { break }
            switch letter(key) {
            case "W": s.closeSelectedWindow()
            default: break
            }
        }
        return true
    }

    /// The letter on the key in the current keyboard layout; on non-Latin layouts the key's US position.
    private func letter(_ key: Int64) -> String {
        let name = ShotHotkey.keyName(UInt16(key))
        if name.count == 1, name.unicodeScalars.allSatisfy({ $0.isASCII }) { return name }
        return key == 13 ? "W" : ""
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return Unmanaged.passUnretained(event)
    }
    return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Uyku engelleme (Amphetamine "Indefinitely" gibi: ekran uyumaz, kapak kapanınca uyur)

enum KeepAwake {
    private static var assertion: IOPMAssertionID = 0
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "keepAwake") }
        set { UserDefaults.standard.set(newValue, forKey: "keepAwake"); apply() }
    }
    static func apply() {
        if enabled, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "AllTab: keep awake" as CFString, &assertion)
        } else if !enabled, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

// MARK: - Girişte başlat (SMAppService, macOS 13+)

enum LoginItem {
    static var enabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSLog("AllTab launch-at-login change failed: \(error.localizedDescription)") }
        }
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var allGranted: Bool { accessibility && screenRecording }

    /// macOS reads Screen Recording once per process, so a running app keeps seeing "denied" after the
    /// user grants it. A fresh copy of ourselves (`--probe`) sees the live state.
    static func probeScreenRecording(_ done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            p.arguments = ["--probe"]
            var granted = false
            if (try? p.run()) != nil { p.waitUntilExit(); granted = p.terminationStatus == 0 }
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Ground truth for Screen Recording: other apps' window titles are only readable when it is granted
    /// (CGPreflightScreenCaptureAccess alone can disagree with the real state).
    static var canReadOtherWindowTitles: Bool {
        let me = getpid()
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return infos.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let name = w[kCGWindowName as String] as? String else { return false }
            return !name.isEmpty
        }
    }

    /// One system dialog only: macOS adds AllTab to the list and offers "Open System Settings".
    /// When the user clicks it, System Settings tends to open behind other windows, so we
    /// watch for it for a few seconds and bring it to front once.
    static func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        raiseSystemSettingsWhenItAppears()
    }

    static func openScreenRecording() {
        if !screenRecording { CGRequestScreenCaptureAccess() }
        raiseSystemSettingsWhenItAppears()
    }

    private static var askedAccessibility = false
    private static var askedScreenRecording = false

    /// Asks for one missing permission at a time, each at most once per run: Accessibility first,
    /// Screen Recording after Accessibility is granted.
    static func askNext() {
        if !accessibility {
            guard !askedAccessibility else { return }
            askedAccessibility = true
            openAccessibility()
        } else if !screenRecording {
            guard !askedScreenRecording else { return }
            askedScreenRecording = true
            openScreenRecording()
        }
    }

    private static var watcher: Timer?
    private static func raiseSystemSettingsWhenItAppears() {
        watcher?.invalidate()
        let deadline = Date().addingTimeInterval(20)
        var seenPid: pid_t = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier ?? 0
        watcher = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { t in
            guard Date() < deadline else { t.invalidate(); return }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return }
            // Newly launched, or already running but got (re)activated by the dialog's button
            if app.processIdentifier != seenPid || app.isActive {
                seenPid = app.processIdentifier
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    SkyLight.bringToFront(pid: app.processIdentifier, window: 0)
                    app.activate(options: [.activateIgnoringOtherApps])
                }
                t.invalidate()
            }
        }
    }
}

// MARK: - Ayarlar penceresi

final class SettingsWindow: NSWindowController {
    private let axStatus = NSTextField(labelWithString: "")
    private let scStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton(title: L.t("Open Settings", "Ayarı Aç"), target: nil, action: nil)
    private let scButton = NSButton(title: L.t("Open Settings", "Ayarı Aç"), target: nil, action: nil)
    private let hotkeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginCheck = NSButton(checkboxWithTitle: L.t("Launch at login", "Girişte otomatik başlat"), target: nil, action: nil)
    private let awakeCheck = NSButton(checkboxWithTitle: L.t("Keep awake (display never sleeps, lid close still sleeps)", "Uyku engelle (ekran uyumasın, kapak kapanınca uyur)"), target: nil, action: nil)
    private let dockCheck = NSButton(checkboxWithTitle: L.t("Show an app's windows on its Dock icon", "Dock simgesinin üzerine gelince pencereleri göster"), target: nil, action: nil)
    private var permNote: NSTextField?
    private let swipeCheck = NSButton(checkboxWithTitle: L.t("Two-finger swipe in Finder: right = Back, left = Forward", "Finder'da iki parmak kaydırma: sağa = Geri, sola = İleri"), target: nil, action: nil)
    private let updateCheck = NSButton(checkboxWithTitle: L.t("Check for updates automatically", "Güncellemeleri otomatik denetle"), target: nil, action: nil)
    private let shotCheck = NSButton(checkboxWithTitle: L.t("Enable screenshot tool", "Ekran görüntüsü aracını kullan"), target: nil, action: nil)
    private let shotKeyLabel = NSTextField(labelWithString: "")
    private let shotKeyButton = NSButton(title: L.t("Change", "Değiştir"), target: nil, action: nil)
    private var refresh: Timer?
    /// True while the user is going through the permission setup with this window open.
    var assisting = false
    private var lastAccessibility = false
    private var systemSettingsObserver: NSObjectProtocol?
    weak var app: AppDelegate?

    init(app: AppDelegate) {
        self.app = app
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 10),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L.t("AllTab Settings", "AllTab Ayarları")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func section(_ title: String) -> NSTextField {
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return t
    }
    private func note(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = NSFont.systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        return t
    }
    private func separator() -> NSBox { let b = NSBox(); b.boxType = .separator; return b }

    private func permRow(_ status: NSTextField, _ title: String, _ desc: String, _ button: NSButton, _ sel: Selector) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let text = NSStackView(views: [name, note(desc)])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        button.target = self; button.action = sel; button.bezelStyle = .rounded
        let row = NSStackView(views: [status, text, button])
        row.orientation = .horizontal; row.alignment = .top; row.spacing = 8
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func build() {
        for hk in Hotkey.allCases {
            hotkeyPopup.addItem(withTitle: hk.title)
            hotkeyPopup.lastItem?.representedObject = hk.rawValue
        }
        hotkeyPopup.target = self; hotkeyPopup.action = #selector(hotkeyChanged)
        for st in SwitcherStyle.allCases {
            stylePopup.addItem(withTitle: st.title)
            stylePopup.lastItem?.representedObject = st.rawValue
        }
        stylePopup.target = self; stylePopup.action = #selector(styleChanged)
        loginCheck.target = self; loginCheck.action = #selector(loginChanged)
        awakeCheck.target = self; awakeCheck.action = #selector(awakeChanged)
        swipeCheck.target = self; swipeCheck.action = #selector(swipeChanged)
        dockCheck.target = self; dockCheck.action = #selector(dockChanged)
        updateCheck.target = self; updateCheck.action = #selector(updateChanged)
        let updateNow = NSButton(title: L.t("Check Now", "Şimdi Denetle"), target: self, action: #selector(checkUpdateNow))
        let updateRow = NSStackView(views: [updateCheck, updateNow])
        updateRow.orientation = .horizontal; updateRow.spacing = 12

        let hkRow = NSStackView(views: [NSTextField(labelWithString: L.t("Switch windows:", "Pencere değiştir:")), hotkeyPopup])
        hkRow.orientation = .horizontal; hkRow.spacing = 8
        let styleRow = NSStackView(views: [NSTextField(labelWithString: L.t("Layout:", "Görünüm:")), stylePopup])
        styleRow.orientation = .horizontal; styleRow.spacing = 8

        shotCheck.target = self; shotCheck.action = #selector(shotChanged)
        shotKeyButton.target = self; shotKeyButton.action = #selector(recordShotKey)
        shotKeyLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let shotRow = NSStackView(views: [NSTextField(labelWithString: L.t("Shortcut:", "Kısayol:")), shotKeyLabel, shotKeyButton])
        shotRow.orientation = .horizontal; shotRow.spacing = 8
        NotificationCenter.default.addObserver(forName: ShotHotkey.changed, object: nil, queue: .main) { [weak self] _ in self?.loadShot() }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [note("AllTab \(version)"), spacer,
                                         NSButton(title: L.t("Restart", "Yeniden Başlat"), target: self, action: #selector(restart)),
                                         NSButton(title: L.t("Quit", "Çıkış"), target: NSApp, action: #selector(NSApplication.terminate(_:)))])
        footer.orientation = .horizontal; footer.spacing = 8

        let permHelp = note(L.t("If AllTab is missing from the list, add /Applications/AllTab.app with + and turn it on. AllTab restarts itself when needed after a permission is granted.",
                                "Ayar sayfasında listede AllTab yoksa + ile /Applications/AllTab.app'ı ekle ve anahtarı aç. İzin verildiğinde uygulama gerekirse kendini yeniden başlatır."))
        permNote = permHelp   // only shown while a permission is missing

        // Two columns side by side, so the whole window fits on a laptop screen without scrolling
        let left: [NSView] = [
            section(L.t("Shortcut", "Kısayol")), hkRow, styleRow,
            note(L.t("Hold the modifier and press Tab to move forward, Shift+Tab back, arrow keys work too. A click opens a window, W or × closes it. Release to switch, Esc cancels.",
                     "Tuşu basılı tutup Tab ile ilerle, Shift+Tab geri, ok tuşları da çalışır. Tıklayınca pencere açılır, W ya da × kapatır. Bırakınca seçili pencereye geçer, Esc iptal.")),
            separator(),
            section(L.t("Permissions", "İzinler")),
            permRow(axStatus, L.t("Accessibility", "Erişilebilirlik"), L.t("Required to capture the shortcut and bring windows to front.", "Kısayolu yakalamak ve pencereleri öne getirmek için zorunlu."), axButton, #selector(openAX)),
            permRow(scStatus, L.t("Screen Recording", "Ekran Kaydı"), L.t("For window thumbnails and the screenshot tool. Without it, app icons are shown.", "Pencerelerin küçük resimleri ve ekran görüntüsü için. Verilmezse simge gösterilir."), scButton, #selector(openSC)),
            permHelp,
            separator(),
            section(L.t("Dock", "Dock")), dockCheck,
            note(L.t("Hidden, minimized and other-desktop windows are listed too. Click one to open it, × closes it.",
                     "Gizli, simge durumundaki ve başka masaüstündeki pencereler de listelenir. Tıklayınca pencere açılır, × kapatır.")),
        ]
        let right: [NSView] = [
            section(L.t("Screenshot", "Ekran Görüntüsü")), shotCheck, shotRow,
            note(L.t("Press the shortcut to freeze the screen, drag to select an area, mark it with a red rectangle / arrow / pen. To move the selection use the Move tool (4), hold Space while dragging, or the arrow keys. ⌘C copies (then ⌘V anywhere), ⌘S saves, ⌘Z undoes, Esc cancels.",
                     "Kısayola basınca ekran dondurulur, sürükleyerek alan seç, kırmızı çerçeve / ok / kalem ile işaretle. Seçimi taşımak için Taşı aracı (4), Space basılı sürükleme ya da ok tuşları. ⌘C kopyalar (sonra ⌘V ile yapıştır), ⌘S kaydeder, ⌘Z geri alır, Esc iptal.")),
            separator(),
            section(L.t("Finder", "Finder")), swipeCheck,
            note(L.t("Swipe with two fingers in a Finder window, like in Chrome. Uses Finder's own Back / Forward commands.",
                     "Finder penceresinde iki parmakla kaydır, Chrome'daki gibi. Finder'ın kendi Geri / İleri komutunu kullanır.")),
            separator(),
            section(L.t("General", "Genel")), loginCheck, awakeCheck, updateRow,
        ]
        let colW: CGFloat = 400
        func column(_ rows: [NSView]) -> NSStackView {
            let st = NSStackView(views: rows)
            st.orientation = .vertical
            st.alignment = .leading
            st.spacing = 8
            for v in rows { st.setCustomSpacing(v is NSBox ? 12 : 8, after: v) }
            for v in rows where v is NSBox || v is NSStackView || (v as? NSTextField)?.font?.pointSize == 11 {
                v.widthAnchor.constraint(equalToConstant: colW).isActive = true
            }
            st.widthAnchor.constraint(equalToConstant: colW).isActive = true
            return st
        }
        let columns = NSStackView(views: [column(left), column(right)])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 36
        let bottomLine = separator()
        let outer = NSStackView(views: [columns, bottomLine, footer])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 16, right: 24)
        outer.translatesAutoresizingMaskIntoConstraints = false
        bottomLine.widthAnchor.constraint(equalTo: columns.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: columns.widthAnchor).isActive = true
        let content = NSView()
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func show() {
        assisting = !Permissions.allGranted
        lastAccessibility = Permissions.accessibility
        load()
        window?.center()
        bringToFront()
        // This is a menu bar app: when System Settings is closed macOS hands focus to the previous app and
        // our window ends up buried behind it. While the user is setting up permissions, bring it back.
        if systemSettingsObserver == nil {
            systemSettingsObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let self, self.assisting, self.window?.isVisible == true,
                      let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.systempreferences" else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.bringToFront() }
            }
        }
        refresh?.invalidate()
        // Yalnızca pencere açıkken izin durumunu tazele
        refresh = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self, let w = self.window, w.isVisible else { t.invalidate(); return }
            self.loadPermissions()
        }
    }

    private func load() {
        let style = SwitcherStyle.current.rawValue
        if let i = stylePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == style }) { stylePopup.selectItem(at: i) }
        let cur = Hotkey.current.rawValue
        if let i = hotkeyPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == cur }) { hotkeyPopup.selectItem(at: i) }
        loginCheck.state = LoginItem.enabled ? .on : .off
        awakeCheck.state = KeepAwake.enabled ? .on : .off
        swipeCheck.state = SwipeNav.enabled ? .on : .off
        dockCheck.state = DockPreview.enabled ? .on : .off
        updateCheck.state = Updater.autoCheck ? .on : .off
        loadShot()
        loadPermissions()
    }

    private func loadShot() {
        shotCheck.state = ShotHotkey.enabled ? .on : .off
        shotKeyLabel.stringValue = ShotHotkey.recording ? L.t("press keys…", "tuşlara bas…") : ShotHotkey.display
        shotKeyButton.title = ShotHotkey.recording ? L.t("Cancel", "İptal") : L.t("Change", "Değiştir")
        shotKeyButton.isEnabled = ShotHotkey.enabled
    }

    @objc private func shotChanged() {
        ShotHotkey.enabled = shotCheck.state == .on
        NotificationCenter.default.post(name: ShotHotkey.changed, object: nil)   // re-registers the backup shortcut
    }
    @objc private func recordShotKey() {
        ShotHotkey.recording.toggle()
        loadShot()
    }

    private func loadPermissions() {
        let ax = Permissions.accessibility, sc = Permissions.screenRecording
        if assisting && ax && !lastAccessibility { bringToFront() }   // show the new ✅
        lastAccessibility = ax
        if ax && sc { assisting = false }
        axStatus.stringValue = ax ? "✅" : "⚠️"
        scStatus.stringValue = sc ? "✅" : "⚠️"
        axButton.title = ax ? L.t("Granted", "Verildi") : L.t("Open Settings", "Ayarı Aç")
        scButton.title = sc ? L.t("Granted", "Verildi") : L.t("Open Settings", "Ayarı Aç")
        axButton.isEnabled = !ax
        scButton.isEnabled = !sc
        permNote?.isHidden = ax && sc
    }

    @objc private func styleChanged() {
        if let raw = stylePopup.selectedItem?.representedObject as? String, let st = SwitcherStyle(rawValue: raw) { SwitcherStyle.current = st }
    }
    @objc private func hotkeyChanged() {
        if let raw = hotkeyPopup.selectedItem?.representedObject as? String, let hk = Hotkey(rawValue: raw) { Hotkey.current = hk }
        app?.hotkey.registerBackup()
    }
    @objc private func loginChanged() {
        LoginItem.enabled = loginCheck.state == .on
        loginCheck.state = LoginItem.enabled ? .on : .off
    }
    @objc private func awakeChanged() { KeepAwake.enabled = awakeCheck.state == .on; app?.syncUI() }
    @objc private func swipeChanged() { SwipeNav.enabled = swipeCheck.state == .on }
    @objc private func dockChanged() { DockPreview.enabled = dockCheck.state == .on; app?.dock.apply() }
    @objc private func updateChanged() { Updater.autoCheck = updateCheck.state == .on }
    @objc private func checkUpdateNow() { Updater.check(interactive: true) }
    @objc private func openAX() { Permissions.openAccessibility() }
    @objc private func openSC() { Permissions.openScreenRecording() }
    @objc private func restart() { app?.relaunch() }
}

// MARK: - Uygulama

final class AppDelegate: NSObject, NSApplicationDelegate {
    var switcher: Switcher!
    var hotkey: HotkeyTap!
    var dock: DockPreview!
    var status: NSStatusItem!
    var settings: SettingsWindow!
    let screenshot = ScreenshotTool()
    private var launchedWithoutScreenRecording = false
    let awakeItem = NSMenuItem(title: L.t("Keep Awake", "Uyku Engelle"), action: #selector(toggleAwake), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--debug") { debugLog = true }
        switcher = Switcher()
        hotkey = HotkeyTap(switcher)
        dock = DockPreview(tracker: switcher.tracker)
        switcher.onVisibility.append { [weak self] open in if open { self?.dock.preview.cancel() } }
        settings = SettingsWindow(app: self)
        onScreenshotHotkey = { [weak self] in self?.screenshot.start() }
        if debugLog { installDebugHooks() }

        // Screen Recording granted while we run: macOS wants a restart and its "Quit & Reopen" button is
        // unreliable, so poll with a fresh process (only while the permission is missing) and restart ourselves.
        if !Permissions.screenRecording {
            var probing = false
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                Permissions.askNext()   // moves on to Screen Recording once Accessibility is granted
                guard !probing else { return }
                probing = true
                Permissions.probeScreenRecording { granted in
                    probing = false
                    dlog("probe screenRecording=\(granted)")
                    if granted { t.invalidate(); self?.relaunch(afterGrant: true) }
                }
            }
        }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        KeepAwake.apply()
        SwipeNav.apply()
        Updater.checkIfDue()
        let menu = NSMenu()
        menu.addItem(withTitle: L.t("Settings…", "Ayarlar…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: L.t("Take Screenshot", "Ekran Görüntüsü Al"), action: #selector(takeScreenshot), keyEquivalent: "")
        menu.addItem(awakeItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: L.t("Check for Updates…", "Güncellemeleri Denetle…"), action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: L.t("Quit", "Çıkış"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        syncUI()

        launchedWithoutScreenRecording = !Permissions.screenRecording
        dlog("launch accessibility=\(Permissions.accessibility) screenRecording=\(Permissions.screenRecording) canReadOtherWindowTitles=\(Permissions.canReadOtherWindowTitles) pid=\(getpid())")
        // Relaunched by ourselves right after a grant: show the Settings window so the user sees both ✅.
        if CommandLine.arguments.contains("--after-grant") { openSettings() }
        // Missing permissions: the app cannot work, so push the user through the flow instead of waiting silently.
        if !Permissions.allGranted {
            openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Permissions.askNext() }
        }
    }

    @objc func openSettings() { settings.show() }
    @objc func checkForUpdates() { Updater.check(interactive: true) }
    @objc func takeScreenshot() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.screenshot.start() } }

    @objc func toggleAwake() {
        KeepAwake.enabled.toggle()
        syncUI()
    }

    /// Menü işareti ve menü çubuğu simgesi (uyku engelleme açıkken dolu simge)
    func syncUI() {
        awakeItem.state = KeepAwake.enabled ? .on : .off
        let name = KeepAwake.enabled ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "AllTab") {
            img.isTemplate = true
            status.button?.image = img
            status.button?.title = ""
        } else {
            status.button?.title = "⇥"
        }
    }

    private var relaunching = false

    /// Restart (used by the Settings button and after a permission grant).
    @objc func relaunch() { relaunch(afterGrant: false) }

    func relaunch(afterGrant: Bool) {
        spawnRelauncher(afterGrant: afterGrant)
        NSApp.terminate(nil)
    }

    /// macOS's own "Quit & Reopen" button quits us but does not reliably reopen us. If a normal quit
    /// happens right after Screen Recording was granted, reopen ourselves.
    func applicationWillTerminate(_ n: Notification) {
        SystemSwitcher.set(enabled: true)   // give macOS its own Cmd+Tab back
        guard launchedWithoutScreenRecording, !relaunching else { return }
        var granted = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["--probe"]
        if (try? p.run()) != nil { p.waitUntilExit(); granted = p.terminationStatus == 0 }
        if granted { spawnRelauncher(afterGrant: true) }
    }

    private func spawnRelauncher(afterGrant: Bool) {
        guard !relaunching else { return }
        relaunching = true
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let args = afterGrant ? " --args --after-grant" : ""
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(path)\"\(args)"]
        try? p.run()
    }

    /// `--debug` ile açılınca: dağıtık bildirimle panel/ayarlar kontrolü (yalnızca test için)
    private func installDebugHooks() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.turandogan.alltab.debug"), object: nil, queue: .main) { [weak self] n in
            guard let self, let s = self.switcher else { return }
            func find(_ q: Substring) -> Int? {
                s.windows.firstIndex { ($0.app.localizedName ?? "").lowercased().contains(q.lowercased()) }
            }
            switch n.object as? String {
            case "show": s.holdOpen = true; s.show()
            case "hold": s.holdOpen = true
            case "next": s.step(1)
            case let cmd? where cmd.hasPrefix("select:"):
                if let i = s.windows.firstIndex(where: { ($0.app.localizedName ?? "").lowercased().contains(cmd.dropFirst(7).lowercased()) }) { s.selected = i; s.grid.needsDisplay = true }
                dlog("liste: " + s.windows.enumerated().map { "\($0.offset):\($0.element.app.localizedName ?? "?")[\($0.element.state ?? "")]\($0.offset == s.selected ? "*" : "")" }.joined(separator: " "))
            // close:/drop: yalnızca adı eşleşen uygulamaya dokunur, eşleşme yoksa hiçbir şey yapmaz
            case let cmd? where cmd.hasPrefix("close:"):
                if let i = find(cmd.dropFirst(6)) { s.closeWindow(at: i) } else { dlog("close: eslesme yok") }
            case let cmd? where cmd.hasPrefix("drop:"):   // kapatmadan yalnızca listeden düşürür: geri dönüşü dener
                if let i = find(cmd.dropFirst(5)) { s.drop([s.windows[i].id], recheckAfter: 1.2) } else { dlog("drop: eslesme yok") }
            case "list":
                dlog("liste: " + s.windows.enumerated().map { "\($0.offset):\($0.element.app.localizedName ?? "?")#\($0.element.id)[\($0.element.state ?? "")]\($0.offset == s.selected ? "*" : "")" }.joined(separator: " "))
            case let cmd? where cmd.hasPrefix("index:"):
                if let i = Int(cmd.dropFirst(6)), s.windows.indices.contains(i) { s.selected = i; s.grid.needsDisplay = true }
            case "scan":   // seçili pencerede başka masaüstü yolunu (AX taraması) dener, hiçbir şeye basmaz
                guard s.windows.indices.contains(s.selected) else { break }
                let w = s.windows[s.selected]
                let keys = "W=\(ShotHotkey.keyName(13)) Q=\(ShotHotkey.keyName(12))"
                DispatchQueue.global().async {
                    let t = Date()
                    let el = axWindowByScan(pid: w.pid, id: w.id)
                    let button = el.flatMap { axValue($0, kAXCloseButtonAttribute) } != nil
                    dlog("scan \(w.app.localizedName ?? "?") #\(w.id) [\(w.state ?? "")] bulundu=\(el != nil) kapat=\(button) sure=\(Int(Date().timeIntervalSince(t) * 1000))ms \(keys)")
                }
            case "cancel": s.holdOpen = false; s.cancel()
            case "commit": s.holdOpen = false; s.commit()
            case "dockinfo": dlog(self.dock.describe())   // yalnız okur, ekranda bir şey açmaz
            case "settings": self.openSettings()
            case "shot": self.screenshot.start()
            case "swipeback": SwipeNav.go(back: true)
            case "swipeforward": SwipeNav.go(back: false)
            case "update": Updater.check(interactive: true)
            case "grant": self.relaunch(afterGrant: true)
            case "assist": self.settings.assisting = true
            default: break
            }
        }
    }
}

// `AllTab --probe`: print nothing, exit 0 when Screen Recording is granted (used to see the live state from a fresh process)
if CommandLine.arguments.contains("--probe") { exit(CGPreflightScreenCaptureAccess() ? 0 : 1) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
