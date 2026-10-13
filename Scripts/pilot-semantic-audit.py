#!/usr/bin/env python3
"""Audit frozen pilot pairs with two extractors, preserving invalid XML characters.
Compile pilot-pdfkit-semantics.swift and supply its executable as second argument.
No render/glyph, annotation, form, or release acceptance is inferred.
"""
import csv, hashlib, json, subprocess, sys
from pathlib import Path
import xml.etree.ElementTree as ET
base = Path(sys.argv[1]).resolve()
checker = sys.argv[2]
manifest = json.loads((base/'manifest.json').read_text())
records = list(csv.DictReader((base/'run/summary.csv').open()))
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def extract(path):
    proc = subprocess.run(['pdftotext', '-bbox-layout', str(path), '-'], capture_output=True, check=True)
    text = proc.stdout.decode('utf-8', errors='strict')
    invalid = [(i, ord(c)) for i,c in enumerate(text) if not (ord(c) in (9,10,13) or 32 <= ord(c) <= 0xD7FF or 0xE000 <= ord(c) <= 0xFFFD or 0x10000 <= ord(c) <= 0x10FFFF)]
    # Preserve each forbidden code point as a visible escape; do not drop glyphs.
    invalid_values = {v for _,v in invalid}
    escaped = ''.join(c if ord(c) not in invalid_values else f'\\u{ord(c):04x}' for c in text)
    tree = ET.fromstring(escaped); ns = {'x':'http://www.w3.org/1999/xhtml'}
    words = [[(w.text or '', *[w.attrib[k] for k in ('xMin','yMin','xMax','yMax')]) for w in page.findall('.//x:word', ns)] for page in tree.findall('.//x:page', ns)]
    return proc.stdout, invalid, words, proc.stderr.decode('utf-8', errors='strict')
rows=[]
for d in manifest['documents']:
    source=base/d['path']; assert sha(source)==d['sha256']
    candidate=base/'run/outputs'/f'{source.parent.name}__{source.stem}__Smart.pdf'
    if candidate.exists():
        record=[r for r in records if Path(r['input_path']).name==source.name and r['success']=='true' and r['preset']=='Smart']
        assert len(record)==1 and sha(candidate)==record[0]['output_sha256']
        cohort='original_pilot'
    else:
        candidate=base/'timeout-diagnostic/fixed-run/outputs'/f'{source.parent.name}__{source.stem}__Smart.pdf'
        fixed=list(csv.DictReader((base/'timeout-diagnostic/fixed-run/summary.csv').open()))
        record=[r for r in fixed if Path(r['input_path']).name==source.name and r['success']=='true']
        assert len(record)==1 and sha(candidate)==record[0]['output_sha256']
        cohort='timeout_followup'
    before, invalid_a, words_a, warnings_a = extract(source)
    after, invalid_b, words_b, warnings_b = extract(candidate)
    proc=subprocess.run([checker,str(source),str(candidate)],capture_output=True,text=True)
    native=json.loads(proc.stdout)
    row=dict(file=source.name,cohort=cohort,source_sha256=sha(source),candidate_sha256=sha(candidate),
             bbox_raw_bytes_equal=before==after,invalid_xml_source=invalid_a,invalid_xml_candidate=invalid_b,
             invalid_xml_audit_equal=invalid_a==invalid_b,words_and_positions_equal=words_a==words_b,
             source_words=sum(map(len,words_a)),poppler_warnings_source=warnings_a,poppler_warnings_candidate=warnings_b,
             pdfkit=native,pdfkit_stderr=proc.stderr)
    row['invalid_xml_values_equal']=[v for _,v in invalid_a]==[v for _,v in invalid_b]
    row['extracted_text_geometry_pass']=words_a==words_b and row['invalid_xml_values_equal'] and all(p['text_equal'] for p in native['pages']) and native['source_pages']==native['candidate_pages']
    row['strict_pdfkit_geometry_pass']=native['pass'] and proc.returncode==0
    row['text_geometry_pass']=row['extracted_text_geometry_pass'] and row['strict_pdfkit_geometry_pass']
    rows.append(row)
result=dict(manifest_sha256=sha(base/'manifest.json'),documents=rows,
            all_text_geometry_pass=all(r['text_geometry_pass'] for r in rows),
            pdfkit_checker_sha256=sha(Path(checker)),
            limitations='Extracted text and geometry only. Raster glyphs, diagrams, links, annotations and forms require separate checks; no release acceptance.')
folder=base/'semantic-audit';folder.mkdir(exist_ok=True)
(folder/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps([dict(file=r['file'],words=r['source_words'],invalid_xml_characters=len(r['invalid_xml_source']),pass_text_geometry=r['text_geometry_pass']) for r in rows],indent=2))
if not result['all_text_geometry_pass']: sys.exit(1)
