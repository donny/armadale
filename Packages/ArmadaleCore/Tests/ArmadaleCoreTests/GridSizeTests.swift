import Foundation
import Testing
@testable import ArmadaleCore

/// A session's last grid size (DESIGN §2, §3): recorded in one change,
/// repaired on load, taken over by a respawn, absent in older files.
@Suite("Session grid size")
@MainActor
struct GridSizeTests {
    private func model(sessions count: Int) -> (AppModel, [SessionID]) {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = model.workspace(workspace)!.tabGroups[0].id
        for _ in 1..<count { _ = model.newTab(in: group) }
        let ids = model.fillEmptyPanes()
        return (model, ids)
    }

    @Test func sizesAreRecordedInOneChange() throws {
        let (model, ids) = model(sessions: 3)
        let before = model.changeCount
        let sizes = [ids[0]: SessionGridSize(columns: 80, rows: 24), ids[1]: SessionGridSize(columns: 132, rows: 43)]
        #expect(model.setGridSizes(sizes))
        #expect(model.changeCount == before + 1, "one change for every size together")
        #expect(model.session(ids[0])?.gridSize == SessionGridSize(columns: 80, rows: 24))
        #expect(model.session(ids[1])?.gridSize == SessionGridSize(columns: 132, rows: 43))
        #expect(model.session(ids[2])?.gridSize == nil)
        // The same sizes again change nothing.
        #expect(!model.setGridSizes(sizes))
        #expect(model.changeCount == before + 1)
    }

    @Test func implausibleSizesAndUnknownSessionsAreIgnored() {
        let (model, ids) = model(sessions: 1)
        let before = model.changeCount
        #expect(!model.setGridSizes([
            ids[0]: SessionGridSize(columns: 0, rows: 24),
            .generate(): SessionGridSize(columns: 80, rows: 24),
        ]))
        #expect(!model.setGridSizes([ids[0]: SessionGridSize(columns: 80, rows: -1)]))
        #expect(!model.setGridSizes([ids[0]: SessionGridSize(columns: 100_000, rows: 24)]))
        #expect(model.changeCount == before)
        #expect(model.session(ids[0])?.gridSize == nil)
    }

    @Test(arguments: [
        (0, 24), (80, 0), (-3, 24), (80, -1), (SessionGridSize.maximumColumns + 1, 24),
        (80, SessionGridSize.maximumRows + 1), (Int.max, Int.max),
    ])
    func theRepairDropsNonsense(columns: Int, rows: Int) throws {
        let (model, ids) = model(sessions: 2)
        var state = model.persistedState
        state.sessions[0].gridSize = SessionGridSize(columns: columns, rows: rows)
        state.sessions[1].gridSize = SessionGridSize(columns: 80, rows: 24)
        let (repaired, issues) = state.repaired()
        #expect(repaired.sessions.first { $0.id == ids[0] }?.gridSize == nil)
        #expect(repaired.sessions.first { $0.id == ids[1] }?.gridSize == SessionGridSize(columns: 80, rows: 24))
        #expect(issues.count == 1)
        #expect(issues.first?.contains("grid size") == true)
    }

    @Test func plausibleBounds() {
        #expect(SessionGridSize(columns: 1, rows: 1).isPlausible)
        #expect(SessionGridSize(columns: SessionGridSize.maximumColumns, rows: SessionGridSize.maximumRows).isPlausible)
        #expect(!SessionGridSize(columns: 0, rows: 1).isPlausible)
    }

    @Test func aSizeRoundTripsAndIsAbsentWhenUnknown() throws {
        let (model, ids) = model(sessions: 2)
        model.setGridSizes([ids[0]: SessionGridSize(columns: 120, rows: 40)])
        let data = try StateStore.encode(model.persistedState)
        let decoded = try StateStore.decode(data)
        #expect(decoded.sessions.map(\.gridSize) == model.persistedState.sessions.map(\.gridSize))
        #expect(try StateStore.decode(StateStore.encode(decoded)) == decoded)
        #expect(decoded.sessions.first { $0.id == ids[0] }?.gridSize == SessionGridSize(columns: 120, rows: 40))
        // Only a recorded size is written.
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try #require(raw["sessions"] as? [[String: Any]])
        let written = sessions.first { $0["id"] as? String == ids[0].raw }
        let unwritten = sessions.first { $0["id"] as? String == ids[1].raw }
        #expect(written?["gridSize"] != nil)
        #expect(unwritten != nil && unwritten?["gridSize"] == nil)
    }

    /// Files of the versions before 0.1.2, which did not record grid
    /// sizes, have none: they decode as absent, so those sessions are
    /// attached when first shown. (0.1.2's fixture has one:
    /// `StateFixtureTests.contentOf012`.)
    @Test(arguments: ["0.1.0", "0.1.1"])
    func olderFilesHaveNone(version: String) throws {
        let state = try StateStore.decode(StateFixtureTests.fixture(version))
        #expect(!state.sessions.isEmpty)
        #expect(state.sessions.allSatisfy { $0.gridSize == nil })
    }

    @Test func aRespawnTakesOverThePanesSize() throws {
        let (model, ids) = model(sessions: 1)
        let size = SessionGridSize(columns: 101, rows: 33)
        model.setGridSizes([ids[0]: size])
        let old = try #require(model.session(ids[0]))
        let fresh = Session(location: old.location, profileID: old.profileID, launch: old.launch, workingDirectory: old.workingDirectory)
        model.replaceSession(old.id, with: fresh)
        #expect(model.session(fresh.id)?.gridSize == size)
        // A fresh session that brings its own keeps it.
        let other = SessionGridSize(columns: 90, rows: 20)
        var third = Session(profileID: old.profileID, launch: old.launch, workingDirectory: "/")
        third.gridSize = other
        model.replaceSession(fresh.id, with: third)
        #expect(model.session(third.id)?.gridSize == other)
    }
}
