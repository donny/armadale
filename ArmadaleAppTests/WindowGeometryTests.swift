import ArmadaleCore
import CoreGraphics
import Testing

/// A workspace window's saved geometry (docs/DESIGN.md section 8, "App
/// lifecycle"): no full-screen frame is ever recorded, and a saved frame
/// opens on a screen that still exists. Full screen itself is AppKit and
/// checked live.
@Suite("Window geometry")
struct WindowGeometryTests {
    private let normal = WindowFrame(x: 100, y: 120, width: 1100, height: 700)
    private let screenSized = WindowFrame(x: 0, y: 0, width: 1728, height: 1117)

    @Test func aNormalWindowRecordsItsFrame() {
        #expect(WindowGeometry.recordedFrame(isFullScreen: false, current: normal, lastNormal: nil) == normal)
        #expect(WindowGeometry.recordedFrame(isFullScreen: false, current: normal, lastNormal: screenSized) == normal)
    }

    @Test func fullScreenKeepsTheLastNormalFrame() {
        #expect(WindowGeometry.recordedFrame(isFullScreen: true, current: screenSized, lastNormal: normal) == normal)
        // Nothing normal known yet: nothing recorded, the default size opens.
        #expect(WindowGeometry.recordedFrame(isFullScreen: true, current: screenSized, lastNormal: nil) == nil)
    }

    @Test func frameConversionRoundTrips() {
        #expect(WindowFrame(normal.rect) == normal)
    }

    // A laptop screen with an external display to its right, as visible
    // frames (menu bar and Dock taken off).
    private let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    private let external = CGRect(x: 1728, y: 0, width: 2560, height: 1410)

    @Test func aFrameWhoseTitleBarIsOnAScreenOpensAsSaved() {
        let frame = CGRect(x: 100, y: 100, width: 1100, height: 700)
        #expect(WindowGeometry.placement(of: frame, visibleFrames: [laptop]) == .asSaved)
        let onExternal = CGRect(x: 2000, y: 200, width: 1100, height: 700)
        #expect(WindowGeometry.placement(of: onExternal, visibleFrames: [laptop, external]) == .asSaved)
        // Spanning both displays on purpose: left where it is.
        let spanning = CGRect(x: 1228, y: 100, width: 1100, height: 700)
        #expect(WindowGeometry.placement(of: spanning, visibleFrames: [laptop, external]) == .asSaved)
        // Hanging off the laptop's right edge, the external display gone.
        let hanging = CGRect(x: 1500, y: 100, width: 1100, height: 700)
        #expect(WindowGeometry.placement(of: hanging, visibleFrames: [laptop]) == .asSaved)
        // Below the bottom edge but with the title bar on screen.
        let low = CGRect(x: 100, y: -600, width: 1100, height: 700)
        #expect(WindowGeometry.placement(of: low, visibleFrames: [laptop]) == .asSaved)
        // Taller than the visible frame, title bar partly under the menu
        // bar but still overlapping (an old screen-sized frame).
        let tall = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        #expect(WindowGeometry.placement(of: tall, visibleFrames: [laptop]) == .asSaved)
    }

    @Test func aFrameOnADisconnectedDisplayOpensCentredAtTheDefaultSize() {
        let onExternal = CGRect(x: 2000, y: 200, width: 1100, height: 700)
        #expect(WindowGeometry.placement(of: onExternal, visibleFrames: [laptop]) == .centredDefault)
        // Merely touching an edge is not on screen.
        let touching = CGRect(x: 1728, y: 100, width: 800, height: 600)
        #expect(WindowGeometry.placement(of: touching, visibleFrames: [laptop]) == .centredDefault)
        #expect(WindowGeometry.placement(of: onExternal, visibleFrames: []) == .centredDefault)
        #expect(WindowGeometry.placement(of: .zero, visibleFrames: [laptop]) == .centredDefault)
    }

    @Test func aFrameWithItsTitleBarOffScreenIsConstrainedToTheScreenItOverlapsMost() {
        // Title bar above the top of the laptop's visible frame.
        let high = CGRect(x: 100, y: 500, width: 1100, height: 700)
        #expect(WindowGeometry.placement(of: high, visibleFrames: [laptop]) == .constrained(toScreen: 0))
        // Title bar above both displays, the body mostly on the external one.
        let aboveBoth = CGRect(x: 1628, y: 900, width: 1100, height: 700)
        #expect(WindowGeometry.placement(of: aboveBoth, visibleFrames: [laptop, external]) == .constrained(toScreen: 1))
        // The strip is the top 40 pt: 41 pt above the top is off screen.
        let justAbove = CGRect(x: 100, y: 1080 - 700 + 41, width: 1100, height: 700)
        #expect(WindowGeometry.placement(of: justAbove, visibleFrames: [laptop]) == .constrained(toScreen: 0))
        let justOn = CGRect(x: 100, y: 1080 - 700 + 39, width: 1100, height: 700)
        #expect(WindowGeometry.placement(of: justOn, visibleFrames: [laptop]) == .asSaved)
    }
}
