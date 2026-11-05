#!/usr/bin/env swift
// Renders the background of the release DMG's Finder window from code.
//
//   swift scripts/render-dmg-background.swift [repo-root]
//
// Writes, under <repo-root>/scripts/dmg:
//   background.png      600 × 400 px (72 dpi, 1x)
//   background@2x.png   1200 × 800 px (144 dpi, 2x)
//   background.tiff     both in one multi-representation TIFF
//                       (`tiffutil -cathidpicheck`), which is what
//                       scripts/dmg/settings.py hands to dmgbuild
// The generated files are committed, so a release needs no rendering step;
// change this script and rerun it, do not edit the images.
//
// Layout (docs/DESIGN.md section 11, "Release pipeline"): every coordinate
// here is in points with the origin at the top-left of the window's content
// area, the same convention as Finder's icon positions (each icon's centre,
// in points from the top-left) in scripts/dmg/settings.py. The app icon sits
// at (150, 200) and the Applications folder at (450, 200), both 128 pt; the
// background is the website's light ground with a muted arrow between the
// two icons and a one-line caption below them. Nothing else: the app icon
// itself is the first item in the window.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
}

enum Palette {
    /// The website's light background (`--bg` in docs/index.html).
    static let ground = RGB(0xF5F5F7)
    /// The website's muted text colour (`--muted`).
    static let muted = RGB(0x6E6E73)
}

/// Points, top-left origin (Finder's convention).
enum Layout {
    static let size = CGSize(width: 600, height: 400)
    /// Icon centres; mirrored by icon_locations in scripts/dmg/settings.py.
    static let appIcon = CGPoint(x: 150, y: 200)
    static let applications = CGPoint(x: 450, y: 200)
    static let iconSize: CGFloat = 128

    /// The arrow's shaft, from just right of the app icon (whose right edge
    /// is at 214) to just left of the Applications folder (386).
    static let arrowStart = CGPoint(x: 230, y: 200)
    static let arrowEnd = CGPoint(x: 370, y: 200)
    static let arrowStroke: CGFloat = 3
    /// The open arrowhead: two strokes back from the tip.
    static let headLength: CGFloat = 11
    static let headHalfWidth: CGFloat = 9

    static let caption = "Drag Armadale to Applications"
    static let captionSize: CGFloat = 13
    /// The caption's visual centre. The icons' labels sit at about 268–286
    /// (below the 128 pt icons), so this keeps a clear gap under them.
    static let captionCentre = CGPoint(x: 300, y: 320)

    static let scales = [1, 2]
}

// MARK: - Drawing

func draw(in ctx: CGContext, scale: CGFloat) {
    // Flip to top-left origin, in points.
    ctx.translateBy(x: 0, y: Layout.size.height * scale)
    ctx.scaleBy(x: scale, y: -scale)

    ctx.setFillColor(Palette.ground.cg)
    ctx.fill(CGRect(origin: .zero, size: Layout.size))

    // Arrow: shaft and an open head, one stroke with round caps and joins.
    let tip = Layout.arrowEnd
    let path = CGMutablePath()
    path.move(to: Layout.arrowStart)
    path.addLine(to: tip)
    path.move(to: CGPoint(x: tip.x - Layout.headLength, y: tip.y - Layout.headHalfWidth))
    path.addLine(to: tip)
    path.addLine(to: CGPoint(x: tip.x - Layout.headLength, y: tip.y + Layout.headHalfWidth))
    ctx.addPath(path)
    ctx.setStrokeColor(Palette.muted.cg)
    ctx.setLineWidth(Layout.arrowStroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Caption: the system font, centred on captionCentre. Core Text draws
    // with y up, so the text matrix flips it back within the flipped context.
    let font = CTFontCreateUIFontForLanguage(.system, Layout.captionSize, nil)!
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.muted.cg,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: Layout.caption, attributes: attributes))
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let baseline = Layout.captionCentre.y + (ascent - descent) / 2
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: Layout.captionCentre.x - width / 2, y: baseline)
    CTLineDraw(line, ctx)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("render-dmg-background: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func renderPNG(scale: Int, to url: URL) {
    let width = Int(Layout.size.width) * scale, height = Int(Layout.size.height) * scale
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Opaque: the background covers the whole window.
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fail("no CGContext for \(width)×\(height)")
    }
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSmoothing(false)
    ctx.interpolationQuality = .high
    draw(in: ctx, scale: CGFloat(scale))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    // 72 dpi × scale, so both files describe the same 600 × 400 points.
    let dpi = 72 * scale
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("finalize failed for \(url.path)") }
    print("wrote \(url.path)")
}

func fileName(scale: Int) -> String { scale == 1 ? "background.png" : "background@\(scale)x.png" }

// MARK: - Main

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let dir = root.appendingPathComponent("scripts/dmg")
do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
} catch {
    fail(error.localizedDescription)
}
for scale in Layout.scales {
    renderPNG(scale: scale, to: dir.appendingPathComponent(fileName(scale: scale)))
}

// One TIFF with both representations; -cathidpicheck refuses a pair whose
// second image is not exactly twice the first.
let tiff = dir.appendingPathComponent("background.tiff")
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck"] + Layout.scales.map { dir.appendingPathComponent(fileName(scale: $0)).path } + ["-out", tiff.path]
do {
    try tiffutil.run()
} catch {
    fail("cannot run tiffutil: \(error.localizedDescription)")
}
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { fail("tiffutil -cathidpicheck failed (status \(tiffutil.terminationStatus))") }
print("wrote \(tiff.path)")
