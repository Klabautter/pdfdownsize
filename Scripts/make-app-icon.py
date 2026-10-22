# Erzeugt AppIcon.icon (Icon Composer, macOS 26) aus dem bisherigen Motiv:
# Blatt mit Eselsohr, Inhalt (Bildblock + Zeilen), zwei Pfeile – je eine
# SVG-Ebene, Glas/Schatten/Dunkelvariante rechnet das System.
#
#   python3 Scripts/make-app-icon.py PDFTools/AppIcon.icon
#
# Feinschliff (Glas, Transluzenz, Schatten) danach in Icon Composer; dann
# diese Datei nicht erneut laufen lassen, sie überschreibt icon.json.
import json, os, sys
out = sys.argv[1]; A = os.path.join(out, 'Assets'); os.makedirs(A, exist_ok=True)
def svg(name, body):
    open(os.path.join(A, name), 'w').write(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{body}</svg>\n')
# Blatt
x0, x1, y0, y1, r, fold = 287, 737, 214, 814, 34, 124
page = (f'M{x0+r},{y0} L{x1-fold},{y0} L{x1},{y0+fold} L{x1},{y1-r} Q{x1},{y1} {x1-r},{y1} '
        f'L{x0+r},{y1} Q{x0},{y1} {x0},{y1-r} L{x0},{y0+r} Q{x0},{y0} {x0+r},{y0} Z')
svg('page.svg', f'<path d="{page}" fill="#FFFFFF"/>')
fr = 22
svg('fold.svg', f'<path d="M{x1-fold},{y0} L{x1-fold},{y0+fold-fr} Q{x1-fold},{y0+fold} {x1-fold+fr},{y0+fold} L{x1},{y0+fold} Z" fill="#C9D7F5"/>')
# Inhalt
# Drei kräftige Zeilen statt fünf feiner: Bei 16 pt verschwammen fünf zu
# einer grauen Fläche (HIG: wenige Formen, keine sehr dünnen Linien).
lx, lw, lh = x0 + 68, (x1 - x0) - 136, 42
rows = [(0.50, 1), (0.34, 0.82), (0.18, 0.6)]
H = y1 - y0
lines = ''.join(f'<rect x="{lx}" y="{y1 - H*fy - lh:.0f}" width="{lw*fw:.0f}" height="{lh}" rx="{lh/2}" fill="#C3CEE3"/>' for fy, fw in rows)
svg('lines.svg', lines)
svg('picture.svg', f'<rect x="{lx}" y="{y1 - H*0.74 - 100:.0f}" width="168" height="100" rx="18" fill="#3D7FFF"/>')
# Pfeile
cy, h, d, sw = 514, 88, 66, 46
def chev(tip, dirn): return f'M{tip-dirn*d},{cy-h} L{tip},{cy} L{tip-dirn*d},{cy+h}'
svg('arrows.svg', f'<path d="{chev(x0-44,1)} {chev(x1+44,-1)}" fill="none" stroke="#FFFFFF" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"/>')

def layer(name, glass=True, **kw):
    d = {"glass": glass, "hidden": False, "image-name": name + ".svg", "name": name}
    d.update(kw); return d
icon = {
  "fill": {"linear-gradient": ["display-p3:0.40000,0.65000,1.00000,1.00000",
                                "display-p3:0.10000,0.32000,0.92000,1.00000"],
           "orientation": {"start": {"x": 0.5, "y": 0.0}, "stop": {"x": 0.5, "y": 1.0}}},
  "groups": [
    {"name": "Pfeile", "layers": [layer("arrows")],
     "shadow": {"kind": "neutral", "opacity": 0.5},
     "translucency": {"enabled": True, "value": 0.4}},
    {"name": "Inhalt", "layers": [layer("picture"), layer("lines", glass=False)],
     "shadow": {"kind": "none", "opacity": 0.0},
     "translucency": {"enabled": False, "value": 0.0}},
    {"name": "Blatt", "layers": [layer("fold", glass=False), layer("page")],
     "shadow": {"kind": "layer-color", "opacity": 0.5},
     "translucency": {"enabled": True, "value": 0.15}},
  ],
  "supported-platforms": {"squares": ["macOS"]},
}
json.dump(icon, open(os.path.join(out, 'icon.json'), 'w'), indent=2)
