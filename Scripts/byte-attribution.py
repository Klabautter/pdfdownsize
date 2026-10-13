#!/usr/bin/env python3
"""Phase 0 – Byte-Attribution: PDF-Bytes nach Klasse (nur stdlib).

Aufruf: byte-attribution.py <pdf> [--qpdf PFAD] [--no-dpi]

Primärpfad: qpdf --json (v2) – Objektgraph inkl. Stream-Dicts; indirekte
/Length-Referenzen („N 0 R") werden über die Objekttabelle aufgelöst.
Hinweis qpdf 12.4.0: v2 liefert NUR {"stream": {"dict": ...}} (kein
stream.length-Feld); `--json-key=objects` funktioniert nur mit --json=1 und
zeigt dort keine Streams. Fallback (Notfall): `qpdf --qdf
--object-streams=disable --decode-level=none` flatten, Bytescan + XRef-
Auflösung direkt auf dem Flattened-Artefakt.

Exit-Codes: 0 = ok, 2 = Datei nicht lesbar/kein PDF, 3 = Attribuierung
fehlgeschlagen. JSON geht nach stdout, Diagnosen nach stderr.
"""
import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zlib

WS = b"\x00\t\n\f\r "
DELIMS = b"\x00\t\n\f\r ()<>[]{}/%"
NUM_RE = re.compile(rb"[-+]?(?:\d+\.?\d*|\.\d+)")
INT_RE = re.compile(rb"\d+(?![\d.])")
REF_STR_RE = re.compile(r"^(\d+) (\d+) R$")
OBJ_KEY_RE = re.compile(r"^obj:(\d+) (\d+) R$")
OBJ_HEADER_RE = re.compile(rb"(?<![0-9])(\d{1,9})\s+(\d{1,5})\s+obj\b")

ASCII_TRANSPORT = {"/ASCIIHexDecode", "/ASCII85Decode"}
FILTER_CLASS = {
    "/DCTDecode": "jpeg",
    "/JPXDecode": "jpx",
    "/CCITTFaxDecode": "ccitt",
    "/JBIG2Decode": "jbig2",
    "/FlateDecode": "flate",
}
IMAGE_CLASSES = ("jpeg", "jpx", "ccitt", "jbig2", "flate", "other")
IDENT = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

CM_TOKEN_RE = re.compile(
    r"([-+.]?(?:\d+\.?\d*|\.\d+)(?:\s+[-+.]?(?:\d+\.?\d*|\.\d+)){5})\s+cm"
    r"|/([^\s/<>\[\](){}%]{1,127})\s+Do"
    r"|(?<![A-Za-z])([qQ])(?![A-Za-z])"
    r"|\bBI\b.*?\bEI\b",
    re.DOTALL,
)


class AttributionError(Exception):
    pass


class ParseError(Exception):
    pass


def _skip_ws(data, i):
    n = len(data)
    while i < n:
        c = data[i]
        if c in WS:
            i += 1
        elif c == 0x25:
            j = data.find(b"\n", i)
            i = n if j < 0 else j + 1
        else:
            break
    return i


def _parse_name(data, i):
    j = i + 1
    n = len(data)
    while j < n and data[j] not in DELIMS:
        j += 1
    return data[i:j].decode("latin-1"), j


def parse_value(data, i):
    i = _skip_ws(data, i)
    if i >= len(data):
        raise ParseError("EOF")
    if data.startswith(b"<<", i):
        d = {}
        i += 2
        while True:
            i = _skip_ws(data, i)
            if data.startswith(b">>", i):
                return d, i + 2
            if i >= len(data) or data[i] != 0x2F:
                raise ParseError("Dict ohne Schluessel bei %d" % i)
            name, i = _parse_name(data, i)
            val, i = parse_value(data, i)
            d[name] = val
    if data[i:i + 1] == b"[":
        lst = []
        i += 1
        while True:
            i = _skip_ws(data, i)
            if i >= len(data):
                raise ParseError("unterminiertes Array")
            if data[i:i + 1] == b"]":
                return lst, i + 1
            val, i = parse_value(data, i)
            lst.append(val)
    if data[i:i + 1] == b"/":
        return _parse_name(data, i)
    if data[i:i + 1] == b"(":
        depth = 1
        j = i + 1
        n = len(data)
        while j < n and depth > 0:
            c = data[j]
            if c == 0x5C:
                j += 2
                continue
            if c == 0x28:
                depth += 1
            elif c == 0x29:
                depth -= 1
            j += 1
        return b"", j
    if data[i:i + 1] == b"<":
        j = data.find(b">", i)
        return b"", (len(data) if j < 0 else j + 1)
    m = NUM_RE.match(data, i)
    if m:
        raw = m.group()
        i2 = m.end()
        if b"." not in raw and b"e" not in raw and b"E" not in raw:
            a = int(raw)
            j = _skip_ws(data, i2)
            m2 = INT_RE.match(data, j)
            if m2:
                g = int(m2.group())
                k = _skip_ws(data, m2.end())
                if data[k:k + 1] == b"R" and (
                    k + 1 >= len(data) or data[k + 1] in DELIMS
                ):
                    return ("R", a, g), k + 1
            return a, i2
        return float(raw), i2
    for kw, val in ((b"true", True), (b"false", False), (b"null", None)):
        if data.startswith(kw, i):
            return val, i + len(kw)
    raise ParseError("unerwartetes Token bei %d" % i)


def load_json_v2(qpdf, path, warnings):
    proc = subprocess.run(
        [qpdf, "--json", "--json-stream-data=none", "--", path],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise AttributionError(
            "qpdf --json fehlgeschlagen (rc=%d): %s"
            % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()[:200])
        )
    d = json.loads(proc.stdout)
    q = d.get("qpdf")
    if not (isinstance(q, list) and len(q) >= 2 and isinstance(q[1], dict)):
        raise AttributionError("JSON v2 ohne qpdf[1]-Objekttabelle")
    objects = {}
    for key, entry in q[1].items():
        m = OBJ_KEY_RE.match(key)
        if not m:
            continue
        ident = (int(m.group(1)), int(m.group(2)))
        sdict = None
        slen = None
        value = None
        if isinstance(entry, dict):
            if isinstance(entry.get("stream"), dict):
                sd = entry["stream"]
                sdict = sd.get("dict") if isinstance(sd.get("dict"), dict) else {}
                slen = sd.get("length")
                value = entry.get("value")
            elif "value" in entry:
                value = entry["value"]
            else:
                value = entry
        else:
            value = entry
        objects[ident] = {"dict": sdict, "stream_len": slen, "value": value,
                          "stream_data": None}
    return objects


def flatten(qpdf, path, warnings):
    tmpdir = tempfile.mkdtemp(prefix="pdftools-attr-")
    out = os.path.join(tmpdir, "flat.pdf")
    cmd = [
        qpdf,
        "--qdf",
        "--object-streams=disable",
        "--decode-level=none",
        "--normalize-content=n",
        "--decrypt",
        "--",
        path,
        out,
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True)
        if proc.returncode != 0 or not os.path.isfile(out):
            if proc.stderr:
                warnings.append(
                    "Flatten fehlgeschlagen: %s"
                    % proc.stderr.decode("utf-8", "replace").strip()[:200]
                )
            return None
        with open(out, "rb") as fh:
            data = fh.read()
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return parse_flat(data, warnings)


def parse_flat(data, warnings):
    objects = {}
    for m in OBJ_HEADER_RE.finditer(data):
        ident = (int(m.group(1)), int(m.group(2)))
        if ident in objects:
            continue
        try:
            val, j = parse_value(data, m.end())
        except (ParseError, ValueError, IndexError, RecursionError):
            continue
        ent = {"dict": None, "stream_len": None, "value": val,
               "stream_data": None, "_start": None, "_raw": None}
        if isinstance(val, dict):
            k = _skip_ws(data, j)
            if data.startswith(b"stream", k):
                p = k + 6
                if data[p:p + 2] == b"\r\n":
                    p += 2
                elif data[p:p + 1] in (b"\n", b"\r"):
                    p += 1
                ent["dict"] = val
                ent["_start"] = p
                ent["_raw"] = val.get("/Length")
        objects[ident] = ent

    def get(ident):
        ent = objects.get(ident)
        if ent is None:
            for (n, g), e in objects.items():
                if n == ident[0]:
                    return e
        return ent

    for ent in objects.values():
        if ent["_start"] is None:
            continue
        ln = ent["_raw"]
        if isinstance(ln, tuple) and len(ln) == 3 and ln[0] == "R":
            tgt = get((ln[1], ln[2]))
            ln = tgt["value"] if tgt and isinstance(tgt["value"], int) else None
        start = ent["_start"]
        if isinstance(ln, int) and ln >= 0 and start + ln <= len(data):
            tail = data[start + ln:start + ln + 16].lstrip(b"\r\n \t")
            if tail.startswith(b"endstream"):
                ent["stream_len"] = ln
            else:
                idx = data.find(b"endstream", start, start + ln + 512)
                if idx >= 0:
                    warnings.append(
                        "Objekt: /Length %d passt nicht, endstream bei +%d"
                        % (ln, idx - start)
                    )
                    ent["stream_len"] = idx - start
                else:
                    ent["stream_len"] = ln
        else:
            idx = data.find(b"endstream", start, min(len(data), start + 262144))
            if idx >= 0:
                warnings.append("Objekt ohne nutzbare /Length – endstream-Scan")
                ent["stream_len"] = idx - start
        if ent["stream_len"] is not None:
            ent["stream_data"] = data[start:start + ent["stream_len"]]
        del ent["_start"]
        del ent["_raw"]
    return objects


def make_resolver(objects):
    def resolve(v, depth=0):
        while v is not None and depth < 64:
            if isinstance(v, str):
                m = REF_STR_RE.match(v)
                if not m:
                    return v
                ident = (int(m.group(1)), int(m.group(2)))
            elif isinstance(v, tuple) and len(v) == 3 and v[0] == "R":
                ident = (v[1], v[2])
            else:
                return v
            ent = objects.get(ident)
            if ent is None:
                cand = [e for (n, g), e in objects.items() if n == ident[0]]
                ent = cand[0] if cand else None
            if ent is None:
                return None
            v = ent["value"]
            depth += 1
        return v

    return resolve


def ref_to_ident(v):
    if isinstance(v, str):
        m = REF_STR_RE.match(v)
        if m:
            return (int(m.group(1)), int(m.group(2)))
    if isinstance(v, tuple) and len(v) == 3 and v[0] == "R":
        return (v[1], v[2])
    return None


def collect_pages(objects):
    pages = []
    for ident in sorted(objects):
        v = objects[ident]["value"]
        if isinstance(v, dict) and v.get("/Type") == "/Page":
            pages.append((ident, v))
    return pages


def page_resources(objects, resolve, pval):
    cur = pval
    for _ in range(16):
        if isinstance(cur, dict) and "/Resources" in cur:
            res = resolve(cur["/Resources"])
            if isinstance(res, dict):
                return res
            return {}
        parent = cur.get("/Parent") if isinstance(cur, dict) else None
        pident = ref_to_ident(parent)
        if pident is None:
            return {}
        ent = objects.get(pident)
        cur = ent["value"] if ent else None
        if not isinstance(cur, dict):
            return {}
    return {}


def collect_content_idents(objects, pval):
    """Object-IDs aller /Contents-Streams einer Seite (direkt, Array oder
    indirekter Ref auf Array)."""
    ids = set()
    seen = set()
    frontier = [pval.get("/Contents")]
    while frontier:
        v = frontier.pop()
        if v is None:
            continue
        ident = ref_to_ident(v)
        if ident is not None:
            if ident in seen:
                continue
            seen.add(ident)
            ent = objects.get(ident)
            if ent is None:
                continue
            if isinstance(ent.get("dict"), dict):
                ids.add(ident)
            elif isinstance(ent.get("value"), list):
                frontier.extend(ent["value"])
            continue
        if isinstance(v, list):
            frontier.extend(v)
    return ids


def stream_len_of(ent, resolve):
    if isinstance(ent.get("stream_len"), int):
        return ent["stream_len"]
    if not isinstance(ent.get("dict"), dict):
        return None
    ln = resolve(ent["dict"].get("/Length"))
    return ln if isinstance(ln, int) and ln >= 0 else None


def classify_stream(d, is_page_content):
    t = d.get("/Type")
    st = d.get("/Subtype")
    if isinstance(t, list):
        t = t[0] if t else None
    # Ghostscript schreibt /Type /XObject bei Bildern oft nicht mit.
    if st == "/Image":
        return "image"
    if t in ("/FontFile", "/FontFile2", "/FontFile3") or "/Length1" in d:
        return "font"
    if t == "/Metadata" or st == "/XML":
        return "metadata"
    if t == "/EmbeddedFile":
        return "embedded"
    if t == "/ObjStm":
        return "objstm"
    if st == "/Form" or is_page_content:
        return "content"
    return "unclassified"


def image_filter_key(d):
    f = d.get("/Filter")
    filters = f if isinstance(f, list) else ([f] if f else [])
    real = [x for x in filters if isinstance(x, str) and x not in ASCII_TRANSPORT]
    for x in reversed(real):
        if x in FILTER_CLASS:
            return FILTER_CLASS[x]
    return "other"


def colorspace_name(v, resolve):
    v = resolve(v)
    if isinstance(v, str):
        return v.lstrip("/")
    if isinstance(v, list) and v:
        first = resolve(v[0])
        if isinstance(first, str):
            return first.lstrip("/")
    return None


def decompress_stream(ent):
    d = ent.get("dict") or {}
    data = ent.get("stream_data")
    if not isinstance(data, (bytes, bytearray)):
        return None
    f = d.get("/Filter")
    filters = f if isinstance(f, list) else ([f] if f else [])
    try:
        raw = bytes(data)
        for flt in filters:
            if flt == "/FlateDecode":
                raw = zlib.decompress(raw)
            elif flt == "/ASCII85Decode":
                import base64
                raw = base64.a85decode(raw, adobe=True)
            elif flt == "/ASCIIHexDecode":
                import base64
                raw = base64.b16decode(
                    re.sub(rb"[^0-9A-Fa-f]", b"", raw).upper() + b"0"
                )
            else:
                return None
        return raw.decode("latin-1")
    except Exception:
        return None


def compose(ctm, m):
    a1, b1, c1, d1, e1, f1 = m
    a2, b2, c2, d2, e2, f2 = ctm
    return (
        a1 * a2 + b1 * c2,
        a1 * b2 + b1 * d2,
        c1 * a2 + d1 * c2,
        c1 * b2 + d1 * d2,
        e1 * a2 + f1 * c2 + e2,
        e1 * b2 + f1 * d2 + f2,
    )


def _as_matrix(v, resolve):
    v = resolve(v)
    if isinstance(v, list) and len(v) == 6 and all(
        isinstance(x, (int, float)) for x in v
    ):
        return tuple(float(x) for x in v)
    return IDENT


def analyze_dpi(objects, pages, resolve, warnings):
    dpi_by_ident = {}

    def record(ident, ctm):
        ent = objects.get(ident)
        if ent is None or not isinstance(ent.get("dict"), dict):
            return
        d = ent["dict"]
        w = resolve(d.get("/Width"))
        h = resolve(d.get("/Height"))
        if not (isinstance(w, int) and isinstance(h, int) and w > 0 and h > 0):
            return
        a, b, c, dd, e, f = ctm
        w_pt = math.hypot(a, b)
        h_pt = math.hypot(c, dd)
        if w_pt <= 0 or h_pt <= 0:
            return
        dpi = min(w * 72.0 / w_pt, h * 72.0 / h_pt)
        if dpi <= 0 or dpi > 100000:
            return
        cur = dpi_by_ident.get(ident)
        if cur is None or dpi < cur:
            dpi_by_ident[ident] = dpi

    def scan(text, xobjs, ctm, depth):
        if text is None or depth > 5:
            return
        for m in CM_TOKEN_RE.finditer(text):
            if m.group(0).startswith("BI"):
                continue
            if m.group(1) is not None:
                try:
                    nums = [float(x) for x in m.group(1).split()]
                    ctm = compose(ctm, tuple(nums))
                except ValueError:
                    pass
                continue
            if m.group(3) is not None:
                if m.group(3) == "q" and len(ctm_stack) < 64:
                    ctm_stack.append(ctm)
                elif m.group(3) == "Q" and ctm_stack:
                    ctm = ctm_stack.pop()
                continue
            name = "/" + m.group(2)
            ident = ref_to_ident(xobjs.get(name))
            if ident is None:
                continue
            ent = objects.get(ident)
            if ent is None or not isinstance(ent.get("dict"), dict):
                continue
            d = ent["dict"]
            if d.get("/Subtype") == "/Image":
                record(ident, ctm)
            elif d.get("/Subtype") == "/Form" and depth < 5:
                inner = resolve(d.get("/Resources"))
                inner_x = resolve(inner.get("/XObject")) if isinstance(inner, dict) else None
                scan(
                    decompress_stream(ent),
                    inner_x if isinstance(inner_x, dict) else {},
                    compose(ctm, _as_matrix(d.get("/Matrix"), resolve)),
                    depth + 1,
                )

    for ident, pval in pages:
        res = page_resources(objects, resolve, pval)
        xobjs = resolve(res.get("/XObject"))
        if not isinstance(xobjs, dict):
            continue
        xmap = {k: v for k, v in xobjs.items() if isinstance(k, str)}
        ctm_stack = []
        texts = []
        for cid in sorted(collect_content_idents(objects, pval)):
            ent = objects.get(cid)
            if ent is not None:
                texts.append(decompress_stream(ent))
        scan("\n".join(t for t in texts if t is not None), xmap, IDENT, 0)
    return dpi_by_ident


def attribute(path, doc_bytes, qpdf, want_dpi):
    warnings = []
    method = "qpdf-json-v2"
    objects = None
    try:
        objects = load_json_v2(qpdf, path, warnings)
        if not objects:
            raise AttributionError("JSON v2 enthaelt keine Objekte")
    except (AttributionError, ValueError, OSError, subprocess.SubprocessError) as e:
        warnings.append("JSON v2 nicht verwertbar (%s) – Flatten-Fallback" % e)
        objects = None

    flat = None
    if objects is not None:
        if want_dpi:
            flat = flatten(qpdf, path, warnings)
    else:
        flat = flatten(qpdf, path, warnings)
        if flat is None:
            raise AttributionError(
                "Weder qpdf --json noch qdf-Flatten konnten das Dokument lesen"
            )
        objects = flat
        method = "qdf-flatten-fallback"

    resolve = make_resolver(objects)
    pages = collect_pages(objects)
    dpi_by_ident = {}
    sig_dpi = {}
    same_objects = flat is None or flat is objects
    if flat is not None and not same_objects:
        flat_resolve = make_resolver(flat)
        dpi_by_ident = analyze_dpi(
            flat, collect_pages(flat), flat_resolve, warnings
        )
        for ident, dpi in dpi_by_ident.items():
            ent = flat.get(ident)
            if ent is None or not isinstance(ent.get("dict"), dict):
                continue
            d = ent["dict"]
            sig_dpi.setdefault(
                (flat_resolve(d.get("/Width")), flat_resolve(d.get("/Height")),
                 stream_len_of(ent, flat_resolve)),
                [],
            ).append(dpi)
    elif flat is not None:
        dpi_by_ident = analyze_dpi(objects, pages, resolve, warnings)

    content_idents = set()
    for ident, pval in pages:
        content_idents |= collect_content_idents(objects, pval)

    classes = {k: 0 for k in IMAGE_CLASSES}
    counts = {"fonts": 0, "content_streams": 0, "metadata": 0,
              "embedded_files": 0, "objstm": 0, "unclassified": 0}
    other_bytes = {"fonts": 0, "content_streams": 0, "metadata": 0,
                   "embedded_files": 0, "unclassified": 0}
    unresolved = 0
    images_detail = []

    image_count = 0
    for ident in sorted(objects):
        ent = objects[ident]
        if not isinstance(ent.get("dict"), dict):
            continue
        d = ent["dict"]
        nbytes = stream_len_of(ent, resolve)
        if nbytes is None:
            unresolved += 1
            warnings.append("Objekt %d %d: /Length nicht aufloesbar" % ident)
            nbytes = 0
        kind = classify_stream(d, ident in content_idents)
        if kind == "image":
            classes[image_filter_key(d)] += nbytes
            image_count += 1
            sig = (resolve(d.get("/Width")), resolve(d.get("/Height")), nbytes)
            dpi_val = None
            if same_objects and ident in dpi_by_ident:
                dpi_val = dpi_by_ident[ident]
            elif sig in sig_dpi and sig_dpi[sig]:
                dpi_val = sig_dpi[sig].pop(0)
            detail = {
                "object": "%d %d R" % ident,
                "width": resolve(d.get("/Width")),
                "height": resolve(d.get("/Height")),
                "bpc": resolve(d.get("/BitsPerComponent")),
                "colorspace": colorspace_name(d.get("/ColorSpace"), resolve),
                "filter": image_filter_key(d),
                "bytes": nbytes,
                "effective_dpi": round(dpi_val, 1) if dpi_val else None,
            }
            images_detail.append(detail)
        elif kind == "font":
            counts["fonts"] += 1
            other_bytes["fonts"] += nbytes
        elif kind == "content":
            counts["content_streams"] += 1
            other_bytes["content_streams"] += nbytes
        elif kind == "metadata":
            counts["metadata"] += 1
            other_bytes["metadata"] += nbytes
        elif kind == "embedded":
            counts["embedded_files"] += 1
            other_bytes["embedded_files"] += nbytes
        elif kind == "objstm":
            counts["objstm"] += 1
        else:
            counts["unclassified"] += 1
            other_bytes["unclassified"] += nbytes

    fonts_bytes = other_bytes["fonts"]
    attributed = (
        sum(classes.values())
        + fonts_bytes
        + other_bytes["content_streams"]
        + other_bytes["metadata"]
        + other_bytes["embedded_files"]
    )
    structure = doc_bytes - attributed
    if structure < 0:
        warnings.append(
            "attribuierte Bytes (%d) > document_bytes (%d) – Struktur auf 0 geklemmt"
            % (attributed, doc_bytes)
        )
        structure = 0

    report = {
        "document_bytes": doc_bytes,
        "images": {"total": sum(classes.values())},
        "fonts": fonts_bytes,
        "content_streams": other_bytes["content_streams"],
        "metadata": other_bytes["metadata"],
        "embedded_files": other_bytes["embedded_files"],
        "structure_estimate": structure,
        "image_count": image_count,
        "font_count": counts["fonts"],
        "page_count": len(pages),
        "images_detail": images_detail,
        "method": method,
        "attributed_bytes": attributed,
    }
    report["images"].update(classes)
    if counts["unclassified"]:
        report["unclassified_streams"] = {
            "count": counts["unclassified"],
            "bytes": other_bytes["unclassified"],
        }
    if unresolved:
        report["unresolved_length_streams"] = unresolved
    if warnings:
        report["warnings"] = warnings
    return report


def main(argv):
    ap = argparse.ArgumentParser(description="PDF-Byte-Attribution (Phase 0)")
    ap.add_argument("pdf", help="Pfad zum PDF")
    ap.add_argument("--qpdf", default=None, help="Pfad zum qpdf-CLI")
    ap.add_argument("--no-dpi", action="store_true",
                    help="effective_dpi-Analyse ueberspringen")
    args = ap.parse_args(argv)

    qpdf = args.qpdf
    if not qpdf:
        cand = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "Vendor", "qpdf", "qpdf")
        qpdf = cand if os.access(cand, os.X_OK) else (shutil.which("qpdf") or "qpdf")

    path = args.pdf
    if not os.path.isfile(path) or not os.access(path, os.R_OK):
        print("Fehler: Datei nicht lesbar: %s" % path, file=sys.stderr)
        return 2
    try:
        with open(path, "rb") as fh:
            head = fh.read(1024)
    except OSError as e:
        print("Fehler: Datei nicht lesbar: %s" % e, file=sys.stderr)
        return 2
    if b"%PDF" not in head:
        print("Fehler: kein PDF (Header fehlt): %s" % path, file=sys.stderr)
        return 2

    doc_bytes = os.path.getsize(path)
    try:
        report = attribute(path, doc_bytes, qpdf, want_dpi=not args.no_dpi)
    except AttributionError as e:
        print("Fehler: Attribuierung fehlgeschlagen: %s" % e, file=sys.stderr)
        return 3

    json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
