import ArmadaleCore
import Foundation
import Testing
@testable import ArmadaleSessions

@Suite("LaunchResolver")
struct LaunchResolverTests {
    private func resolver(
        environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": "/Users/me", "SHELL": "/bin/zsh"],
        locale: String = "en_AU",
        existing: Set<String> = ["/Users/me", "/work", "/usr/share/locale/en_AU.UTF-8"]
    ) -> LaunchResolver {
        LaunchResolver(context: LaunchResolver.Context(
            environment: environment,
            loginShell: "/bin/zsh",
            appVersion: "1.2.3",
            locale: Locale(identifier: locale),
            homeDirectory: "/Users/me",
            directoryExists: { existing.contains($0) }))
    }

    private func session(_ launch: LaunchSpec = LaunchSpec(), directory: String = "/work") -> Session {
        Session(profileID: Profile.shell.id, launch: launch, workingDirectory: directory)
    }

    @Test func noProgramMeansLoginShell() {
        let launch = resolver().resolve(session())
        #expect(launch.program == "/bin/zsh")
        #expect(launch.argv0 == "-zsh")
        #expect(launch.arguments == ["-l"])
        #expect(launch.workingDirectory == "/work")
    }

    @Test func programRunsThroughLoginShellQuoted() {
        let launch = resolver().resolve(session(LaunchSpec(program: "claude", arguments: ["--model", "it's big", "a b"])))
        #expect(launch.program == "/bin/zsh")
        #expect(launch.argv0 == "-zsh")
        #expect(launch.arguments == ["-l", "-c", "exec claude --model 'it'\\''s big' 'a b'"])
    }

    @Test func environmentFollowsDesign() {
        let s = session()
        let environment = resolver(environment: [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/me", "SHELL": "/bin/zsh",
            "TERM": "dumb", "TERM_PROGRAM": "ghostty", "ZMX_SESSION": "x", "ZMX_SESSION_PREFIX": "y",
            "TMUX": "/tmp/tmux", "GHOSTTY_RESOURCES_DIR": "/g", "DYLD_LIBRARY_PATH": "/d", "SHLVL": "3",
            "ARMADALE_STATE_DIR": "/s", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0", "SSH_AUTH_SOCK": "/agent",
            "TERMINFO": "/ghostty/terminfo", "COLORFGBG": "15;0", "XPC_SERVICE_NAME": "application.com.mitchellh.ghostty",
        ]).resolve(s).environment
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "Armadale")
        #expect(environment["TERM_PROGRAM_VERSION"] == "1.2.3")
        #expect(environment["ARMADALE_SESSION_ID"] == s.id.raw)
        #expect(environment["PWD"] == "/work")
        #expect(environment["LANG"] == "en_AU.UTF-8")
        for removed in ["ZMX_SESSION", "ZMX_SESSION_PREFIX", "TMUX", "GHOSTTY_RESOURCES_DIR", "DYLD_LIBRARY_PATH",
                        "SHLVL", "ARMADALE_STATE_DIR", "TERMINFO", "COLORFGBG", "XPC_SERVICE_NAME"] {
            #expect(environment[removed] == nil, "\(removed) should be removed")
        }
        // The app's own environment is otherwise passed on.
        #expect(environment["__CF_USER_TEXT_ENCODING"] == "0x1F5:0x0:0x0")
        #expect(environment["SSH_AUTH_SOCK"] == "/agent")
        #expect(environment["PATH"] == "/usr/bin:/bin")
    }

    @Test func existingLangIsKeptAndUnknownLocaleFallsBack() {
        let kept = resolver(environment: ["LANG": "de_DE.UTF-8"]).resolve(session()).environment
        #expect(kept["LANG"] == "de_DE.UTF-8")
        let fallback = resolver(environment: [:], locale: "xx_YY").resolve(session()).environment
        #expect(fallback["LANG"] == "en_US.UTF-8")
        // Missing basics are filled in.
        #expect(fallback["SHELL"] == "/bin/zsh")
        #expect(fallback["HOME"] == "/Users/me")
        #expect(fallback["PATH"] != nil)
    }

    @Test func profileEnvironmentIsMergedLast() {
        let launch = LaunchSpec(environment: ["TERM": "xterm-direct", "EDITOR": "vim"])
        let environment = resolver().resolve(session(launch)).environment
        #expect(environment["TERM"] == "xterm-direct")
        #expect(environment["EDITOR"] == "vim")
    }

    @Test func missingDirectoryFallsBackToHomeAndTildeExpands() {
        #expect(resolver().resolve(session(directory: "/gone")).workingDirectory == "/Users/me")
        #expect(resolver().resolve(session(directory: "~")).workingDirectory == "/Users/me")
        #expect(resolver(existing: ["/Users/me/src"]).resolve(session(directory: "~/src")).workingDirectory == "/Users/me/src")
    }

    @Test func userLoginShellIsAnExecutable() {
        let shell = LaunchResolver.userLoginShell()
        #expect(shell.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: shell))
    }

    @Test func quotingProtectsZshSpecialWords() async throws {
        #expect(LaunchResolver.shellQuoted("=ls") == "'=ls'")
        #expect(LaunchResolver.shellQuoted("--model=opus") == "'--model=opus'")
        #expect(LaunchResolver.shellQuoted("") == "''")
        #expect(LaunchResolver.shellQuoted("plain-word_1.2/x") == "plain-word_1.2/x")
        // And zsh really receives the words verbatim.
        let words = ["=ls", "a b", "it's", "$HOME", "*", "~", "!x"]
        let command = "printf '%s\\n' " + words.map(LaunchResolver.shellQuoted).joined(separator: " ")
        let process = try PTYProcess.spawn(
            program: "/bin/zsh", arguments: ["-f", "-c", command],
            environment: testEnvironment(), size: PTYSize(columns: 80, rows: 24))
        let text = await OutputCollector(process.output).waitForEnd()
        #expect(text == words.joined(separator: "\n") + "\n")
    }
}
