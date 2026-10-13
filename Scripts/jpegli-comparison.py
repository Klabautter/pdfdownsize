"""Local codec screening, not a full PDF pipeline or perceptual equivalence claim."""
import argparse
import csv
import hashlib
import json
import math
import statistics
import subprocess
import time
from pathlib import Path

import numpy as np
from PIL import Image
from skimage.metrics import structural_similarity


def run(command):
    return subprocess.run(command, check=True, capture_output=True, timeout=180)


def metrics(reference, candidate):
    rgb = np.asarray(candidate.convert("RGB"), dtype=np.float32)
    if rgb.shape != reference.shape:
        raise ValueError("Encoder changed dimensions")
    weights = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    score, local = structural_similarity(
        reference @ weights, rgb @ weights, data_range=255, full=True,
        gaussian_weights=True, sigma=1.5, use_sample_covariance=False)
    # Tile averages expose concentrated damage hidden by a global average.
    h, w = local.shape
    tiles = [local[y:min(y + 64, h - 5), x:min(x + 64, w - 5)].mean()
             for y in range(5, h - 5, 64) for x in range(5, w - 5, 64)]
    mse = float(np.mean((reference - rgb) ** 2))
    return dict(ssim=float(score), tile_p05=float(np.percentile(tiles, 5)),
                rgb_psnr=10 * math.log10(255 ** 2 / max(mse, 1e-12)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mozjpeg", required=True)
    parser.add_argument("--jpegli", required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(args.manifest.read_text())
    selected = {"screenshot-ui", "photo-heavy", "mixed-content", "scan-color-mrc",
                "scan-grayscale", "phone-camera", "already-optimized"}
    checkpoint = args.output / "measurements.json"
    records = json.loads(checkpoint.read_text()) if checkpoint.exists() else []
    sources = []
    for case in manifest["cases"]:
        if case["id"] not in selected:
            continue
        folder = args.output / case["id"]
        folder.mkdir(exist_ok=True)
        source = Path(manifest["corpus_root"]).expanduser() / case["path"]
        run(["/opt/homebrew/bin/pdfimages", "-f", "1", "-l", "1", "-png",
             str(source), str(folder / "extracted")])
        images = []
        for path in sorted(folder.glob("extracted-*.png")):
            with Image.open(path) as im:
                if min(im.size) >= 128:
                    images.append((im.width * im.height, path))
        if not images:
            sources.append(dict(case=case["id"], skipped="No usable image on first page"))
            continue
        extracted = max(images, key=lambda item: item[0])[1]
        with Image.open(extracted) as im:
            original_size = im.size
            fixture = im.convert("RGB")
        fixture.thumbnail((2000, 2000), Image.Resampling.LANCZOS)
        fixture.save(folder / "reference.png")
        fixture.save(folder / "reference.ppm")
        raw = fixture.tobytes()
        (folder / "reference.rgb").write_bytes(raw)
        sources.append(dict(case=case["id"], pdf=str(source), extracted=extracted.name,
                            original_size=original_size, size=fixture.size,
                            sha256=hashlib.sha256(raw).hexdigest()))
        reference = np.asarray(fixture, dtype=np.float32)
        for quality in [20, 30, 40, 50, 55, 60, 65, 70, 75, 80, 85, 90, 93, 95, 97, 99]:
            for encoder in ["mozjpeg", "jpegli"]:
                if any(row["case"] == case["id"] and row["encoder"] == encoder
                       and row["quality"] == quality for row in records):
                    continue
                output = folder / f"{encoder}-{quality}.jpg"
                if encoder == "mozjpeg":
                    command = [args.mozjpeg, str(folder / "reference.rgb"),
                               str(fixture.width), str(fixture.height), str(quality), str(output)]
                else:
                    command = [args.jpegli, str(folder / "reference.ppm"), str(output),
                               "--quality", str(quality), "--chroma_subsampling=420"]
                durations = []
                for _ in range(3):
                    start = time.perf_counter()
                    run(command)
                    durations.append(time.perf_counter() - start)
                with Image.open(output) as decoded:
                    measured = metrics(reference, decoded)
                records.append(dict(case=case["id"], encoder=encoder, quality=quality,
                                    bytes=output.stat().st_size,
                                    seconds=statistics.median(durations), **measured))
            (args.output / "measurements.json").write_text(json.dumps(records, indent=2))
        print(f"Finished {case['id']}: {fixture.size}", flush=True)

    (args.output / "sources.json").write_text(json.dumps(sources, indent=2))
    with (args.output / "measurements.csv").open("w") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    profiles = {"balanced": (0.98, 0.93, 35), "high": (0.99, 0.97, 38)}
    matches = []
    for source in sources:
        if "skipped" in source:
            continue
        for profile, floors in profiles.items():
            match = dict(case=source["case"], profile=profile)
            for encoder in ["mozjpeg", "jpegli"]:
                passing = [row for row in records if row["case"] == source["case"]
                           and row["encoder"] == encoder and row["ssim"] >= floors[0]
                           and row["tile_p05"] >= floors[1] and row["rgb_psnr"] >= floors[2]]
                match[encoder] = min(passing, key=lambda row: row["bytes"]) if passing else None
            if match["mozjpeg"] and match["jpegli"]:
                match["jpegli_savings"] = 1 - match["jpegli"]["bytes"] / match["mozjpeg"]["bytes"]
            matches.append(match)
    (args.output / "matches.json").write_text(json.dumps(matches, indent=2))
    print(json.dumps(matches, indent=2))


if __name__ == "__main__":
    main()
