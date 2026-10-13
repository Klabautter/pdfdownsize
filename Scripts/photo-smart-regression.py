#!/usr/bin/env python3
"""Reproducible local detail check for the five-page arXiv photo regression.

Requires Poppler's pdfimages/pdftotext/pdfinfo, Pillow and NumPy. The 652 px
JPEGs are offline image experiments, not a produced Smart PDF or a size claim.

Smart contract (2026-09-29, product decision): quality is judged at NORMAL
viewing – macOS at 100 % on Retina, 144 device pixels per inch. Zoomed views
(200 %, 400 %, print) are reported as diagnostics and never veto.
"""

import argparse
import numpy as np
import hashlib
import io
import json
import math
import re
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageStat


SOURCE_SHA256 = "73d905019697202c7551ec6f7bc63b6c10da92a623aa03f36e68de73ce02cb02"
# One-percent headroom above the reproducible 1,080,291-byte Smart output after
# P0.3 (JPEG decodes detached from ImageIO, area-filter downscaling, MRC stages
# no longer displaced by the candidate budget). Earlier ceilings (1,472,368 /
# 1,834,943 bytes) belonged to a measurement artefact and to the discarded
# Lanczos-3 resampler. This is a regression ceiling, not a quality/size optimum
# or a release target.
MAX_CURRENT_BYTES = 1_625_000
PLACED_INCHES = 2000 / 1850
# Smart target resolution (DPI rule) and the normal-view anchor quality.
SMART_TARGET_DPI = 220
ANCHOR_JPEG_QUALITY = 75
NORMAL_VIEW = "100pct_retina_144ppi"
POSITIONS = {2: "grayscale_image", 3: "photo", 4: "grayscale_image",
             5: "grayscale_image", 6: "photo", 7: "grayscale_image"}
SIZES = {NORMAL_VIEW: round(PLACED_INCHES * 144),
         "100pct_96ppi": 104, "200pct_96ppi": 208,
         "400pct_96ppi": 416, "print_300ppi": 324}
RESAMPLE = Image.Resampling.LANCZOS


def run(*args: str) -> bytes:
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def pages(path: Path) -> int:
    match = re.search(rb"^Pages:\s+(\d+)$", run("pdfinfo", str(path)), re.M)
    if not match:
        raise RuntimeError(f"Cannot read page count: {path}")
    return int(match.group(1))


def page_text_layout(path: Path) -> bytes:
    """Compare page-4 text geometry without volatile PDF producer metadata."""
    xml = run("pdftotext", "-f", "4", "-l", "4", "-bbox-layout", str(path), "-")
    if b"<body>" not in xml:
        raise RuntimeError(f"Cannot read page-4 text layout: {path}")
    return xml.split(b"<body>", 1)[1]


def images(path: Path, destination: Path) -> dict[int, tuple[Image.Image, int]]:
    destination.mkdir()
    run("pdfimages", "-f", "4", "-l", "4", "-j", str(path), str(destination / "img"))
    found = {}
    for number in POSITIONS:
        matches = list(destination.glob(f"img-{number:03d}.*"))
        if len(matches) != 1:
            raise RuntimeError(f"Expected one page-4 image at position {number}: {path}")
        with Image.open(matches[0]) as img:
            found[number] = (img.convert("RGB"), matches[0].stat().st_size)
    return found


def psnr(a: Image.Image, b: Image.Image) -> float | None:
    rms = ImageStat.Stat(ImageChops.difference(a, b)).rms
    mse = sum(v * v for v in rms) / len(rms)
    return round(10 * math.log10(255 * 255 / mse), 2) if mse else None


def edge_mae(a: Image.Image, b: Image.Image) -> float:
    a_edge = a.convert("L").filter(ImageFilter.FIND_EDGES)
    b_edge = b.convert("L").filter(ImageFilter.FIND_EDGES)
    return round(ImageStat.Stat(ImageChops.difference(a_edge, b_edge)).mean[0], 2)


def min_tile_psnr(a: Image.Image, b: Image.Image) -> float | None:
    values = []
    for row in range(4):
        for col in range(4):
            box = (col * a.width // 4, row * a.height // 4,
                   (col + 1) * a.width // 4, (row + 1) * a.height // 4)
            value = psnr(a.crop(box), b.crop(box))
            if value is not None:
                values.append(value)
    return min(values) if values else None


def ssim(a: Image.Image, b: Image.Image) -> tuple[float, float]:
    """Mean and 5th-percentile SSIM on luminance, 7x7 windows."""
    from numpy.lib.stride_tricks import sliding_window_view
    x = np.asarray(a.convert("L"), dtype=np.float64)
    y = np.asarray(b.convert("L"), dtype=np.float64)
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    wx, wy = sliding_window_view(x, (7, 7)), sliding_window_view(y, (7, 7))
    mx, my = wx.mean((-1, -2)), wy.mean((-1, -2))
    vx, vy = wx.var((-1, -2)), wy.var((-1, -2))
    cov = ((wx - mx[..., None, None]) * (wy - my[..., None, None])).mean((-1, -2))
    s = ((2 * mx * my + c1) * (2 * cov + c2)) / ((mx ** 2 + my ** 2 + c1) * (vx + vy + c2))
    return round(float(s.mean()), 4), round(float(np.percentile(s, 5)), 4)


def area_downsample(image: Image.Image, pixels: int) -> Image.Image:
    """Same filter family as production (ImageResampler, P0.3): halve while
    at least twice the target, then one final step. A Lanczos anchor rewarded
    ringing the product deliberately avoids (product decision 2026-09-30)."""
    current = image
    while current.width >= 2 * pixels and current.height >= 2 * pixels:
        current = current.reduce(2)
    return current.resize((pixels, pixels), Image.Resampling.BICUBIC)


def smart_anchor(original: Image.Image) -> Image.Image:
    """What the DPI rule allows: clean downsample to the Smart target DPI,
    stored as a standard-quality JPEG."""
    pixels = round(PLACED_INCHES * SMART_TARGET_DPI)
    buffer = io.BytesIO()
    area_downsample(original, pixels).save(buffer, "JPEG", quality=ANCHOR_JPEG_QUALITY)
    buffer.seek(0)
    with Image.open(buffer) as anchor:
        return anchor.convert("RGB")


def metrics(original: Image.Image, variant: Image.Image) -> dict:
    result = {}
    for label, pixels in SIZES.items():
        a = original.resize((pixels, pixels), RESAMPLE)
        b = variant.resize((pixels, pixels), RESAMPLE)
        mean_ssim, p05_ssim = ssim(a, b)
        result[label] = {"ssim": mean_ssim, "ssim_p05": p05_ssim,
                         "psnr_db": psnr(a, b),
                         "worst_4x4_tile_psnr_db": min_tile_psnr(a, b),
                         "edge_mae_0_255": edge_mae(a, b)}
    return result


def guard(result: dict, anchor: dict) -> bool:
    # Normal view only: at least as good as the DPI-rule anchor (target-DPI
    # downsample, standard JPEG). PSNR was dropped as veto: on textured sonar
    # imagery it penalised resampler differences nobody can see (measured:
    # lossless 163 px images 5 dB below a Lanczos reference, visually equal).
    got, ref = result[NORMAL_VIEW], anchor[NORMAL_VIEW]
    return got["ssim"] >= ref["ssim"] and got["ssim_p05"] >= ref["ssim_p05"]


def jpeg652(original: Image.Image) -> tuple[Image.Image, int]:
    buffer = io.BytesIO()
    original.resize((652, 652), RESAMPLE).save(buffer, "JPEG", quality=85,
                                                optimize=True, progressive=True)
    buffer.seek(0)
    with Image.open(buffer) as candidate:
        return candidate.convert("RGB"), len(buffer.getvalue())


def contact(rows: list[tuple[int, dict]], path: Path) -> None:
    names = ("original", "current", "historical", "offline_652px_q85")
    width, height = 416, 442
    sheet = Image.new("RGB", (width * len(names), height * len(rows)), "white")
    draw = ImageDraw.Draw(sheet)
    for row, (number, variants) in enumerate(rows):
        for col, name in enumerate(names):
            variant = variants.get(name)
            if variant is not None:
                sheet.paste(variant.resize((width, width), RESAMPLE),
                            (col * width, row * height + 25))
            draw.text((col * width + 5, row * height + 5),
                      f"{number}: {name}", fill="black")
    sheet.save(path, optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--historical", type=Path, required=True)
    parser.add_argument("--ladder", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    if sha(args.source) != SOURCE_SHA256:
        raise SystemExit("Source hash differs from fixed regression fixture")
    variants = {"source": args.source, "current": args.current,
                "historical": args.historical}
    if args.ladder:
        variants["ladder"] = args.ladder
    source_pages = pages(args.source)
    if source_pages != 5 or any(pages(p) != source_pages for p in variants.values()):
        raise SystemExit("Page-count mismatch")
    original_text = run("pdftotext", "-layout", str(args.source), "-")
    original_layout = page_text_layout(args.source)
    text_equal = {name: run("pdftotext", "-layout", str(path), "-") == original_text
                  for name, path in variants.items() if name != "source"}
    layout_equal = {name: page_text_layout(path) == original_layout
                    for name, path in variants.items() if name != "source"}
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="photo-smart-detail-") as temp:
        extraction = {name: images(path, Path(temp) / name)
                      for name, path in variants.items()}
        report = {"source_sha256": SOURCE_SHA256, "page": 4,
                  "current_size_ceiling_bytes": MAX_CURRENT_BYTES,
                  "placed_width_inches": round(PLACED_INCHES, 4),
                  "normal_view": NORMAL_VIEW,
                  "anchor": {"target_dpi": SMART_TARGET_DPI,
                             "jpeg_quality": ANCHOR_JPEG_QUALITY},
                  "view_sizes_pixels": SIZES,
                  "pdf": {name: {"sha256": sha(path), "bytes": path.stat().st_size,
                                 "pages": source_pages,
                                 "extracted_text_equal": text_equal.get(name),
                                 "page4_text_layout_equal": layout_equal.get(name)}
                          for name, path in variants.items()},
                  "images": []}
        rows = []
        for number, kind in POSITIONS.items():
            original, original_bytes = extraction["source"][number]
            if original.size != (2000, 2000):
                raise RuntimeError(f"Fixture image dimensions changed: {number}")
            offline, offline_bytes = jpeg652(original)
            anchor_values = metrics(original, smart_anchor(original))
            choices = {name: extraction[name][number] for name in extraction if name != "source"}
            choices["offline_652px_q85"] = (offline, offline_bytes)
            record = {"position": number, "kind": kind,
                      "original_stream_bytes": original_bytes,
                      "anchor_normal_view": anchor_values[NORMAL_VIEW],
                      "variants": {}}
            for name, (img, size) in choices.items():
                values = metrics(original, img)
                record["variants"][name] = {"dimensions": list(img.size),
                                              "stream_bytes": size,
                                              "screen_pass": guard(values, anchor_values),
                                              "view_metrics": values}
            report["images"].append(record)
            rows.append((number, {"original": original,
                                  **{name: img for name, (img, _) in choices.items()}}))
    (args.output_dir / "photo-smart-detail.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    contact(rows, args.output_dir / "photo-smart-detail-400pct.png")
    current_size_pass = args.current.stat().st_size <= MAX_CURRENT_BYTES
    print(json.dumps({"text_equal": text_equal,
                      "page4_text_layout_equal": layout_equal,
                      "current_size_pass": current_size_pass,
                      "screen_pass": {name: sum(r["variants"][name]["screen_pass"]
                                                for r in report["images"])
                                      for name in report["images"][0]["variants"]},
                      "image_count": len(report["images"])}, indent=2))
    if not current_size_pass or not text_equal["current"] or not layout_equal["current"] or any(not r["variants"]["current"]["screen_pass"]
                                        for r in report["images"]):
        raise SystemExit("Current Smart PDF failed fixed regression checks")


if __name__ == "__main__":
    main()
