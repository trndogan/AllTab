import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// Arka plan: yuvarlak kare, koyu mavi -> mor gradyan
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: size * 0.225, yRadius: size * 0.225)
let grad = NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.37, blue: 0.95, alpha: 1),
                               NSColor(calibratedRed: 0.42, green: 0.18, blue: 0.85, alpha: 1)])!
grad.draw(in: bg, angle: -60)
// Hafif ust parlama
let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
glow.draw(in: bg, angle: -90)
// 2x2 pencere karolari (Alt+Tab izgarasi)
let pad: CGFloat = size * 0.17, gap: CGFloat = size * 0.06
let tile = (size - 2 * pad - gap) / 2
func tileRect(_ c: Int, _ r: Int) -> NSRect {
    NSRect(x: pad + CGFloat(c) * (tile + gap), y: pad + CGFloat(1 - r) * (tile + gap), width: tile, height: tile * 0.78)
}
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
for r in 0..<2 { for c in 0..<2 {
    let rect = tileRect(c, r).offsetBy(dx: 0, dy: (r == 0 ? -tile * 0.11 : tile * 0.11))
    let selected = (c == 0 && r == 0)
    let p = NSBezierPath(roundedRect: rect, xRadius: size * 0.035, yRadius: size * 0.035)
    (selected ? NSColor.white : NSColor.white.withAlphaComponent(0.45)).setFill()
    p.fill()
    // baslik cubugu
    let bar = NSRect(x: rect.minX, y: rect.maxY - rect.height * 0.2, width: rect.width, height: rect.height * 0.2)
    let bp = NSBezierPath(roundedRect: bar, xRadius: size * 0.035, yRadius: size * 0.035)
    (selected ? NSColor(calibratedWhite: 0.88, alpha: 1) : NSColor.white.withAlphaComponent(0.25)).setFill()
    bp.fill()
    if selected {
        // secili karoya cerceve
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let o = NSBezierPath(roundedRect: rect.insetBy(dx: -size * 0.018, dy: -size * 0.018), xRadius: size * 0.05, yRadius: size * 0.05)
        o.lineWidth = size * 0.018
        NSColor.white.setStroke(); o.stroke()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    }
}}
img.unlockFocus()
let tiff = img.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("icon_1024.png yazildi")
