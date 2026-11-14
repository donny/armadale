"""What a release would lose of a state file it loaded.

    /usr/bin/python3 -I scripts/state-fixtures/compare.py <given.json> <resaved.json> <accepted-drops>

`given.json` is the file the release was handed; `resaved.json` is the state
that release loaded and repaired, encoded again by its own StateStore (what
its next save would write). Prints one line per key path whose value the
release would drop or change, with array indices folded into `[*]`, and exits
1 if any of them is not listed in `accepted-drops`, 0 if none, and 2 on an
error (usage, a missing or unreadable file, a file that is not JSON). Not loss, and ignored: key order,
whitespace, the top-level `schemaVersion`, and keys the release adds.
Used by scripts/check-state-compat.sh.
"""

import json
import sys


def losses(given, resaved, path, found):
    """Adds to `found` (path: note) every path under `path` where `given` holds something
    `resaved` lacks or has differently."""
    if isinstance(given, dict):
        if not isinstance(resaved, dict):
            found[path or "(top level)"] = ""
            return
        for key, value in given.items():
            child = f"{path}.{key}" if path else key
            if child == "schemaVersion":
                continue
            if key not in resaved:
                found[child] = ""
            else:
                losses(value, resaved[key], child, found)
    elif isinstance(given, list):
        if not isinstance(resaved, list):
            found[path] = ""
            return
        if len(resaved) < len(given):
            found[f"{path}[*]"] = "items dropped"
        for index, value in enumerate(given[: len(resaved)]):
            losses(value, resaved[index], f"{path}[*]", found)
    else:
        # 1 and 1.0 are the same number; true and 1 are not the same value.
        if isinstance(given, bool) or isinstance(resaved, bool):
            same = type(given) is type(resaved) and given == resaved
        else:
            same = given == resaved
        if not same:
            found.setdefault(path, "")


def accepted(path):
    """The key paths in the accepted-drops file (first word of each line
    that is not blank or a comment)."""
    with open(path, encoding="utf-8") as handle:
        return {
            line.split()[0]
            for line in handle
            if line.strip() and not line.lstrip().startswith("#")
        }


def fail(message):
    print(f"compare.py: error: {message}", file=sys.stderr)
    sys.exit(2)


def main():
    if len(sys.argv) != 4:
        fail("usage: compare.py <given.json> <resaved.json> <accepted-drops>")
    try:
        with open(sys.argv[1], encoding="utf-8") as handle:
            given = json.load(handle)
        with open(sys.argv[2], encoding="utf-8") as handle:
            resaved = json.load(handle)
        allowed = accepted(sys.argv[3])
    except (OSError, ValueError) as error:
        fail(str(error))
    found = {}
    losses(given, resaved, "", found)
    unaccepted = 0
    for path in sorted(found):
        note = f" ({found[path]})" if found[path] else ""
        if path in allowed:
            print(f"{path}{note} (accepted)")
        else:
            print(f"{path}{note}")
            unaccepted += 1
    sys.exit(1 if unaccepted else 0)


if __name__ == "__main__":
    main()
