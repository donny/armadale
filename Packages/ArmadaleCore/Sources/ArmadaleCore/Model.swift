import Foundation

/// A window's worth of tab groups. Closing the window keeps the workspace;
/// only an explicit delete removes it.
public struct Workspace: Identifiable, Codable, Sendable, Hashable {
    public let id: WorkspaceID
    public var name: String
    public var tabGroups: [TabGroup]
    public var selectedTabGroupID: TabGroupID?
    /// Window geometry and visibility; `nil` until the workspace is first shown.
    public var window: WindowState?

    public init(
        id: WorkspaceID = .generate(),
        name: String,
        tabGroups: [TabGroup] = [],
        selectedTabGroupID: TabGroupID? = nil,
        window: WindowState? = nil
    ) {
        self.id = id
        self.name = name
        self.tabGroups = tabGroups
        self.selectedTabGroupID = selectedTabGroupID ?? tabGroups.first?.id
        self.window = window
    }

    /// The selected tab group, if any.
    public var selectedTabGroup: TabGroup? {
        tabGroups.first { $0.id == selectedTabGroupID }
    }
}

/// A rectangle in screen points, independent of CoreGraphics so the model
/// stays free of UI frameworks.
public struct WindowFrame: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Persisted window state of a workspace.
public struct WindowState: Codable, Sendable, Hashable {
    /// Last known frame, or `nil` to let the app pick a default.
    public var frame: WindowFrame?
    /// Width of the sidebar in points, or `nil` for the default.
    public var sidebarWidth: Double?
    /// Whether the sidebar is collapsed.
    public var sidebarCollapsed: Bool
    /// Whether the window was open at last save; open windows are restored at launch.
    public var isOpen: Bool

    public init(frame: WindowFrame? = nil, sidebarWidth: Double? = nil, sidebarCollapsed: Bool = false, isOpen: Bool = true) {
        self.frame = frame
        self.sidebarWidth = sidebarWidth
        self.sidebarCollapsed = sidebarCollapsed
        self.isOpen = isOpen
    }
}

/// A named folder of tabs, shown in the sidebar.
public struct TabGroup: Identifiable, Codable, Sendable, Hashable {
    public let id: TabGroupID
    public var name: String
    public var tabs: [Tab]
    public var selectedTabID: TabID?

    public init(id: TabGroupID = .generate(), name: String, tabs: [Tab] = [], selectedTabID: TabID? = nil) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.selectedTabID = selectedTabID ?? tabs.first?.id
    }

    /// The selected tab, if any.
    public var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }
}

/// A tab: a binary split tree of panes.
public struct Tab: Identifiable, Codable, Sendable, Hashable {
    public let id: TabID
    /// User-assigned title; `nil` means "derive from the focused pane's session".
    public var customTitle: String?
    public var layout: PaneLayout
    /// The panes referenced by `layout`'s leaves, mapping each pane to its session.
    public var panes: [Pane]
    public var focusedPaneID: PaneID
    public var zoomedPaneID: PaneID?

    public init(
        id: TabID = .generate(),
        customTitle: String? = nil,
        layout: PaneLayout,
        panes: [Pane],
        focusedPaneID: PaneID,
        zoomedPaneID: PaneID? = nil
    ) {
        self.id = id
        self.customTitle = customTitle
        self.layout = layout
        self.panes = panes
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
    }

    /// Creates a tab holding a single pane.
    public init(id: TabID = .generate(), pane: Pane) {
        self.init(id: id, layout: .pane(pane.id), panes: [pane], focusedPaneID: pane.id)
    }

    /// The pane record for `id`, if it belongs to this tab.
    public func pane(_ id: PaneID) -> Pane? {
        panes.first { $0.id == id }
    }
}

/// A rectangle in a tab's split tree. A pane always has exactly one session.
public struct Pane: Identifiable, Codable, Sendable, Hashable {
    public let id: PaneID
    public var sessionID: SessionID

    public init(id: PaneID = .generate(), sessionID: SessionID) {
        self.id = id
        self.sessionID = sessionID
    }
}

/// Where a session runs.
public enum Location: Codable, Sendable, Hashable {
    /// On this Mac.
    case local
    /// On an SSH host.
    case remote(host: HostID)
}

/// The fully resolved command a session was created with. Stored on the
/// session, so editing a profile never changes a running session; a
/// respawn takes the profile as it is then, and this launch only if the
/// profile was deleted (``AppModel/launchForRespawn(of:)``).
public struct LaunchSpec: Codable, Sendable, Hashable {
    /// Executable to run; `nil` means the user's login shell.
    public var program: String?
    public var arguments: [String]
    public var environment: [String: String]

    public init(program: String? = nil, arguments: [String] = [], environment: [String: String] = [:]) {
        self.program = program
        self.arguments = arguments
        self.environment = environment
    }
}

/// The persistent unit of work: a process in a working directory, local or remote.
public struct Session: Identifiable, Codable, Sendable, Hashable {
    public let id: SessionID
    public var location: Location
    public var profileID: ProfileID
    public var launch: LaunchSpec
    public var workingDirectory: String
    /// Last title set by the program (OSC 0/2), for display.
    public var title: String
    public var createdAt: Date
    /// Version of the session runtime (zmx) that created the daemon, so a
    /// later Armadale can detect a protocol mismatch. `nil` for ephemeral
    /// sessions and for sessions not yet started. Optional, so state files
    /// written before it existed decode unchanged.
    public var runtimeVersion: String?

    public init(
        id: SessionID = .generate(),
        location: Location = .local,
        profileID: ProfileID,
        launch: LaunchSpec,
        workingDirectory: String,
        title: String = "",
        createdAt: Date = Date(),
        runtimeVersion: String? = nil
    ) {
        self.id = id
        self.location = location
        self.profileID = profileID
        self.launch = launch
        self.workingDirectory = workingDirectory
        self.title = title
        self.createdAt = createdAt
        self.runtimeVersion = runtimeVersion
    }
}

extension Session {
    /// The host a remote session runs on; `nil` for a local one.
    public var remoteHostID: HostID? {
        if case .remote(let host) = location { return host }
        return nil
    }
}

/// An SSH target.
public struct Host: Identifiable, Codable, Sendable, Hashable {
    public let id: HostID
    /// Display name.
    public var name: String
    /// `user@host` or an `ssh_config` alias.
    public var sshDestination: String
    public var port: Int?
    public var identityFile: String?
    /// An ssh configuration file passed as `ssh -F` instead of the user's
    /// own `~/.ssh/config` (and the system one), e.g. the file
    /// `limactl show-ssh --format=config` writes for a Lima VM. `nil` uses
    /// the user's configuration.
    public var sshConfigFile: String?
    /// Where Armadale keeps its helper and runtime files on the host: an
    /// absolute path, or one under the home directory (`~/…`).
    public var remoteDirectory: String

    /// The default ``remoteDirectory``.
    public static let defaultRemoteDirectory = "~/.armadale"

    public init(
        id: HostID = .generate(),
        name: String,
        sshDestination: String,
        port: Int? = nil,
        identityFile: String? = nil,
        sshConfigFile: String? = nil,
        remoteDirectory: String = Host.defaultRemoteDirectory
    ) {
        self.id = id
        self.name = name
        self.sshDestination = sshDestination
        self.port = port
        self.identityFile = identityFile
        self.sshConfigFile = sshConfigFile
        self.remoteDirectory = remoteDirectory
    }

    /// The name shown for the host: its name, else its destination.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? sshDestination : trimmed
    }

    /// Why `destination` cannot be used to reach a host, or `nil` if it
    /// can: it must be non-empty, contain no whitespace or control
    /// characters, and not start with `-` (ssh would read it as an option).
    public static func destinationProblem(_ destination: String) -> String? {
        if destination.isEmpty { return "Enter a destination, such as user@example.com or a name from your SSH configuration." }
        if destination.hasPrefix("-") { return "A destination can’t start with “-”." }
        if destination.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return "A destination can’t contain spaces."
        }
        return nil
    }

    /// Why `directory` cannot be the remote directory, or `nil` if it can.
    /// Armadale creates it (private) and keeps everything there, so it must
    /// be a folder of its own: `~/…` or an absolute path, at least two
    /// levels deep (`~/.armadale`, `/opt/armadale`; never `~`, `/` or
    /// `/opt`), without `.` or `..` components or control characters.
    public static func remoteDirectoryProblem(_ directory: String) -> String? {
        if directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "The folder can’t contain control characters."
        }
        let components: [Substring]
        if directory.hasPrefix("~/") {
            components = ["~"] + directory.dropFirst(2).split(separator: "/")
        } else if directory.hasPrefix("/") {
            components = directory.split(separator: "/")
        } else {
            return "Use a full path, or one in your home folder on the host (starting with “~/”)."
        }
        if components.contains(where: { $0 == "." || $0 == ".." }) {
            return "The folder can’t contain “.” or “..”."
        }
        guard components.count >= 2 else {
            return "Use a folder of Armadale’s own, such as ~/.armadale, not your home folder or a top-level folder."
        }
        return nil
    }
}

/// The coding agent a profile launches. Unknown flavors round-trip as `.other`.
public enum AgentFlavor: Codable, Sendable, Hashable {
    case claudeCode
    case codex
    case other(String)

    /// Stable string used in JSON.
    public var rawValue: String {
        switch self {
        case .claudeCode: "claude-code"
        case .codex: "codex"
        case .other(let name): name
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "claude-code": self = .claudeCode
        case "codex": self = .codex
        default: self = .other(rawValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A launch template from which sessions are created.
public struct Profile: Identifiable, Codable, Sendable, Hashable {
    /// What kind of program a profile runs; drives icon and status rules.
    public enum Kind: Codable, Sendable, Hashable {
        /// The user's login shell.
        case shell
        /// An arbitrary command.
        case command
        /// A coding agent.
        case agent(AgentFlavor)

        private enum CodingKeys: String, CodingKey { case type, flavor }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "shell": self = .shell
            case "command": self = .command
            case "agent": self = .agent(try container.decode(AgentFlavor.self, forKey: .flavor))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container, debugDescription: "Unknown profile kind \(other)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .shell: try container.encode("shell", forKey: .type)
            case .command: try container.encode("command", forKey: .type)
            case .agent(let flavor):
                try container.encode("agent", forKey: .type)
                try container.encode(flavor, forKey: .flavor)
            }
        }
    }

    public let id: ProfileID
    public var name: String
    public var kind: Kind
    /// Executable to run; `nil` means the user's login shell.
    public var program: String?
    public var arguments: [String]
    public var environment: [String: String]
    /// SF Symbol name.
    public var icon: String
    /// For an agent Armadale knows (``AgentIntegration``): add the launch
    /// arguments that make it signal its pane (Claude Code's
    /// `--settings {"preferredNotifChannel":"ghostty"}`) in front of
    /// ``arguments`` at launch. On by default, also for the built-in, whose
    /// ``arguments`` stay fixed while this stays the user's choice. Saved
    /// state without it decodes as on.
    public var attentionIntegration: Bool

    public init(
        id: ProfileID = .generate(),
        name: String,
        kind: Kind,
        program: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        icon: String,
        attentionIntegration: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.program = program
        self.arguments = arguments
        self.environment = environment
        self.icon = icon
        self.attentionIntegration = attentionIntegration
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, program, arguments, environment, icon, attentionIntegration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProfileID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        program = try container.decodeIfPresent(String.self, forKey: .program)
        arguments = try container.decode([String].self, forKey: .arguments)
        environment = try container.decode([String: String].self, forKey: .environment)
        icon = try container.decode(String.self, forKey: .icon)
        // Added in step 7; profiles saved before it get the default.
        attentionIntegration = try container.decodeIfPresent(Bool.self, forKey: .attentionIntegration) ?? true
    }

    /// How this profile's agent signals its pane, if Armadale knows.
    public var agentIntegration: AgentIntegration? {
        guard case .agent(let flavor) = kind else { return nil }
        return AgentIntegration.for(flavor)
    }

    /// The arguments a session started from this profile gets: the agent
    /// integration's (when ``attentionIntegration`` is on), then ``arguments``.
    public var launchArguments: [String] {
        guard attentionIntegration, let integration = agentIntegration else { return arguments }
        return integration.launchArguments + arguments
    }

    /// The launch spec a new session created from this profile records.
    public var launchSpec: LaunchSpec {
        LaunchSpec(program: program, arguments: launchArguments, environment: environment)
    }
}

extension Profile {
    /// The user's login shell.
    public static let shell = Profile(
        id: ProfileID(raw: "builtin.shell"), name: "Shell", kind: .shell, icon: "terminal")
    /// Claude Code (`claude`). Its launch gets ``AgentIntegration/claudeCode``'s
    /// arguments while ``attentionIntegration`` is on (the default).
    public static let claudeCode = Profile(
        id: ProfileID(raw: "builtin.claude-code"), name: "Claude Code", kind: .agent(.claudeCode),
        program: "claude", icon: "sparkle")
    /// Codex (`codex`), with no arguments: its defaults already ring the
    /// bell in an unfocused Armadale pane (``AgentIntegration/codex``).
    public static let codex = Profile(
        id: ProfileID(raw: "builtin.codex"), name: "Codex", kind: .agent(.codex),
        program: "codex", icon: "chevron.left.forwardslash.chevron.right")

    /// Profiles that ship with Armadale, in menu order.
    public static let builtIns: [Profile] = [.shell, .claudeCode, .codex]

    /// Prefixes of environment variables that only Armadale sets: its own
    /// (`ARMADALE_SESSION_ID`) and its session runtime's. A profile can
    /// never set them; they would reach, or misdirect, the session helper.
    public static let reservedEnvironmentPrefixes = ["ARMADALE_", "ZMX_"]

    /// Why `name` cannot be one of a profile's environment variables, or
    /// `nil` if it can: it must be non-empty, contain no `=` or NUL, and not
    /// be reserved (``reservedEnvironmentPrefixes``).
    public static func environmentNameProblem(_ name: String) -> String? {
        if name.isEmpty { return "A variable needs a name." }
        if name.contains("=") { return "A variable name can’t contain “=”." }
        if name.contains("\0") { return "A variable name can’t contain a null character." }
        if name.contains(where: \.isWhitespace) { return "A variable name can’t contain spaces." }
        if reservedEnvironmentPrefixes.contains(where: { name.hasPrefix($0) }) {
            return "“\(name)” is set by Armadale itself and can’t be changed here."
        }
        return nil
    }

    /// Whether the profile runs a coding agent (the "Only for agent
    /// profiles" notification filter).
    public var isAgent: Bool {
        if case .agent = kind { return true }
        return false
    }

    /// Whether this is one of the ``builtIns``. Built-in profiles cannot be
    /// deleted, and only their name and icon can be changed.
    public var isBuiltIn: Bool {
        Profile.builtIns.contains { $0.id == id }
    }
}
