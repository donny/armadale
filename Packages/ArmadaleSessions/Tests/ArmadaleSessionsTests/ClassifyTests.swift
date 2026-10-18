import Testing
@testable import ArmadaleSessions

/// How LocalZmxBackend reads a client's first output.
@Suite("ZmxProtocol.classify")
struct ClassifyTests {
    let name = "a-abcdefghijklmnop"
    private func classify(_ text: String, attach: Bool = false) -> ZmxProtocol.FirstOutput {
        ZmxProtocol.classify(Array(text.utf8), sessionName: name, wantsAttach: attach)
    }

    @Test func attachedToAnExistingSession() {
        #expect(classify("\u{1b}[2J\u{1b}[H replay") == .attached)
        #expect(classify("\u{1b}[2J") == .attached)
        #expect(classify("\u{1b}[2J", attach: true) == .attached)
    }

    @Test func theCreatedLineArrivingInPieces() {
        let full = "session \"\(name)\" created\r\n\u{1b}[2J\u{1b}[H"
        let bytes = Array(full.utf8)
        let created = Array("session \"\(name)\" created".utf8).count
        for cut in 0...bytes.count {
            let prefix = Array(bytes[..<cut])
            let forAttach = ZmxProtocol.classify(prefix, sessionName: name, wantsAttach: false)
            let forCreate = ZmxProtocol.classify(prefix, sessionName: name, wantsAttach: true)
            if cut < created {
                // Not enough yet to tell: keep waiting.
                #expect(forAttach == .undecided, "cut \(cut)")
                #expect(forCreate == .undecided, "cut \(cut)")
            } else {
                // For attach-only, `created` alone settles it: the session
                // did not exist.
                #expect(forAttach == .createdAndAttached, "cut \(cut)")
                // Create waits for the client's clear, which comes after it
                // connected.
                let attached = cut >= created + 2 + 4
                #expect(forCreate == (attached ? .createdAndAttached : .created), "cut \(cut)")
                #expect(forCreate.isDecided == attached)
            }
        }
    }

    @Test func otherOutputIsNeitherAttachedNorCreated() {
        #expect(classify("error: socket directory path is too long") == .other)
        #expect(classify("x") == .other)
        #expect(classify("\u{1b}[31mred") == .other)
        // `created` followed by an error (the program died before the
        // client connected).
        #expect(classify("session \"\(name)\" created\r\nerror: cannot connect", attach: true) == .other)
        // Another session's name is not ours.
        #expect(classify("session \"a-other\" created\r\n") == .other)
        #expect(classify("") == .undecided)
    }
}
