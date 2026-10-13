#!/usr/bin/env python3
"""Offline candidate diagnostics at fixed viewing conditions; no production gate.

Regions and their provisional thresholds must be frozen from the reference before
examining candidates. A passing numerical screen never grants semantic acceptance.
Requires Pillow. Coordinates use the reference raster, top-left origin.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageStat


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def psnr(a, b):
    mse = sum(v * v for v in ImageStat.Stat(ImageChops.difference(a, b)).rms) / 3
    return 10 * math.log10(255 * 255 / mse) if mse else None


def validate(spec, reference):
    if spec.get("reference_size") != list(reference.size):
        raise ValueError("Reference dimensions differ from frozen regions")
    ppi = spec.get("reference_ppi")
    if isinstance(ppi, bool) or not isinstance(ppi, (float, int)) or not math.isfinite(ppi) or ppi <= 0:
        raise ValueError("Missing or invalid physical reference ppi")
    regions = spec.get("regions")
    if not isinstance(regions, list) or not regions:
        raise ValueError("Protected regions are required; absence is not a pass")
    identifiers = set()
    for region in regions:
        name = region.get("id")
        if not isinstance(name, str) or not name or name in identifiers:
            raise ValueError("Region IDs must be unique and nonempty")
        identifiers.add(name)
        if region.get("kind") not in ("raster_text", "line", "diagram_data"):
            raise ValueError("Unknown protected content type")
        box = region.get("box")
        if not isinstance(box, list) or len(box) != 4 or any(type(v) is not int for v in box):
            raise ValueError("Region coordinates must be four integers")
        x0, y0, x1, y1 = box
        if not (0 <= x0 < x1 <= reference.width and 0 <= y0 < y1 <= reference.height):
            raise ValueError("Region outside reference; silent padding is forbidden")
        floor = region.get("minimum_psnr_db")
        if isinstance(floor, bool) or not isinstance(floor, (int, float)) or not math.isfinite(floor) or floor <= 0:
            raise ValueError("Each region needs an explicit calibrated screen floor")


def evaluate(reference, candidate, spec):
    validate(spec, reference)
    if candidate.size != reference.size:
        raise ValueError("Candidate must use identical renderer, box and reference ppi")
    reference, candidate = reference.convert("RGB"), candidate.convert("RGB")
    views = []
    for ppi in (96, 192, 300, 384):
        size = tuple(max(1, round(n * ppi / spec["reference_ppi"])) for n in reference.size)
        a = reference.resize(size, Image.Resampling.LANCZOS)
        b = candidate.resize(size, Image.Resampling.LANCZOS)
        views.append({"ppi": ppi, "size": list(size), "psnr_db": psnr(a, b),
                      "diagnostic_only": ppi == 384})
    regions = []
    for region in spec["regions"]:
        # Crop BEFORE pooling; never enlarge a small protected crop to 320 px.
        a, b = (im.crop(region["box"]) for im in (reference, candidate))
        score = psnr(a, b)
        regions.append({**region, "psnr_db": score,
                        "screen_pass": score is None or score >= region["minimum_psnr_db"]})
    return {"view_metrics": views, "protected_regions": regions,
            "protected_screen_pass": all(r["screen_pass"] for r in regions),
            "semantic_acceptance": "pending",
            "release_accepted": False,
            "limitations": "Local PSNR is a calibrated screening signal, not OCR, line topology or data fidelity proof. Region coverage and visual/semantic approval remain required. 384 ppi is diagnostic only."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--regions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    spec = json.loads(args.regions.read_text())
    if digest(args.reference) != spec.get("reference_sha256"):
        raise SystemExit("Reference hash differs from frozen regions")
    with Image.open(args.reference) as reference, Image.open(args.candidate) as candidate:
        report = evaluate(reference, candidate, spec)
    report.update(reference_sha256=digest(args.reference),
                  candidate_sha256=digest(args.candidate), regions_sha256=digest(args.regions))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"protected_screen_pass": report["protected_screen_pass"],
                      "semantic_acceptance": report["semantic_acceptance"]}))
    if not report["protected_screen_pass"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
