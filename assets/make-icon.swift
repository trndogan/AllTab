import AppKit
// AllTab simgesi: koyu lacivert→mor zemin, üst üste bindirilmiş üç pencere kartı, öndeki beyaz ve vurgulu,
// sağ altta turuncu "⇥" rozeti. 1024x1024 PNG üretir.
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// Zemin
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S), xRadius: S * 0.2237, yRadius: S * 0.2237)
NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.47, alpha: 1),
                    NSColor(calibratedRed: 0.38, green: 0.22, blue: 0.78, alpha: 1)])!.draw(in: bg, angle: -65)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!.draw(in: bg, angle: -90)
// İnce iç kenar parlaması
ctx.saveGState(); bg.addClip()
NSColor.white.withAlphaComponent(0.18).setStroke()
let inner = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S).insetBy(dx: 2, dy: 2), xRadius: S * 0.22, yRadius: S * 0.22)
inner.lineWidth = 4; inner.stroke()
ctx.restoreGState()

func card(_ r: NSRect, fill: NSColor, bar: NSColor, alpha: CGFloat, lights: Bool, shadow: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -shadow * 0.5), blur: shadow, color: NSColor.black.withAlphaComponent(0.38).cgColor)
    let p = NSBezierPath(roundedRect: r, xRadius: S * 0.04, yRadius: S * 0.04)
    fill.withAlphaComponent(alpha).setFill(); p.fill()
    ctx.restoreGState()
    // Başlık çubuğu
    ctx.saveGState()
    NSBezierPath(roundedRect: r, xRadius: S * 0.04, yRadius: S * 0.04).addClip()
    let barH = r.height * 0.2
    bar.withAlphaComponent(alpha).setFill()
    NSBezierPath(rect: NSRect(x: r.minX, y: r.maxY - barH, width: r.width, height: barH)).fill()
    if lights {
        let d = barH * 0.42, y = r.maxY - barH / 2 - d / 2
        for (i, c) in [NSColor(calibratedRed: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(calibratedRed: 1, green: 0.74, blue: 0.18, alpha: 1), NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.35, alpha: 1)].enumerated() {
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + barH * 0.55 + CGFloat(i) * d * 1.6, y: y, width: d, height: d)).fill()
        }
        // İçerik çizgileri
        NSColor(calibratedWhite: 0.80, alpha: 1).setFill()
        let lx = r.minX + r.width * 0.12, lw = r.width * 0.76, lh = r.height * 0.07
        for i in 0..<3 {
            let w = lw * [1.0, 0.72, 0.5][i]
            NSBezierPath(roundedRect: NSRect(x: lx, y: r.maxY - barH - r.height * 0.22 - CGFloat(i) * lh * 2.3, width: w, height: lh), xRadius: lh / 2, yRadius: lh / 2).fill()
        }
    }
    ctx.restoreGState()
}
// Arkadaki iki kart (soluk, geride)
let w = S * 0.54, h = S * 0.40
card(NSRect(x: S * 0.33, y: S * 0.40, width: w, height: h), fill: .white, bar: NSColor(calibratedWhite: 0.9, alpha: 1), alpha: 0.28, lights: false, shadow: S * 0.02)
card(NSRect(x: S * 0.245, y: S * 0.33, width: w, height: h), fill: .white, bar: NSColor(calibratedWhite: 0.9, alpha: 1), alpha: 0.5, lights: false, shadow: S * 0.025)
// Öndeki kart (seçili)
let front = NSRect(x: S * 0.16, y: S * 0.25, width: w, height: h)
card(front, fill: .white, bar: NSColor(calibratedWhite: 0.93, alpha: 1), alpha: 1, lights: true, shadow: S * 0.04)
// Seçim çerçevesi
let ring = NSBezierPath(roundedRect: front.insetBy(dx: -S * 0.022, dy: -S * 0.022), xRadius: S * 0.055, yRadius: S * 0.055)
ring.lineWidth = S * 0.016
NSColor.white.withAlphaComponent(0.95).setStroke(); ring.stroke()
// ⇥ rozeti
let bd = S * 0.26
let badge = NSRect(x: S * 0.63, y: S * 0.13, width: bd, height: bd)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.035, color: NSColor.black.withAlphaComponent(0.4).cgColor)
NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.62, blue: 0.2, alpha: 1), NSColor(calibratedRed: 1, green: 0.42, blue: 0.25, alpha: 1)])!.draw(in: NSBezierPath(ovalIn: badge), angle: -70)
ctx.restoreGState()
let para = NSMutableParagraphStyle(); para.alignment = .center
let glyph = NSAttributedString(string: "⇥", attributes: [.font: NSFont.systemFont(ofSize: bd * 0.62, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: para])
let gs = glyph.size()
glyph.draw(in: NSRect(x: badge.minX, y: badge.midY - gs.height / 2 + bd * 0.02, width: bd, height: gs.height))
img.unlockFocus()
let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("icon_1024.png yazildi")
