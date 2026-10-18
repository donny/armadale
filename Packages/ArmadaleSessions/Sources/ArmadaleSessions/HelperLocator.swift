import Darwin
import Foundation
import MachO

/// Finds the helper executables Armadale bundles.
public enum HelperLocator {
    /// A helper could not be found.
    public struct NotFound: Error, CustomStringConvertible, Sendable {
        public let name: String
        public let searched: [String]
        /// The override variable named a path that is not an executable.
        public var badOverride: (variable: String, path: String)?

        public init(name: String, searched: [String], badOverride: (variable: String, path: String)? = nil) {
            self.name = name
            self.searched = searched
            self.badOverride = badOverride
        }

        public var description: String {
            if let badOverride {
                return "\(badOverride.variable) is set to \(badOverride.path), which is not an executable file. "
                    + "Fix or unset it; Armadale does not fall back to another \(name) when it is set."
            }
            let hint = name == "zmx"
                ? "Run scripts/fetch-zmx.sh to download the pinned zmx release into Vendor/zmx, or set \(HelperLocator.zmxOverride)."
                : "Build the app (or `swift build` in Packages/ArmadaleSessions), or set \(HelperLocator.cttyExecOverride)."
            return "Armadale's \(name) helper was not found. Looked in: \(searched.joined(separator: ", ")). " + hint
        }
    }

    /// Environment variable that overrides the `ctty-exec` location.
    public static let cttyExecOverride = "ARMADALE_CTTY_EXEC"

    /// The `ctty-exec` trampoline, looked up in order:
    /// 1. `$ARMADALE_CTTY_EXEC`;
    /// 2. `Contents/Helpers/ctty-exec` of the main bundle;
    /// 3. next to the running test bundle (SwiftPM and Xcode put executable
    ///    products in the same directory as `.xctest` bundles).
    public static func cttyExec(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        mainBundle: Bundle = .main
    ) throws(NotFound) -> URL {
        try locate("ctty-exec", override: environment[cttyExecOverride], overrideVariable: cttyExecOverride, mainBundle: mainBundle)
    }

    /// Environment variable that overrides the `zmx` location.
    public static let zmxOverride = "ARMADALE_ZMX"

    /// The bundled `zmx` (not the installed copy that sessions run; see
    /// ``HelperInstaller``), looked up in order:
    /// 1. `$ARMADALE_ZMX`;
    /// 2. `Contents/Helpers/zmx` of the main bundle;
    /// 3. `Vendor/zmx/macos-<arch>/zmx` in the source tree, where
    ///    `scripts/fetch-zmx.sh` puts it (SwiftPM and Xcode package tests).
    public static func zmx(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        mainBundle: Bundle = .main
    ) throws(NotFound) -> URL {
        try locate("zmx", override: environment[zmxOverride], overrideVariable: zmxOverride, mainBundle: mainBundle, extra: vendoredZmx)
    }

    /// `Vendor/zmx/macos-<arch>/zmx` of the repository this file was built from.
    public static var vendoredZmx: URL {
        #if arch(arm64)
        vendoredZmx(platform: "macos-aarch64")
        #else
        vendoredZmx(platform: "macos-x86_64")
        #endif
    }

    /// `Vendor/zmx/<platform>/zmx` of the repository this file was built from.
    public static func vendoredZmx(platform: String) -> URL {
        // Sources/ArmadaleSessions/HelperLocator.swift → repository root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ArmadaleSessions
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Packages/ArmadaleSessions
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository
            .appending(path: "Vendor/zmx/\(platform)/zmx")
    }

    /// The zmx binary Armadale deploys to a host of `platform`
    /// (docs/DESIGN.md section 6), looked up in order:
    /// 1. in the main bundle: `Contents/Resources/remote/zmx-<platform>` for
    ///    Linux (data, copied there by scripts/embed-zmx.sh), the universal
    ///    `Contents/Helpers/zmx` for macOS;
    /// 2. `Vendor/zmx/<platform>/zmx` in the source tree (tests, and runs
    ///    of a build without the bundled copies).
    public static func remoteZmx(for platform: RemotePlatform, mainBundle: Bundle = .main) throws(NotFound) -> URL {
        let bundled: URL = switch platform {
        case .linuxAarch64, .linuxX86_64:
            mainBundle.bundleURL.appending(path: "Contents/Resources/remote/zmx-\(platform.rawValue)")
        case .macosAarch64, .macosX86_64:
            mainBundle.bundleURL.appending(path: "Contents/Helpers/zmx")
        }
        let candidates = [bundled, vendoredZmx(platform: platform.rawValue)]
        for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate.path) {
            return candidate
        }
        throw NotFound(name: "zmx for \(platform.rawValue)", searched: candidates.map(\.path))
    }

    static func locate(
        _ name: String, override: String?, overrideVariable: String? = nil, mainBundle: Bundle, extra: URL? = nil
    ) throws(NotFound) -> URL {
        // An explicit override is used or it is an error, never skipped: a
        // silent fallback would hide a mistake in a test setup.
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard isExecutableFile(url) else {
                let error = NotFound(
                    name: name, searched: [override],
                    badOverride: (overrideVariable ?? "The override for \(name)", override))
                NSLog("Armadale: %@", error.description)
                throw error
            }
            return url
        }
        // Candidates are produced lazily: the test-bundle lookup walks the
        // loaded images and is only needed when the others fail.
        let candidates: [() -> URL?] = [
            { mainBundle.bundleURL.appending(path: "Contents/Helpers/\(name)") },
            { extra ?? productsDirectory()?.appending(path: name) },
        ]
        var searched: [String] = []
        for candidate in candidates {
            guard let url = candidate() else { continue }
            if isExecutableFile(url) { return url }
            searched.append(url.path)
        }
        throw NotFound(name: name, searched: searched)
    }

    /// The directory holding the loaded `.xctest` bundle, if tests are running.
    static func productsDirectory() -> URL? {
        if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        // swift-testing's runner may load the bundle with dlopen, which
        // `Bundle.allBundles` does not list; look through the loaded images.
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            if let range = path.range(of: ".xctest/") {
                let bundlePath = String(path[..<range.lowerBound]) + ".xctest"
                return URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
            }
        }
        return nil
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && access(url.path, X_OK) == 0
    }
}
