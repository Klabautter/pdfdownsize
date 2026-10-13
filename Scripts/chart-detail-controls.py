#!/usr/bin/env python3
"""Diagnostic: demonstrate dilution of local raster damage in aggregate PSNR.
Input must be the frozen NASA p5 192-dpi chart crop. No production gate tuning.
"""
import hashlib,json,math,sys
from pathlib import Path
from PIL import Image,ImageChops,ImageDraw,ImageStat
src=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
a=Image.open(src).convert('RGB');assert a.size==(1300,660)
def psnr(a,b):
    mse=sum(v*v for v in ImageStat.Stat(ImageChops.difference(a,b)).rms)/3
    return 10*math.log10(255*255/mse) if mse else None
rows=[]
# First upper plot's 17.2 tick label; short horizontal segment of its baseline.
for name,box in [('erased-tick-label',(75,280,115,303)),('broken-axis-line',(145,271,180,276))]:
    b=a.copy();ImageDraw.Draw(b).rectangle((box[0],box[1],box[2]-1,box[3]-1),fill='white')
    b.save(out/f'{name}.png')
    global_score=psnr(a,b)
    rows.append(dict(control=name,box_192dpi=box,aggregate_psnr_db=global_score,
        local_psnr_db=psnr(a.crop(box),b.crop(box)),
        aggregate_passes_photo_screen_35db=global_score is None or global_score>=35,
        expected_semantic_acceptance=False))
result=dict(input_sha256=hashlib.sha256(src.read_bytes()).hexdigest(),controls=rows,
    limitation='Synthetic erasures demonstrate spatial dilution only. The 35-dB threshold belongs to the photo fixture, not charts. No production acceptance rule is changed.')
(out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(rows,indent=2))
