import AppKit
import Testing
import TerminalSurface

@MainActor
private final class StubSurface: TerminalSurface {
    let kind: String
    let view = NSView()
    weak var delegate: (any TerminalSurfaceDelegate)?
    var gridSize = GridSize(columns: 80, rows: 24)
    private(set) var applied: [TerminalAppearance] = []

    init(kind: String, appearance: TerminalAppearance) {
        self.kind = kind
        apply(appearance)
    }

    func feed(_ bytes: ArraySlice<UInt8>) {}
    func apply(_ appearance: TerminalAppearance) { applied.append(appearance) }
    func clearScrollback() {}
    func scrollToBottom() {}
    func find(_ query: String, direction: FindDirection) {}
    var selectedText: String? { nil }
}

@Suite("SurfaceRegistry")
@MainActor
struct SurfaceRegistryTests {
    private func factory(_ id: String) -> SurfaceFactory {
        SurfaceFactory(id: id, displayName: id.capitalized) { StubSurface(kind: id, appearance: $0) }
    }

    @Test func persistedIdentifierResolvesAndUnknownFallsBackToTheDefault() throws {
        let registry = SurfaceRegistry(default: factory("first"), others: [factory("second")])
        #expect(registry.factories.map(\.id) == ["first", "second"])
        #expect(registry.factory(for: "second").id == "second")
        #expect(registry.factory(for: "removed-renderer").id == "first")
        #expect(registry.factory(for: nil).id == "first")
        #expect(registry.contains("second"))
        #expect(!registry.contains("removed-renderer"))

        let appearance = TerminalAppearance(fontName: "Menlo", fontSize: 17)
        let surface = try #require(registry.factory(for: "second").makeSurface(appearance: appearance) as? StubSurface)
        #expect(surface.kind == "second")
        #expect(surface.applied == [appearance])
    }

    @Test func registeringTheSameIdentifierReplaces() {
        let registry = SurfaceRegistry(default: factory("first"))
        registry.register(SurfaceFactory(id: "first", displayName: "Renamed") { StubSurface(kind: "x", appearance: $0) })
        #expect(registry.factories.count == 1)
        #expect(registry.factory(for: "first").displayName == "Renamed")
    }
}
