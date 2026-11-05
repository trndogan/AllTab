// AllTab – Screenshot tool (Lightshot-style)
// Kısayol → ekran dondurulur → sürükleyerek alan seç → kırmızı çerçeve / ok / kalem ile işaretle
// ⌘C kopyala, ⌘S kaydet, ⌘Z geri al, Enter kopyala, Esc iptal.

import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

// MARK: - Kısayol ayarı

enum ShotHotkey {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "shotEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "shotEnabled") }
    }
    /// Varsayılan: keycode 33 (Türkçe Q'da Ğ, ABD'de [) + ⌘
    static var keyCode: Int64 {
        get { UserDefaults.standard.object(forKey: "shotKey") as? Int64 ?? 33 }
        set { UserDefaults.standard.set(newValue, forKey: "shotKey") }
    }
    static var modifiers: UInt64 {
        get { UserDefaults.standard.object(forKey: "shotMods") as? UInt64 ?? CGEventFlags.maskCommand.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "shotMods") }
    }
    /// Ayarlar penceresinde "Değiştir" basılınca true olur, sonraki tuş kombinasyonu kaydedilir.
    static var recording = false
    static let changed = Notification.Name("alltab.shotHotkeyChanged")

    static let modMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    static func matches(_ key: Int64, _ flags: CGEventFlags) -> Bool {
        key == keyCode && flags.intersection(modMask).rawValue == modifiers
    }

    /// Kayıt modunda gelen tuşu kaydeder. En az bir değiştirici (⌘⌥⌃) gerekir, Esc iptal eder.
    static func record(_ key: Int64, _ flags: CGEventFlags) {
        if key != 53 { // Esc değilse
            let mods = flags.intersection(modMask)
            guard !mods.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty else { return }
            keyCode = key
            modifiers = mods.rawValue
        }
        recording = false
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static var display: String {
        let f = CGEventFlags(rawValue: modifiers)
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s + keyName(UInt16(keyCode))
    }

    /// Geçerli klavye düzenine göre tuşun adı (Türkçe'de 33 → Ğ, ABD'de [).
    static func keyName(_ code: UInt16) -> String {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                         101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let s = special[code] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = unsafeBitCast(ptr, to: CFData.self) as Data
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        var dead: UInt32 = 0
        let err = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  UInt32(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard err == noErr, len > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: len).uppercased(with: Locale(identifier: "tr"))
    }
}

// MARK: - İşaretler

enum Mark {
    case rect(CGRect)
    case arrow(CGPoint, CGPoint)
    case pen([CGPoint])

    static let color = CGColor(red: 0.95, green: 0.18, blue: 0.18, alpha: 1)
    static let width: CGFloat = 3

    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(Mark.color)
        ctx.setFillColor(Mark.color)
        ctx.setLineWidth(Mark.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch self {
        case .rect(let r):
            ctx.addPath(CGPath(roundedRect: r.standardized, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.strokePath()
        case .arrow(let a, let b):
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            let ang = atan2(b.y - a.y, b.x - a.x)
            let len: CGFloat = 14, spread: CGFloat = .pi / 7
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x - len * cos(ang - spread), y: b.y - len * sin(ang - spread)))
            ctx.addLine(to: CGPoint(x: b.x - len * cos(ang + spread), y: b.y - len * sin(ang + spread)))
            ctx.closePath(); ctx.fillPath()
        case .pen(let pts):
            guard let f = pts.first else { break }
            ctx.move(to: f)
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

enum Tool: Int { case rect, arrow, pen }

// MARK: - Kaplama penceresi

final class ShotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ShotView: NSView {
    let image: CGImage
    let scale: CGFloat
    var selection: CGRect?
    var marks: [Mark] = []
    var tool: Tool = .rect
    var onDone: (() -> Void)?

    private var dragStart: CGPoint?
    private var live: Mark?
    private var selecting = false
    private let toolbar = NSVisualEffectView()
    private let tools = NSSegmentedControl(labels: [L.t("▭ Rectangle", "▭ Çerçeve"), L.t("→ Arrow", "→ Ok"), L.t("✎ Pen", "✎ Kalem")], trackingMode: .selectOne, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage, scale: CGFloat, frame: CGRect) {
        self.image = image
        self.scale = scale
        super.init(frame: frame)
        wantsLayer = true
        buildToolbar()
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = .white
        sizeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        sizeLabel.drawsBackground = true
        sizeLabel.isHidden = true
        addSubview(sizeLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildToolbar() {
        toolbar.material = .hudWindow
        toolbar.state = .active
        toolbar.appearance = NSAppearance(named: .darkAqua)
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 8
        toolbar.isHidden = true
        tools.selectedSegment = 0
        tools.target = self; tools.action = #selector(toolChanged)
        let undo = NSButton(title: L.t("↶ Undo", "↶ Geri Al"), target: self, action: #selector(undo))
        let copy = NSButton(title: L.t("Copy ⌘C", "Kopyala ⌘C"), target: self, action: #selector(copyAndClose))
        let save = NSButton(title: L.t("Save ⌘S", "Kaydet ⌘S"), target: self, action: #selector(saveAndClose))
        let cancel = NSButton(title: L.t("Cancel", "İptal"), target: self, action: #selector(cancel))
        copy.keyEquivalent = "\r"
        let stack = NSStackView(views: [tools, undo, NSBox.separatorBox(), copy, save, cancel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])
        addSubview(toolbar)
    }

    // MARK: Çizim

    override func draw(_ dirty: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        // Dondurulmuş ekran (CGImage üstten başlar, flipped görünümde ters çevirerek çiz)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: bounds)
        ctx.restoreGState()

        // Seçim dışını karart
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
        if let sel = selection?.standardized {
            ctx.addRect(bounds); ctx.addRect(sel)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1)
            ctx.stroke(sel.insetBy(dx: -0.5, dy: -0.5))
            ctx.saveGState()
            ctx.clip(to: sel)
            for m in marks { m.draw(in: ctx) }
            live?.draw(in: ctx)
            ctx.restoreGState()
        } else {
            ctx.fill(bounds)
        }
    }

    private func layoutChrome() {
        guard let sel = selection?.standardized, !selecting else {
            toolbar.isHidden = true
            if let sel = selection?.standardized, selecting { updateSizeLabel(sel) } else { sizeLabel.isHidden = true }
            return
        }
        updateSizeLabel(sel)
        toolbar.isHidden = false
        toolbar.layoutSubtreeIfNeeded()
        let size = toolbar.fittingSize
        var x = sel.midX - size.width / 2
        x = max(8, min(x, bounds.width - size.width - 8))
        var y = sel.maxY + 8
        if y + size.height > bounds.height - 8 { y = sel.minY - size.height - 8 }
        if y < 8 { y = sel.maxY - size.height - 8 }
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func updateSizeLabel(_ sel: CGRect) {
        sizeLabel.stringValue = " \(Int(sel.width * scale)) × \(Int(sel.height * scale)) "
        sizeLabel.sizeToFit()
        var y = sel.minY - sizeLabel.frame.height - 4
        if y < 4 { y = sel.minY + 4 }
        sizeLabel.frame.origin = CGPoint(x: max(4, sel.minX), y: y)
        sizeLabel.isHidden = false
    }

    // MARK: Fare

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let sel = selection?.standardized, sel.contains(p) {
            // Seçim içinde: işaret çiz
            dragStart = p
            switch tool {
            case .rect: live = .rect(CGRect(origin: p, size: .zero))
            case .arrow: live = .arrow(p, p)
            case .pen: live = .pen([p])
            }
        } else {
            // Yeni seçim
            selection = CGRect(origin: p, size: .zero)
            marks = []
            selecting = true
            dragStart = p
            toolbar.isHidden = true
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let s = dragStart else { return }
        if selecting {
            selection = CGRect(x: s.x, y: s.y, width: p.x - s.x, height: p.y - s.y)
            if let sel = selection?.standardized { updateSizeLabel(sel) }
        } else if let l = live {
            switch l {
            case .rect: live = .rect(CGRect(x: s.x, y: s.y, width: p.x - s.x, height: p.y - s.y))
            case .arrow: live = .arrow(s, p)
            case .pen(var pts): pts.append(p); live = .pen(pts)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if selecting {
            selecting = false
            if let sel = selection?.standardized, sel.width < 4 || sel.height < 4 { selection = nil }
            else { selection = selection?.standardized }
        } else if let l = live {
            marks.append(l)
            live = nil
        }
        dragStart = nil
        layoutChrome()
        needsDisplay = true
    }

    // MARK: Klavye

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        switch (e.keyCode, cmd) {
        case (53, _): cancel()                                   // Esc
        case (36, _), (76, _): copyAndClose()                    // Enter
        case (8, true): copyAndClose()                           // ⌘C
        case (1, true): saveAndClose()                           // ⌘S
        case (6, true): undo()                                   // ⌘Z
        case (18, false): tools.selectedSegment = 0; toolChanged() // 1
        case (19, false): tools.selectedSegment = 1; toolChanged() // 2
        case (20, false): tools.selectedSegment = 2; toolChanged() // 3
        default: break
        }
    }

    @objc private func toolChanged() { tool = Tool(rawValue: tools.selectedSegment) ?? .rect }
    @objc private func undo() { _ = marks.popLast(); needsDisplay = true }
    @objc private func cancel() { onDone?() }

    // MARK: Çıktı

    /// Seçili alanı işaretlerle birlikte, ekranın gerçek piksel çözünürlüğünde üretir.
    func render() -> CGImage? {
        guard let sel = selection?.standardized else { return nil }
        let px = CGRect(x: sel.minX * scale, y: sel.minY * scale, width: sel.width * scale, height: sel.height * scale).integral
        guard let crop = image.cropping(to: px),
              let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: px.width, height: px.height))
        // Görünüm (üst-sol, nokta) → çıktı (alt-sol, piksel)
        ctx.translateBy(x: 0, y: px.height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        ctx.clip(to: sel)
        for m in marks { m.draw(in: ctx) }
        return ctx.makeImage()
    }

    private func pngData() -> Data? {
        guard let img = render() else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        rep.size = NSSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    @objc func copyAndClose() {
        guard let img = render() else { cancel(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let ns = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
        pb.writeObjects([ns])
        if let png = pngData() { pb.setData(png, forType: .png) }
        onDone?()
    }

    @objc func saveAndClose() {
        guard let png = pngData() else { cancel(); return }
        let done = onDone
        onDone = nil
        window?.orderOut(nil)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = L.t("Screenshot", "Ekran Görüntüsü") + " \(df.string(from: Date())).png"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { resp in
            if resp == .OK, let url = panel.url { try? png.write(to: url) }
            done?()
        }
    }
}

extension NSBox {
    static func separatorBox() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 1).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }
}

// MARK: - Yakalama akışı

final class ScreenshotTool {
    private var window: ShotWindow?
    private var previousApp: NSRunningApplication?

    var isActive: Bool { window != nil }

    /// Fare hangi ekrandaysa onu dondurur ve seçim kaplamasını açar.
    func start() {
        guard window == nil, Permissions.screenRecording else {
            if !Permissions.screenRecording { Permissions.openScreenRecording() }
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            guard let display = content?.displays.first(where: { $0.displayID == displayID }) else { return }
            let scale = screen.backingScaleFactor
            let cfg = SCStreamConfiguration()
            cfg.width = Int(screen.frame.width * scale)
            cfg.height = Int(screen.frame.height * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: [])
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in
                guard let img else { return }
                DispatchQueue.main.async { self?.present(img, scale: scale, on: screen) }
            }
        }
    }

    private func present(_ img: CGImage, scale: CGFloat, on screen: NSScreen) {
        let w = ShotWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.acceptsMouseMovedEvents = true
        let view = ShotView(image: img, scale: scale, frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onDone = { [weak self] in self?.finish() }
        w.contentView = view
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        NSCursor.crosshair.push()
    }

    private func finish() {
        NSCursor.pop()
        window?.orderOut(nil)
        window = nil
        // Odağı önceki uygulamaya geri ver (⌘V hemen çalışsın)
        previousApp?.activate(options: [])
        previousApp = nil
    }
}
