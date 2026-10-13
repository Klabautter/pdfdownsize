#!/usr/bin/env python3
"""Verify frozen pilot provenance, extracted words/positions, and fixed detail pages.
Requires Poppler and Pillow. Pixel error is diagnostic, not a quality pass gate.
"""
import argparse, csv, hashlib, json, subprocess, tempfile, time
from pathlib import Path
import xml.etree.ElementTree as ET
from PIL import Image, ImageChops, ImageStat, ImageDraw
p=argparse.ArgumentParser(); p.add_argument('pilot',type=Path)
p.add_argument('--reuse-existing-previews',action='store_true',help='Explicit recovery only: previews must belong to the frozen baseline; old preview metrics are not recovered.')
a=p.parse_args(); base=a.pilot.resolve()
manifest=json.loads((base/'manifest.json').read_text()); out=base/'details'; out.mkdir(exist_ok=True)
rows=[]; previews=[]
def words(path):
 data=subprocess.check_output(['pdftotext','-bbox-layout',str(path),'-'])
 tree=ET.fromstring(data); ns={'x':'http://www.w3.org/1999/xhtml'}
 return [[(w.text or '',*[w.attrib[k] for k in ['xMin','yMin','xMax','yMax']]) for w in page.findall('.//x:word',ns)] for page in tree.findall('.//x:page',ns)]
with tempfile.TemporaryDirectory() as tmp:
 for d in manifest['documents']:
  src=base/d['path']; assert hashlib.sha256(src.read_bytes()).hexdigest()==d['sha256'],src
  result=base/'run/outputs'/f'{src.parent.name}__{src.stem}__Smart.pdf'
  deadline=time.monotonic()+240
  while not result.exists() and not (base/'run/summary.csv').exists() and time.monotonic()<deadline:
   time.sleep(1)
  if not result.exists():
   rows.append({'file':src.name,'output_missing':True,'input_word_count':None,'same_words_and_positions':None})
   continue
  with (base/'run/summary.csv').open() as stream:
   records=list(csv.DictReader(stream))
  expected=[r for r in records if Path(r['input_path']).name==src.name and r['preset']=='Smart' and r['success']=='true']
  if len(expected)!=1 or hashlib.sha256(result.read_bytes()).hexdigest()!=expected[0]['output_sha256']:
   raise RuntimeError(f'Output does not match frozen baseline: {result}')
  row={'file':src.name,'details':[]}
  try:
   before,after=words(src),words(result)
   row.update(pages=len(before),same_pages=len(before)==len(after),same_words_and_positions=before==after,input_word_count=sum(map(len,before)))
  except (ET.ParseError,subprocess.CalledProcessError) as exc:
   row.update(text_check_error=str(exc),same_words_and_positions=None,input_word_count=None)
  (out/'checkpoint.json').write_text(json.dumps(rows+[row],indent=2)+'\n')
  for page in d['detail_pages']:
   existing=out/f'{src.stem}-p{page}-200pct.png'
   if a.reuse_existing_previews and existing.exists():
    row['details'].append(dict(page=page,existing_preview=str(existing),metrics_not_retained_from_interrupted_run=True))
    continue
   for dpi,label in [(96,'100pct'),(192,'200pct'),(384,'400pct'),(300,'print300dpi')]:
    images=[]
    for kind,path in [('input',src),('smart',result)]:
     prefix=Path(tmp)/kind
     subprocess.run(['pdftoppm','-f',str(page),'-l',str(page),'-singlefile','-r',str(dpi),'-png',str(path),str(prefix)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
     with Image.open(str(prefix)+'.png') as im: images.append(im.convert('RGB'))
    if images[0].size!=images[1].size: raise RuntimeError('Render size changed')
    w,h=images[0].size; box=(w//4,h//4,3*w//4,3*h//4)
    crops=[im.crop(box) for im in images]
    mae=sum(ImageStat.Stat(ImageChops.difference(*crops)).mean)/3
    row['details'].append(dict(page=page,condition=label,center_box=box,mae_255=mae))
    if label=='200pct':
     # Native 200% center detail, with scale stated; no full-page overview.
     canvas=Image.new('RGB',(1100,560),'white'); draw=ImageDraw.Draw(canvas)
     draw.text((10,5),f'{src.name} page {page} | left INPUT, right SMART | center detail at 192 dpi',fill='black')
     for x,crop in zip([0,550],crops):
      crop=crop.crop((max(0,(crop.width-530)//2),max(0,(crop.height-520)//2),max(0,(crop.width-530)//2)+530,max(0,(crop.height-520)//2)+520))
      canvas.paste(crop,(x+10,30))
     file=out/f'{src.stem}-p{page}-200pct.png'; canvas.save(file); previews.append(str(file))
  rows.append(row)
  (out/'checkpoint.json').write_text(json.dumps(rows,indent=2)+'\n')
(out/'results.json').write_text(json.dumps({'manifest_sha256':hashlib.sha256((base/'manifest.json').read_bytes()).hexdigest(),'documents':rows,'limitations':'Center crops on preselected pages only; text equality cannot certify scanned glyphs; MAE has no acceptance threshold.'},indent=2)+'\n')
print(json.dumps([dict(file=r['file'],words=r['input_word_count'],same_words_and_positions=r['same_words_and_positions']) for r in rows],indent=2))
