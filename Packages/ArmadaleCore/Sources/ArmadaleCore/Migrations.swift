import Foundation

/// Errors raised while upgrading a state document.
public enum MigrationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The document is not a JSON object.
    case notAnObject
    /// The document has no integer `schemaVersion`.
    case missingSchemaVersion
    /// No migration path exists from this (older) version.
    case unsupportedVersion(Int)
    /// The document was written by a newer Armadale.
    case newerVersion(Int)
    /// A migration step did not produce the version it promised.
    case stepDidNotAdvance(from: Int)

    public var description: String {
        switch self {
        case .notAnObject: "State file is not a JSON object."
        case .missingSchemaVersion: "State file has no schemaVersion."
        case .unsupportedVersion(let v): "State schema version \(v) is too old to migrate."
        case .newerVersion(let v): "State schema version \(v) was written by a newer Armadale."
        case .stepDidNotAdvance(let v): "Migration from schema version \(v) did not advance the version."
        }
    }
}

/// Upgrades raw state documents, one version at a time, to
/// ``PersistedState/currentSchemaVersion``.
///
/// Each step takes the JSON object for version `N` and returns the object
/// for version `N + 1`, including the bumped `schemaVersion`. Steps operate
/// on untyped JSON so old shapes never need Swift types of their own.
public enum Migrations {
    /// A JSON object as produced by `JSONSerialization`.
    public typealias Document = [String: Any]
    /// Upgrades a document from version `N` to `N + 1`.
    public typealias Step = @Sendable (Document) throws -> Document

    /// Registered steps keyed by the version they upgrade *from*.
    ///
    /// When the version is bumped (the rule is in DESIGN §3: whenever a
    /// released build could not decode the file, or would decode it and
    /// lose something whose loss is unsafe), a step from the previous
    /// version is added here.
    ///
    /// - 1 → 2 (November 14, 2026) changes nothing but the version. Every
    ///   shape schema 1 ever had is still decoded by the same additive
    ///   decoding; the bump is there so released builds refuse the newer
    ///   file instead of misreading it: 0.1.0 cannot decode an empty pane,
    ///   and 0.1.1 would drop the orphan reclaim's spared sessions.
    public static let steps: [Int: Step] = [
        1: { document in
            var document = document
            document["schemaVersion"] = 2
            return document
        },
    ]

    /// The document's integer `schemaVersion`, or `nil`. A JSON boolean is
    /// not a version, although `JSONSerialization` would bridge `true` to 1.
    static func schemaVersion(of document: Document) -> Int? {
        guard let value = document["schemaVersion"],
              CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID()
        else { return nil }
        return value as? Int
    }

    /// Upgrades `document` to `targetVersion` using `steps`.
    ///
    /// - Throws: ``MigrationError`` if the version is missing, newer than
    ///   `targetVersion`, or has no path to it. Documents without a
    ///   `schemaVersion` (pre-release, "version 0") are rejected.
    public static func migrate(
        _ document: Document,
        to targetVersion: Int = PersistedState.currentSchemaVersion,
        steps: [Int: Step] = Migrations.steps
    ) throws -> Document {
        guard let version = schemaVersion(of: document) else {
            throw MigrationError.missingSchemaVersion
        }
        if version > targetVersion { throw MigrationError.newerVersion(version) }

        var current = document
        var currentVersion = version
        while currentVersion < targetVersion {
            guard let step = steps[currentVersion] else {
                throw MigrationError.unsupportedVersion(currentVersion)
            }
            current = try step(current)
            guard let next = schemaVersion(of: current), next == currentVersion + 1 else {
                throw MigrationError.stepDidNotAdvance(from: currentVersion)
            }
            currentVersion = next
        }
        return current
    }

    /// Parses `data`, migrates it, and returns JSON for the current version.
    public static func migrate(
        data: Data,
        to targetVersion: Int = PersistedState.currentSchemaVersion,
        steps: [Int: Step] = Migrations.steps
    ) throws -> Data {
        guard let document = try JSONSerialization.jsonObject(with: data) as? Document else {
            throw MigrationError.notAnObject
        }
        if schemaVersion(of: document) == targetVersion { return data }
        let migrated = try migrate(document, to: targetVersion, steps: steps)
        return try JSONSerialization.data(withJSONObject: migrated, options: [.sortedKeys])
    }
}
