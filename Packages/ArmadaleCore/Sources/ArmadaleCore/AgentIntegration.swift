import Foundation

/// How an agent is made to tell its terminal that it finished or needs
/// input, so the pane gets attention (DESIGN §10). Researched against the
/// installed agents and their sources, not guessed:
///
/// - **Claude Code 2.1.292.** Its terminal notifications go through the
///   `preferredNotifChannel` setting. `auto` (the default) picks a method
///   only for Apple Terminal, iTerm2, Kitty and Ghostty (by
///   `TERM_PROGRAM`) and sends nothing in any other terminal, Armadale
///   included; `ghostty` sends `OSC 777;notify;<title>;<message>`. It fires
///   after 60 s waiting for input (`messageIdleNotifThresholdMs`, a global
///   config key with no command-line form), on permission prompts and on
///   sign-in and usage-limit events. `--settings <json>` passes settings for
///   one session, above the user's own files, so a profile with
///   ``Profile/attentionIntegration`` on adds ``launchArguments``. A signal
///   the moment Claude stops needs a `Stop` hook (``hookSnippet(helperPath:)``).
/// - **Codex 0.163.0.** Nothing to pass: in a terminal it does not know
///   (`TERM_PROGRAM=Armadale`) its default `tui.notification_method =
///   "auto"` rings BEL, and its default `tui.notification_condition =
///   "unfocused"` uses focus reports (DECSET 1004), which Armadale's
///   SwiftTerm surfaces send, so it rings exactly when the pane is not the
///   focused one of the key window. Command-line `-c` overrides were tried
///   and dropped: they make Codex start "without the shared background
///   server". `notify` and `tui.notification_method = "osc9"` (message text
///   instead of a bell) are optional user settings (``hookSnippet(helperPath:)``).
public struct AgentIntegration: Sendable, Hashable {
    public var flavor: AgentFlavor
    /// Arguments added in front of a profile's own when its
    /// ``Profile/attentionIntegration`` is on. Empty when the agent needs none.
    public var launchArguments: [String]
    /// The Profiles editor's toggle for ``launchArguments``; `nil` when
    /// there is nothing to toggle.
    public var toggleTitle: String?
    /// What happens, for the Profiles editor.
    public var summary: String
    /// The file the optional settings go in.
    public var hookFile: String
    /// What the optional settings add.
    public var hookSummary: String

    /// Name of the helper script in the app bundle's `Contents/Resources`.
    public static let notifyHelperName = "armadale-notify"

    public static let claudeCode = AgentIntegration(
        flavor: .claudeCode,
        launchArguments: ["--settings", #"{"preferredNotifChannel":"ghostty"}"#],
        toggleTitle: "Signal attention when Claude Code needs input (sets the notification channel for this session)",
        summary: "When this is on, Armadale starts Claude Code with --settings {\"preferredNotifChannel\":\"ghostty\"}. "
            + "Claude Code then sends a notification sequence when it has waited a minute for your input, when it "
            + "asks for permission, and on sign-in or usage-limit events. This overrides your own "
            + "preferredNotifChannel (even notifications_disabled) for sessions started from this profile; your "
            + "settings files are not changed. Turn it off to keep your own channel.",
        hookFile: "~/.claude/settings.json",
        hookSummary: "To get attention the moment Claude stops, add a Stop hook that runs Armadale’s "
            + "notify helper. The helper does nothing outside Armadale.")

    public static let codex = AgentIntegration(
        flavor: .codex,
        launchArguments: [],
        toggleTitle: nil,
        summary: "Codex needs no arguments: with its defaults it rings the bell when a turn completes or it "
            + "asks for approval while its pane isn’t the focused one (Armadale reports focus to it), unless "
            + "you turned tui.notifications off.",
        hookFile: "~/.codex/config.toml",
        hookSummary: "Optional: notification_method = \"osc9\" makes Codex send its message text instead of "
            + "a plain bell (add it to your [tui] table, or create one). Codex’s notify command can also run "
            + "Armadale’s notify helper after every turn; notify must be at the top of the file, before any "
            + "[table], and it replaces any notify you already have.")

    /// The integration for `flavor`, if Armadale knows one.
    public static func `for`(_ flavor: AgentFlavor) -> AgentIntegration? {
        switch flavor {
        case .claudeCode: claudeCode
        case .codex: codex
        case .other: nil
        }
    }

    /// The exact text to add to ``hookFile``, with the helper at `helperPath`.
    public func hookSnippet(helperPath: String) -> String {
        switch flavor {
        case .claudeCode:
            let command = Self.posixQuoted(helperPath) + " 'Claude Code' 'Finished'"
            return """
            {
              "hooks": {
                "Stop": [
                  { "hooks": [ { "type": "command", "command": \(Self.jsonQuoted(command)) } ] }
                ]
              }
            }
            """
        case .codex, .other:
            return """
            notify = [\(Self.tomlQuoted(helperPath)), "Codex", "Turn complete"]

            [tui]
            notification_method = "osc9"
            """
        }
    }

    /// `'…'` for a POSIX shell.
    static func posixQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func jsonQuoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func tomlQuoted(_ text: String) -> String {
        jsonQuoted(text) // TOML basic strings use the same escapes
    }
}

extension Profile {
    /// A saved built-in profile with what it runs taken from this version
    /// of Armadale; its name, icon and attention toggle are the user's.
    /// Other profiles are returned unchanged.
    static func refreshingBuiltIn(_ saved: Profile) -> Profile {
        guard let shipped = builtIns.first(where: { $0.id == saved.id }) else { return saved }
        var profile = shipped
        profile.name = saved.name
        profile.icon = saved.icon
        profile.attentionIntegration = saved.attentionIntegration
        return profile
    }
}
