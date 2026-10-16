import Testing
@testable import ArmadaleSessions

@Suite("ZmxOutputFilter")
@MainActor
struct ZmxOutputFilterTests {
    let tail = ZmxOutputFilter.detachSequence
    let body = Array("hello\r\nworld $ ".utf8)

    /// Runs `batches` through a fresh filter and returns everything shown.
    private func shown(_ batches: [[UInt8]]) -> [UInt8] {
        var filter = ZmxOutputFilter()
        var result: [UInt8] = []
        for batch in batches { result += filter.filter(batch) }
        return result + filter.finish()
    }

    @Test func theTailIsRemovedWhereverTheStreamIsSplit() {
        let stream = body + tail
        for split in 0...stream.count {
            let batches = [Array(stream[..<split]), Array(stream[split...])]
            #expect(shown(batches) == body, "split at \(split)")
        }
        // Split into three at every pair of points inside the tail.
        for first in body.count...stream.count {
            for second in first...stream.count {
                let batches = [Array(stream[..<first]), Array(stream[first..<second]), Array(stream[second...])]
                #expect(shown(batches) == body, "split at \(first), \(second)")
            }
        }
        // One byte at a time.
        #expect(shown(stream.map { [$0] }) == body)
        // The tail alone.
        #expect(shown([tail]).isEmpty)
    }

    @Test func bytesHeldBackAreReleasedAsSoonAsTheyCannotBeTheTail() {
        var filter = ZmxOutputFilter()
        #expect(filter.filter(Array("abc\u{1b}".utf8)) == Array("abc".utf8))
        #expect(filter.filter(Array("[0m".utf8)) == Array("\u{1b}[0m".utf8))
        #expect(filter.filter(Array("\u{1b}c\u{1b}]11".utf8)).isEmpty)
        #expect(filter.finish() == Array("\u{1b}c\u{1b}]11".utf8), "a partial tail at the end is shown")
    }

    @Test func aResetInsideTheStreamIsKept() {
        // A program's own RIS mid-stream.
        let ris = Array("abc\u{1b}cdef".utf8)
        #expect(shown([ris + tail]) == ris)
        #expect(shown([ris]) == ris)
        // The whole sequence followed by more output is not the tail.
        let mid = body + tail + Array("more".utf8)
        for split in 0...mid.count {
            #expect(shown([Array(mid[..<split]), Array(mid[split...])]) == mid, "split at \(split)")
        }
        // Only the exact sequence: a variant is passed through.
        let variant = Array("\u{1b}c\u{1b}]110\u{1b}\\\u{1b}]111\u{1b}\\\u{1b}]113\u{1b}\\".utf8)
        #expect(shown([body + variant]) == body + variant)
        // The tail twice: only the last one goes.
        #expect(shown([body + tail + tail]) == body + tail)
    }

    @Test func emptyBatchesAreHarmless() {
        var filter = ZmxOutputFilter()
        #expect(filter.filter([]).isEmpty)
        #expect(filter.filter(Array(tail.prefix(3))).isEmpty)
        #expect(filter.filter([]).isEmpty)
        #expect(filter.filter(Array(tail.dropFirst(3))).isEmpty)
        #expect(filter.finish().isEmpty)
    }
}
