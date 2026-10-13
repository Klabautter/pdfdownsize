#!/usr/bin/env python3
"""Reproduzierbarer PDF-Kompressionsvergleich fuer lokale und manuelle Engines."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import shutil
import statistics
import subprocess
import sys
import time
import unicodedata
from datetime import datetime, timezone
from pathlib import Path


GS_PRESETS = {
    "Klein": "/screen",
    "Smart": "/ebook",
    "Qualitaet": "/printer",
}


def run_process(arguments: list[str], timeout: int = 1200) -> tuple[int, str, float]:
    started = time.monotonic()
    try:
        result = subprocess.run(
            arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=timeout, check=False)
        return result.returncode, result.stdout[-4000:], time.monotonic() - started
    except subprocess.TimeoutExpired as error:
        output = (error.stdout or "") if isinstance(error.stdout, str) else ""
        return 124, (output + f"\nTIMEOUT nach {timeout}s")[-4000:], time.monotonic() - started


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def page_count(path: Path) -> int:
    code, output, _ = run_process(["pdfinfo", str(path)], timeout=120)
    if code != 0:
        return -1
    for line in output.splitlines():
        if line.startswith("Pages:"):
            try:
                return int(line.split(":", 1)[1].strip())
            except ValueError:
                return -1
    return -1


def qpdf_check(path: Path) -> str:
    code, output, _ = run_process(["qpdf", "--check", str(path)], timeout=180)
    if code == 0:
        return "ok"
    if code == 3:
        return "warnings"
    first = next((line for line in output.splitlines() if line.strip()), "")
    return f"fatal:exit{code}:{first}"[:500]


def load_suite(path: Path, include_stress: bool) -> tuple[dict, list[dict]]:
    suite = json.loads(path.read_text(encoding="utf-8"))
    cases = [case for case in suite["cases"]
             if include_stress or case.get("tier") != "stress"]
    root = Path(suite["corpus_root"]).expanduser()
    for case in cases:
        source = (root / case["path"]).resolve()
        if not source.is_file():
            raise SystemExit(f"Korpusdatei fehlt: {source}")
        case["source"] = str(source)
    return suite, cases


def output_name(case: dict, preset: str) -> str:
    relative = Path(case["path"])
    category = relative.parts[0]
    stem = relative.stem
    return f"{category}__{stem}__{preset}.pdf"


def record_for(case: dict, engine: str, preset: str, output: Path,
               runtime: float | None, exit_code: int, error: str) -> dict:
    source = Path(case["source"])
    input_bytes = source.stat().st_size
    exists = output.is_file() and output.stat().st_size > 0
    measured_output_bytes = output.stat().st_size if exists else None
    before = page_count(source)
    after = page_count(output) if exists else -1
    check = qpdf_check(output) if exists else "not-run"
    success = exit_code == 0 and exists and before == after and not check.startswith("fatal")
    # Ungueltige Ausgaben duerfen keinen scheinbaren Kompressionsgewinn liefern.
    output_bytes = measured_output_bytes if success else input_bytes
    return {
        "case_id": case["id"], "tier": case.get("tier", "core"),
        "source_path": case["path"], "engine": engine, "preset": preset,
        "input_bytes": input_bytes, "output_bytes": output_bytes,
        "measured_output_bytes": measured_output_bytes,
        "saved_percent": (1 - output_bytes / input_bytes) * 100 if input_bytes else 0,
        "runtime_seconds": runtime, "pages_before": before, "pages_after": after,
        "qpdf_check": check, "success": success,
        "error": "" if success else (error.strip() or f"exit {exit_code}")[:4000],
        "output_sha256": sha256(output) if exists else "",
        "output_path": str(output),
    }


def write_records(engine_dir: Path, records: list[dict]) -> None:
    engine_dir.mkdir(parents=True, exist_ok=True)
    (engine_dir / "records.json").write_text(
        json.dumps(records, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8")
    fields = list(records[0].keys()) if records else []
    with (engine_dir / "records.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(records)


def run_local(args: argparse.Namespace) -> None:
    suite, cases = load_suite(Path(args.suite), args.include_stress)
    manifest_cases = list(cases)
    if args.case_id:
        cases = [case for case in cases if case["id"] == args.case_id]
        if not cases:
            raise SystemExit(f"Unbekannte oder nicht aktivierte case-id: {args.case_id}")
    run_root = Path(args.out)
    engine_dir = run_root / "engines" / args.engine
    outputs = engine_dir / "outputs"
    outputs.mkdir(parents=True, exist_ok=True)
    records: list[dict] = []

    if args.engine == "ghostscript":
        executable = shutil.which("gs")
        if not executable:
            raise SystemExit("Ghostscript (gs) fehlt")
        presets = GS_PRESETS.items()
        if args.preset:
            presets = [(args.preset, GS_PRESETS[args.preset])]
        for case in cases:
            for preset, pdf_setting in presets:
                output = outputs / output_name(case, preset)
                command = [
                    executable, "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.7",
                    f"-dPDFSETTINGS={pdf_setting}", "-dNOPAUSE", "-dQUIET",
                    "-dBATCH", f"-sOutputFile={output}", case["source"],
                ]
                code, log, runtime = run_process(command, timeout=args.timeout)
                records.append(record_for(case, args.engine, preset, output,
                                          runtime, code, log))
                print(f"{args.engine} {case['id']} {preset}: "
                      f"{'ok' if records[-1]['success'] else 'FAIL'}")
    elif args.engine == "qpdf-lossless":
        executable = shutil.which("qpdf")
        if not executable:
            raise SystemExit("qpdf fehlt")
        for case in cases:
            preset = "Lossless"
            output = outputs / output_name(case, preset)
            command = [
                executable, "--object-streams=generate", "--recompress-flate",
                "--compression-level=9", case["source"], str(output),
            ]
            code, log, runtime = run_process(command, timeout=args.timeout)
            records.append(record_for(case, args.engine, preset, output,
                                      runtime, code, log))
            print(f"{args.engine} {case['id']}: "
                  f"{'ok' if records[-1]['success'] else 'FAIL'}")
    else:
        raise SystemExit(f"Unbekannte lokale Engine: {args.engine}")

    if args.append and (engine_dir / "records.json").is_file():
        previous = json.loads((engine_dir / "records.json").read_text(encoding="utf-8"))
        replaced = {(row["case_id"], row["preset"]) for row in records}
        records = [row for row in previous
                   if (row["case_id"], row["preset"]) not in replaced] + records
        records.sort(key=lambda row: (row["case_id"], row["preset"]))
    write_records(engine_dir, records)
    write_manifest(run_root, suite, manifest_cases)
    summarize_run(run_root)


def import_output(args: argparse.Namespace) -> None:
    suite, cases = load_suite(Path(args.suite), include_stress=True)
    case = next((item for item in cases if item["id"] == args.case_id), None)
    if not case:
        raise SystemExit(f"Unbekannte case-id: {args.case_id}")
    source_output = Path(args.file).resolve()
    if not source_output.is_file():
        raise SystemExit(f"Ausgabe fehlt: {source_output}")
    run_root = Path(args.out)
    engine_dir = run_root / "engines" / args.engine
    outputs = engine_dir / "outputs"
    outputs.mkdir(parents=True, exist_ok=True)
    destination = outputs / output_name(case, args.preset)
    shutil.copy2(source_output, destination)
    records_path = engine_dir / "records.json"
    records = json.loads(records_path.read_text(encoding="utf-8")) \
        if records_path.is_file() else []
    records = [row for row in records if not (
        row["case_id"] == case["id"] and row["preset"] == args.preset)]
    records.append(record_for(case, args.engine, args.preset, destination,
                              args.runtime, 0, ""))
    records.sort(key=lambda row: (row["case_id"], row["preset"]))
    write_records(engine_dir, records)
    write_manifest(run_root, suite, cases)
    summarize_run(run_root)


def record_failure(args: argparse.Namespace) -> None:
    suite, cases = load_suite(Path(args.suite), include_stress=True)
    case = next((item for item in cases if item["id"] == args.case_id), None)
    if not case:
        raise SystemExit(f"Unbekannte case-id: {args.case_id}")
    run_root = Path(args.out)
    engine_dir = run_root / "engines" / args.engine
    output = engine_dir / "outputs" / output_name(case, args.preset)
    records_path = engine_dir / "records.json"
    records = json.loads(records_path.read_text(encoding="utf-8")) \
        if records_path.is_file() else []
    records = [row for row in records if not (
        row["case_id"] == case["id"] and row["preset"] == args.preset)]
    records.append(record_for(case, args.engine, args.preset, output,
                              args.runtime, 1, args.reason))
    records.sort(key=lambda row: (row["case_id"], row["preset"]))
    write_records(engine_dir, records)
    write_manifest(run_root, suite, cases)
    summarize_run(run_root)


def import_quality(args: argparse.Namespace) -> None:
    run_root = Path(args.out)
    engine_dir = run_root / "engines" / args.engine
    records_path = engine_dir / "records.json"
    if not records_path.is_file():
        raise SystemExit(f"records.json fehlt: {records_path}")
    records = json.loads(records_path.read_text(encoding="utf-8"))
    allowed = {
        (Path(row["source_path"]).parts[0], Path(row["source_path"]).stem,
         normalized(row["preset"]))
        for row in records if row["success"]
    }
    source = Path(args.source_quality)
    with source.open(encoding="utf-8", newline="") as handle:
        source_rows = list(csv.DictReader(handle))
        fields = list(source_rows[0].keys()) if source_rows else []
    selected = [row for row in source_rows if (
        row["category"], row["stem"], normalized(row["preset"])) in allowed]
    with (engine_dir / "quality.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(selected)
    summarize_run(run_root)


def normalized(value: str) -> str:
    return unicodedata.normalize("NFC", value)


def find_smoke_output(source_run: Path, record: dict) -> Path | None:
    category = record["category"]
    stem = Path(record["inputPath"]).stem
    preset = normalized(record["preset"])
    for candidate in (source_run / "outputs").glob(f"{category}__{stem}__*.pdf"):
        candidate_preset = normalized(candidate.stem.rsplit("__", 1)[-1])
        if candidate_preset == preset:
            return candidate
    return None


def import_pdftools_run(args: argparse.Namespace) -> None:
    suite, cases = load_suite(Path(args.suite), args.include_stress)
    source_run = Path(args.source_run).resolve()
    summary_path = source_run / "summary.json"
    if not summary_path.is_file():
        raise SystemExit(f"Smoke-Zusammenfassung fehlt: {summary_path}")
    smoke = json.loads(summary_path.read_text(encoding="utf-8"))
    by_name_and_preset = {
        (Path(row["inputPath"]).name, normalized(row["preset"])): row
        for row in smoke.get("records", [])
    }
    run_root = Path(args.out)
    engine_dir = run_root / "engines" / args.engine
    outputs = engine_dir / "outputs"
    outputs.mkdir(parents=True, exist_ok=True)
    records: list[dict] = []
    for case in cases:
        for preset in ("Klein", "Smart", "Qualität"):
            smoke_record = by_name_and_preset.get(
                (Path(case["path"]).name, normalized(preset)))
            destination = outputs / output_name(case, preset)
            if not smoke_record:
                records.append(record_for(
                    case, args.engine, preset, destination, None, 1,
                    f"Kein Ergebnis in {source_run}"))
                continue
            smoke_output = find_smoke_output(source_run, smoke_record)
            if smoke_record.get("success") and smoke_output:
                shutil.copy2(smoke_output, destination)
                code = 0
                error = ""
            else:
                code = 1
                error = smoke_record.get("error") or "Smoke-Lauf fehlgeschlagen"
            records.append(record_for(
                case, args.engine, preset, destination,
                smoke_record.get("runtimeSeconds"), code, error))
    write_records(engine_dir, records)
    write_manifest(run_root, suite, cases)
    summarize_run(run_root)


def write_manifest(run_root: Path, suite: dict, cases: list[dict]) -> None:
    run_root.mkdir(parents=True, exist_ok=True)
    clean_cases = [{key: value for key, value in case.items() if key != "source"}
                   for case in cases]
    manifest = {
        "schema": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "suite": suite["name"],
        "corpus_root": suite["corpus_root"],
        "cases": clean_cases,
        "host": {
            "platform": sys.platform,
            "python": sys.version.split()[0],
            "ghostscript": tool_version(["gs", "--version"]),
            "qpdf": tool_version(["qpdf", "--version"]),
        },
    }
    (run_root / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8")


def tool_version(command: list[str]) -> str:
    if not shutil.which(command[0]):
        return "not-installed"
    code, output, _ = run_process(command, timeout=30)
    return output.strip().splitlines()[0] if code == 0 and output.strip() else f"exit-{code}"


def quality_by_scope(engine_dir: Path, records: list[dict]) -> dict[tuple[str, str], dict]:
    path = engine_dir / "quality.csv"
    if not path.is_file():
        return {}
    tier_by_identity = {
        (Path(row["source_path"]).parts[0], Path(row["source_path"]).stem,
         normalized(row["preset"])): row["tier"]
        for row in records if row["success"]
    }
    grouped: dict[tuple[str, str], list[dict]] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            preset = normalized(row["preset"])
            tier = tier_by_identity.get((row["category"], row["stem"], preset))
            if not tier:
                continue
            grouped.setdefault((preset, tier), []).append(row)
            grouped.setdefault((preset, "all"), []).append(row)
    result = {}
    for key, rows in grouped.items():
        result[key] = {
            "quality_pairs": len(rows),
            "ssim_mean": statistics.fmean(float(row["ssim_mean"]) for row in rows),
            "ssim_min": min(float(row["ssim_min"]) for row in rows),
            "docs_below_090": sum(float(row["ssim_min"]) < 0.90 for row in rows),
            "car_max": max(float(row["car_max"]) for row in rows),
        }
    return result


def summarize_run(run_root: Path) -> None:
    rows = []
    engines_root = run_root / "engines"
    if not engines_root.is_dir():
        return
    for engine_dir in sorted(path for path in engines_root.iterdir() if path.is_dir()):
        records_path = engine_dir / "records.json"
        if not records_path.is_file():
            continue
        records = json.loads(records_path.read_text(encoding="utf-8"))
        quality = quality_by_scope(engine_dir, records)
        for preset in sorted({row["preset"] for row in records}):
            preset_rows = [row for row in records if row["preset"] == preset]
            scopes = [("core", [row for row in preset_rows if row["tier"] == "core"])]
            stress = [row for row in preset_rows if row["tier"] == "stress"]
            if stress:
                scopes.extend((("stress", stress), ("all", preset_rows)))
            for scope, selected in scopes:
                if not selected:
                    continue
                successful = [row for row in selected if row["success"]]
                input_bytes = sum(row["input_bytes"] for row in selected)
                output_bytes = sum(row["output_bytes"] for row in selected)
                runtimes = [row["runtime_seconds"] for row in successful
                            if row["runtime_seconds"] is not None]
                row = {
                    "engine": engine_dir.name, "preset": preset, "scope": scope,
                    "ok": len(successful), "failed": len(selected) - len(successful),
                    "input_bytes": input_bytes, "output_bytes": output_bytes,
                    "weighted_saving_percent":
                        (1 - output_bytes / input_bytes) * 100 if input_bytes else 0,
                    "median_runtime_seconds": statistics.median(runtimes) if runtimes else None,
                }
                row.update(quality.get((normalized(preset), scope), {}))
                rows.append(row)
    (run_root / "summary.json").write_text(
        json.dumps(rows, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8")
    write_report(run_root, rows)


def write_report(run_root: Path, rows: list[dict]) -> None:
    lines = [
        "# PDF Compression Competition Benchmark",
        "",
        "Gewichtete Ersparnis = 1 - Summe(Output) / Summe(Input). "
        "Fehler werden fail-closed mit Inputgroesse gewertet.",
        "",
        "| Engine | Modus | Bereich | ok | fail | Ersparnis | Median Laufzeit | "
        "Qual.-Paare | SSIM mean/min | Docs <0,90 | max CAR |",
        "|---|---|---|--:|--:|--:|--:|--:|--:|--:|--:|",
    ]
    for row in rows:
        runtime = "-" if row["median_runtime_seconds"] is None \
            else f"{row['median_runtime_seconds']:.2f}s"
        quality = "-" if "ssim_mean" not in row \
            else f"{row['ssim_mean']:.4f}/{row['ssim_min']:.4f}"
        below = str(row.get("docs_below_090", "-"))
        car = "-" if "car_max" not in row else f"{row['car_max']:.3f}"
        pairs = str(row.get("quality_pairs", "-"))
        lines.append(
            f"| {row['engine']} | {row['preset']} | {row['scope']} | {row['ok']} | "
            f"{row['failed']} | {row['weighted_saving_percent']:.1f}% | "
            f"{runtime} | {pairs} | {quality} | {below} | {car} |")
    lines += [
        "",
        "## Fairness-Regeln",
        "",
        "- Fremde Preset-Namen werden nicht als qualitaetsgleich angenommen; "
        "entscheidend sind die gemessenen SSIM/CAR-Werte.",
        "- Seitenzahl und qpdf-Strukturpruefung muessen bestehen.",
        "- Manuelle/Web-Ausgaben werden unveraendert importiert; fehlende "
        "Laufzeiten bleiben leer.",
        "- Core- und Stress-Faelle bleiben im Manifest getrennt markiert.",
        "",
    ]
    (run_root / "report.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    local = sub.add_parser("run-local")
    local.add_argument("--suite", required=True)
    local.add_argument("--out", required=True)
    local.add_argument("--engine", choices=["ghostscript", "qpdf-lossless"], required=True)
    local.add_argument("--include-stress", action="store_true")
    local.add_argument("--case-id")
    local.add_argument("--preset", choices=list(GS_PRESETS))
    local.add_argument("--append", action="store_true")
    local.add_argument("--timeout", type=int, default=1200)
    local.set_defaults(function=run_local)

    imported = sub.add_parser("import-output")
    imported.add_argument("--suite", required=True)
    imported.add_argument("--out", required=True)
    imported.add_argument("--engine", required=True)
    imported.add_argument("--preset", required=True)
    imported.add_argument("--case-id", required=True)
    imported.add_argument("--file", required=True)
    imported.add_argument("--runtime", type=float)
    imported.set_defaults(function=import_output)

    failed = sub.add_parser("record-failure")
    failed.add_argument("--suite", required=True)
    failed.add_argument("--out", required=True)
    failed.add_argument("--engine", required=True)
    failed.add_argument("--preset", required=True)
    failed.add_argument("--case-id", required=True)
    failed.add_argument("--runtime", type=float)
    failed.add_argument("--reason", required=True)
    failed.set_defaults(function=record_failure)

    quality = sub.add_parser("import-quality")
    quality.add_argument("--out", required=True)
    quality.add_argument("--engine", required=True)
    quality.add_argument("--source-quality", required=True)
    quality.set_defaults(function=import_quality)

    pdftools = sub.add_parser("import-pdftools-run")
    pdftools.add_argument("--suite", required=True)
    pdftools.add_argument("--out", required=True)
    pdftools.add_argument("--source-run", required=True)
    pdftools.add_argument("--engine", default="pdftools-v2")
    pdftools.add_argument("--include-stress", action="store_true")
    pdftools.set_defaults(function=import_pdftools_run)

    summary = sub.add_parser("summarize")
    summary.add_argument("--out", required=True)
    summary.set_defaults(function=lambda args: summarize_run(Path(args.out)))
    args = parser.parse_args()
    args.function(args)


if __name__ == "__main__":
    main()
