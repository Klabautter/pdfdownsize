#!/usr/bin/env python3
"""Replay fixed-view diagnostics; numerical screens never grant acceptance."""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / 'benchmark/feature-freeze-20260928/independent-pilot/targeted/chart'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    reference = CHART / 'input-200.png'
    spec = json.loads((CHART / 'protected-screen/regions.json').read_text())
    if sha(reference) != spec['reference_sha256']:
        raise SystemExit('Frozen reference changed')
    for name, box in [('a', [84, 31, 346, 271]), ('b', [499, 31, 761, 271]),
                      ('c', [914, 31, 1176, 271]), ('d', [84, 356, 346, 595]),
                      ('e', [499, 356, 761, 595]), ('f', [914, 356, 1176, 595])]:
        spec['regions'].append(dict(id='plot-' + name, kind='diagram_data',
                                    box=box, minimum_psnr_db=25))
    manifest = args.out / 'regions.json'
    manifest.write_text(json.dumps(spec, indent=2) + '\n')
    with Image.open(reference) as source:
        source = source.convert('RGB')
        candidates = [('identical', source.copy(), 'identity')]
        for ppi in (180, 168, 144, 96):
            size = tuple(round(n * ppi / spec['reference_ppi']) for n in source.size)
            candidate = source.resize(size, Image.Resampling.LANCZOS).resize(source.size, Image.Resampling.LANCZOS)
            candidates.append((f'downsample-{ppi}ppi', candidate, f'LANCZOS {size}, reconstructed to reference extent'))
        altered = source.copy()
        ImageDraw.Draw(altered).rectangle((555, 125, 575, 145), fill='white')
        candidates.append(('erased-data-patch', altered, 'white rectangle in plot b: [555,125,576,146)'))
        missing_plot = source.copy()
        ImageDraw.Draw(missing_plot).rectangle((499, 31, 760, 270), fill='white')
        candidates.append(('erased-entire-plot', missing_plot, 'white plot-b interior'))
    rows = []
    for name, candidate, method in candidates:
        path, report = args.out / (name + '.png'), args.out / (name + '.json')
        candidate.save(path)
        command = [sys.executable, str(ROOT / 'Scripts/smart_detail_screen.py'),
                   '--reference', str(reference), '--candidate', str(path),
                   '--regions', str(manifest), '--output', str(report)]
        run = subprocess.run(command, capture_output=True, text=True)
        if run.returncode not in (0, 1) or not report.is_file():
            raise SystemExit(f'{name}: missing report or unexpected exit: {run.stderr}')
        result = json.loads(report.read_text())
        if run.returncode != (0 if result['protected_screen_pass'] else 1):
            raise SystemExit(f'{name}: report and exit disagree')
        rows.append(dict(candidate=name, method=method, command=command, exit_code=run.returncode,
                         image_sha256=sha(path), report_sha256=sha(report),
                         protected_screen_pass=result['protected_screen_pass'],
                         regions=result['protected_regions'], semantic_acceptance='pending'))
    if not rows[0]['protected_screen_pass'] or rows[-1]['protected_screen_pass']:
        raise SystemExit('Identity or erased-entire-plot diagnostic control failed')
    summary = dict(reference_sha256=sha(reference), regions_sha256=sha(manifest),
                   screen_script_sha256=sha(ROOT / 'Scripts/smart_detail_screen.py'),
                   generator_sha256=sha(Path(__file__)), candidates=rows,
                   release_accepted=False,
                   limitation='Synthetic downsampling is not production pipeline validation; readability and data fidelity need semantic review. Thresholds remain provisional.')
    (args.out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps([dict(candidate=r['candidate'], screen_pass=r['protected_screen_pass']) for r in rows]))

if __name__ == '__main__':
    main()
