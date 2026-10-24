/// How a session's program ended, as far as Armadale knows
/// (docs/DESIGN.md section 4, "Ended").
public enum ProgramExit: Sendable, Hashable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    /// It exited by itself (`exit(N)`, `return` from main) with this status.
    case exited(Int32)
    /// It was ended by this signal.
    case signaled(Int32)

    /// An integer literal is a normal exit.
    public init(integerLiteral value: Int32) {
        self = .exited(value)
    }

    /// The status as a shell reports it: N for a normal exit, 128 + N for a
    /// death by signal N.
    public var status: Int32 {
        switch self {
        case .exited(let code): code
        case .signaled(let signal): 128 + signal
        }
    }

    public var description: String {
        switch self {
        case .exited(let code): "exited(\(code))"
        case .signaled(let signal): "signaled(\(signal))"
        }
    }
}

/// What happens to a pane when its session's program ends.
public enum EndedPaneAction: Sendable, Hashable {
    /// Close the pane, as its Close Pane button would (nothing runs in it,
    /// so without asking). That may close its tab, its tab group, and its
    /// workspace with its window.
    case closePane
    /// Keep the pane, showing the Session Ended placeholder over the last
    /// screen, with how the program ended when that is known.
    case keepPlaceholder
}

/// The rule for a pane whose session ended. A program that exited by itself
/// with status 0 takes its pane with it. So does the user's shell when it
/// exits by itself with any status: a shell's `exit` and ^D report the last
/// command's status (130 after a ^C at the prompt, 1 after a failed
/// command), and leaving the shell is what the user did. Anything else keeps
/// the placeholder, so what went wrong stays readable: a non-shell program's
/// non-zero status, a death by signal, an unknown end. Where the pane is
/// does not matter: a workspace's only pane closes too, and with it the
/// workspace and its window (October 23, 2026; until then it kept the
/// placeholder).
public enum EndedSessionRule {
    /// Program names (basenames) that count as the user's shell when a
    /// profile names one explicitly.
    public static let shellNames: Set<String> = ["sh", "bash", "zsh", "fish", "tcsh", "csh", "ksh", "dash", "nu"]

    /// Whether `launch` runs the user's shell: no program of its own (the
    /// login shell), or a program that is a shell by name.
    public static func runsShell(_ launch: LaunchSpec) -> Bool {
        guard let program = launch.program, !program.isEmpty else { return true }
        let name = program.split(separator: "/").last.map(String.init) ?? program
        return shellNames.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }

    public static func action(exit: ProgramExit?, runsShell: Bool) -> EndedPaneAction {
        guard case .exited(let status)? = exit else { return .keepPlaceholder }
        return status == 0 || runsShell ? .closePane : .keepPlaceholder
    }
}

extension AppModel {
    /// Applies ``EndedSessionRule`` to the pane showing `session`, whose
    /// program ended as `exit` says: closes it (``closePane(_:)``, which may
    /// close its tab, its tab group and its workspace too) or leaves it.
    /// Returns the closed pane, if any.
    @discardableResult
    public func closePaneIfSessionEndedCleanly(_ session: SessionID, exit: ProgramExit?) -> PaneID? {
        guard let place = place(of: session), let launch = self.session(session)?.launch,
              EndedSessionRule.action(exit: exit, runsShell: EndedSessionRule.runsShell(launch)) == .closePane
        else { return nil }
        closePane(place.pane)
        return place.pane
    }
}
