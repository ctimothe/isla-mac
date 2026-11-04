// Draws the disk image's window background: the landing page's field of
// thin white lines, two hairlines, and an arrow from the app to the
// Applications folder. Run it once and commit the PNG; the build never
// compiles this. 660 x 400 points at 2x, tagged 144 dpi so Finder shows it
// sharp on a Retina display and at the right size.
//
//   swift Scripts/dmg-background.swift Resources/dmg/background.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let w = 660, h = 400, scale = 2
let image = NSImage(size: NSSize(width: w, height: h))
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

// The lines: vertical, 8 pt apart, bent by two slow sines so they read as the
// site's waves at rest. Faint, so the icons and the arrow stay the subject.
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.34))
ctx.setLineWidth(0.6)
var x = -20.0
while x < Double(w) + 20 {
    let path = CGMutablePath()
    var y = -10.0
    var first = true
    while y <= Double(h) + 10 {
        let bend = sin((y + x * 0.9) * 0.012) * 9 + sin((y * 0.004 + x * 0.02)) * 14
        let p = CGPoint(x: x + bend, y: y)
        if first { path.move(to: p); first = false } else { path.addLine(to: p) }
        y += 4
    }
    ctx.addPath(path)
    ctx.strokePath()
    x += 8
}

// A quiet pool behind the two icons and the arrow so they sit on near-black:
// opaque at the centre, gone by the edges, drawn over the whole canvas so
// nothing clips to a disc.
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                          colors: [CGColor(gray: 0, alpha: 0.96), CGColor(gray: 0, alpha: 0.85), CGColor(gray: 0, alpha: 0)] as CFArray,
                          locations: [0, 0.45, 1])!
let centre = CGPoint(x: 330, y: 215)
ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                       endCenter: centre, endRadius: 330,
                       options: [.drawsBeforeStartLocation])

// The hairlines, as on the site.
ctx.setFillColor(CGColor(gray: 1, alpha: 0.8))
ctx.fill(CGRect(x: 0, y: Double(h) - 1, width: Double(w), height: 1))
ctx.fill(CGRect(x: 0, y: 0, width: Double(w), height: 1))

// Three arrows from the app to the folder: one straight through the middle,
// one arcing over, one arcing under. Finder draws a still picture and nothing
// else, so the sense of movement comes from the three paths converging.
// Icons sit at x 165 and 495 (centres, 128 pt), so the arrows run between
// the app's right edge and the folder's left edge.
let x0 = 250.0, x1 = 410.0, mid = 210.0
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
ctx.setLineWidth(1.8)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
func head(at tip: CGPoint, from dir: CGPoint) {
    let len = hypot(dir.x, dir.y)
    let ux = dir.x / len, uy = dir.y / len
    let size = 11.0, spread = 0.55
    let l = CGPoint(x: tip.x - size * (ux * cos(spread) - uy * sin(spread)), y: tip.y - size * (uy * cos(spread) + ux * sin(spread)))
    let r = CGPoint(x: tip.x - size * (ux * cos(spread) + uy * sin(spread)), y: tip.y - size * (uy * cos(spread) - ux * sin(spread)))
    ctx.move(to: l); ctx.addLine(to: tip); ctx.addLine(to: r)
    ctx.strokePath()
}
// Middle, straight.
ctx.move(to: CGPoint(x: x0, y: mid)); ctx.addLine(to: CGPoint(x: x1, y: mid)); ctx.strokePath()
head(at: CGPoint(x: x1, y: mid), from: CGPoint(x: 1, y: 0))
// Over and under: quadratic arcs whose heads follow the curve's tangent,
// which for a quadratic is the line from the control point to the end.
for sign in [1.0, -1.0] {
    let start = CGPoint(x: x0, y: mid + 28 * sign)
    let control = CGPoint(x: (x0 + x1) / 2, y: mid + 88 * sign)
    let end = CGPoint(x: x1, y: mid + 28 * sign)
    ctx.move(to: start); ctx.addQuadCurve(to: end, control: control); ctx.strokePath()
    head(at: end, from: CGPoint(x: end.x - control.x, y: end.y - control.y))
}

// The one line of copy.
let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(white: 1, alpha: 0.7),
    .paragraphStyle: paragraph,
]
NSAttributedString(string: "Drag Isla to Applications", attributes: attrs)
    .draw(in: CGRect(x: 0, y: 70, width: Double(w), height: 20))

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) \(w * scale)x\(h * scale)")
