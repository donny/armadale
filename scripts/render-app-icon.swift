#!/usr/bin/env swift
// Renders the Armadale app icon from a single geometric description.
//
//   swift scripts/render-app-icon.swift [repo-root]
//
// Writes, under <repo-root>/Armadale/Resources:
//   Assets.xcassets/AppIcon.appiconset/   PNGs 16…1024 px and Contents.json
//   AppIcon.icon/                         Icon Composer document for macOS 26+
//                                         (icon.json plus the layer SVGs)
// and <repo-root>/docs/icon/AppIcon.svg, the master vector for reference.
//
// Design ("Panes", Balanced shape, Graphite palette): a dark rounded tile
// holding three panes — one tall on the left, two square on the right — with
// the top-right pane lit in the attention colour. Pane corners are concentric
// with the tile's corners (tile radius 232 − inset 168 = 64). The asset-
// catalog rasters follow the macOS icon grid: an 824 pt tile centred on a
// 1024 pt canvas with a soft baked shadow. The Icon Composer layers are
// full-bleed; the system supplies the tile shape, depth and lighting.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design

struct RGB {
    let r: Double, g: Double, b: Double
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
    /// Icon Composer's colour notation.
    var extendedSRGB: String { String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", r, g, b) }
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }
}

enum Palette {
    static let ground = RGB(0x1E2228)
    static let pane = RGB(0x4E5666)
    static let lit = RGB(0xF26B4A)
}

/// All geometry on a 1024-unit tile.
enum Geometry {
    static let tile: CGFloat = 1024
    static let tileRadius: CGFloat = 232
    static let paneRadius: CGFloat = 64
    static let tall = CGRect(x: 168, y: 168, width: 320, height: 688)
    static let lowRight = CGRect(x: 536, y: 536, width: 320, height: 320)
    static let lit = CGRect(x: 536, y: 168, width: 320, height: 320)
    static let dimPanes = [tall, lowRight]

    /// macOS icon grid for rasters: 824 pt tile centred on 1024.
    static let canvas: CGFloat = 1024
    static let gridTile: CGFloat = 824
    static let gridInset: CGFloat = (canvas - gridTile) / 2
}

// MARK: - CoreGraphics rendering (asset catalog rasters)

/// Coordinates here are top-left origin on the 1024 tile; the context is flipped first.
func drawTile(in ctx: CGContext, canvasPixels: Int) {
    let px = CGFloat(canvasPixels)
    let scale = px / Geometry.canvas
    ctx.translateBy(x: 0, y: px)
    ctx.scaleBy(x: scale, y: -scale)

    // Tile with a baked shadow, as the pre-26 macOS icon template does.
    let tileRect = CGRect(x: Geometry.gridInset, y: Geometry.gridInset, width: Geometry.gridTile, height: Geometry.gridTile)
    let tileScale = Geometry.gridTile / Geometry.tile
    let tilePath = CGPath(roundedRect: tileRect, cornerWidth: Geometry.tileRadius * tileScale, cornerHeight: Geometry.tileRadius * tileScale, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: CGColor(gray: 0, alpha: 0.30))
    ctx.addPath(tilePath)
    ctx.setFillColor(Palette.ground.cg)
    ctx.fillPath()
    ctx.restoreGState()

    // Everything else is drawn in tile units.
    ctx.translateBy(x: Geometry.gridInset, y: Geometry.gridInset)
    ctx.scaleBy(x: tileScale, y: tileScale)

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func gradient(_ top: CGColor, _ bottom: CGColor) -> CGGradient {
        CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    }
    let tileSheen = gradient(CGColor(gray: 1, alpha: 0.10), CGColor(gray: 0, alpha: 0.10))
    let paneSheen = gradient(CGColor(gray: 1, alpha: 0.12), CGColor(gray: 1, alpha: 0))

    let fullTile = CGRect(x: 0, y: 0, width: Geometry.tile, height: Geometry.tile)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: fullTile, cornerWidth: Geometry.tileRadius, cornerHeight: Geometry.tileRadius, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(tileSheen, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: Geometry.tile), options: [])
    ctx.restoreGState()

    func pane(_ rect: CGRect, _ color: CGColor) {
        let path = CGPath(roundedRect: rect, cornerWidth: Geometry.paneRadius, cornerHeight: Geometry.paneRadius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(paneSheen, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        ctx.restoreGState()
    }
    for rect in Geometry.dimPanes { pane(rect, Palette.pane.cg) }
    pane(Geometry.lit, Palette.lit.cg)
}

func renderPNG(pixels: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "render-app-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "no CGContext for \(pixels)px"])
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawTile(in: ctx, canvasPixels: pixels)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "render-app-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "render-app-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "finalize failed for \(url.path)"])
    }
}

// MARK: - SVG

func svgRect(_ r: CGRect, rx: CGFloat, fill: String, extra: String = "") -> String {
    "  <rect x=\"\(Int(r.minX))\" y=\"\(Int(r.minY))\" width=\"\(Int(r.width))\" height=\"\(Int(r.height))\" rx=\"\(Int(rx))\" fill=\"\(fill)\"\(extra)/>\n"
}

/// The master vector: full design on the macOS grid (824 tile on a 1024 canvas), no shadow.
func masterSVG() -> String {
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\">\n"
    s += "  <!-- Armadale app icon: Panes (Balanced, Graphite). Generated by scripts/render-app-icon.swift. -->\n"
    s += "  <defs>\n"
    s += "    <linearGradient id=\"tile-sheen\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"#FFFFFF\" stop-opacity=\"0.10\"/><stop offset=\"1\" stop-color=\"#000000\" stop-opacity=\"0.10\"/></linearGradient>\n"
    s += "    <linearGradient id=\"pane-sheen\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"#FFFFFF\" stop-opacity=\"0.12\"/><stop offset=\"1\" stop-color=\"#FFFFFF\" stop-opacity=\"0\"/></linearGradient>\n"
    s += "  </defs>\n"
    let k = Geometry.gridTile / Geometry.tile
    s += "  <g transform=\"translate(\(Int(Geometry.gridInset)) \(Int(Geometry.gridInset))) scale(\(String(format: "%.6f", k)))\">\n"
    let tile = CGRect(x: 0, y: 0, width: Geometry.tile, height: Geometry.tile)
    s += "  " + svgRect(tile, rx: Geometry.tileRadius, fill: Palette.ground.hex)
    s += "  " + svgRect(tile, rx: Geometry.tileRadius, fill: "url(#tile-sheen)")
    for r in Geometry.dimPanes {
        s += "  " + svgRect(r, rx: Geometry.paneRadius, fill: Palette.pane.hex)
        s += "  " + svgRect(r, rx: Geometry.paneRadius, fill: "url(#pane-sheen)")
    }
    s += "  " + svgRect(Geometry.lit, rx: Geometry.paneRadius, fill: Palette.lit.hex)
    s += "  " + svgRect(Geometry.lit, rx: Geometry.paneRadius, fill: "url(#pane-sheen)")
    s += "  </g>\n</svg>\n"
    return s
}

/// A flat, full-bleed layer for Icon Composer (1024 canvas, no background, no sheen).
func layerSVG(rects: [CGRect], fill: RGB, comment: String) -> String {
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\">\n"
    s += "  <!-- \(comment) -->\n"
    for r in rects { s += svgRect(r, rx: Geometry.paneRadius, fill: fill.hex) }
    s += "</svg>\n"
    return s
}

// MARK: - Icon Composer document

func iconJSON() -> String {
    """
    {
      "fill" : {
        "automatic-gradient" : "\(Palette.ground.extendedSRGB)"
      },
      "groups" : [
        {
          "layers" : [
            {
              "image-name" : "panes.svg",
              "name" : "Panes"
            }
          ],
          "shadow" : {
            "kind" : "neutral",
            "opacity" : 0.4
          },
          "translucency" : {
            "enabled" : true,
            "value" : 0.3
          }
        },
        {
          "layers" : [
            {
              "image-name" : "lit.svg",
              "name" : "Lit pane"
            }
          ],
          "shadow" : {
            "kind" : "neutral",
            "opacity" : 0.5
          },
          "translucency" : {
            "enabled" : false,
            "value" : 0
          }
        }
      ],
      "supported-platforms" : {
        "circles" : [
          "watchOS"
        ],
        "squares" : "shared"
      }
    }

    """
}

// MARK: - Asset catalog Contents.json

struct IconSlot { let points: Int; let scale: Int; var pixels: Int { points * scale } }
let slots: [IconSlot] = [16, 32, 128, 256, 512].flatMap { [IconSlot(points: $0, scale: 1), IconSlot(points: $0, scale: 2)] }

func contentsJSON() -> String {
    let images = slots.map { slot in
        """
            {
              "filename" : "icon_\(slot.pixels).png",
              "idiom" : "mac",
              "scale" : "\(slot.scale)x",
              "size" : "\(slot.points)x\(slot.points)"
            }
        """
    }.joined(separator: ",\n")
    return """
    {
      "images" : [
    \(images)
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

// MARK: - Main

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let fm = FileManager.default

func write(_ text: String, to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.data(using: .utf8)!.write(to: url)
    print("wrote \(url.path)")
}

do {
    let resources = root.appendingPathComponent("Armadale/Resources")

    let appiconset = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try fm.createDirectory(at: appiconset, withIntermediateDirectories: true)
    for pixels in Set(slots.map(\.pixels)).sorted() {
        let url = appiconset.appendingPathComponent("icon_\(pixels).png")
        try renderPNG(pixels: pixels, to: url)
        print("wrote \(url.path)")
    }
    try write(contentsJSON(), to: appiconset.appendingPathComponent("Contents.json"))
    try write("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n",
              to: resources.appendingPathComponent("Assets.xcassets/Contents.json"))

    let icon = resources.appendingPathComponent("AppIcon.icon")
    try write(iconJSON(), to: icon.appendingPathComponent("icon.json"))
    try write(layerSVG(rects: Geometry.dimPanes, fill: Palette.pane, comment: "Idle panes layer"),
              to: icon.appendingPathComponent("Assets/panes.svg"))
    try write(layerSVG(rects: [Geometry.lit], fill: Palette.lit, comment: "Lit pane layer"),
              to: icon.appendingPathComponent("Assets/lit.svg"))

    try write(masterSVG(), to: root.appendingPathComponent("docs/icon/AppIcon.svg"))
} catch {
    FileHandle.standardError.write("render-app-icon: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
