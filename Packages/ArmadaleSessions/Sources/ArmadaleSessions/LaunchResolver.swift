import ArmadaleCore
import Darwin
import Foundation

/// A session's launch, resolved to exactly what gets executed.
public struct ResolvedLaunch: Sendable, Hashable {
    /// Absolute path of the executable.
    public var program: String
    /// argv[0]. A leading `-` makes a shell a login shell.
    public var argv0: String
    /// argv[1...].
    public var arguments: [String]
    /// The complete environment.
    public var environment: [String: String]
    /// An existing directory to start in.
    public var workingDirectory: String

    public init(program: String, argv0: String, arguments: [String], environment: [String: String], workingDirectory: String) {
        self.program = program
        self.argv0 = argv0
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// Turns a ``Session``'s ``LaunchSpec`` into a program, argv and environment
/// (docs/DESIGN.md section 4, "Environment handed to new sessions").
///
/// - No program: the user's login shell as a login shell (`-zsh -l`).
/// - A program (`claude`, `codex`, …): run through the login shell as
///   `$SHELL -l -c 'exec <program> <args…>'`, so it is found on, and runs
///   with, the user's login `PATH` and environment rather than the app's
///   minimal launchd one.
public struct LaunchResolver: Sendable {
    /// Everything resolution reads from the outside world, injectable for tests.
    public struct Context: Sendable {
        /// The app's own environment, the base for every session.
        public var environment: [String: String]
        /// Absolute path of the user's login shell.
        public var loginShell: String
        /// `TERM_PROGRAM_VERSION`.
        public var appVersion: String
        /// The user's preferred locale, e.g. `en_AU`; used for `LANG` when unset.
        public var locale: Locale
        public var homeDirectory: String
        /// Whether a path is an existing directory.
        public var directoryExists: @Sendable (String) -> Bool

        public init(
            environment: [String: String],
            loginShell: String,
            appVersion: String,
            locale: Locale,
            homeDirectory: String,
            directoryExists: @escaping @Sendable (String) -> Bool
        ) {
            self.environment = environment
            self.loginShell = loginShell
            self.appVersion = appVersion
            self.locale = locale
            self.homeDirectory = homeDirectory
            self.directoryExists = directoryExists
        }

        /// The running app's context.
        public static var current: Context {
            Context(
                environment: ProcessInfo.processInfo.environment,
                loginShell: LaunchResolver.userLoginShell(),
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                locale: Locale.autoupdatingCurrent,
                homeDirectory: NSHomeDirectory(),
                directoryExists: { path in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                })
        }
    }

    public var context: Context

    public init(context: Context = .current) {
        self.context = context
    }

    /// Variables never passed on: `ZMX_SESSION*` would turn a zmx attach into
    /// a session switch (docs/DESIGN.md section 4); the rest describe the
    /// terminal or debugger Armadale itself was started from, and would
    /// mislead programs (and shell integrations) in its sessions.
    static let removedVariables: Set<String> = [
        "ZMX_SESSION", "ZMX_SESSION_PREFIX",
        "TERM_SESSION_ID", "LC_TERMINAL", "LC_TERMINAL_VERSION", "VTE_VERSION", "WINDOWID",
        "TMUX", "TMUX_PANE", "STY", "ALACRITTY_WINDOW_ID", "ALACRITTY_SOCKET", "ALACRITTY_LOG",
        "TERMINFO", "COLORFGBG", "XPC_SERVICE_NAME",
        "SHLVL", "OLDPWD", "_", "OS_ACTIVITY_DT_MODE", "NSUnbufferedIO",
    ]
    static let removedPrefixes = [
        "DYLD_", "__XPC_DYLD_", "__XCODE_", "ITERM_", "KITTY_", "GHOSTTY_", "WEZTERM_", "ARMADALE_",
    ]

    /// Resolves `session`.
    public func resolve(_ session: Session) -> ResolvedLaunch {
        let shell = context.loginShell
        let shellName = (shell as NSString).lastPathComponent
        let launch = session.launch
        let arguments: [String]
        if let program = launch.program, !program.isEmpty {
            let command = ([program] + launch.arguments).map(Self.shellQuoted).joined(separator: " ")
            arguments = ["-l", "-c", "exec " + command]
        } else {
            arguments = ["-l"] + launch.arguments
        }
        let directory = workingDirectory(for: session)
        return ResolvedLaunch(
            program: shell,
            argv0: "-" + shellName,
            arguments: arguments,
            environment: environment(for: session, workingDirectory: directory),
            workingDirectory: directory)
    }

    /// The session's directory with `~` expanded, or home if it no longer exists.
    func workingDirectory(for session: Session) -> String {
        var path = session.workingDirectory
        if path == "~" {
            path = context.homeDirectory
        } else if path.hasPrefix("~/") {
            path = context.homeDirectory + path.dropFirst(1)
        }
        guard path.hasPrefix("/"), context.directoryExists(path) else { return context.homeDirectory }
        return path
    }

    /// `environment` without the variables that describe whatever Armadale
    /// was started from (and without `ZMX_SESSION*`): the base for sessions
    /// and for helper processes such as zmx control commands.
    public static func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !removedVariables.contains(key) && !removedPrefixes.contains { key.hasPrefix($0) }
        }
    }

    func environment(for session: Session, workingDirectory: String) -> [String: String] {
        var environment = Self.scrubbed(context.environment)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Armadale"
        environment["TERM_PROGRAM_VERSION"] = context.appVersion
        environment["ARMADALE_SESSION_ID"] = session.id.raw
        environment["PWD"] = workingDirectory
        if environment["LANG", default: ""].isEmpty {
            environment["LANG"] = lang()
        }
        if environment["SHELL", default: ""].isEmpty {
            environment["SHELL"] = context.loginShell
        }
        if environment["HOME", default: ""].isEmpty {
            environment["HOME"] = context.homeDirectory
        }
        if environment["PATH", default: ""].isEmpty {
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        // The profile's variables win, except names it may not set at all
        // (Armadale's own and the session runtime's, or malformed ones).
        let profile = session.launch.environment.filter { Profile.environmentNameProblem($0.key) == nil }
        environment.merge(profile) { _, profile in profile }
        // Scrubbed after the merge too: no runtime variable reaches a
        // session, whatever it came from.
        return environment.filter { !$0.key.hasPrefix("ZMX_") }
    }

    /// `LANG` for the user's locale, e.g. `en_AU.UTF-8`, if the system has
    /// that locale; else `en_US.UTF-8`.
    func lang() -> String {
        let fallback = "en_US.UTF-8"
        guard let language = context.locale.language.languageCode?.identifier,
              let region = context.locale.region?.identifier
        else { return fallback }
        let name = "\(language)_\(region).UTF-8"
        return context.directoryExists("/usr/share/locale/\(name)") ? name : fallback
    }

    /// The login shell from the user database, or `/bin/zsh`.
    public static func userLoginShell() -> String {
        if let entry = getpwuid(getuid()), let pointer = entry.pointee.pw_shell {
            let shell = String(cString: pointer)
            if shell.hasPrefix("/"), access(shell, X_OK) == 0 { return shell }
        }
        return "/bin/zsh"
    }

    /// Quotes `word` for POSIX shells.
    static func shellQuoted(_ word: String) -> String {
        // No `=`: zsh expands a word starting with `=` (`=ls` is /bin/ls).
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:,+@%")
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
