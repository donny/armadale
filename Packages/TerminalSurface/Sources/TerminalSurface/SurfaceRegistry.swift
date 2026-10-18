/// One terminal renderer that can be chosen in Settings: an identifier
/// that is persisted, a name to show, and a way to make a surface.
@MainActor
public struct SurfaceFactory: Identifiable {
    /// Stable identifier, stored in preferences (e.g. `swiftterm`).
    public let id: String
    /// Name shown in Settings.
    public let displayName: String
    private let make: @MainActor (TerminalAppearance) -> any TerminalSurface

    public init(id: String, displayName: String, make: @escaping @MainActor (TerminalAppearance) -> any TerminalSurface) {
        self.id = id
        self.displayName = displayName
        self.make = make
    }

    /// A new surface with `appearance` applied.
    public func makeSurface(appearance: TerminalAppearance) -> any TerminalSurface {
        make(appearance)
    }
}

/// The renderers available to the app, keyed by identifier. There is
/// always a default, which an unknown identifier (a renderer removed in a
/// later version, a hand-edited preference) resolves to.
@MainActor
public final class SurfaceRegistry {
    /// Registered factories, the default first, then in registration order.
    public private(set) var factories: [SurfaceFactory]
    /// The identifier unknown ones fall back to.
    public let defaultID: String

    public init(default defaultFactory: SurfaceFactory, others: [SurfaceFactory] = []) {
        self.defaultID = defaultFactory.id
        self.factories = [defaultFactory]
        others.forEach(register)
    }

    /// Adds a factory, replacing one with the same identifier.
    public func register(_ factory: SurfaceFactory) {
        if let index = factories.firstIndex(where: { $0.id == factory.id }) {
            factories[index] = factory
        } else {
            factories.append(factory)
        }
    }

    /// The factory for `id`, or the default one if `id` is `nil` or unknown.
    public func factory(for id: String?) -> SurfaceFactory {
        if let id, let factory = factories.first(where: { $0.id == id }) { return factory }
        return factories.first { $0.id == defaultID } ?? factories[0]
    }

    /// Whether `id` names a registered factory.
    public func contains(_ id: String) -> Bool {
        factories.contains { $0.id == id }
    }
}
