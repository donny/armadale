import Darwin
import Foundation
import MachO

/// Finds the helper executables Armadale bundles.
public enum HelperLocator {
    /// A helper could not be found.
    public struct NotFound: Error, CustomStringConvertible, Sendable {
        public let name: String
        public let searched: [String]
        public var description: String {
            "Armadale's \(name) helper was not found. Looked in: \(searched.joined(separator: ", ")). "
                + "Build the app (or `swift build` in Packages/ArmadaleSessions), or set the override variable."
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
        try locate("ctty-exec", override: environment[cttyExecOverride], mainBundle: mainBundle)
    }

    static func locate(_ name: String, override: String?, mainBundle: Bundle) throws(NotFound) -> URL {
        // Candidates are produced lazily: the test-bundle lookup walks the
        // loaded images and is only needed when the others fail.
        let candidates: [() -> URL?] = [
            { override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } },
            { mainBundle.bundleURL.appending(path: "Contents/Helpers/\(name)") },
            { productsDirectory()?.appending(path: name) },
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
