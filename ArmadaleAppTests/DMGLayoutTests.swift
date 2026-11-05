import Foundation
import ImageIO
import Testing

/// The release DMG's Finder window (docs/DESIGN.md section 11, "The DMG
/// window"): the committed background images that
/// scripts/render-dmg-background.swift generates, and the dmgbuild settings
/// that use them.
@Suite("DMG layout")
struct DMGLayoutTests {
    private static let dmgDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/dmg")

    /// The value of `key` for each image in the file at `name`, in order.
    private func imageProperty(_ key: CFString, _ name: String) throws -> [Double] {
        let url = Self.dmgDirectory.appendingPathComponent(name)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(name) is missing")
        return (0..<CGImageSourceGetCount(source)).compactMap { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return (properties?[key] as? NSNumber)?.doubleValue
        }
    }

    /// Pixel size of each image in the file at `name`, in order.
    private func pixelSizes(_ name: String) throws -> [[Double]] {
        let widths = try imageProperty(kCGImagePropertyPixelWidth, name)
        let heights = try imageProperty(kCGImagePropertyPixelHeight, name)
        return zip(widths, heights).map { [$0, $1] }
    }

    @Test func backgroundsAreTheWindowSizeAtOneAndTwoX() throws {
        #expect(try pixelSizes("background.png") == [[600, 400]])
        #expect(try pixelSizes("background@2x.png") == [[1200, 800]])
        #expect(try pixelSizes("background.tiff") == [[600, 400], [1200, 800]])
    }

    /// 72 dpi at 1x and 144 at 2x, so every representation is 600 × 400 points.
    @Test func backgroundsCarryTheirResolution() throws {
        #expect(try imageProperty(kCGImagePropertyDPIWidth, "background.png") == [72])
        #expect(try imageProperty(kCGImagePropertyDPIWidth, "background@2x.png") == [144])
        #expect(try imageProperty(kCGImagePropertyDPIWidth, "background.tiff") == [72, 144])
    }

    @Test func settingsUseTheTiffAndTheWindowSize() throws {
        let settings = try String(contentsOf: Self.dmgDirectory.appendingPathComponent("settings.py"), encoding: .utf8)
        #expect(settings.contains("\"background.tiff\""))
        #expect(settings.contains("(600, 400))"), "window_rect's size matches the background")
        #expect(settings.contains("icon_size = 128"))
        #expect(settings.contains("appname: (150, 200)"))
        #expect(settings.contains("\"Applications\": (450, 200)"))
        #expect(!settings.lowercased().contains("zmx"))
    }
}
