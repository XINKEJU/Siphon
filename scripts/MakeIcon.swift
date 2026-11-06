// Siphon macOS application icon generator.
//
// Renders a single vector design at every resolution Apple requires, so 16px
// stays crisp instead of being downscaled from 1024px. Design follows the
// macOS Big Sur+ app icon guidelines:
//   * square, opaque, no baked-in corners -- the system applies the squircle
//   * no text, one dominant symbol inside the safe area (~20% inset)
//   * saturated gradient ground, white foreground, subtle top glass highlight
//   * soft drop shadow for depth; small sizes drop the fine detail
//
// Compile note: swiftc only allows top-level statements in a file named
// main.swift, so make-icon.sh copies this source to a temp main.swift.

import AppKit
import CoreGraphics

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    FileHandle.standardError.write("usage: makeicon <project-root>\n".data(using: .utf8)!)
    exit(2)
}

let root = URL(fileURLWithPath: argv[1])
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
let catalog = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
for dir in [iconset, catalog] {
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Draw the icon into `ctx`, in a `s` x `s` square with the origin at (0,0).
/// Design coordinates are 0...1 with y increasing downward; `Y` flips them.
func drawIcon(_ ctx: CGContext, _ s: CGFloat, detailed: Bool) {
    func X(_ v: CGFloat) -> CGFloat { v * s }
    func Y(_ v: CGFloat) -> CGFloat { (1 - v) * s }
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: X(x), y: Y(y)) }

    // Apple recommends simplifying an icon at small sizes rather than just
    // downscaling it: drop fine detail, remove the shadow, thicken strokes.
    let tiny = s < 64
    let cs = CGColorSpaceCreateDeviceRGB()

    // 1. Ground: diagonal cyan -> blue -> indigo.
    let ground = CGGradient(
        colorsSpace: cs,
        colors: [rgba(76, 201, 245), rgba(47, 107, 255), rgba(75, 39, 201)] as CFArray,
        locations: [0, 0.48, 1])!
    ctx.drawLinearGradient(ground, start: P(0, 0), end: P(1, 1), options: [])

    if !tiny {
        // 2. Soft light source in the upper left.
        let glow = CGGradient(
            colorsSpace: cs,
            colors: [rgba(255, 255, 255, 0.22), rgba(255, 255, 255, 0)] as CFArray,
            locations: [0, 1])!
        ctx.drawRadialGradient(glow,
                               startCenter: P(0.24, 0.10), startRadius: 0,
                               endCenter: P(0.24, 0.10), endRadius: s * 0.82,
                               options: [])
    }

    if detailed {
        // 3. Glass highlight along the top edge.
        let glass = CGGradient(
            colorsSpace: cs,
            colors: [rgba(255, 255, 255, 0.18), rgba(255, 255, 255, 0)] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(glass, start: P(0.5, 0), end: P(0.5, 0.50), options: [])

        // 4. Faint flow lines -- the "siphon" current, kept very low contrast
        //    so it never competes with the foreground symbol.
        ctx.saveGState()
        ctx.setStrokeColor(rgba(255, 255, 255, 0.075))
        ctx.setLineWidth(s * 0.072)
        ctx.setLineCap(.round)
        let flows: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-0.02, 0.34, 0.04, 0.12),
            (0.18, 0.56, 0.26, 0.36),
            (0.40, 0.78, 0.48, 0.60),
        ]
        for (y0, y1, c1, c2) in flows {
            let path = CGMutablePath()
            path.move(to: P(-0.10, y0))
            path.addCurve(to: P(1.10, y1), control1: P(0.30, c1), control2: P(0.70, c2))
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // 5. Foreground: one continuous rounded download glyph.
    //    Every part is a stroked path converted to a fill path, which keeps a
    //    uniform winding direction (no holes where the stem meets the wings).
    let glyph = CGMutablePath()
    let stroke = X(tiny ? 0.15 : 0.125)

    let stem = CGMutablePath()
    stem.move(to: P(0.5, 0.285))
    stem.addLine(to: P(0.5, 0.615))
    glyph.addPath(stem.copy(strokingWithWidth: stroke, lineCap: .round,
                            lineJoin: .round, miterLimit: 10))

    let wings = CGMutablePath()
    wings.move(to: P(0.305, 0.49))
    wings.addLine(to: P(0.5, 0.69))
    wings.addLine(to: P(0.695, 0.49))
    glyph.addPath(wings.copy(strokingWithWidth: stroke, lineCap: .round,
                             lineJoin: .round, miterLimit: 10))

    if !tiny {
        let tray = CGMutablePath()
        tray.move(to: P(0.31, 0.83))
        tray.addLine(to: P(0.69, 0.83))
        glyph.addPath(tray.copy(strokingWithWidth: X(0.10), lineCap: .round,
                                lineJoin: .round, miterLimit: 10))
    }

    // Shadow pass: filling the glyph once with a shadow produces a single,
    // clean silhouette shadow instead of three overlapping ones.
    ctx.saveGState()
    if !tiny {
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.016),
                      blur: s * (detailed ? 0.032 : 0.018),
                      color: rgba(12, 18, 70, 0.42))
    }
    ctx.setFillColor(rgba(255, 255, 255))
    ctx.addPath(glyph)
    ctx.fillPath()
    ctx.restoreGState()

    // Colour pass: a very slight vertical white -> ice-blue gradient.
    // Skipped at tiny sizes where pure white gives maximum contrast.
    if !tiny {
        ctx.saveGState()
        ctx.addPath(glyph)
        ctx.clip()
        let face = CGGradient(
            colorsSpace: cs,
            colors: [rgba(255, 255, 255), rgba(206, 226, 255)] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(face, start: P(0.5, 0.20), end: P(0.5, 0.90), options: [])
        ctx.restoreGState()
    }
}

func bitmap(_ side: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil,
                     pixelsWide: side, pixelsHigh: side,
                     bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!
}

func withContext(_ rep: NSBitmapImageRep, _ body: (CGContext) -> Void) {
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    body(gc.cgContext)
    NSGraphicsContext.restoreGraphicsState()
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url, options: .atomic)
}

func icon(_ side: Int) -> NSBitmapImageRep {
    let rep = bitmap(side)
    withContext(rep) { drawIcon($0, CGFloat(side), detailed: side >= 128) }
    return rep
}

/// Master artwork with no alpha channel at all (Apple submission requirement).
/// AppKit cannot create a graphics context for an alpha-less NSBitmapImageRep,
/// so this renders straight into a raw CGContext and wraps the resulting image.
func opaqueIcon(_ side: Int) -> NSBitmapImageRep {
    let ctx = CGContext(data: nil, width: side, height: side,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    drawIcon(ctx, CGFloat(side), detailed: true)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!)
}

// All ten macOS icon slots, each rendered at its native pixel size.
let slots: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, side) in slots {
    writePNG(icon(side), to: iconset.appendingPathComponent(name))
}

// Same PNGs, reusable as an Xcode asset catalog by anyone opening this in Xcode.
for (name, side) in slots {
    let src = iconset.appendingPathComponent(name)
    let dst = catalog.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: dst)
    try! FileManager.default.copyItem(at: src, to: dst)
    _ = side
}
let contents = """
{
  "images" : [
    { "size" : "16x16",  "idiom" : "mac", "scale" : "1x", "filename" : "icon_16x16.png" },
    { "size" : "16x16",  "idiom" : "mac", "scale" : "2x", "filename" : "icon_16x16@2x.png" },
    { "size" : "32x32",  "idiom" : "mac", "scale" : "1x", "filename" : "icon_32x32.png" },
    { "size" : "32x32",  "idiom" : "mac", "scale" : "2x", "filename" : "icon_32x32@2x.png" },
    { "size" : "128x128","idiom" : "mac", "scale" : "1x", "filename" : "icon_128x128.png" },
    { "size" : "128x128","idiom" : "mac", "scale" : "2x", "filename" : "icon_128x128@2x.png" },
    { "size" : "256x256","idiom" : "mac", "scale" : "1x", "filename" : "icon_256x256.png" },
    { "size" : "256x256","idiom" : "mac", "scale" : "2x", "filename" : "icon_256x256@2x.png" },
    { "size" : "512x512","idiom" : "mac", "scale" : "1x", "filename" : "icon_512x512.png" },
    { "size" : "512x512","idiom" : "mac", "scale" : "2x", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "version" : 1, "author" : "Siphon" }
}
"""
try! contents.write(to: catalog.appendingPathComponent("Contents.json"),
                    atomically: true, encoding: .utf8)

// Master 1024px artwork (square, no alpha channel) for the repo / App Store.
writePNG(opaqueIcon(1024), to: resources.appendingPathComponent("AppIcon-1024.png"))

// Finder-style preview: squircle mask + drop shadow on a transparent canvas.
// This is a presentation asset only; the shipped icon stays square so the OS
// can apply its own mask.
do {
    let canvas: CGFloat = 1200
    let side: CGFloat = 1024
    let pad = (canvas - side) / 2
    let radius = side * 0.2237
    let rep = bitmap(Int(canvas))
    withContext(rep) { ctx in
        // Neutral light ground so the preview reads correctly in README / browsers
        // on both light and dark themes (a transparent PNG turns black in many viewers).
        ctx.setFillColor(rgba(245, 245, 247))
        ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        let rect = CGRect(x: pad, y: pad, width: side, height: side)
        let rounded = CGPath(roundedRect: rect, cornerWidth: radius,
                             cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 44,
                      color: rgba(0, 0, 0, 0.30))
        ctx.setFillColor(rgba(255, 255, 255))
        ctx.addPath(rounded)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: pad, y: pad)
        let local = CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                           cornerWidth: radius, cornerHeight: radius,
                           transform: nil)
        ctx.addPath(local)
        ctx.clip()
        drawIcon(ctx, side, detailed: true)
        ctx.restoreGState()
    }
    writePNG(rep, to: resources.appendingPathComponent("AppIcon-Preview.png"))
}

print("Rendered \(slots.count) icon sizes + 1024 master + Finder preview")
