/// The zmx release Armadale bundles. Must equal the `version` line of
/// `scripts/zmx.lock` (a test checks this). It names the installed helper
/// copy (`bin/zmx-<version>`) and is recorded on every session the bundled
/// zmx creates (`Session.runtimeVersion`), so a later Armadale with a newer
/// zmx keeps attaching that session with the binary that created it
/// (docs/DESIGN.md section 13: zmx has no version handshake).
public enum ZmxVersion {
    public static let current = "0.8.1"
}
