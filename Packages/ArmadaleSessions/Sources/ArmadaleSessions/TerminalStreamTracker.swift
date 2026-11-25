/// Follows a terminal output stream byte by byte, the way SwiftTerm 1.99.0's
/// parser does (`EscapeSequenceParser.swift`: `buildVt500TransitionTable`
/// and the parse loop), to know whether the stream is *between sequences*:
/// in the ground state with no UTF-8 character half written. A recording
/// starts only at such a point (docs/DESIGN.md section 7, "Recording a
/// pane"): started inside a sequence, the snapshot's queries would cut it
/// short in the pane and the recording would begin with its tail.
///
/// What is copied from SwiftTerm, so the two agree on where a sequence
/// ends:
/// - the transition table, built by the same additions in the same order
///   (a later addition overrides an earlier one: so CAN and SUB end a
///   sequence in most states but not in the CSI and escape-intermediate
///   states, whose C0 executables were added after the "anywhere" rules);
/// - bytes 0xA0 and above use the table's 0xA0 column; in the CSI-ignore,
///   DCS-ignore and DCS-passthrough states they keep the state, elsewhere
///   (but ground) they end the sequence;
/// - in the ground state every byte from 0x20 on is printed (C1 controls
///   are not recognised there), up to the next C0 byte;
/// - an OSC or APC string is taken in runs: the first byte of a run (after
///   the string opened, after a C0 byte inside it, or at the start of a
///   batch) goes through the table, so a C1 byte there ends or switches the
///   sequence; inside a run every byte from 0x20 on belongs to the string,
///   except that in an OSC string a 0x9C (C1 ST) ends it unless it
///   continues a UTF-8 character of the payload;
/// - ESC ending an OSC whose payload starts `7501;` waits for the next
///   byte: `\` ends it, anything else is read again as an escape sequence;
/// - ESC ending a DCS passthrough or a string starts an escape sequence.
/// Not copied: the limits on very long OSC (1 MB) and APC (65 MB) strings,
/// past which SwiftTerm discards payload but keeps the same framing.
public struct TerminalStreamTracker: Sendable {
    /// SwiftTerm's parser states (`ParserState`).
    public enum State: UInt8, Sendable, CaseIterable {
        case ground = 0, escape, escapeIntermediate, csiEntry, csiParam, csiIntermediate, csiIgnore
        case sosPmApcString, oscString, apcString, dcsEntry, dcsParam, dcsIgnore, dcsIntermediate
        case dcsPassthrough, programStatusEscape
    }

    /// What a byte does in a state: the next state, and what the loop does
    /// besides (`ParserAction`, only the ones that change the framing).
    private enum Action: UInt8 {
        case plain, error, oscStart, oscPut, oscEnd, dcsUnhook
    }

    public private(set) var state: State = .ground
    /// Continuation bytes still owed by a UTF-8 character in the ground state.
    public private(set) var pendingContinuations = 0
    /// Inside an OSC or APC string: whether the next byte continues a run
    /// (else it goes through the table).
    private var inRun = false
    /// The first bytes of the OSC payload (for `7501;`) and its last three
    /// (for a UTF-8 character a 0x9C may continue).
    private var oscPrefix: [UInt8] = []
    private var oscTail: [UInt8] = []

    public init() {}

    /// Whether the stream is between sequences: ground, no character half
    /// written.
    public var isBetweenSequences: Bool { state == .ground && pendingContinuations == 0 }

    /// Follows `bytes`, one batch as fed to the terminal. Runs of printed
    /// text and of string payload are skipped to their next C0 byte, as
    /// SwiftTerm's parser does.
    public mutating func feed<Bytes: Collection<UInt8>>(_ bytes: Bytes) {
        let done: Bool? = bytes.withContiguousStorageIfAvailable { buffer in
            feedBuffer(buffer)
            return true
        }
        if done == nil { _ = advance(bytes, stoppingAtGround: false) }
    }

    private mutating func feedBuffer(_ buffer: UnsafeBufferPointer<UInt8>) {
        inRun = false
        let count = buffer.count
        var index = 0
        while index < count {
            switch state {
            case .ground:
                var end = index
                while end < count, buffer[end] > 0x1F { end += 1 }
                if end > index {
                    // Only the run's last four bytes can leave a character open.
                    if end - index > 4 {
                        pendingContinuations = 0
                        for position in (end - 4)..<end { followUTF8(buffer[position]) }
                    } else {
                        for position in index..<end { followUTF8(buffer[position]) }
                    }
                    index = end
                    continue
                }
            case .oscString where inRun, .apcString where inRun:
                let isOsc = state == .oscString
                var end = index
                while end < count, buffer[end] > 0x1F, !(isOsc && buffer[end] == 0x9C) { end += 1 }
                if end > index {
                    if isOsc {
                        var position = index
                        while oscPrefix.count < 5, position < end { oscPrefix.append(buffer[position]); position += 1 }
                        for position in max(index, end - 3)..<end { oscTail.append(buffer[position]) }
                        if oscTail.count > 3 { oscTail.removeFirst(oscTail.count - 3) }
                    }
                    index = end
                    continue
                }
            case .csiParam:
                // Digits, `;` and `:` keep a CSI's parameters going.
                var end = index
                while end < count, (0x30...0x3B).contains(buffer[end]) { end += 1 }
                if end > index {
                    pendingContinuations = 0
                    index = end
                    continue
                }
            default:
                break
            }
            if step(buffer[index]) { index += 1 }
        }
    }

    /// Follows `bytes` up to the first point between sequences and returns
    /// how many bytes that took (at least one), or follows them all and
    /// returns `nil` when there is none. Call ``feed(_:)`` with the rest of
    /// the batch afterwards: it is a new batch to the tracker as it is to
    /// the terminal.
    public mutating func feedToFirstGround<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> Int? {
        advance(bytes, stoppingAtGround: true)
    }

    private mutating func advance<Bytes: Collection<UInt8>>(_ bytes: Bytes, stoppingAtGround: Bool) -> Int? {
        inRun = false  // a new batch: a string's next byte goes through the table
        var count = 0
        var iterator = bytes.makeIterator()
        var pending: UInt8? = nil
        while true {
            guard let byte = pending ?? iterator.next() else { break }
            pending = nil
            if !step(byte) {
                pending = byte  // read again in the new state (OSC 7501 ST)
                continue
            }
            count += 1
            if stoppingAtGround && isBetweenSequences { return count }
        }
        return nil
    }

    /// One byte; returns false when the byte must be read again.
    private mutating func step(_ code: UInt8) -> Bool {
        switch state {
        case .ground where code > 0x1F:
            followUTF8(code)
            return true
        case .oscString where inRun, .apcString where inRun:
            if code < 0x20 { break }  // a C0 byte ends the run: through the table
            if state == .oscString, code == 0x9C, !Self.expectsUTF8Continuation(oscTail) {
                endString()
                state = .ground
                return true
            }
            if state == .oscString { appendOsc(code) }
            return true
        default:
            break
        }
        pendingContinuations = 0
        if state == .programStatusEscape {
            // `\` ends the status OSC; anything else is read again as an escape.
            if code == UInt8(ascii: "\\") {
                state = .ground
                return true
            }
            state = .escape
            return false
        }
        let entry = Self.table[Int(state.rawValue) << 8 | Int(min(code, 0xA0))]
        let action = Action(rawValue: entry >> 5) ?? .plain
        var next = State(rawValue: entry & 0x1F) ?? .ground
        switch action {
        case .plain:
            break
        case .oscStart:
            oscPrefix = []
            oscTail = []
        case .error:
            if code > 0x9F {
                switch state {
                case .csiIgnore, .dcsIgnore, .dcsPassthrough: next = state
                default: next = .ground
                }
            }
        case .oscPut:
            // Starts a run: this byte and those after it, up to a C0 byte.
            if state == .oscString {
                if code == 0x9C, !Self.expectsUTF8Continuation(oscTail) {
                    endString()
                    state = .ground
                    return true
                }
                appendOsc(code)
            }
            inRun = true
            return true
        case .oscEnd:
            let isStatus = state == .oscString && oscPrefix.count >= 5 && oscPrefix.prefix(5).elementsEqual([55, 53, 48, 49, 59])
            endString()
            if code == 0x1B { next = isStatus ? .programStatusEscape : .escape }
        case .dcsUnhook:
            if code == 0x1B { next = .escape }
        }
        // In a string, the byte after a table step starts a new run.
        if next == .oscString || next == .apcString { inRun = false }
        state = next
        return true
    }

    private mutating func followUTF8(_ code: UInt8) {
        if code & 0xC0 == 0x80 {
            if pendingContinuations > 0 { pendingContinuations -= 1 }
            return
        }
        switch code {
        case 0xC2...0xDF: pendingContinuations = 1
        case 0xE0...0xEF: pendingContinuations = 2
        case 0xF0...0xF4: pendingContinuations = 3
        default: pendingContinuations = 0
        }
    }

    private mutating func appendOsc(_ code: UInt8) {
        if oscPrefix.count < 5 { oscPrefix.append(code) }
        oscTail.append(code)
        if oscTail.count > 3 { oscTail.removeFirst() }
    }

    private mutating func endString() {
        inRun = false
        oscPrefix = []
        oscTail = []
    }

    /// SwiftTerm's `oscExpectsUTF8Continuation`, over the payload's last
    /// three bytes (all it ever looks at).
    static func expectsUTF8Continuation(_ tail: [UInt8]) -> Bool {
        var continuations = 0
        for byte in tail.reversed() {
            if byte >= 0x80 && byte <= 0xBF {
                continuations += 1
                if continuations == 3 { return false }
                continue
            }
            let size: Int
            switch byte {
            case 0xC2...0xDF: size = 2
            case 0xE0...0xEF: size = 3
            case 0xF0...0xF4: size = 4
            default: return false
            }
            return continuations < size - 1
        }
        return false
    }

    // MARK: The table

    /// `(action << 5) | next`, indexed by `state << 8 | min(code, 0xA0)`.
    private static let table: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 16 << 8)
        func add(_ codes: [UInt8], _ state: State, _ action: Action, _ next: State) {
            for code in codes { table[Int(state.rawValue) << 8 | Int(code)] = action.rawValue << 5 | next.rawValue }
        }
        func add(_ code: UInt8, _ state: State, _ action: Action, _ next: State) { add([code], state, action, next) }
        /// SwiftTerm's `r(low:high:)`: `low..<high`.
        func r(_ low: UInt8, _ high: UInt8) -> [UInt8] { Array(low..<high) }
        let states: [State] = State.allCases.filter { $0 != .programStatusEscape }
        for state in states { add(Array(0...0xA0), state, .error, .ground) }
        let printables = r(0x20, 0x7F)
        let executables = r(0x00, 0x19) + r(0x1C, 0x20)
        add(printables, .ground, .plain, .ground)
        for state in states {
            add([0x18, 0x1A, 0x99, 0x9A], state, .plain, .ground)
            add(r(0x80, 0x90), state, .plain, .ground)
            add(r(0x90, 0x98), state, .plain, .ground)
            add(0x9C, state, .plain, .ground)
            add(0x1B, state, .plain, .escape)
            add(0x9D, state, .oscStart, .oscString)
            add([0x98, 0x9E], state, .plain, .sosPmApcString)
            add(0x9F, state, .oscStart, .apcString)
            add(0x9B, state, .plain, .csiEntry)
            add(0x90, state, .plain, .dcsEntry)
        }
        add(executables, .ground, .plain, .ground)
        add(executables, .escape, .plain, .escape)
        add(0x7F, .escape, .plain, .escape)
        add(executables, .oscString, .plain, .oscString)
        add(executables, .apcString, .plain, .apcString)
        add(executables, .csiEntry, .plain, .csiEntry)
        add(0x7F, .csiEntry, .plain, .csiEntry)
        add(executables, .csiParam, .plain, .csiParam)
        add(0x7F, .csiParam, .plain, .csiParam)
        add(executables, .csiIgnore, .plain, .csiIgnore)
        add(executables, .csiIntermediate, .plain, .csiIntermediate)
        add(0x7F, .csiIntermediate, .plain, .csiIntermediate)
        add(executables, .escapeIntermediate, .plain, .escapeIntermediate)
        add(0x7F, .escapeIntermediate, .plain, .escapeIntermediate)
        // OSC
        add(0x5D, .escape, .oscStart, .oscString)
        add(printables, .oscString, .oscPut, .oscString)
        add(0x7F, .oscString, .oscPut, .oscString)
        add([0x1B, 0x18, 0x1A, 0x07], .oscString, .oscEnd, .ground)
        add(0x9C, .oscString, .oscPut, .oscString)
        add(r(0x1C, 0x20), .oscString, .plain, .oscString)
        // APC
        add(0x5F, .escape, .oscStart, .apcString)
        add(printables, .apcString, .oscPut, .apcString)
        add(0x7F, .apcString, .oscPut, .apcString)
        add([0x1B, 0x18, 0x1A, 0x07], .apcString, .oscEnd, .ground)
        add(0x9C, .apcString, .oscPut, .apcString)
        add(r(0x1C, 0x20), .apcString, .plain, .apcString)
        // SOS, PM
        add([0x58, 0x5E], .escape, .plain, .sosPmApcString)
        add(printables, .sosPmApcString, .plain, .sosPmApcString)
        add(executables, .sosPmApcString, .plain, .sosPmApcString)
        add(0x9C, .sosPmApcString, .plain, .ground)
        add(0x7F, .sosPmApcString, .plain, .sosPmApcString)
        // CSI
        add(0x5B, .escape, .plain, .csiEntry)
        add(r(0x40, 0x7F), .csiEntry, .plain, .ground)
        add(r(0x30, 0x3A), .csiEntry, .plain, .csiParam)
        add(0x3B, .csiEntry, .plain, .csiParam)
        add([0x3C, 0x3D, 0x3E, 0x3F], .csiEntry, .plain, .csiParam)
        add(r(0x30, 0x3A), .csiParam, .plain, .csiParam)
        add(0x3B, .csiParam, .plain, .csiParam)
        add(r(0x40, 0x7F), .csiParam, .plain, .ground)
        add([0x3C, 0x3D, 0x3E, 0x3F], .csiParam, .plain, .csiIgnore)
        add(0x3A, .csiParam, .plain, .csiParam)
        add(r(0x20, 0x40), .csiIgnore, .plain, .csiIgnore)
        add(0x7F, .csiIgnore, .plain, .csiIgnore)
        add(r(0x40, 0x7F), .csiIgnore, .plain, .ground)
        add(r(0x20, 0x30), .csiEntry, .plain, .csiIntermediate)
        add(r(0x20, 0x30), .csiIntermediate, .plain, .csiIntermediate)
        add(r(0x30, 0x40), .csiIntermediate, .plain, .csiIgnore)
        add(r(0x40, 0x7F), .csiIntermediate, .plain, .ground)
        add(r(0x20, 0x30), .csiParam, .plain, .csiIntermediate)
        // Escape intermediates and dispatch
        add(r(0x20, 0x30), .escape, .plain, .escapeIntermediate)
        add(r(0x20, 0x30), .escapeIntermediate, .plain, .escapeIntermediate)
        add(r(0x30, 0x7F), .escapeIntermediate, .plain, .ground)
        add(r(0x30, 0x50), .escape, .plain, .ground)
        add(r(0x51, 0x58), .escape, .plain, .ground)
        add([0x59, 0x5A, 0x5C], .escape, .plain, .ground)
        add(r(0x60, 0x7F), .escape, .plain, .ground)
        // DCS
        add(0x50, .escape, .plain, .dcsEntry)
        add(executables, .dcsEntry, .plain, .dcsEntry)
        add(0x7F, .dcsEntry, .plain, .dcsEntry)
        add(r(0x1C, 0x20), .dcsEntry, .plain, .dcsEntry)
        add(r(0x20, 0x30), .dcsEntry, .plain, .dcsIntermediate)
        add(0x3A, .dcsEntry, .plain, .dcsIgnore)
        add(r(0x30, 0x3A), .dcsEntry, .plain, .dcsParam)
        add(0x3B, .dcsEntry, .plain, .dcsParam)
        add([0x3C, 0x3D, 0x3E, 0x3F], .dcsEntry, .plain, .dcsParam)
        add(executables, .dcsIgnore, .plain, .dcsIgnore)
        add(r(0x20, 0x80), .dcsIgnore, .plain, .dcsIgnore)
        add(r(0x1C, 0x20), .dcsIgnore, .plain, .dcsIgnore)
        add(executables, .dcsParam, .plain, .dcsParam)
        add(0x7F, .dcsParam, .plain, .dcsParam)
        add(r(0x1C, 0x20), .dcsParam, .plain, .dcsParam)
        add(r(0x30, 0x3A), .dcsParam, .plain, .dcsParam)
        add(0x3B, .dcsParam, .plain, .dcsParam)
        add([0x3A, 0x3C, 0x3D, 0x3E, 0x3F], .dcsParam, .plain, .dcsIgnore)
        add(r(0x20, 0x30), .dcsParam, .plain, .dcsIntermediate)
        add(executables, .dcsIntermediate, .plain, .dcsIntermediate)
        add(0x7F, .dcsIntermediate, .plain, .dcsIntermediate)
        add(r(0x1C, 0x20), .dcsIntermediate, .plain, .dcsIntermediate)
        add(r(0x20, 0x30), .dcsIntermediate, .plain, .dcsIntermediate)
        add(r(0x30, 0x40), .dcsIntermediate, .plain, .dcsIgnore)
        add(r(0x40, 0x7F), .dcsIntermediate, .plain, .dcsPassthrough)
        add(r(0x40, 0x7F), .dcsParam, .plain, .dcsPassthrough)
        add(r(0x40, 0x7F), .dcsEntry, .plain, .dcsPassthrough)
        add(executables, .dcsPassthrough, .plain, .dcsPassthrough)
        add(printables, .dcsPassthrough, .plain, .dcsPassthrough)
        add(0x7F, .dcsPassthrough, .plain, .dcsPassthrough)
        add([0x1B, 0x9C], .dcsPassthrough, .dcsUnhook, .ground)
        add(0xA0, .oscString, .oscPut, .oscString)
        add(0xA0, .apcString, .oscPut, .apcString)
        return table
    }()
}
