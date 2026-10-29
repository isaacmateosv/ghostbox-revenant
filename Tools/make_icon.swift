// Draws the app icon (dark tile with a neon ghost: cyan outline, green LED eyes, waveform hem) as a 1024px PNG.
// The ghost uses the same outline as the panel's brand mark (Sources/UI/index.html, 32-unit grid).
// Usage: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let cyan = NSColor(calibratedRed: 0.282, green: 0.882, blue: 1, alpha: 1)
let green = NSColor(calibratedRed: 0.373, green: 0.82, blue: 0.247, alpha: 1)

// Tile: macOS icon grid leaves ~10% margin around a rounded square
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor(calibratedRed: 0.07, green: 0.075, blue: 0.09, alpha: 1).setFill()
tilePath.fill()
ctx.restoreGState()
NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.18, alpha: 1),
           ending: NSColor(calibratedRed: 0.035, green: 0.04, blue: 0.05, alpha: 1))!.draw(in: tilePath, angle: -90)

// Inside the tile: a cyan glow behind the ghost and faint scan lines
ctx.saveGState()
tilePath.addClip()
NSGradient(starting: cyan.withAlphaComponent(0.2), ending: cyan.withAlphaComponent(0))!
    .draw(fromCenter: NSPoint(x: 512, y: 540), radius: 0, toCenter: NSPoint(x: 512, y: 540), radius: 400, options: [])
NSColor(calibratedWhite: 1, alpha: 0.03).setFill()
for y in stride(from: tile.minY + 12, to: tile.maxY, by: 24) { NSBezierPath(rect: NSRect(x: tile.minX, y: y, width: tile.width, height: 4)).fill() }
ctx.restoreGState()
NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
tilePath.lineWidth = 6
tilePath.stroke()

// Ghost: 32-unit SVG grid (y down) mapped onto the tile, 22 px per unit, centred
func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 512 + (x - 16) * 22, y: 512 - (y - 16.5) * 22) }
let ghost = NSBezierPath()
ghost.move(to: p(6, 28))
ghost.line(to: p(6, 15))
ghost.appendArc(withCenter: p(16, 15), radius: 220, startAngle: 180, endAngle: 0, clockwise: true)
for (x, y) in [(26, 28), (22.67, 25.5), (19.33, 28), (16, 25.5), (12.67, 28), (9.33, 25.5)] as [(CGFloat, CGFloat)] {
    ghost.line(to: p(x, y))
}
ghost.close()
ghost.lineJoinStyle = .round
ghost.lineWidth = 30

NSGradient(starting: cyan.withAlphaComponent(0.32), ending: cyan.withAlphaComponent(0.04))!.draw(in: ghost, angle: -90)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 44, color: cyan.withAlphaComponent(0.85).cgColor)
cyan.setStroke()
ghost.stroke()
ctx.restoreGState()

// Eyes: green LEDs with a glow and a small highlight
for x: CGFloat in [12.5, 19.5] {
    let c = p(x, 15)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36, color: green.cgColor)
    green.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 46, y: c.y - 46, width: 92, height: 92)).fill()
    ctx.restoreGState()
    NSColor(calibratedWhite: 1, alpha: 0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 22, y: c.y + 8, width: 22, height: 22)).fill()
}
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
