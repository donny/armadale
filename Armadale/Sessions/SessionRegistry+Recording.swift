import AppKit
import ArmadaleCore
import ArmadaleSessions
import os
import UniformTypeIdentifiers

private let recordingLog = Logger(subsystem: "com.tinylittleapps.armadale", category: "recording")

/// Recording a pane (docs/DESIGN.md section 8, "Recording a pane"): the
/// pane menu's Record Pane… and Stop Recording, the header's stop button,
/// the tab's dot, and a recording that stopped because its file could not
/// be written. The recording itself is the controller's
/// (``SessionController/startRecording(to:title:)``, section 7).
extension SessionRegistry {
    /// The pane menu's Record Pane… for `session` (``PaneThemeBinding/record``):
    /// the save sheet of the window showing its pane, if that window is open.
    func recordPane(session: SessionID) {
        guard let workspace = model.place(of: session)?.workspace,
              let actions = actionsOfWorkspace(workspace)
        else { return }
        actions.recordPane(session: session)
    }

    /// Starts recording `session`'s pane into `url`, the header titled with
    /// the pane's title. Throws as the controller does, and refuses a file
    /// another recording is writing (`fileInUse`): one running, or one that
    /// has ended and whose writer has not closed the file yet.
    func startRecording(session: SessionID, to url: URL) throws(RecordingError) {
        guard let controller = controllers[session] else { throw .sessionEnded }
        func path(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        let wanted = path(url)
        let running = controllers.values.compactMap { $0.recording?.url }
        let writing = recordingWriters.filter { !$0.isClosed }.compactMap(\.url)
        if (running + writing).contains(where: { path($0) == wanted }) {
            throw .fileInUse(name: url.lastPathComponent)
        }
        try controller.startRecording(to: url, title: displayName(of: controller.session))
        recordingWriters.removeAll { $0.isClosed }
        if let writer = controller.recordingWriter { recordingWriters.append(writer) }
    }

    /// Stop Recording (the pane menu, the header's stop button).
    func stopRecording(session: SessionID) {
        controllers[session]?.stopRecording()
    }

    /// Whether any of `sessions` is being recorded: the tab bar's and the
    /// sidebar's red dot on a tab row. Not a ``SessionStatus``; it takes no
    /// part in the glyph's precedence. Observed through each controller's
    /// ``SessionController/recording``.
    func isRecording(anyOf sessions: some Sequence<SessionID>) -> Bool {
        sessions.contains { controllers[$0]?.isRecording ?? false }
    }

    /// Whether a pane of `tab` is being recorded: its red dot in the tab
    /// bar and the sidebar.
    func isRecording(_ tab: ArmadaleCore.Tab) -> Bool {
        isRecording(anyOf: tab.layout.leaves().compactMap { tab.pane($0)?.sessionID })
    }

    /// The longest a quit waits for recordings' files, all together.
    static let recordingQuitWait: Duration = .seconds(1)

    /// The quit (``detachAllNow()``, `applicationWillTerminate`): ends every
    /// running recording and waits for the files of all recordings of this
    /// run to be written and closed, the ones already ending (a stop, a
    /// closed pane, an ended session, End Sessions and Quit) included, at
    /// most ``recordingQuitWait`` from the first wait of this quit.
    func finishRecordingsForQuit() {
        for controller in controllers.values { controller.stopRecording() }
        let deadline = recordingQuitDeadline ?? .now + Self.recordingQuitWait
        recordingQuitDeadline = deadline
        RecordingFileWriter.waitForWriters(recordingWriters, until: deadline)
        recordingWriters.removeAll { $0.isClosed }
    }

    // MARK: Problems

    /// A recording stopped because its file could not be written: queued
    /// to be told (``showNextRecordingProblem(preferring:)``).
    func recordingFailed(_ controller: SessionController, failure: RecordingFailure) {
        recordingLog.error("A recording stopped: its file could not be written (\(failure.reason, privacy: .public))")
        queueRecordingProblem(.writeFailed(failure), workspace: model.place(of: controller.session.id)?.workspace)
    }

    /// Tells `problem` in its turn: on `workspace`'s window when it is
    /// open, else on the next workspace window that opens or becomes key.
    func queueRecordingProblem(_ problem: RecordingProblem, workspace: WorkspaceID?) {
        recordingProblems.append(QueuedRecordingProblem(problem: problem, workspace: workspace))
        showNextRecordingProblem()
    }

    /// Shows the first queued problem, unless one is up: on its pane's
    /// window if open, else on `preferred` (a window that just opened or
    /// became key); otherwise it waits.
    func showNextRecordingProblem(preferring preferred: WorkspaceActions? = nil) {
        guard !isShowingRecordingProblem, let next = recordingProblems.first else { return }
        let target = next.workspace.flatMap { actionsOfWorkspace($0) } ?? preferred
        guard let target, target.window != nil else { return }
        recordingProblems.removeFirst()
        isShowingRecordingProblem = true
        target.showRecordingProblem(next.problem) { [weak self] answered in
            guard let self else { return }
            self.isShowingRecordingProblem = false
            if answered {
                self.showNextRecordingProblem()
            } else {
                // Taken down unanswered (its window closed, a quit): told
                // again first, on the next window that becomes key.
                self.recordingProblems.insert(next, at: 0)
            }
        }
    }
}

/// A problem with a recording waiting to be told, and where.
struct QueuedRecordingProblem {
    var problem: RecordingProblem
    /// The workspace of the pane, when it still has one.
    var workspace: WorkspaceID?
}

/// What the alert about a recording says (``WorkspaceActions/showRecordingProblem(_:)``).
struct RecordingProblem: Equatable {
    var message: String
    var informative: String

    /// The recording could not start.
    static func couldNotStart(_ error: RecordingError) -> RecordingProblem {
        RecordingProblem(message: "The recording could not start.", informative: error.description)
    }

    /// The recording stopped because its file could not be written.
    static func writeFailed(_ failure: RecordingFailure) -> RecordingProblem {
        RecordingProblem(
            message: "The recording stopped.",
            informative: "“\(failure.url.lastPathComponent)” could not be written. \(failure.reason). "
                + "What was recorded until then is in the file.")
    }
}

/// The save sheet's suggested file name and type (docs/DESIGN.md section
/// 8, "Recording a pane").
enum RecordingFileName {
    /// asciicast's extension.
    static let pathExtension = "cast"

    /// The type the save panel is given, so it keeps the extension. Not
    /// declared in Info.plist: a dynamic type from the extension does it.
    static var contentType: UTType {
        UTType(filenameExtension: pathExtension, conformingTo: .data) ?? .data
    }

    /// "<pane title> <yyyy-MM-dd> at <HH.mm.ss>.cast", in `timeZone`, with
    /// what a file name cannot hold replaced (``cleaned(_:)``); "Pane"
    /// when nothing is left of the title.
    static func suggested(title: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = cleaned(title)
        return "\(name.isEmpty ? "Pane" : name) \(formatter.string(from: date)).\(pathExtension)"
    }

    /// The most of the title the name keeps, in UTF-8 bytes: a file name
    /// holds 255, and the date, time and extension take 28.
    static let maximumTitleBytes = 255 - 28

    /// What a name never starts with: a dot (a hidden file), a space, and
    /// `-` or `~`, which a title that is a path leaves there (a shell
    /// often titles its pane with its directory: `/tmp/work` would become
    /// `-tmp-work` and `~/work` `~-work`, which a command line takes for
    /// an option or expands).
    private static let droppedAtStart: Set<Character> = [".", " ", "-", "~"]

    /// `title` made fit for a file name: `/` and `:` (which Finder shows as
    /// `/`) become `-`, control characters and runs of whitespace one
    /// space, leading dots, dashes and tildes (``droppedAtStart``),
    /// trailing dashes and surrounding spaces go, and it is cut to
    /// ``maximumTitleBytes`` bytes on a character boundary.
    static func cleaned(_ title: String) -> String {
        var out = ""
        var lastWasSpace = false
        for scalar in title.unicodeScalars {
            let isSpace = scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
            if isSpace {
                if !lastWasSpace { out.unicodeScalars.append(" ") }
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            out.unicodeScalars.append(scalar == "/" || scalar == ":" ? "-" : scalar)
        }
        var trimmed = Substring(out)
        while let first = trimmed.first, droppedAtStart.contains(first) { trimmed = trimmed.dropFirst() }
        var result = ""
        var bytes = 0
        for character in trimmed {
            let size = character.utf8.count
            guard bytes + size <= maximumTitleBytes else { break }
            result.append(character)
            bytes += size
        }
        while result.last == " " || result.last == "-" { result.removeLast() }
        return result
    }
}
