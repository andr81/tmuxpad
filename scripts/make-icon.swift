// App icon: 1024×1024 PNG, dark background, monospaced `❯_` glyph and a thin split frame.
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

// background: vertical gradient, near-black blue
let gradient = CGGradient(
    colorsSpace: space, colors: [color(0x1B2130), color(0x0B0E14)] as CFArray, locations: [0, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 0), options: [])

// split frame: a rounded pane outline and a vertical divider on the right third
let inset: CGFloat = 120
let frame = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
ctx.setStrokeColor(color(0x5B6B8C, alpha: 0.55))
ctx.setLineWidth(10)
ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 56, cornerHeight: 56, transform: nil))
ctx.strokePath()
let divider = frame.minX + frame.width * 0.68
ctx.move(to: CGPoint(x: divider, y: frame.minY))
ctx.addLine(to: CGPoint(x: divider, y: frame.maxY))
ctx.strokePath()

// glyph `❯_` in the left pane
func draw(_ text: String, font: CTFont, color fill: CGColor, at point: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}
let font = CTFontCreateWithName("Menlo-Bold" as CFString, 330, nil)
let baseline = side / 2 - 110
draw("❯", font: font, color: color(0x7DD3A0), at: CGPoint(x: frame.minX + 60, y: baseline))
draw("_", font: font, color: color(0xE6EAF2), at: CGPoint(x: frame.minX + 290, y: baseline))

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
