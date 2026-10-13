#!/usr/bin/env python3
"""Negative controls for all-page PDFKit semantic/geometry audit (requires pikepdf)."""
import json, subprocess, sys
from pathlib import Path
import pikepdf
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
checker=sys.argv[2]
def fixture(name,text='Label 17.2',x=72,width=612):
    pdf=pikepdf.Pdf.new();page=pdf.add_blank_page(page_size=(width,792))
    font=pikepdf.Dictionary(Type=pikepdf.Name('/Font'),Subtype=pikepdf.Name('/Type1'),BaseFont=pikepdf.Name('/Helvetica'))
    page.Resources=pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=pdf.make_indirect(font)))
    page.Contents=pdf.make_stream(f'BT /F1 12 Tf {x} 720 Td ({text}) Tj ET'.encode())
    path=out/f'{name}.pdf';pdf.save(path);return path
source=fixture('source')
controls=[('identical',fixture('identical'),True),('changed-digit',fixture('changed-digit',text='Label 17.3'),False),('shifted-label',fixture('shifted-label',x=73),False),('changed-page-box',fixture('changed-page-box',width=612.01),False)]
rows=[]
for name,path,expected in controls:
    result=subprocess.run([checker,str(source),str(path)],capture_output=True,text=True)
    parsed=json.loads(result.stdout)
    assert parsed['pass']==expected and result.returncode==(0 if expected else 1),name
    rows.append(dict(control=name,expected=expected,result=parsed))
(out/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
print('4 controls passed: identical accepted; changed digit, label shift and page box rejected')
