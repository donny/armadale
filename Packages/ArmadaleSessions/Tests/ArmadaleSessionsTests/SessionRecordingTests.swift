import ArmadaleCore
import Darwin
import Foundation
import TerminalSurface
import Testing
@testable import ArmadaleSessions

/// A recording's file, parsed line by line.
struct CastFile {
    var header: [String: Any]
    /// `(time, code, data)` for every event after the header.
    var events: [(time: Double, code: String, data: String)]

    /// Parses `url`; every line must be one JSON value.
    init(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let data = try Data(contentsOf: url)
        #expect(data.last == 0x0A, "the file ends with a whole line", sourceLocation: sourceLocation)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
        let first = try #require(lines.first, sourceLocation: sourceLocation)
        header = try #require(try JSONSerialization.jsonObject(with: Data(first)) as? [String: Any], sourceLocation: sourceLocation)
        events = []
        for line in lines.dropFirst() {
            let event = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [Any], sourceLocation: sourceLocation)
            let time = try #require(event.first as? Double, sourceLocation: sourceLocation)
            let code = try #require(event.count == 3 ? event[1] as? String : nil, sourceLocation: sourceLocation)
            let value = try #require(event[2] as? String, sourceLocation: sourceLocation)
            events.append((time, code, value))
        }
    }

    /// The text of the output events, in order.
    var output: String { events.filter { $0.code == "o" }.map(\.data).joined() }
}

/// Recording a pane through its controller (docs/DESIGN.md section 7,
/// "Recording a pane"): what the surface is fed reaches the file, resizes
/// are events, input never is, and the recording ends with the session,
/// a close, a respawn, a stop and a quit, leaving a complete file.
@Suite("Recording a pane")
@MainActor
struct SessionRecordingTests {
    private let backend = FakeBackend()
    private let surface = FakeSurface()
    private let delegate = RecordingDelegate()
    private let session = Session(
        profileID: Profile.shell.id, launch: LaunchSpec(program: "claude", arguments: []), workingDirectory: "/work")

    private func makeController() -> SessionController {
        let surface = surface
        let controller = SessionController(session: session, backend: backend, makeSurface: { surface })
        controller.delegate = delegate
        return controller
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "armadale-recording-\(UUID().uuidString).cast")
    }

    private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    private func handle(_ index: Int = 0) async throws -> FakeHandle {
        let handles = await backend.handles
        return try #require(handles.count > index ? handles[index] : nil)
    }

    /// Waits until `text` is on the surface (the pump has fed it).
    private func fed(_ text: String) async {
        await eventually { surface.text.hasSuffix(text) }
    }

    private func closedFile(_ controller: SessionController, _ url: URL) async throws -> CastFile {
        let writer = try #require(controller.recordingWriter)
        await writer.drained()
        #expect(writer.isClosed, "the file is closed")
        return try CastFile(url)
    }

    @Test func outputAfterTheSnapshotReachesTheFile() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = makeController()
        await controller.start(.create)
        let client = try await handle()
        client.emit("before\r\n")
        await fed("before\r\n")
        #expect(controller.canStartRecording)

        try controller.startRecording(to: url, title: "build")
        #expect(controller.isRecording)
        #expect(controller.recording?.url == url)
        #expect(!controller.canStartRecording, "one recording at a time")
        client.emit("after \u{1b}[31mred\u{1b}[0m\r\n")
        await fed("\u{1b}[0m\r\n")
        // Typed input goes to the program and never into the file.
        surface.delegate?.surface(surface, didInput: Array("secret\r".utf8))
        #expect(client.writes == [Array("secret\r".utf8)])
        controller.stopRecording()
        #expect(!controller.isRecording)
        client.emit("later")
        await fed("later")

        let file = try await closedFile(controller, url)
        #expect(file.header["version"] as? Int == 2)
        #expect(file.header["width"] as? Int == 100)
        #expect(file.header["height"] as? Int == 30)
        #expect(file.header["title"] as? String == "build")
        #expect((file.header["timestamp"] as? Int).map { abs($0 - Int(Date().timeIntervalSince1970)) < 60 } == true)
        #expect(file.events.first?.time == 0)
        #expect(file.events.first?.data == "SNAPSHOT", "the first event is the surface's snapshot")
        #expect(file.output == "SNAPSHOTafter \u{1b}[31mred\u{1b}[0m\r\n")
        #expect(file.events.allSatisfy { $0.code == "o" || $0.code == "r" }, "never an input event")
        #expect(!file.output.contains("secret"))
        let times = file.events.map(\.time)
        #expect(times == times.sorted(), "times never go backwards")
    }

    /// A reset and the replay after a reattach are what the pane shows, so
    /// they are in the recording too.
    @Test func aResetAndTheReplayAreRecorded() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        await backend.setCanAttach(true)
        await backend.setResolutions([.detached])
        let controller = makeController()
        await controller.start(.create)
        try controller.startRecording(to: url, title: "t")
        // The client goes away, the session lives: reattached from a reset.
        let first = try await handle(0)
        first.finishOutput()
        first.exit(0)
        await eventually { controller.state == .attached && surface.text.hasSuffix("\u{1b}c") }
        let second = try await handle(1)
        second.emit("replayed screen")
        await fed("replayed screen")
        #expect(controller.isRecording, "a reattach does not end it")
        controller.stopRecording()
        let file = try await closedFile(controller, url)
        #expect(file.output == "SNAPSHOT\u{1b}creplayed screen")
    }

    /// The applied grid size is an `"r"` event when it changes.
    @Test func resizesAreEvents() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = makeController()
        await controller.start(.create)
        try controller.startRecording(to: url, title: "t")
        surface.setGridSize(columns: 90, rows: 20)
        surface.setGridSize(columns: 90, rows: 20)
        surface.setGridSize(columns: 132, rows: 43)
        controller.stopRecording()
        let file = try await closedFile(controller, url)
        #expect(file.events.filter { $0.code == "r" }.map(\.data) == ["90x20", "132x43"])
    }

    @Test func theRecordingEndsWithTheSession() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = makeController()
        await controller.start(.create)
        try controller.startRecording(to: url, title: "t")
        let client = try await handle()
        // A character cut short by the end of the stream.
        client.emitBytes(Array("bye ".utf8) + [0xE6])
        client.emitBytes([0xBC])
        client.finishOutput()
        client.exit(0)
        await eventually { controller.state.isEnded }
        #expect(!controller.isRecording)
        let file = try await closedFile(controller, url)
        #expect(file.output == "SNAPSHOTbye \u{FFFD}", "held bytes are flushed at the end")
    }

    @Test func closeEndsTheRecording() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = makeController()
        await controller.start(.create)
        try controller.startRecording(to: url, title: "t")
        try await handle().emit("x")
        await fed("x")
        await controller.close()
        #expect(!controller.isRecording)
        #expect(try await closedFile(controller, url).output == "SNAPSHOTx")
    }

    @Test func respawnEndsTheRecording() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = makeController()
        await controller.start(.create)
        try controller.startRecording(to: url, title: "t")
        await controller.respawn()
        #expect(controller.state == .attached)
        #expect(!controller.isRecording, "the fresh session is not recorded")
        try await handle(1).emit("fresh")
        await fed("fresh")
        let file = try await closedFile(controller, url)
        #expect(file.output == "SNAPSHOT", "neither the reset nor the fresh session's output")
    }

    /// While a respawn is ending the old session its state can still read
    /// attached: a recording must not start then, or it would run on into
    /// the fresh session.
    @Test func noRecordingStartsWhileARespawnIsUnderWay() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        await backend.setKillDelay(.milliseconds(300))
        let controller = makeController()
        await controller.start(.create)
        #expect(controller.canStartRecording)
        let respawn = Task { await controller.respawn() }
        // The respawn has begun (it is waiting for the kill).
        for _ in 0..<200 where controller.recordingRefusal == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(controller.recordingRefusal == .stillStarting)
        #expect(throws: RecordingError.stillStarting) { try controller.startRecording(to: url, title: "t") }
        #expect(!controller.isRecording)
        await respawn.value
        #expect(controller.state == .attached)
        #expect(controller.canStartRecording, "the fresh session can be recorded")
    }

    /// Quitting: the file is complete when ``SessionController/detachNow()``
    /// returns, with no waiting.
    @Test func detachNowClosesTheFileAtOnce() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        await backend.setCanAttach(true)
        let controller = makeController()
        await controller.start(.create)
        try controller.startRecording(to: url, title: "t")
        try await handle().emitBytes([0x61, 0xE6, 0xBC])
        await eventually { surface.fed.suffix(3) == [0x61, 0xE6, 0xBC] }
        controller.detachNow()
        let writer = try #require(controller.recordingWriter)
        #expect(writer.isClosed, "closed before detachNow returned")
        #expect(!controller.isRecording)
        #expect(try CastFile(url).output == "SNAPSHOTa\u{FFFD}", "what was held is flushed too")
    }

    @Test func stopRecordingNowClosesTheFileAtOnce() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = makeController()
        await controller.start(.create)
        try controller.startRecording(to: url, title: "t")
        controller.stopRecordingNow()
        #expect(try #require(controller.recordingWriter).isClosed)
        #expect(try CastFile(url).output == "SNAPSHOT")
    }

    @Test func startingTwiceOrWithoutALiveTerminalIsRefused() async throws {
        let url = temporaryFile(), other = temporaryFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: other)
        }
        let controller = makeController()
        #expect(!controller.canStartRecording, "never attached: nothing to record")
        #expect(throws: RecordingError.stillStarting) { try controller.startRecording(to: url, title: "t") }
        #expect(!FileManager.default.fileExists(atPath: url.path), "refused before the file is made")
        await controller.start(.create)
        try controller.startRecording(to: url, title: "t")
        #expect(throws: RecordingError.alreadyRecording) { try controller.startRecording(to: other, title: "t") }
        #expect(!FileManager.default.fileExists(atPath: other.path))
        controller.stopRecording()

        // Ended: nothing to record.
        let client = try await handle()
        client.finishOutput()
        client.exit(0)
        await eventually { controller.state.isEnded }
        #expect(!controller.canStartRecording)
        #expect(controller.recordingRefusal == .sessionEnded)
        #expect(throws: RecordingError.sessionEnded) { try controller.startRecording(to: other, title: "t") }
    }

    // MARK: During an attach

    /// Each refusal says what is true, and fits the alert's second line.
    @Test func refusalsSayWhatIsTrue() {
        #expect(RecordingError.sessionEnded.description == "There is nothing to record: the session has ended.")
        #expect(RecordingError.notConnected.description
            == "There is nothing to record: the session is not connected right now.")
        #expect(RecordingError.stillStarting.description
            == "There is nothing to record yet: the session is still starting.")
    }

    /// A first attach under way: still starting. Disconnected with no
    /// attach under way, and unavailable: not connected.
    @Test func whenThereIsNoLiveTerminal() async throws {
        await backend.setCreateDelay(.milliseconds(300))
        let starting = makeController()
        let task = Task { await starting.start(.create) }
        await eventually { starting.state == .attaching }
        #expect(starting.recordingRefusal == .stillStarting)
        await task.value
        #expect(starting.canStartRecording)

        await backend.setCreateDelay(nil)
        await backend.setCanAttach(true)
        await backend.setResolutions([.detached, .detached])
        await backend.setAlive([session.id])
        let controller = makeController()
        await controller.start(.create)
        // Two lost clients within the allowance: disconnected.
        for index in 1...2 {
            let client = try await handle(index)
            client.finishOutput()
            client.exit(0)
            if index == 1 {
                for _ in 0..<300 where await backend.handles.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
                await eventually { controller.state == .attached }
            }
        }
        await eventually { controller.state.isDisconnected }
        #expect(controller.recordingRefusal == .notConnected)
        controller.markUnavailable(reason: "Host removed")
        #expect(controller.recordingRefusal == .notConnected)
    }

    /// A recording that was running when the connection was lost waits
    /// through the disconnect, and ends when the pane becomes unavailable:
    /// nothing more will come from it.
    @Test func becomingUnavailableEndsARecordingThatWaitedThroughADisconnect() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        await backend.setCanAttach(true)
        await backend.setResolutions([.detached, .detached])
        await backend.setAlive([session.id])
        let controller = makeController()
        await controller.start(.create)
        try controller.startRecording(to: url, title: "t")
        // Two lost clients within the allowance (the create's, then the
        // automatic reattach's): disconnected.
        for index in 0...1 {
            let client = try await handle(index)
            client.finishOutput()
            client.exit(0)
            if index == 0 {
                for _ in 0..<300 where await backend.handles.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
                await eventually { controller.state == .attached }
            }
        }
        await eventually { controller.state.isDisconnected }
        #expect(controller.isRecording, "a recording waits through a disconnect")
        controller.markUnavailable(reason: "Host removed")
        #expect(!controller.isRecording)
        #expect(controller.state.isUnavailable)
    }

    /// Asked for while a session attached in this run is being attached
    /// again (here the reattach after a lost client): pending, then started
    /// at the reset that attach feeds; the file holds the snapshot, then the
    /// replay.
    @Test func aRecordingAskedForDuringAReattachStartsAtItsReset() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        await backend.setCanAttach(true)
        await backend.setResolutions([.detached])
        let controller = makeController()
        await controller.start(.create)
        try await handle().emit("old screen")
        await fed("old screen")
        await backend.setAttachDelay(.milliseconds(300))
        let first = try await handle()
        first.finishOutput()
        first.exit(0)
        await eventually { controller.state == .attaching }
        #expect(controller.canStartRecording, "a session attached in this run, being attached again")
        try controller.startRecording(to: url, title: "t")
        #expect(controller.isRecording && controller.isRecordingPending)
        await eventually { controller.state == .attached }
        #expect(!controller.isRecordingPending, "started at the reset")
        try await handle(1).emit("replayed")
        await fed("replayed")
        controller.stopRecording()
        let file = try await closedFile(controller, url)
        #expect(file.output == "SNAPSHOTreplayed", "the snapshot, then the replay; not the old screen, not the reset")
    }

    /// The reattach finds the session gone: the pending recording ends with
    /// its header alone. It ends disconnected: the recording stays pending,
    /// and starts when an attach succeeds.
    @Test(arguments: [true, false])
    func aRecordingPendingThroughAFailedReattach(sessionGone: Bool) async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        await backend.setCanAttach(true)
        await backend.setResolutions([.detached])
        let controller = makeController()
        await controller.start(.create)
        await backend.setAttachDelay(.milliseconds(300))
        await backend.setAttachError(sessionGone ? BackendError.noSuchSession(session.id) : BackendError.runtimeFailure("lost"))
        await backend.setAlive(sessionGone ? [] : [session.id])
        let first = try await handle()
        first.finishOutput()
        first.exit(0)
        await eventually { controller.state == .attaching }
        try controller.startRecording(to: url, title: "t")
        #expect(controller.isRecordingPending)
        if sessionGone {
            await eventually { controller.state.isEnded }
            #expect(!controller.isRecording)
            let file = try await closedFile(controller, url)
            #expect(file.events.isEmpty && file.header["version"] as? Int == 2, "the header alone")
        } else {
            await eventually { controller.state.isDisconnected }
            #expect(controller.isRecording && controller.isRecordingPending, "pending through the disconnect")
            await backend.setAttachError(nil)
            await backend.setAttachDelay(nil)
            await controller.reconnect()
            #expect(controller.state == .attached)
            #expect(!controller.isRecordingPending)
            controller.stopRecording()
            #expect(try await closedFile(controller, url).output == "SNAPSHOT")
        }
    }

    @Test func aFileThatCannotBeCreatedChangesNothing() async throws {
        let controller = makeController()
        await controller.start(.create)
        let url = URL(fileURLWithPath: "/nonexistent-armadale-folder/x.cast")
        #expect(throws: RecordingError.cannotCreateFile(name: "x.cast", reason: "No such file or directory")) {
            try controller.startRecording(to: url, title: "t")
        }
        #expect(!controller.isRecording)
        #expect(controller.recordingWriter == nil)
        #expect(controller.canStartRecording)
    }

    // MARK: Started inside a sequence

    /// Asked for while the output has stopped inside a sequence, the
    /// recording waits: its file exists, it shows as recording, and it
    /// starts (snapshot first) right after the sequence ends; the
    /// sequence's tail is not in the file.
    @Test func aRecordingAskedForInsideASequenceStartsAfterIt() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = makeController()
        await controller.start(.create)
        let client = try await handle()
        client.emit("before \u{1b}[38;5;19")
        await fed("\u{1b}[38;5;19")
        try controller.startRecording(to: url, title: "t")
        #expect(controller.isRecording)
        #expect(controller.isRecordingPending)
        #expect(FileManager.default.fileExists(atPath: url.path), "the file is made at once")
        let writer = try #require(controller.recordingWriter)
        await writer.drained()
        #expect(try Data(contentsOf: url).isEmpty, "nothing written while pending")
        client.emit("6mRED")
        await fed("6mRED")
        #expect(!controller.isRecordingPending)
        #expect(surface.text.hasSuffix("before \u{1b}[38;5;196mRED"), "the pane gets every byte")
        controller.stopRecording()
        let file = try await closedFile(controller, url)
        #expect(file.output == "SNAPSHOTRED", "from the snapshot taken after the sequence, without its tail")
        #expect(file.events.first?.time == 0)
    }

    /// A pending recording ended (stop, the session's end, a close, a quit)
    /// writes its header alone, with the grid size of that moment.
    @Test(arguments: ["stop", "end", "close", "quit"])
    func aPendingRecordingEndsWithItsHeaderAlone(how: String) async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = makeController()
        await controller.start(.create)
        let client = try await handle()
        client.emit("\u{1b}]0;my ti")
        await fed("my ti")
        try controller.startRecording(to: url, title: "t")
        #expect(controller.isRecordingPending)
        surface.setGridSize(columns: 90, rows: 25)
        switch how {
        case "stop": controller.stopRecording()
        case "end":
            client.finishOutput()
            client.exit(0)
            await eventually { controller.state.isEnded }
        case "close": await controller.close()
        default: controller.detachNow()
        }
        #expect(!controller.isRecording)
        let file = try await closedFile(controller, url)
        #expect(file.events.isEmpty, "no snapshot, no event")
        #expect(file.header["width"] as? Int == 90 && file.header["height"] as? Int == 25)
    }

    /// A host's removal ends the recording.
    @Test func becomingUnreachableEndsTheRecording() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = makeController()
        await controller.start(.create)
        try controller.startRecording(to: url, title: "t")
        controller.detachAsUnavailable(reason: "Host removed", backend: backend)
        #expect(!controller.isRecording)
        #expect(try await closedFile(controller, url).output == "SNAPSHOT")
    }

    /// A write that fails ends the recording and tells the delegate.
    @Test func aWriteFailureEndsTheRecording() async throws {
        let controller = makeController()
        await controller.start(.create)
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        close(ends[0])
        let url = URL(fileURLWithPath: "/tmp/pipe.cast")
        try controller.startRecording(writer: RecordingFileWriter(descriptor: ends[1]), url: url, title: "t")
        await eventually { !controller.isRecording }
        #expect(delegate.recordingFailures == [RecordingFailure(url: url, reason: "Broken pipe")])
        #expect(controller.canStartRecording, "a new one may start")
    }
}
