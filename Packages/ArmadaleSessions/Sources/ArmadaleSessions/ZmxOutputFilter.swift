/// Removes the reset sequence a zmx client writes when it detaches or its
/// session ends: RIS (`ESC c`) followed by OSC 110/111/112 (docs/DESIGN.md
/// section 4, "Client stream filtering"). RIS would wipe the pane just as
/// the *Session Ended* placeholder appears over its last contents.
///
/// Only the exact sequence at the very end of the stream is removed. A
/// suffix of the output that could be the start of it is held back until
/// more output shows otherwise (it is then passed on unchanged) or the
/// stream ends (it is then dropped if it is the whole sequence, and passed
/// on otherwise). An `ESC c` anywhere else, from the program itself, is
/// never touched.
public struct ZmxOutputFilter: OutputFilter {
    /// `ESC c ESC ] 110 ESC \ ESC ] 111 ESC \ ESC ] 112 ESC \`.
    public nonisolated static let detachSequence: [UInt8] = Array("\u{1b}c\u{1b}]110\u{1b}\\\u{1b}]111\u{1b}\\\u{1b}]112\u{1b}\\".utf8)

    private var held: [UInt8] = []

    public init() {}

    public mutating func filter(_ bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        var data = held
        data.append(contentsOf: bytes)
        let keep = Self.heldSuffixLength(of: data)
        held = Array(data.suffix(keep))
        data.removeLast(keep)
        return data
    }

    public mutating func finish() -> [UInt8] {
        defer { held = [] }
        return held == Self.detachSequence ? [] : held
    }

    /// Length of the longest suffix of `data` that is a prefix of (or all
    /// of) ``detachSequence``.
    nonisolated static func heldSuffixLength(of data: [UInt8]) -> Int {
        let sequence = detachSequence
        var length = min(sequence.count, data.count)
        while length > 0 {
            if data[(data.count - length)...].elementsEqual(sequence[..<length]) { return length }
            length -= 1
        }
        return 0
    }
}
