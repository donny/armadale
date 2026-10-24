import Foundation

/// Reads and writes `state.json`.
///
/// - Saves are atomic: the new document is written to a temporary file in
///   the same directory, flushed with `fsync`, and renamed over
///   `state.json`. Before the rename the previous `state.json` is
///   hard-linked to `state.json.bak`, so a complete `state.json` exists at
///   every instant.
/// - Loading distinguishes a damaged file (recovered from the backup, the
///   damaged file moved aside) from a file this build must not touch: one
///   written by a newer Armadale, or one that cannot be read at all. In the
///   latter cases nothing on disk is moved or overwritten.
public enum StateStore {
    /// Name of the primary state file.
    public static let fileName = "state.json"

    /// The outcome of ``load(from:fileManager:)``.
    public enum LoadResult: Sendable {
        /// `state.json` was read. `isFirstLaunch` is true when neither it nor
        /// a backup existed and `state` is ``PersistedState/empty``.
        case loaded(PersistedState, isFirstLaunch: Bool)
        /// `state.json` was missing or could not be parsed. If the backup
        /// was usable, `recovered` holds it; otherwise it is `nil` and the
        /// caller starts fresh. Every damaged file was moved aside to the
        /// `quarantined` URLs, so the next save cannot rotate it into the backup.
        case unparseable(problem: String, recovered: PersistedState?, quarantined: [URL])
        /// The file was written by a newer Armadale (`version` >
        /// ``PersistedState/currentSchemaVersion``). Nothing was touched;
        /// the caller must not save.
        case newerVersion(Int, file: URL)
        /// The file exists but could not be read (permissions, I/O).
        /// Nothing was touched; the caller must not save.
        case ioError(String, file: URL)

        /// The usable state, if any.
        public var state: PersistedState? {
            switch self {
            case .loaded(let state, _): state
            case .unparseable(_, let recovered, _): recovered
            case .newerVersion, .ioError: nil
            }
        }

        /// Whether the caller may write state after this load. False when
        /// writing could destroy a newer or unreadable file.
        public var allowsSaving: Bool {
            switch self {
            case .loaded, .unparseable: true
            case .newerVersion, .ioError: false
            }
        }
    }

    /// `state.json.bak` next to `url`.
    public static func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bak")
    }

    // MARK: Coding

    /// The encoder used for state files: pretty-printed, sorted keys, ISO 8601 dates.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The matching decoder.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Migrates and decodes a state document. Loading drops the empty
    /// closed workspaces older versions kept
    /// (``PersistedState/droppingEmptyClosedWorkspaces()``), so the result
    /// may hold fewer workspaces than the file.
    public static func decode(_ data: Data) throws -> PersistedState {
        try decodeCountingDrops(data).state
    }

    /// ``decode(_:)``, also saying how many empty closed workspaces it dropped.
    static func decodeCountingDrops(_ data: Data) throws -> (state: PersistedState, droppedWorkspaces: Int) {
        let migrated = try Migrations.migrate(data: data)
        let decoded = try makeDecoder().decode(PersistedState.self, from: migrated)
        let state = decoded.droppingEmptyClosedWorkspaces()
        return (state, decoded.workspaces.count - state.workspaces.count)
    }

    /// Encodes a state document.
    public static func encode(_ state: PersistedState) throws -> Data {
        try makeEncoder().encode(state)
    }

    // MARK: Load

    /// How one file read went.
    private enum FileRead {
        case missing
        case ok(PersistedState, droppedWorkspaces: Int)
        case unparseable(String)
        case newer(Int)
        case ioError(String)
    }

    private static func read(_ url: URL, fileManager: FileManager) -> FileRead {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .ioError(error.localizedDescription)
        }
        do {
            let decoded = try decodeCountingDrops(data)
            return .ok(decoded.state, droppedWorkspaces: decoded.droppedWorkspaces)
        } catch MigrationError.newerVersion(let version) {
            return .newer(version)
        } catch {
            return .unparseable(describe(error))
        }
    }

    /// Loads state from `url` (normally `…/state.json`), falling back to its
    /// `.bak` sibling as described in ``LoadResult``. Also removes temporary
    /// files left by an interrupted save. Empty closed workspaces are
    /// dropped (``decode(_:)``); `droppedEmptyWorkspaces` is called with
    /// their number when the state returned had any, for the log.
    public static func load(
        from url: URL, fileManager: FileManager = .default, droppedEmptyWorkspaces: (Int) -> Void = { _ in }
    ) -> LoadResult {
        removeStaleTemporaryFiles(for: url, fileManager: fileManager)
        let backup = backupURL(for: url)

        let primaryProblem: String
        let primaryIsDamaged: Bool
        switch read(url, fileManager: fileManager) {
        case .ok(let state, let dropped):
            if dropped > 0 { droppedEmptyWorkspaces(dropped) }
            return .loaded(state, isFirstLaunch: false)
        case .newer(let version):
            return .newerVersion(version, file: url)
        case .ioError(let message):
            return .ioError(message, file: url)
        case .unparseable(let message):
            primaryProblem = message
            primaryIsDamaged = true
        case .missing:
            primaryProblem = "\(fileName) is missing"
            primaryIsDamaged = false
        }

        switch read(backup, fileManager: fileManager) {
        case .missing where !primaryIsDamaged:
            return .loaded(.empty, isFirstLaunch: true)
        case .ok(let state, let dropped):
            if dropped > 0 { droppedEmptyWorkspaces(dropped) }
            let moved = primaryIsDamaged ? [quarantine(url, fileManager: fileManager)].compactMap { $0 } : []
            return .unparseable(problem: primaryProblem, recovered: state, quarantined: moved)
        case .newer(let version):
            return .newerVersion(version, file: backup)
        case .ioError(let message):
            return .ioError(message, file: backup)
        case .missing, .unparseable:
            var moved: [URL] = []
            if primaryIsDamaged, let m = quarantine(url, fileManager: fileManager) { moved.append(m) }
            if fileManager.fileExists(atPath: backup.path), let m = quarantine(backup, fileManager: fileManager) {
                moved.append(m)
            }
            return .unparseable(problem: primaryProblem, recovered: nil, quarantined: moved)
        }
    }

    /// Moves a damaged state file to `<name>.corrupt-<timestamp>` and
    /// returns the new location, or `nil` if it could not be moved.
    @discardableResult
    public static func quarantine(_ url: URL, fileManager: FileManager = .default, now: Date = Date()) -> URL? {
        let stamp = Int(now.timeIntervalSince1970)
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        do {
            try fileManager.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as MigrationError: error.description
        case let error as DecodingError: "\(error)"
        default: error.localizedDescription
        }
    }

    // MARK: Save

    /// Writes `state` to `url` atomically, keeping the previous file as `.bak`.
    /// Creates the parent directory if needed.
    public static func save(_ state: PersistedState, to url: URL, fileManager: FileManager = .default) throws {
        let data = try encode(state)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let temp = directory.appendingPathComponent(temporaryPrefix(for: url) + UUID().uuidString + ".tmp")
        do {
            try writeSynced(data, to: temp)
            try rotateBackup(of: url, fileManager: fileManager)
            try replace(url, with: temp)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    /// `.state.json.` — temporary files are `.state.json.<uuid>.tmp`.
    static func temporaryPrefix(for url: URL) -> String {
        ".\(url.lastPathComponent)."
    }

    /// Deletes `.state.json.*.tmp` files left by a save that was interrupted
    /// before its rename.
    static func removeStaleTemporaryFiles(for url: URL, fileManager: FileManager) {
        let directory = url.deletingLastPathComponent()
        let prefix = temporaryPrefix(for: url)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Creates `url` exclusively, writes `data`, and `fsync`s before closing.
    private static func writeSynced(_ data: Data, to url: URL) throws {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        }
        guard fd >= 0 else { throw posixError(url) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    /// Makes `state.json.bak` a copy of the current `state.json` without ever
    /// removing `state.json` itself.
    private static func rotateBackup(of url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let backup = backupURL(for: url)
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
        do {
            try fileManager.linkItem(at: url, to: backup)
        } catch {
            try fileManager.copyItem(at: url, to: backup)
        }
    }

    /// `rename(2)` `source` over `destination`, atomically replacing it.
    private static func replace(_ destination: URL, with source: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return rename(src, dst)
            }
        }
        if result != 0 { throw posixError(destination) }
    }

    private static func posixError(_ url: URL) -> CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [
            NSFilePathErrorKey: url.path,
            NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
        ])
    }
}

/// Locates Armadale's state directory.
public enum StateLocation {
    /// Environment variable that overrides the state directory (tests, debugging).
    public static let overrideVariable = "ARMADALE_STATE_DIR"

    /// `~/Library/Application Support/Armadale/`, or the directory named by
    /// ``overrideVariable`` when set.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment[overrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Armadale", isDirectory: true)
    }

    /// `state.json` inside ``directory(environment:fileManager:)``.
    public static func stateFile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        directory(environment: environment, fileManager: fileManager).appendingPathComponent(StateStore.fileName)
    }
}
