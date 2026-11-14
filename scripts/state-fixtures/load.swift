// Loads a state file with the `StateStore.load` of whichever ArmadaleCore it
// is built against, and prints how that version answers, as one line:
// `loaded`, or `newerVersion`, `unparseable` or `ioError` followed by a tab
// and the load result (on one line, shortened). When it loaded and a second
// path is given, also writes there the loaded state after that version's
// own repair (`PersistedState.repaired()`, which every released app applies
// before its first save), encoded by its own `StateStore.encode`: what its
// next save would write as far as its load and repair decide it. Changes
// its `AppModel` makes at launch or later are not modelled. Used by
// scripts/check-state-compat.sh against every release tag:
//
//   scripts/state-fixtures/run.sh <tag> scripts/state-fixtures/load.swift <copy/of/state.json> [resaved.json]
//
// Loading moves a damaged file aside, so always hand it a copy. Written
// against what every released StateStore has (`load(from:)`, `encode(_:)`,
// `repaired()` and the four outcomes), matched without their associated values, which
// differ between versions.
import ArmadaleCore
import Foundation

@main
enum Load {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 || arguments.count == 3 else {
            FileHandle.standardError.write(Data("usage: \(arguments[0]) <state.json> [resaved.json]\n".utf8))
            exit(2)
        }
        let result = StateStore.load(from: URL(fileURLWithPath: arguments[1]))
        let answer: String
        if case .loaded = result {
            answer = "loaded"
        } else if case .newerVersion = result {
            answer = "newerVersion"
        } else if case .unparseable = result {
            answer = "unparseable"
        } else if case .ioError = result {
            answer = "ioError"
        } else {
            answer = "other"
        }
        guard answer != "loaded" else {
            if arguments.count == 3, let state = result.state {
                try StateStore.encode(state.repaired().state).write(to: URL(fileURLWithPath: arguments[2]))
            }
            print(answer)
            return
        }
        let detail = String(describing: result).split(whereSeparator: \.isNewline).joined(separator: " ")
        print("\(answer)\t\(detail.prefix(400))")
    }
}
