#!/usr/bin/env python3
"""Complete-PDF experiments for the frozen photo case; no production defaults change.
Requires pikepdf/Pillow, Poppler pdfimages. Replace original image samples into
an existing Smart PDF, preserving vector/text objects and placement matrices.
"""
import argparse, hashlib, io, json, resource, subprocess, tempfile, time
from pathlib import Path
import pikepdf
from PIL import Image
SOURCE_SHA = '73d905019697202c7551ec6f7bc63b6c10da92a623aa03f36e68de73ce02cb02'
CURRENT_SHA = '695cef537b2238de6593f98b7ff528e338173d62eedc46e5dd2da5515a0ace1d'
TARGETS = {2: '/Im9', 3: '/Im10', 4: '/Im11', 5: '/Im12', 6: '/Im13', 7: '/Im14'}
GRAY = {2, 4, 5, 7}
def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--current', type=Path, required=True)
    ap.add_argument('--output-dir', type=Path, required=True)
    args = ap.parse_args()
    if sha(args.source) != SOURCE_SHA:
        raise ValueError('Source differs from frozen regression fixture')
    if sha(args.current) != CURRENT_SHA:
        raise ValueError('Smart baseline differs from frozen regression fixture')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    report = {'experiment_only': True, 'source_sha256': SOURCE_SHA,
              'current_sha256': sha(args.current), 'current_bytes': args.current.stat().st_size,
              'pixels': 652, 'jpeg_quality': 85, 'variants': {}}
    with tempfile.TemporaryDirectory() as td:
        prefix = Path(td) / 'image'
        subprocess.run(['pdfimages', '-f', '4', '-l', '4', '-png', str(args.source), str(prefix)], check=True)
        for variant, selected in [('gray-only', GRAY), ('all-six', set(TARGETS))]:
            start = time.monotonic()
            with pikepdf.open(args.current) as pdf:
                replacements = []
                resources = pdf.pages[3].Resources.XObject
                for position in sorted(selected):
                    obj = resources[TARGETS[position]]
                    if (int(obj.Width), int(obj.Height), str(obj.ColorSpace), int(obj.BitsPerComponent)) != (2000, 2000, '/DeviceRGB', 8):
                        raise ValueError('Unexpected Smart image dictionary')
                    if any(key in obj for key in ['/SMask', '/Mask', '/Decode']):
                        raise ValueError('Masked or remapped image needs separate handling')
                    image = Image.open(Path(td) / f'image-{position:03}.png').convert('RGB')
                    image = image.resize((652, 652), Image.Resampling.LANCZOS)
                    encoded = io.BytesIO()
                    image.save(encoded, 'JPEG', quality=85, subsampling=0, optimize=True)
                    obj.write(encoded.getvalue(), filter=pikepdf.Name.DCTDecode)
                    obj.Width = obj.Height = 652
                    replacements.append({'position': position, 'object': list(obj.objgen), 'jpeg_bytes': len(encoded.getvalue())})
                output = args.output_dir / f'photo-{variant}-652px-q85.pdf'
                pdf.save(output, object_stream_mode=pikepdf.ObjectStreamMode.generate)
            report['variants'][variant] = {'path': str(output.resolve()), 'sha256': sha(output),
                'bytes': output.stat().st_size, 'saving_vs_current_pct': 100 * (1 - output.stat().st_size / args.current.stat().st_size),
                'generation_seconds': time.monotonic() - start,
                'process_peak_rss_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                'replacements': replacements}
    (args.output_dir / 'generation.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['variants'], indent=2))
if __name__ == '__main__':
    main()
