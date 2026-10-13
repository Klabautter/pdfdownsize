#!/usr/bin/env python3
"""Isolated Brotli/Flate bakeoff. Never rewrites PDFs or enables a production codec.
Install Brotli into a disposable venv. Input bytes are read through qpdf; only
single-filter Flate streams are tested. Predictor bytes remain unchanged.
Catalog-bearing object streams and xref streams are excluded conservatively.
"""
import argparse
import hashlib
import json
import subprocess
import time
import zlib
from pathlib import Path
import brotli


def benchmark(path, qpdf, maximum_stream_bytes, maximum_streams):
    graph = json.loads(subprocess.check_output(
        [qpdf, '--json', '--json-stream-data=none', str(path)]))['qpdf'][1]
    rows, skipped = [], []
    for key, obj in graph.items():
        stream = obj.get('stream')
        if not stream:
            continue
        dictionary = stream['dict']
        if dictionary.get('/Filter') != '/FlateDecode':
            continue
        reason = None
        if dictionary.get('/Type') in ('/ObjStm', '/XRef'):
            reason = 'discovery-or-object-stream'
        elif not isinstance(dictionary.get('/Length'), int):
            reason = 'indirect-or-unknown-length'
        elif dictionary['/Length'] > maximum_stream_bytes:
            reason = 'compressed-stream-budget'
        elif len(rows) >= maximum_streams:
            reason = 'stream-count-budget'
        if reason:
            skipped.append({'object': key, 'reason': reason})
            continue
        number, generation, _ = key.removeprefix('obj:').split()
        encoded = subprocess.check_output([qpdf, f'--show-object={number},{generation}',
                                           '--raw-stream-data', str(path)])
        decoder = zlib.decompressobj()
        raw = decoder.decompress(encoded, maximum_stream_bytes + 1)
        if len(raw) > maximum_stream_bytes or decoder.unconsumed_tail:
            skipped.append({'object': key, 'reason': 'decoded-stream-budget'})
            continue
        if not decoder.eof or decoder.unused_data:
            raise ValueError(f'Invalid Flate stream: {key}')
        row = {'object': key, 'type': dictionary.get('/Subtype', dictionary.get('/Type', 'other')),
               'decoded_bytes': len(raw), 'original_flate_bytes': len(encoded),
               'predictor_parameters': dictionary.get('/DecodeParms'),
               'zlib9_bytes': len(zlib.compress(raw, 9))}
        for quality in (9, 11):
            start = time.perf_counter()
            candidate = brotli.compress(raw, quality=quality, mode=brotli.MODE_GENERIC)
            row[f'brotli{quality}_ms'] = round((time.perf_counter() - start) * 1000, 3)
            if brotli.decompress(candidate) != raw:
                raise ValueError(f'Brotli roundtrip mismatch: {key}')
            row[f'brotli{quality}_bytes'] = len(candidate)
        rows.append(row)
    original = sum(r['original_flate_bytes'] for r in rows)
    saved = sum(max(0, r['original_flate_bytes'] - r['brotli11_bytes']) for r in rows)
    return {'input': str(path.resolve()), 'input_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'input_bytes': path.stat().st_size, 'tested_streams': len(rows),
            'tested_flate_bytes': original, 'selective_brotli11_stream_savings': saved,
            'whole_file_upper_bound_percent': 100 * saved / path.stat().st_size,
            'note': 'Upper bound ignores extension metadata and PDF serialization; reader support unverified.',
            'streams': rows, 'skipped': skipped}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('pdfs', nargs='+', type=Path)
    p.add_argument('--qpdf', default=str(Path(__file__).resolve().parents[1] / 'Vendor/qpdf/qpdf'))
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--max-stream-bytes', type=int, default=16 * 1024 * 1024)
    p.add_argument('--max-streams', type=int, default=200)
    args = p.parse_args()
    if args.max_stream_bytes <= 0 or args.max_streams <= 0:
        p.error('Budgets must be positive')
    results = [benchmark(pdf, args.qpdf, args.max_stream_bytes, args.max_streams) for pdf in args.pdfs]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({'schema': 1, 'brotli_version': brotli.__version__,
                                   'results': results}, indent=2, ensure_ascii=False) + '\n')
    for r in results:
        print(f"{Path(r['input']).name}: {r['tested_streams']} streams, "
              f"<= {r['whole_file_upper_bound_percent']:.2f}% whole-file savings")


if __name__ == '__main__':
    main()
