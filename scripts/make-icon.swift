// App icon: 1024×1024 PNG, a tmux window (split panes, green status bar) with a Claude-orange `❯` prompt.
//
//   swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// Core Graphics and Core Text only, runs on macOS without extra tools.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift OUTPUT.png\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

let size = 1024
let side = CGFloat(size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    // the App Store icon has no alpha channel
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("no bitmap context")
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

// background: diagonal gradient, deep indigo to near-black
let gradient = CGGradient(
    colorsSpace: space, colors: [color(0x3A2F7A), color(0x10122A)] as CFArray, locations: [0, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])

// tmux window: a dark rounded card with a green status bar at the bottom
let card = CGRect(x: 140, y: 170, width: side - 280, height: side - 340)
let cardPath = CGPath(roundedRect: card, cornerWidth: 72, cornerHeight: 72, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: color(0x000000, alpha: 0.45))
ctx.setFillColor(color(0x0D1117))
ctx.addPath(cardPath)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(cardPath)
ctx.clip()
let status = CGRect(x: card.minX, y: card.minY, width: card.width, height: 84)
ctx.setFillColor(color(0x3FB950))
ctx.fill(status)
// window tabs on the status bar
ctx.setFillColor(color(0x0D1117, alpha: 0.75))
for (index, width) in [CGFloat(120), 84, 84].enumerated() {
    let x = card.minX + 56 + CGFloat(index) * 150
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: status.midY - 13, width: width, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
}
ctx.fillPath()
ctx.restoreGState()

// panes: a vertical split, the right pane split again
let panes = CGRect(x: card.minX, y: status.maxY, width: card.width, height: card.maxY - status.maxY)
let divider = panes.minX + panes.width * 0.62
ctx.setStrokeColor(color(0x30384F))
ctx.setLineWidth(8)
ctx.move(to: CGPoint(x: divider, y: panes.minY))
ctx.addLine(to: CGPoint(x: divider, y: panes.maxY))
ctx.move(to: CGPoint(x: divider, y: panes.midY))
ctx.addLine(to: CGPoint(x: panes.maxX, y: panes.midY))
ctx.strokePath()

// right panes: a few lines of output
ctx.setFillColor(color(0x5B6787, alpha: 0.8))
for (row, width) in [CGFloat(150), 110, 170].enumerated() {
    let y = panes.maxY - 100 - CGFloat(row) * 52
    ctx.addPath(CGPath(roundedRect: CGRect(x: divider + 44, y: y, width: width, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil))
}
for (row, width) in [CGFloat(130), 180].enumerated() {
    let y = panes.midY - 92 - CGFloat(row) * 52
    ctx.addPath(CGPath(roundedRect: CGRect(x: divider + 44, y: y, width: width, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil))
}
ctx.fillPath()

// left pane: the prompt `❯` in Claude orange and a block cursor
func draw(_ text: String, font: CTFont, color fill: CGColor, at point: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}
let font = CTFontCreateWithName("Menlo-Bold" as CFString, 300, nil)
let baseline = panes.midY - 100
draw("❯", font: font, color: color(0xE07B53), at: CGPoint(x: panes.minX + 64, y: baseline))
ctx.setFillColor(color(0xE6EAF2))
ctx.fill(CGRect(x: panes.minX + 300, y: baseline - 10, width: 96, height: 190))

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    fatalError("cannot create \(output.path)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("cannot write \(output.path)")
}
print("wrote \(output.path)")
