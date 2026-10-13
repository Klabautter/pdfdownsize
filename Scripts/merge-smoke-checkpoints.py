#!/usr/bin/env python3
"""Merge parallel smoke-mode checkpoints into one resumable run directory."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


def load_records(run: Path) -> list[dict]:
    checkpoint = run / "checkpoint.json"
    if not checkpoint.is_file():
        raise SystemExit(f"Checkpoint does not exist: {checkpoint}")
    return json.loads(checkpoint.read_text(encoding="utf-8"))


def copy_tree_files(source: Path, destination: Path) -> None:
    if not source.is_dir():
        return
    destination.mkdir(parents=True, exist_ok=True)
    for item in source.iterdir():
        if item.is_file():
            shutil.copy2(item, destination / item.name)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--source", required=True, action="append", type=Path)
    args = parser.parse_args()

    target = args.target.resolve()
    by_key: dict[tuple[str, str], dict] = {}
    runs = ([target] if (target / "checkpoint.json").exists() else []) + [source.resolve() for source in args.source]
    identities = [json.loads((run / "baseline-identity.json").read_text()) for run in runs]
    if not identities or any(identity != identities[0] for identity in identities):
        raise SystemExit("Merge refused: missing or different baseline identities")
    for run in runs:
        for record in load_records(run):
            key = (record["inputPath"], record["preset"])
            if key in by_key and by_key[key] != record:
                raise SystemExit(f"Merge refused: conflicting operation {key}")
            by_key[key] = record
    # All identities and records validated before any mutation.
    target.mkdir(parents=True, exist_ok=True)
    for run in runs:
        if run != target:
            copy_tree_files(run / "outputs", target / "outputs")
            copy_tree_files(run / "errors", target / "errors")

    (target / "baseline-identity.json").write_text(
        json.dumps(identities[0], indent=2, sort_keys=True) + "\n", encoding="utf-8")
    records = sorted(by_key.values(), key=lambda row: (row["preset"], row["inputPath"]))
    temporary = target / "checkpoint.json.tmp"
    temporary.write_text(
        json.dumps(records, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(target / "checkpoint.json")
    print(f"Merged {len(records)} operations into {target}")


if __name__ == "__main__":
    main()
