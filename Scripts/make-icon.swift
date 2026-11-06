// Draws the app icon: three graph lanes with commit dots on a dark rounded square.
// Usage: swift Scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
           ending: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.15, alpha: 1))!.draw(in: bg, angle: -90)

let blue = NSColor(srgbRed: 0.27, green: 0.60, blue: 0.96, alpha: 1)
let pink = NSColor(srgbRed: 0.90, green: 0.42, blue: 0.62, alpha: 1)
let green = NSColor(srgbRed: 0.36, green: 0.72, blue: 0.42, alpha: 1)
let x0: CGFloat = 370, x1: CGFloat = 512, x2: CGFloat = 654
let top: CGFloat = 790, bottom: CGFloat = 234
let width: CGFloat = 44

func line(_ points: [NSPoint], _ color: NSColor) {
    let p = NSBezierPath()
    p.lineWidth = width
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.move(to: points[0])
    for pt in points.dropFirst() { p.line(to: pt) }
    color.setStroke()
    p.stroke()
}

func curve(from a: NSPoint, to b: NSPoint, _ color: NSColor) {
    let p = NSBezierPath()
    p.lineWidth = width
    p.lineCapStyle = .round
    p.move(to: a)
    p.curve(to: b, controlPoint1: NSPoint(x: a.x, y: (a.y + b.y) / 2), controlPoint2: NSPoint(x: b.x, y: (a.y + b.y) / 2))
    color.setStroke()
    p.stroke()
}

line([NSPoint(x: x0, y: bottom), NSPoint(x: x0, y: top)], blue)
curve(from: NSPoint(x: x0, y: 330), to: NSPoint(x: x1, y: 470), pink)
line([NSPoint(x: x1, y: 470), NSPoint(x: x1, y: 600)], pink)
curve(from: NSPoint(x: x1, y: 600), to: NSPoint(x: x0, y: 720), pink)
curve(from: NSPoint(x: x0, y: 420), to: NSPoint(x: x2, y: 560), green)
line([NSPoint(x: x2, y: 560), NSPoint(x: x2, y: 690)], green)

func dot(_ x: CGFloat, _ y: CGFloat, _ color: NSColor) {
    let r: CGFloat = 46
    let path = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    color.setFill()
    path.fill()
    NSColor(srgbRed: 0.12, green: 0.13, blue: 0.18, alpha: 1).setStroke()
    path.lineWidth = 14
    path.stroke()
}
dot(x0, 260, blue); dot(x0, 760, blue)
dot(x1, 535, pink)
dot(x2, 690, green)

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
