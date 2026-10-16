import Darwin
import Foundation
import Testing
@testable import ArmadaleSessions

@Suite("ProcessFootprint")
struct ProcessFootprintTests {
    /// A child that allocates and touches 64 MB reads as above the 32 MB
    /// flood limit; a small one well below it.
    @Test func reportsAGrowingChild() async throws {
        let big = Process()
        big.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        big.arguments = ["-e", "$| = 1; my $x = \"a\" x (64 * 1024 * 1024); print \"ready\\n\"; sleep 30"]
        let pipe = Pipe()
        big.standardOutput = pipe
        try big.run()
        defer { big.terminate() }
        _ = pipe.fileHandleForReading.availableData // "ready": the memory is in use
        let footprint = try #require(ProcessFootprint.bytes(of: big.processIdentifier))
        #expect(footprint > 32 * 1024 * 1024, "\(footprint) bytes")

        let small = Process()
        small.executableURL = URL(fileURLWithPath: "/bin/sleep")
        small.arguments = ["30"]
        try small.run()
        defer { small.terminate() }
        try await Task.sleep(for: .milliseconds(100))
        let smallFootprint = try #require(ProcessFootprint.bytes(of: small.processIdentifier))
        #expect(smallFootprint < 8 * 1024 * 1024, "\(smallFootprint) bytes")
        // Gone or foreign processes read as nil.
        #expect(ProcessFootprint.bytes(of: 1) == nil, "launchd belongs to root")
    }
}
