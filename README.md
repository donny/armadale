# Armadale

Armadale is a native macOS terminal for running and supervising a fleet of
persistent agent sessions (Claude Code, Codex, or plain shells). Sessions
survive app restarts, live locally or on SSH hosts, and are organised as
**Workspace → Tab Group → Tab → Pane**. The app uses AppKit for windows and
splits and SwiftUI for chrome. Terminal rendering sits behind a pluggable
`TerminalSurface` protocol, and SwiftTerm is the first renderer. Session
persistence comes from a private, bundled `zmx` daemon. Layout is stored as
versioned JSON in `~/Library/Application Support/Armadale/`.

Status: step 1 (skeleton): project, packages, data model, layout operations,
state persistence, and an empty window with a read-only sidebar.

The design is in [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- macOS 27, Xcode 27 (Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Generate, build, test

```sh
xcodegen generate     # creates Armadale.xcodeproj (git-ignored)

# Build the app
xcodebuild -project Armadale.xcodeproj -scheme Armadale \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -onlyUsePackageVersionsFromResolvedFile build

# Run every package's tests through the app scheme
xcodebuild -project Armadale.xcodeproj -scheme Armadale \
  -destination 'platform=macOS' -skipPackagePluginValidation test

# Or test a single package
(cd Packages/ArmadaleCore && swift test)
```

Dependency versions are locked in
`Armadale.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
It is the only tracked file inside the generated project, and
`xcodegen generate` leaves it alone. CI passes
`-onlyUsePackageVersionsFromResolvedFile`, so builds use exactly those
versions. To change a pin, edit `Packages/SwiftTermSurface/Package.swift`,
run `swift package resolve` in that directory, and copy the resulting
`Package.resolved` over the locked one.

SwiftTerm includes a build-tool plugin. On the command line you need
`-skipPackagePluginValidation`. In Xcode, choose **Trust & Enable** the first
time you build.

Set `ARMADALE_STATE_DIR=/some/dir` to point the app at a different state
directory, for example when debugging.

## Layout

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen spec (app target, scheme, signing) |
| `Armadale/` | AppKit app: lifecycle, menus, windows, SwiftUI sidebar |
| `Packages/ArmadaleCore` | Model, `PaneLayout` operations, `AppModel`, `StateStore`, migrations (no AppKit) |
| `Packages/ArmadaleSessions` | Session backends and process plumbing (protocols only so far) |
| `Packages/TerminalSurface` | Renderer protocol and appearance types |
| `Packages/SwiftTermSurface` | SwiftTerm adapter |
