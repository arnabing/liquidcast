import AppKit
import CoreGraphics

let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locations)! }

// macOS icon grid: 824pt body centred in 1024, continuous-corner radius ~185
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the body
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(squircle); ctx.setFillColor(color(0.1, 0.1, 0.2)); ctx.fillPath()
ctx.restoreGState()

// Background: deep violet → teal
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
ctx.drawLinearGradient(gradient([color(0.16, 0.10, 0.42), color(0.10, 0.28, 0.62), color(0.02, 0.55, 0.66)], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Soft glow top-left
ctx.drawRadialGradient(gradient([color(1, 1, 1, 0.22), color(1, 1, 1, 0)], [0, 1]),
                       startCenter: CGPoint(x: 330, y: 800), startRadius: 0, endCenter: CGPoint(x: 330, y: 800), endRadius: 520, options: [])
ctx.restoreGState()

// TV screen
let screen = CGRect(x: 232, y: 372, width: 560, height: 380)
let screenPath = CGPath(roundedRect: screen, cornerWidth: 64, cornerHeight: 64, transform: nil)
ctx.saveGState()
ctx.addPath(screenPath); ctx.setFillColor(color(0.03, 0.05, 0.16, 0.55)); ctx.fillPath()
ctx.restoreGState()

// Liquid wave inside the screen
ctx.saveGState()
ctx.addPath(screenPath); ctx.clip()
let wave = CGMutablePath()
wave.move(to: CGPoint(x: screen.minX - 10, y: screen.minY - 10))
wave.addLine(to: CGPoint(x: screen.minX - 10, y: 560))
wave.addCurve(to: CGPoint(x: 512, y: 560), control1: CGPoint(x: 300, y: 650), control2: CGPoint(x: 420, y: 650))
wave.addCurve(to: CGPoint(x: screen.maxX + 10, y: 575), control1: CGPoint(x: 600, y: 470), control2: CGPoint(x: 720, y: 480))
wave.addLine(to: CGPoint(x: screen.maxX + 10, y: screen.minY - 10))
wave.closeSubpath()
ctx.addPath(wave); ctx.clip()
ctx.drawLinearGradient(gradient([color(0.35, 0.95, 1.0), color(0.10, 0.55, 1.0)], [0, 1]),
                       start: CGPoint(x: 512, y: 640), end: CGPoint(x: 512, y: 372), options: [])
ctx.restoreGState()
// Highlight on the wave crest
ctx.saveGState()
ctx.addPath(screenPath); ctx.clip()
let crest = CGMutablePath()
crest.move(to: CGPoint(x: screen.minX, y: 560))
crest.addCurve(to: CGPoint(x: 512, y: 560), control1: CGPoint(x: 300, y: 650), control2: CGPoint(x: 420, y: 650))
crest.addCurve(to: CGPoint(x: screen.maxX, y: 575), control1: CGPoint(x: 600, y: 470), control2: CGPoint(x: 720, y: 480))
ctx.addPath(crest); ctx.setStrokeColor(color(1, 1, 1, 0.75)); ctx.setLineWidth(10); ctx.setLineCap(.round); ctx.strokePath()
ctx.restoreGState()

// Screen frame
ctx.addPath(screenPath); ctx.setStrokeColor(color(1, 1, 1, 0.95)); ctx.setLineWidth(34); ctx.strokePath()

// AirPlay triangle breaking the bottom of the frame
let tri = CGMutablePath()
tri.move(to: CGPoint(x: 512, y: 420))
tri.addLine(to: CGPoint(x: 630, y: 262))
tri.addLine(to: CGPoint(x: 394, y: 262))
tri.closeSubpath()
// Gap in the frame around the triangle
ctx.saveGState()
ctx.setBlendMode(.normal)
let gap = CGMutablePath()
gap.move(to: CGPoint(x: 512, y: 470)); gap.addLine(to: CGPoint(x: 680, y: 240)); gap.addLine(to: CGPoint(x: 344, y: 240)); gap.closeSubpath()
ctx.addPath(squircle); ctx.clip()
ctx.addPath(gap); ctx.clip()
ctx.drawLinearGradient(gradient([color(0.16, 0.10, 0.42), color(0.10, 0.28, 0.62), color(0.02, 0.55, 0.66)], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()
let triRounded = CGPath(roundedRect: .zero, cornerWidth: 0, cornerHeight: 0, transform: nil)
_ = triRounded
ctx.addPath(tri); ctx.setFillColor(color(1, 1, 1, 0.95)); ctx.setLineJoin(.round); ctx.setLineWidth(22)
ctx.setStrokeColor(color(1, 1, 1, 0.95)); ctx.drawPath(using: .fillStroke)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")
