# State fixtures

One saved `state.json` per released version, written by that version's own
code, in `Packages/ArmadaleCore/Tests/ArmadaleCoreTests/Fixtures/state-<version>.json`.
`StateFixtureTests` loads each one with the working tree's code; the version
rule they hold is in `docs/DESIGN.md` section 3. Never edit a fixture by
hand, and never write one with a later version's code.

- `run.sh <tag> <program.swift> [args…]` builds one Swift file against the
  `ArmadaleCore` of a release tag (from a temporary `git worktree`, removed
  afterwards) and runs it; `--working-tree` instead of a tag uses the
  working tree's `ArmadaleCore`. Temporary files go under `$TMPDIR`.
- `v<version>.swift` is the generator for that release: it builds a state
  holding every kind of thing that version saves through its `AppModel` and
  writes it with its `StateStore`. A few shapes are added to the saved
  state directly: a workspace with no window state, which no version saves
  but older or hand-edited files hold (kept so decoding it stays covered),
  and in 0.1.1 and later a session without options, as one carried over
  from a 0.1.0 file is saved.
- `current.swift` is the same for the working tree. It must keep up with
  what the state file holds; `scripts/check-state-compat.sh` hands its
  output to every release tag.
- `load.swift` is what `check-state-compat.sh` runs against each tag: it
  loads a copy of the working tree's file with the tag's `StateStore` and,
  when the tag reads it, writes it again with the tag's own encoder.
- `compare.py` compares that with the file the tag was given and prints
  every key path the tag would drop or change at its next save.
- `accepted-drops` lists key paths whose loss is safe (no session ended,
  no layout lost), each with its reason; `check-state-compat.sh` passes a
  tag that loses only those. Empty today.

`scripts/check-state-compat.sh --as-schema 1` hands the tags the working
tree's file with its version set back to 1, which shows what the check
catches: 0.1.0 treats it as damaged, 0.1.1 reads it and would lose
`sessionListIncomplete` and `sparedSessionIDs`.

## Adding the fixture for a new release

Once the release is tagged (`v<version>`):

```sh
cp scripts/state-fixtures/current.swift scripts/state-fixtures/v<version>.swift
# edit its header comment: the command below, and that it is <version>'s generator
scripts/state-fixtures/run.sh v<version> scripts/state-fixtures/v<version>.swift \
    Packages/ArmadaleCore/Tests/ArmadaleCoreTests/Fixtures/state-<version>.json
```

Then add `"<version>": <schema it wrote>` to
`StateFixtureTests.writtenSchema` (the `schemaVersion` at the top of the new
fixture: 2 for a release of the current code) and a `contentOf…` test that
spot-checks what the generator set, and run the gate. The generator must compile against the tagged code, so if
`current.swift` has moved on since the tag, adapt the copy to the tag's API.

The existing fixtures were written on November 14, 2026 with:

```sh
scripts/state-fixtures/run.sh v0.1.0 scripts/state-fixtures/v0.1.0.swift \
    Packages/ArmadaleCore/Tests/ArmadaleCoreTests/Fixtures/state-0.1.0.json
scripts/state-fixtures/run.sh v0.1.1 scripts/state-fixtures/v0.1.1.swift \
    Packages/ArmadaleCore/Tests/ArmadaleCoreTests/Fixtures/state-0.1.1.json
```

IDs and creation times are random, so running a generator again gives a
different file with the same content; the tests look things up by name.
