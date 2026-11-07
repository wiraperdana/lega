// Menggambar ikon aplikasi jadi Resources/AppIcon.icns.
// Bentuknya: squircle hijau toska, cincin storage putih yang sebagian terisi,
// dan kilau empat sudut di tengah sebagai tanda "bersih".
// Jalankan: swift Scripts/make-icon.swift

import AppKit

func draw(size s: CGFloat) -> Data {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle dengan margin standar ikon macOS (sekitar 10% tiap sisi)
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                  color: NSColor(white: 0, alpha: 0.3).cgColor)
    NSColor(red: 0.04, green: 0.42, blue: 0.40, alpha: 1).setFill()
    shape.fill()
    ctx.restoreGState()

    shape.addClip()
    let grad = NSGradient(colors: [
        NSColor(red: 0.13, green: 0.78, blue: 0.62, alpha: 1),
        NSColor(red: 0.03, green: 0.40, blue: 0.42, alpha: 1),
    ])!
    grad.draw(in: rect, angle: -70)

    // Cincin storage
    let c = CGPoint(x: s / 2, y: s / 2)
    let r = rect.width * 0.31
    let lw = rect.width * 0.075
    ctx.setLineCap(.round)
    ctx.setLineWidth(lw)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.25).cgColor)
    ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.4, clockwise: true)
    ctx.strokePath()

    // Kilau empat sudut
    let k = rect.width * 0.15
    let w = k * 0.28
    let star = NSBezierPath()
    star.move(to: CGPoint(x: c.x, y: c.y + k))
    star.curve(to: CGPoint(x: c.x + k, y: c.y), controlPoint1: CGPoint(x: c.x + w * 0.3, y: c.y + w), controlPoint2: CGPoint(x: c.x + w, y: c.y + w * 0.3))
    star.curve(to: CGPoint(x: c.x, y: c.y - k), controlPoint1: CGPoint(x: c.x + w, y: c.y - w * 0.3), controlPoint2: CGPoint(x: c.x + w * 0.3, y: c.y - w))
    star.curve(to: CGPoint(x: c.x - k, y: c.y), controlPoint1: CGPoint(x: c.x - w * 0.3, y: c.y - w), controlPoint2: CGPoint(x: c.x - w, y: c.y - w * 0.3))
    star.curve(to: CGPoint(x: c.x, y: c.y + k), controlPoint1: CGPoint(x: c.x - w, y: c.y + w * 0.3), controlPoint2: CGPoint(x: c.x - w * 0.3, y: c.y + w))
    NSColor.white.setFill()
    star.fill()

    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        // Gambar di 1x piksel: NSImage memakai titik, jadi bagi dengan skala layar
        let data = draw(size: px / (NSScreen.main?.backingScaleFactor ?? 1))
        try! data.write(to: set.appendingPathComponent(name))
    }
}
try! fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print("Resources/AppIcon.icns")
