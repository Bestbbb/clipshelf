// Renders the ClipShelf app icon at every macOS icon size and packs AppIcon.icns.
// Usage: swift scripts/make-app-icon.swift <output.icns> [preview.png]
// Pure vector drawing: each size is rendered natively, so small sizes stay crisp.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-app-icon.swift <output.icns> [preview.png]\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let preview = arguments.count >= 3 ? URL(fileURLWithPath: arguments[2]) : nil

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws in a 1024-point design space scaled to `pixels`.
func render(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(pixels) / 1024
    context.scaleBy(x: s, y: s)
    context.interpolationQuality = .high
    let small = pixels <= 32
    // CGContext shadows ignore the CTM, so scale their geometry explicitly.
    func shadow(_ dy: CGFloat, _ blur: CGFloat, _ shadowColor: CGColor) {
        context.setShadow(offset: CGSize(width: 0, height: dy * s), blur: blur * s, color: shadowColor)
    }
    // Lift the shelf group so the composition sits on the optical centre.
    let lift: CGFloat = 44

    // Squircle body on the macOS 824-point icon grid.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    shadow(-10, 24, color(0x000000, 0.32))
    context.addPath(bodyPath); context.setFillColor(color(0x2B2F7E)); context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath); context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(0x5C6BF0), color(0x3A3FB0), color(0x23266B)] as CFArray,
                              locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft highlight across the upper half.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 860), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 860), endRadius: 520, options: [])
    context.restoreGState()

    // The shelf the cards stand on.
    let shelf = CGRect(x: 196, y: 262 + lift, width: 632, height: small ? 40 : 30)
    context.saveGState()
    shadow(0, 30, color(0x8EA2FF, 0.55))
    context.addPath(CGPath(roundedRect: shelf, cornerWidth: shelf.height / 2, cornerHeight: shelf.height / 2, transform: nil))
    context.setFillColor(color(0xDDE3FF, 0.9)); context.fillPath()
    context.restoreGState()

    struct Card { let rect: CGRect; let header: UInt32; let lines: Int; let selected: Bool }
    let cards = [
        Card(rect: CGRect(x: 214, y: 318 + lift, width: 186, height: 262), header: 0xE58A2B, lines: 2, selected: false),
        Card(rect: CGRect(x: 624, y: 318 + lift, width: 186, height: 262), header: 0x16A193, lines: 2, selected: false),
        Card(rect: CGRect(x: 398, y: 336 + lift, width: 228, height: 318), header: 0x3D7BEA, lines: 3, selected: true),
    ]
    for card in cards {
        let radius: CGFloat = card.selected ? 38 : 32
        let path = CGPath(roundedRect: card.rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        shadow(-10, 22, color(0x0B0D33, 0.45))
        context.addPath(path); context.setFillColor(color(0xF6F7FC)); context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path); context.clip()
        let headerHeight = card.rect.height * 0.27
        context.setFillColor(color(card.header))
        context.fill(CGRect(x: card.rect.minX, y: card.rect.maxY - headerHeight, width: card.rect.width, height: headerHeight))
        if !small {
            // Text lines; the last line is shorter, like a wrapped paragraph.
            let lineHeight: CGFloat = card.selected ? 22 : 20
            let inset: CGFloat = card.selected ? 30 : 26
            var y = card.rect.maxY - headerHeight - inset - lineHeight
            for index in 0..<card.lines {
                let width = (card.rect.width - inset * 2) * (index == card.lines - 1 ? 0.62 : 1)
                context.addPath(CGPath(roundedRect: CGRect(x: card.rect.minX + inset, y: y, width: width, height: lineHeight),
                                       cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
                context.setFillColor(color(0xC7CCDD)); context.fillPath()
                y -= lineHeight + 18
            }
        }
        context.restoreGState()

        if card.selected {
            let ring = card.rect.insetBy(dx: -12, dy: -12)
            context.addPath(CGPath(roundedRect: ring, cornerWidth: radius + 12, cornerHeight: radius + 12, transform: nil))
            context.setStrokeColor(color(0xA9B8FF, 0.95)); context.setLineWidth(small ? 16 : 10); context.strokePath()
        }
    }
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appendingPathComponent("ClipShelf-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try writePNG(render(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(render(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
if let preview { try writePNG(render(pixels: 1024), to: preview) }
print("Wrote \(output.path)")
