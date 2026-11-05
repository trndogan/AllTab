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

typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> CGError
typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SkyLight {
    static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let setFront: SetFrontFn? = sym("_SLPSSetFrontProcessWithOptions")
    static let postEvent: PostEventFn? = sym("SLPSPostEventRecordTo")
    static let psnForPid: PSNFn? = sym("GetProcessForPID")

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
        if _AXUIElementGetWindow(w, &id) == .success, id != 0 { out[id] = w }
    }
    return out
}

func axRaise(_ el: AXUIElement) {
    if (axValue(el, kAXMinimizedAttribute) as? Bool) == true {
        AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
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
            return w
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
        if _AXUIElementGetWindow(w as! AXUIElement, &id) == .success, id != 0 { touch(id) }
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
            if _AXUIElementGetWindow(element, &id) == .success, id != 0 { me.touch(id) }
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
    activationGeneration += 1
    let gen = activationGeneration
    let app = w.app
    if app.isHidden { app.unhide() }
    let ax = w.ax ?? axWindows(of: w.pid)[w.id]
    dlog("activate#\(gen) \(app.localizedName ?? "?") #\(w.id) onScreen=\(w.onScreen) min=\(w.minimized) ax=\(ax != nil) onde=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    SkyLight.bringToFront(pid: w.pid, window: w.id)
    if let ax { axRaise(ax) }
    // Başka masaüstündeki pencere: masaüstü değiştikten sonra bir kez daha öne al
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        guard gen == activationGeneration else { return }
        let front = NSWorkspace.shared.frontmostApplication
        dlog("activate#\(gen) +0.4s onde=\(front?.localizedName ?? "?")")
        if front?.processIdentifier != w.pid {
            SkyLight.bringToFront(pid: w.pid, window: w.id)
            if let el = axWindows(of: w.pid)[w.id] { axRaise(el) }
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
    let gap: CGFloat = 10
    let pad: CGFloat = 16
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    func rect(_ i: Int) -> CGRect {
        CGRect(x: pad + CGFloat(i % cols) * (cell.width + gap),
               y: pad + CGFloat(i / cols) * (cell.height + gap),
               width: cell.width, height: cell.height)
    }

    func index(at p: CGPoint) -> Int? {
        guard let n = switcher?.windows.count else { return nil }
        return (0..<n).first { rect($0).contains(p) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseMoved(with e: NSEvent) {
        guard let s = switcher, let i = index(at: convert(e.locationInWindow, from: nil)), i != s.selected else { return }
        s.selected = i
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        guard let s = switcher, let i = index(at: convert(e.locationInWindow, from: nil)) else { return }
        s.selected = i
        s.commit()
    }

    override func draw(_ dirty: NSRect) {
        guard let s = switcher else { return }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: para]
        let stateAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.white.withAlphaComponent(0.7), .paragraphStyle: para]

        for (i, w) in s.windows.enumerated() {
            let r = rect(i)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            if i == s.selected {
                NSColor.white.withAlphaComponent(0.2).setFill(); path.fill()
                NSColor.white.withAlphaComponent(0.85).setStroke(); path.lineWidth = 1.5; path.stroke()
            } else {
                NSColor.white.withAlphaComponent(0.06).setFill(); path.fill()
            }

            // Başlık satırı: simge + başlık
            let icon = w.app.icon
            icon?.draw(in: CGRect(x: r.minX + 10, y: r.minY + 9, width: 16, height: 16), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            (w.label as NSString).draw(in: CGRect(x: r.minX + 31, y: r.minY + 8, width: r.width - 41, height: 18), withAttributes: titleAttrs)

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
            if let st = w.state {
                let size = (st as NSString).size(withAttributes: stateAttrs)
                let badge = CGRect(x: r.minX + 10, y: r.maxY - 18, width: size.width + 10, height: 15)
                NSColor.black.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
                (st as NSString).draw(in: badge.insetBy(dx: 5, dy: 0).offsetBy(dx: 0, dy: 1), withAttributes: stateAttrs)
            }
        }
    }
}

// MARK: - Değiştirici

final class Switcher {
    let tracker = FocusTracker()
    let panel: NSPanel
    let grid = GridView()
    var windows: [WindowInfo] = []
    var selected = 0
    private(set) var visible = false
    var thumbs: [CGWindowID: CGImage] = [:]
    /// Test için: açıkken tuş bırakma ile kapanmaz
    var holdOpen = false
    private var generation = 0

    init() {
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

    var cols: Int { grid.cols }

    func show() {
        windows = WindowList.fetch(mru: tracker.mru)
        guard !windows.isEmpty else { return }
        let ids = Set(windows.map { $0.id })
        thumbs = thumbs.filter { ids.contains($0.key) }
        selected = windows.count > 1 ? 1 : 0
        layout()
        grid.needsDisplay = true
        panel.orderFrontRegardless()
        visible = true
        generation += 1
        captureThumbs(generation)
    }

    func step(_ d: Int) {
        guard !windows.isEmpty else { return }
        let n = windows.count
        selected = ((selected + d) % n + n) % n
        grid.needsDisplay = true
    }

    func cancel() { hide() }

    func commit() {
        guard visible, selected < windows.count else { hide(); return }
        let w = windows[selected]
        hide()
        dlog("commit secili=\(selected) \(w.app.localizedName ?? "?") / \(w.title)")
        tracker.touch(w.id)
        activate(w)
    }

    private func hide() {
        visible = false
        panel.orderOut(nil)
        generation += 1
    }

    /// Fare hangi ekrandaysa orada, ekrana sığacak şekilde hücre boyutunu ayarlar.
    private func layout() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let n = windows.count
        let pad = grid.pad, gap = grid.gap
        let maxW = screen.visibleFrame.width * 0.92, maxH = screen.visibleFrame.height * 0.85
        var cw: CGFloat = 232, ch: CGFloat = 176
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
        panel.setFrame(CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: false)
        grid.frame = panel.contentView!.bounds
    }

    /// Küçük resimler yalnızca panel açıkken ve eşzamansız çekilir, gelmeyenler simge olarak kalır.
    private func captureThumbs(_ gen: Int) {
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

// MARK: - Klavye yakalama (event tap)

var onScreenshotHotkey: (() -> Void)?

final class HotkeyTap {
    let switcher: Switcher
    private var tap: CFMachPort?
    private var retry: Timer?

    init(_ s: Switcher) {
        switcher = s
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
            DispatchQueue.main.async { onScreenshotHotkey?() }
            return true
        }
        let allMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let others = allMods.subtracting(hk.flag)
        if key == 48, mod, flags.intersection(others).isEmpty {          // Tab
            if !s.visible { s.show() } else { s.step(flags.contains(.maskShift) ? -1 : 1) }
            return true
        }
        guard s.visible else { return false }
        switch key {
        case 53: s.cancel()                 // Esc
        case 36, 76: s.commit()             // Return / Enter
        case 123: s.step(-1)                // ←
        case 124: s.step(1)                 // →
        case 126: s.step(-s.cols)           // ↑
        case 125: s.step(s.cols)            // ↓
        default: break
        }
        return true
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

    /// Requests whatever is missing, Accessibility first.
    static func requestMissing() {
        if !accessibility { openAccessibility() }
        else if !screenRecording { openScreenRecording() }
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
    private let loginCheck = NSButton(checkboxWithTitle: L.t("Launch at login", "Girişte otomatik başlat"), target: nil, action: nil)
    private let awakeCheck = NSButton(checkboxWithTitle: L.t("Keep awake (display never sleeps, lid close still sleeps)", "Uyku engelle (ekran uyumasın, kapak kapanınca uyur)"), target: nil, action: nil)
    private let shotCheck = NSButton(checkboxWithTitle: L.t("Enable screenshot tool", "Ekran görüntüsü aracını kullan"), target: nil, action: nil)
    private let shotKeyLabel = NSTextField(labelWithString: "")
    private let shotKeyButton = NSButton(title: L.t("Change", "Değiştir"), target: nil, action: nil)
    private var refresh: Timer?
    weak var app: AppDelegate?

    init(app: AppDelegate) {
        self.app = app
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
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
        loginCheck.target = self; loginCheck.action = #selector(loginChanged)
        awakeCheck.target = self; awakeCheck.action = #selector(awakeChanged)

        let hkRow = NSStackView(views: [NSTextField(labelWithString: L.t("Switch windows:", "Pencere değiştir:")), hotkeyPopup])
        hkRow.orientation = .horizontal; hkRow.spacing = 8

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

        let rows: [NSView] = [
            section(L.t("Shortcut", "Kısayol")), hkRow,
            note(L.t("Hold the modifier and press Tab to move forward, Shift+Tab back; arrow keys and the mouse work too. Release to switch, Esc cancels.",
                     "Tuşu basılı tutup Tab ile ilerle, Shift+Tab geri, ok tuşları ve fare de çalışır. Bırakınca seçili pencereye geçer, Esc iptal.")),
            separator(),
            section(L.t("Permissions", "İzinler")),
            permRow(axStatus, L.t("Accessibility", "Erişilebilirlik"), L.t("Required to capture the shortcut and bring windows to front.", "Kısayolu yakalamak ve pencereleri öne getirmek için zorunlu."), axButton, #selector(openAX)),
            permRow(scStatus, L.t("Screen Recording", "Ekran Kaydı"), L.t("For window thumbnails and the screenshot tool. Without it, app icons are shown.", "Pencerelerin küçük resimleri ve ekran görüntüsü için. Verilmezse simge gösterilir."), scButton, #selector(openSC)),
            note(L.t("If AllTab is missing from the list, add /Applications/AllTab.app with + and turn it on. AllTab restarts itself when needed after a permission is granted.",
                     "Ayar sayfasında listede AllTab yoksa + ile /Applications/AllTab.app'ı ekle ve anahtarı aç. İzin verildiğinde uygulama gerekirse kendini yeniden başlatır.")),
            separator(),
            section(L.t("Screenshot", "Ekran Görüntüsü")), shotCheck, shotRow,
            note(L.t("Press the shortcut to freeze the screen, drag to select an area, mark it with a red rectangle / arrow / pen. ⌘C copies (then ⌘V anywhere), ⌘S saves, ⌘Z undoes, Esc cancels.",
                     "Kısayola basınca ekran dondurulur, sürükleyerek alan seç, kırmızı çerçeve / ok / kalem ile işaretle. ⌘C kopyalar (sonra ⌘V ile yapıştır), ⌘S kaydeder, ⌘Z geri alır, Esc iptal.")),
            separator(),
            section(L.t("General", "Genel")), loginCheck, awakeCheck,
            separator(),
            footer,
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in rows { stack.setCustomSpacing(v is NSBox ? 12 : 8, after: v) }
        for v in rows where v is NSBox || v is NSStackView || (v as? NSTextField)?.font?.pointSize == 11 {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460),
        ])
        window?.contentView = content
    }

    func show() {
        load()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh?.invalidate()
        // Yalnızca pencere açıkken izin durumunu tazele
        refresh = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self, let w = self.window, w.isVisible else { t.invalidate(); return }
            self.loadPermissions()
        }
    }

    private func load() {
        let cur = Hotkey.current.rawValue
        if let i = hotkeyPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == cur }) { hotkeyPopup.selectItem(at: i) }
        loginCheck.state = LoginItem.enabled ? .on : .off
        awakeCheck.state = KeepAwake.enabled ? .on : .off
        loadShot()
        loadPermissions()
    }

    private func loadShot() {
        shotCheck.state = ShotHotkey.enabled ? .on : .off
        shotKeyLabel.stringValue = ShotHotkey.recording ? L.t("press keys…", "tuşlara bas…") : ShotHotkey.display
        shotKeyButton.title = ShotHotkey.recording ? L.t("Cancel", "İptal") : L.t("Change", "Değiştir")
        shotKeyButton.isEnabled = ShotHotkey.enabled
    }

    @objc private func shotChanged() { ShotHotkey.enabled = shotCheck.state == .on; loadShot() }
    @objc private func recordShotKey() {
        ShotHotkey.recording.toggle()
        loadShot()
    }

    private func loadPermissions() {
        let ax = Permissions.accessibility, sc = Permissions.screenRecording
        axStatus.stringValue = ax ? "✅" : "⚠️"
        scStatus.stringValue = sc ? "✅" : "⚠️"
        axButton.title = ax ? L.t("Granted", "Verildi") : L.t("Open Settings", "Ayarı Aç")
        scButton.title = sc ? L.t("Granted", "Verildi") : L.t("Open Settings", "Ayarı Aç")
        axButton.isEnabled = !ax
        scButton.isEnabled = !sc
    }

    @objc private func hotkeyChanged() {
        if let raw = hotkeyPopup.selectedItem?.representedObject as? String, let hk = Hotkey(rawValue: raw) { Hotkey.current = hk }
    }
    @objc private func loginChanged() {
        LoginItem.enabled = loginCheck.state == .on
        loginCheck.state = LoginItem.enabled ? .on : .off
    }
    @objc private func awakeChanged() { KeepAwake.enabled = awakeCheck.state == .on; app?.syncUI() }
    @objc private func openAX() { Permissions.openAccessibility() }
    @objc private func openSC() { Permissions.openScreenRecording() }
    @objc private func restart() { app?.relaunch() }
}

// MARK: - Uygulama

final class AppDelegate: NSObject, NSApplicationDelegate {
    var switcher: Switcher!
    var hotkey: HotkeyTap!
    var status: NSStatusItem!
    var settings: SettingsWindow!
    let screenshot = ScreenshotTool()
    private var launchedWithoutScreenRecording = false
    let awakeItem = NSMenuItem(title: L.t("Keep Awake", "Uyku Engelle"), action: #selector(toggleAwake), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        switcher = Switcher()
        hotkey = HotkeyTap(switcher)
        settings = SettingsWindow(app: self)
        onScreenshotHotkey = { [weak self] in self?.screenshot.start() }
        if CommandLine.arguments.contains("--debug") { debugLog = true; installDebugHooks() }

        // Screen Recording granted while we run: macOS wants a restart and its "Quit & Reopen" button is
        // unreliable, so poll with a fresh process (only while the permission is missing) and restart ourselves.
        if !Permissions.screenRecording {
            var probing = false
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
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
        let menu = NSMenu()
        menu.addItem(withTitle: L.t("Settings…", "Ayarlar…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: L.t("Take Screenshot", "Ekran Görüntüsü Al"), action: #selector(takeScreenshot), keyEquivalent: "")
        menu.addItem(awakeItem)
        menu.addItem(.separator())
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Permissions.requestMissing() }
        }
    }

    @objc func openSettings() { settings.show() }
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
            switch n.object as? String {
            case "show": s.holdOpen = true; s.show()
            case "hold": s.holdOpen = true
            case "next": s.step(1)
            case let cmd? where cmd.hasPrefix("select:"):
                if let i = s.windows.firstIndex(where: { ($0.app.localizedName ?? "").lowercased().contains(cmd.dropFirst(7).lowercased()) }) { s.selected = i; s.grid.needsDisplay = true }
                dlog("liste: " + s.windows.enumerated().map { "\($0.offset):\($0.element.app.localizedName ?? "?")[\($0.element.state ?? "")]\($0.offset == s.selected ? "*" : "")" }.joined(separator: " "))
            case "cancel": s.holdOpen = false; s.cancel()
            case "commit": s.holdOpen = false; s.commit()
            case "settings": self.openSettings()
            case "shot": self.screenshot.start()
            case "grant": self.relaunch(afterGrant: true)
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
