import Foundation
import Testing
@testable import ArmadaleCore

/// Replays fixed 64-bit words.
private struct SequenceGenerator: RandomNumberGenerator {
    var words: [UInt64]
    mutating func next() -> UInt64 { words.isEmpty ? 0 : words.removeFirst() }
}

@Suite("Identifiers")
struct IdentifierTests {
    @Test func generatedIDsHaveSixteenBase32Characters() {
        for _ in 0..<1_000 {
            let id = SessionID.generate()
            #expect(id.raw.count == 16)
            #expect(ShortIDGenerator.isWellFormed(id.raw))
        }
    }

    @Test func generatedIDsAreUnique() {
        let ids = Set((0..<10_000).map { _ in PaneID.generate() })
        #expect(ids.count == 10_000)
    }

    /// Known value. The 80-bit pattern is the bytes
    /// `01 23 45 67 89 ab cd ef fe dc`. In 5-bit groups that is
    /// 00000 00100 10001 10100 01010 11001 11100 01001
    /// 10101 01111 00110 11110 11111 11111 10110 11100
    /// = 0 4 17 20 10 25 28 9 21 15 6 30 31 31 22 28, which maps through the
    /// RFC 4648 alphabet `abcdefghijklmnopqrstuvwxyz234567` to
    /// `aerukz4jvpg677w4` (the same as `base64.b32encode(...).lower()`).
    @Test func knownValueMatchesStandardBase32() {
        let bytes: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0xFE, 0xDC]
        #expect(ShortIDGenerator.encode(bytes) == "aerukz4jvpg677w4")

        // The generator consumes words big-endian: all of the first word,
        // then the top two bytes of the second.
        var generator = SequenceGenerator(words: [0x0123_4567_89AB_CDEF, 0xFEDC_0000_0000_0000])
        #expect(ShortIDGenerator.make(using: &generator) == "aerukz4jvpg677w4")
    }

    @Test func encodeRejectsWrongLength() {
        #expect(ShortIDGenerator.encode([1, 2, 3]) == nil)
        #expect(ShortIDGenerator.encode(Array(repeating: 0, count: 11)) == nil)
    }

    @Test func encodingIsAllZerosAndAllOnes() {
        #expect(ShortIDGenerator.encode(Array(repeating: 0, count: 10)) == String(repeating: "a", count: 16))
        #expect(ShortIDGenerator.encode(Array(repeating: 0xFF, count: 10)) == String(repeating: "7", count: 16))
    }

    @Test func everyCharacterOfTheAlphabetIsReachable() {
        var seen = Set<Character>()
        for _ in 0..<2_000 { seen.formUnion(WorkspaceID.generate().raw) }
        #expect(seen == Set(ShortIDGenerator.alphabet))
    }

    @Test func codesAsPlainString() throws {
        let id = TabID(raw: "abcdefgh23456722")
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == #"["abcdefgh23456722"]"#)
        #expect(try JSONDecoder().decode([TabID].self, from: data) == [id])
    }

    @Test(arguments: [
        "",                    // empty
        "abc",                 // too short
        "abcdefgh234567222",   // too long
        "ABCDEFGH23456722",    // uppercase
        "abcdefgh23456701",    // 0 and 1 are not base32
        "abcdefgh-2345672",    // punctuation
        "builtin.shell",       // reserved profile form
    ])
    func strictIDsRejectMalformedStrings(_ raw: String) {
        let json = Data("[\"\(raw)\"]".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([WorkspaceID].self, from: json) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([TabGroupID].self, from: json) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([TabID].self, from: json) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([PaneID].self, from: json) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([SessionID].self, from: json) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([HostID].self, from: json) }
    }

    @Test func profileIDsAreLenientButNotEmpty() throws {
        let decoded = try JSONDecoder().decode([ProfileID].self, from: Data(#"["builtin.shell","custom one"]"#.utf8))
        #expect(decoded.map(\.raw) == ["builtin.shell", "custom one"])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([ProfileID].self, from: Data(#"[""]"#.utf8)) }
    }

    @Test func builtInProfileIDsAreStableAndDistinctFromGenerated() {
        #expect(Profile.shell.id.raw == "builtin.shell")
        #expect(Profile.claudeCode.id.raw == "builtin.claude-code")
        #expect(Profile.codex.id.raw == "builtin.codex")
        #expect(Profile.builtIns.allSatisfy { !ShortIDGenerator.isWellFormed($0.id.raw) })
        #expect(Profile.claudeCode.program == "claude")
        #expect(Profile.codex.program == "codex")
        #expect(Profile.shell.program == nil)
    }

    @Test func sessionRuntimeVersionIsOptionalInJSON() throws {
        let session = Session(profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/")
        var object = try #require(
            JSONSerialization.jsonObject(with: StateStore.encode(PersistedState(sessions: [session])))
                as? [String: Any])
        // Simulate a file written before runtimeVersion existed.
        var sessions = try #require(object["sessions"] as? [[String: Any]])
        sessions[0].removeValue(forKey: "runtimeVersion")
        object["sessions"] = sessions
        let old = try StateStore.decode(JSONSerialization.data(withJSONObject: object))
        #expect(old.sessions.first?.runtimeVersion == nil)

        var versioned = session
        versioned.runtimeVersion = "0.8.1"
        let round = try StateStore.decode(StateStore.encode(PersistedState(sessions: [versioned])))
        #expect(round.sessions.first?.runtimeVersion == "0.8.1")
    }
}
