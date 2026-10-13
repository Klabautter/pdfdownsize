#!/usr/bin/env python3
"""Build the deterministic 235-PDF reconciliation corpus as symlinks."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


QUOTAS = {
    "01_BornDigital_Text": 50,
    "02_Vector_Charts": 20,
    "03_Screenshots_UI": 20,
    "04_PhotoHeavy": 25,
    "05_Mixed_Content": 25,
    "06_Scans_Color": 20,
    "07_Scans_Grayscale": 15,
    "08_Scans_Monochrome": 15,
    "09_Scans_PhoneCamera": 15,
    "10_Already_Optimized": 15,
    "11_Maps_CAD_Technical": 15,
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inputs", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    inputs = args.inputs.resolve()
    out = args.out.resolve()
    if not inputs.is_dir():
        raise SystemExit(f"Input corpus does not exist: {inputs}")
    if out.exists() and any(out.iterdir()):
        raise SystemExit(f"Output directory must be empty: {out}")
    out.mkdir(parents=True, exist_ok=True)

    manifest: list[dict[str, str]] = []
    for category, quota in QUOTAS.items():
        candidates = sorted(
            (path.resolve() for path in (inputs / category).rglob("*.pdf")),
            key=str,
        )
        if len(candidates) < quota:
            raise SystemExit(
                f"{category}: requires {quota} PDFs, found {len(candidates)}"
            )
        category_out = out / category
        category_out.mkdir()
        for source in candidates[:quota]:
            destination = category_out / source.name
            if destination.exists() or destination.is_symlink():
                raise SystemExit(f"Duplicate output name: {destination}")
            destination.symlink_to(source)
            manifest.append({
                "category": category,
                "source": str(source),
                "link": str(destination.relative_to(out)),
            })

    (out / "core-235-manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"Built {len(manifest)} PDF links in {out}")


if __name__ == "__main__":
    main()
