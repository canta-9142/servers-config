"""Retain recent published closures in the file binary cache, independently of the store.

Both callers must hold /run/lock/nix-cache-publish.lock.
"""

import argparse
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time

RETENTION = 14 * 24 * 60 * 60
STORE_NAME = re.compile(r"[0123456789abcdfghijklmnpqrsvwxyz]{32}-[^/\s]+")
NAR_URL = re.compile(r"nar/[A-Za-z0-9][A-Za-z0-9._+-]*")


def store_name(path):
    if not path.startswith("/nix/store/") or not STORE_NAME.fullmatch(path[11:]):
        raise ValueError(f"Invalid store path: {path}")
    return path[11:]


def load_state(path, now):
    if not path.exists():
        return {"initialized": now, "publications": []}
    state = json.loads(path.read_text())
    if not isinstance(state["initialized"], (int, float)) or not math.isfinite(state["initialized"]):
        raise ValueError("Invalid cache initialization time")
    for publication in state["publications"]:
        if (not isinstance(publication["time"], (int, float))
                or not math.isfinite(publication["time"]) or not publication["roots"]):
            raise ValueError("Invalid publication record")
        for root in publication["roots"]:
            store_name(root)
    return state


def save_state(path, state):
    # Replace atomically so an interrupted publication never leaves a partial record.
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            json.dump(state, output)
            output.flush()
            os.fsync(output.fileno())
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            temporary.unlink(missing_ok=True)


def read_fields(path):
    if path.is_symlink():
        raise ValueError(f"Unexpected symlink: {path}")
    return dict((key, value.strip()) for key, value in
                (line.split(":", 1) for line in path.read_text().splitlines() if ":" in line))


def read_info(cache, name):
    path = cache / (name[:32] + ".narinfo")
    fields = read_fields(path)
    if store_name(fields["StorePath"]) != name:
        raise ValueError(f"Store path does not match {path}")
    if not NAR_URL.fullmatch(fields["URL"]):
        raise ValueError(f"Invalid NAR URL in {path}")
    references = fields["References"].split()
    if any(not STORE_NAME.fullmatch(reference) for reference in references):
        raise ValueError(f"Invalid references in {path}")
    return fields["URL"], references


def closure(cache, roots):
    pending = [store_name(root) for root in roots]
    live = set()
    nars = set()
    while pending:
        name = pending.pop()
        if name[:32] in live:
            continue
        url, references = read_info(cache, name)
        nar = cache / url
        if nar.is_symlink() or not nar.is_file():
            raise ValueError(f"Missing or unsafe retained NAR: {nar}")
        live.add(name[:32])
        nars.add(nar)
        pending.extend(references)
    return live, nars


def record(cache, state_path, roots, now):
    if (cache / "nar").is_symlink():
        raise ValueError("The cache NAR directory must not be a symlink")
    closure(cache, roots)
    state = load_state(state_path, now)
    state["publications"].append({"time": now, "roots": roots})
    save_state(state_path, state)


def collect(cache, state_path, now, dry_run=False):
    state = load_state(state_path, now)
    if now - state["initialized"] < RETENTION or not state["publications"]:
        print("Cache GC skipped: initial 14-day grace period or no successful publication")
        if not dry_run:
            save_state(state_path, state)
        return
    # Always retain the latest successful publication, even after a long CI outage.
    retained = [entry for entry in state["publications"][:-1] if entry["time"] >= now - RETENTION]
    retained.append(state["publications"][-1])
    if (cache / "nar").is_symlink():
        raise ValueError("The cache NAR directory must not be a symlink")
    live, nars = closure(cache, [root for entry in retained for root in entry["roots"]])
    obsolete_info = []
    for info in sorted(cache.glob("*.narinfo")):
        # Validate every metadata file before deleting anything, including obsolete entries.
        fields = read_fields(info)
        name = store_name(fields["StorePath"])
        if info.name != name[:32] + ".narinfo":
            raise ValueError(f"Unexpected metadata filename: {info}")
        read_info(cache, name)
        if name[:32] not in live:
            obsolete_info.append(info)
    obsolete_nars = sorted(set((cache / "nar").glob("*.nar*")) - nars)
    for path in obsolete_nars:
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Unexpected cache entry: {path}")
    # ponytail: scan the whole file cache; use an indexed cache server if it outgrows this host.
    print(f"Cache GC: retain {len(retained)} publications; "
          f"{'would delete' if dry_run else 'delete'} {len(obsolete_info)} narinfos, {len(obsolete_nars)} NARs")
    # Withdraw metadata before removing payloads. Shared NAR URLs remain live.
    for path in obsolete_info + obsolete_nars:
        if dry_run:
            print(f"Would delete {path}")
        else:
            path.unlink()
    if not dry_run:
        state["publications"] = retained
        save_state(state_path, state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("record").add_argument("roots", nargs="+")
    commands.add_parser("gc").add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    cache = Path("/srv/nix-cache")
    state = Path("/var/lib/nix-cache/publications.json")
    if args.command == "record":
        record(cache, state, args.roots, time.time())
    else:
        collect(cache, state, time.time(), args.dry_run)


if __name__ == "__main__":
    main()
