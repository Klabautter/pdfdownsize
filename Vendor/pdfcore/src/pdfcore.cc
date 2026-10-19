// PDFCore – C++-Implementierung über die qpdf-API (Phase 5).
// Keine Exception verlässt diese Übersetzungseinheit.
#include "pdfcore.h"

#include <qpdf/QPDF.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFOutlineDocumentHelper.hh>
#include <qpdf/QPDFAcroFormDocumentHelper.hh>
#include <qpdf/QPDFPageLabelDocumentHelper.hh>
#include <qpdf/Pl_Buffer.hh>
#include <qpdf/Pl_Discard.hh>
#include <qpdf/Pl_Flate.hh>   /* Phase V2-9 – compression level des Writers */
#include <qpdf/Pl_StdioFile.hh> /* Befund B11 – abbrechbarer Writer-Output */
#include <qpdf/Pipeline.hh>
#include <qpdf/QUtil.hh>
#include <qpdf/Buffer.hh>
#include <qpdf/Constants.h>
#include <cstdio>
#include <cstring>
#include <csetjmp>
#include <cctype>
#include <cstdlib>
#include <new>
#include <string>
#include <vector>
#include <map>
#include <memory>
#include <functional>
#include <set>
#include <utility>
#include <algorithm>
#include <cmath>

#include <jpeglib.h>   /* Phase 1b – mozjpeg (ABI 62, turbo-Superset) */
#include <tiffio.h>    /* Phase 2b – CCITT G4 (Fax-Codec) */
#include <jbig2enc.h>  /* Phase 2b – lossless JBIG2 */
#include <leptonica/allheaders.h>
#include <openjpeg.h>  /* Phase 4b – JPX/JPEG2000 DEKODIERUNG (nur Input) */
#include <hb.h>        /* Phase 5b – Font-Subsetting (hb-subset, Sets-API) */
#include <hb-subset.h>
#include <zlib.h>      /* Phase 3-Followup – Inflate vor dem Zopfli-Repack */
#include <zopfli/zopfli.h>  /* Phase 3-Followup – Max-Flate je Stream */

#include <CommonCrypto/CommonDigest.h>  /* Phase 3b – SHA-256 (libSystem) */

/// Sucht einen Namen im Name Tree (/Names → key) oder im Legacy-Dict (catalog/key).
QPDFObjectHandle lookup_named_dest(QPDF& qpdf, std::string const& name)
{
    QPDFObjectHandle catalog = qpdf.getRoot();
    QPDFObjectHandle namesDict = catalog.getKey("/Names");
    if (!namesDict.isNull() && namesDict.isDictionary()) {
        // Tiefensuche über Kids, Namensvergleich in /Names-Arrays (gerade Indizes).
        std::function<QPDFObjectHandle(QPDFObjectHandle)> walk =
            [&](QPDFObjectHandle node) -> QPDFObjectHandle {
            if (node.isNull() || !node.isDictionary()) { return QPDFObjectHandle(); }
            QPDFObjectHandle arr = node.getKey("/Names");
            if (arr.isArray()) {
                auto v = arr.getArrayAsVector();
                for (size_t i = 0; i + 1 < v.size(); i += 2) {
                    if (!v[i].isString()) { continue; }
                    std::string candidate = v[i].getStringValue();
                    if (!candidate.empty() && candidate.front() == '/') {
                        candidate.erase(candidate.begin());
                    }
                    if (candidate == name) { return v[i + 1]; }
                }
            }
            QPDFObjectHandle kids = node.getKey("/Kids");
            if (kids.isArray()) {
                for (auto const& kid : kids.getArrayAsVector()) {
                    QPDFObjectHandle found = walk(kid);
                    if (!found.isNull()) { return found; }
                }
            }
            return QPDFObjectHandle();
        };
        QPDFObjectHandle tree = namesDict.getKey("/Dests");
        if (!tree.isNull()) {
            QPDFObjectHandle v = walk(tree);
            if (!v.isNull()) { return v; }
        }
    }
    // Legacy: /Dests-Wörterbuch; Schlüssel können mit oder ohne Slash vorliegen.
    QPDFObjectHandle dests = catalog.getKey("/Dests");
    if (!dests.isNull() && dests.isDictionary()) {
        if (dests.hasKey(name)) { return dests.getKey(name); }
        std::string slashed = "/" + name;
        if (dests.hasKey(slashed)) { return dests.getKey(slashed); }
    }
    return QPDFObjectHandle();
}




struct pdfcore_document {
    QPDF qpdf;
    std::map<int, std::vector<std::string>> stringLists;
};

static pdfcore_status map_exception(const std::exception& e)
{
    std::string what(e.what());
    if (what.find("password") != std::string::npos ||
        what.find("encrypted") != std::string::npos) {
        return PDFCORE_ERR_PASSWORD;
    }
    return PDFCORE_ERR_OPEN;
}

pdfcore_document_t *pdfcore_open(const char *path, pdfcore_status *status)
{
    if (status) { *status = PDFCORE_OK; }
    if (!path) {
        if (status) { *status = PDFCORE_ERR_OPEN; }
        return nullptr;
    }
    pdfcore_document *doc = nullptr;
    try {
        doc = new pdfcore_document();
        doc->qpdf.processFile(path);
    } catch (const QPDFExc& e) {
        delete doc;
        if (status) {
            std::string w(e.what());
            *status = (w.find("password") != std::string::npos ||
                       w.find("encrypt") != std::string::npos)
                          ? PDFCORE_ERR_PASSWORD
                          : PDFCORE_ERR_OPEN;
        }
        return nullptr;
    } catch (const std::exception& e) {
        delete doc;
        if (status) { *status = map_exception(e); }
        return nullptr;
    } catch (...) {
        delete doc;
        if (status) { *status = PDFCORE_ERR_INTERNAL; }
        return nullptr;
    }
    return doc;
}

int pdfcore_page_count(pdfcore_document_t *doc)
{
    if (!doc) { return -1; }
    try {
        QPDFPageDocumentHelper helper(doc->qpdf);
        return static_cast<int>(helper.getAllPages().size());
    } catch (...) {
        return -1;
    }
}

/// Bildfilter, deren Ausgabegröße sich nicht aus den Bytes ableiten lässt.
///
/// qpdf dekodiert Flate, LZW, RunLength und die ASCII-Filter; JPEG & Co.
/// bleiben komprimiert. Für die wäre ein Vergleich „Bytes gegen Pixel"
/// sinnlos.
static bool has_opaque_image_filter(QPDFObjectHandle dict)
{
    QPDFObjectHandle filter = dict.getKey("/Filter");
    auto opaque = [](std::string const& n) {
        return n == "/DCTDecode" || n == "/JPXDecode"
            || n == "/JBIG2Decode" || n == "/CCITTFaxDecode";
    };
    if (filter.isName()) { return opaque(filter.getName()); }
    if (filter.isArray()) {
        int n = filter.getArrayNItems();
        for (int i = 0; i < n; ++i) {
            QPDFObjectHandle f = filter.getArrayItem(i);
            if (f.isName() && opaque(f.getName())) { return true; }
        }
    }
    return false;
}

/// Komponenten je Bildpunkt. 0 = unbekannt, dann wird nicht geprüft.
static long long color_space_components(QPDFObjectHandle cs)
{
    if (cs.isName()) {
        std::string n = cs.getName();
        if (n == "/DeviceGray" || n == "/CalGray" || n == "/G") { return 1; }
        if (n == "/DeviceRGB" || n == "/CalRGB" || n == "/RGB") { return 3; }
        if (n == "/DeviceCMYK" || n == "/CMYK") { return 4; }
        return 0;
    }
    if (cs.isArray() && cs.getArrayNItems() > 0) {
        QPDFObjectHandle family = cs.getArrayItem(0);
        if (family.isName()) {
            std::string n = family.getName();
            // Indiziert: ein Byte je Bildpunkt.
            if (n == "/Indexed" || n == "/I") { return 1; }
            if (n == "/ICCBased" && cs.getArrayNItems() > 1) {
                QPDFObjectHandle stream = cs.getArrayItem(1);
                if (stream.isStream()) {
                    QPDFObjectHandle nKey = stream.getDict().getKey("/N");
                    if (nKey.isInteger()) { return nKey.getIntValue(); }
                }
            }
            if (n == "/CalGray") { return 1; }
            if (n == "/CalRGB" || n == "/Lab") { return 3; }
        }
    }
    return 0;
}

int pdfcore_check(pdfcore_document_t *doc)
{
    if (!doc) { return PDFCORE_ERR_OPEN; }
    try {
        size_t warningsBefore = doc->qpdf.getWarnings().size();
        QPDFPageDocumentHelper helper(doc->qpdf);
        std::vector<QPDFPageObjectHelper> pages = helper.getAllPages();
        if (pages.empty()) { return PDFCORE_ERR_CHECK_FAILED; }

        // Kein Test auf den Knotentyp des Seitenbaums.
        //
        // Naheliegend wäre: Steht dort /Type/XXXXX statt /Type/Pages, ist das
        // Korruption. Gemessen ist es wirkungslos – qpdf repariert den Baum
        // beim Lesen und meldet danach /Type/Pages, unabhängig davon, was in
        // der Datei steht. Eine Prüfung darauf wäre toter Code, der
        // Gründlichkeit vortäuscht.
        //
        // Wer solche Schäden sehen will, müsste die Bytes vor qpdfs Reparatur
        // lesen. Dasselbe gilt für einen /Contents-Verweis ins Leere: Auch
        // den entfernt qpdf stillschweigend.

        // Den Seitenbaum aufzulösen genügt NICHT. Ein Dokument kann einen
        // makellosen Baum haben und trotzdem unlesbar sein: falsche
        // /Length-Angabe, abgeschnittener Bildstream, Verweis auf ein Objekt,
        // das es nicht gibt. Solche Schäden zeigen sich erst, wenn man die
        // Daten tatsächlich liest – deshalb wird hier jeder Stream einmal
        // vollständig durchgezogen, so wie `qpdf --check` es tut.
        //
        // Das Ziel ist ein Null-Pipeline: Es geht um das Lesen, nicht um die
        // Daten. Ein Stream, den qpdf nicht dekodieren kann, meldet sich
        // entweder über den Rückgabewert oder über eine neue Warnung.
        std::set<QPDFObjGen> seen;
        bool streamsOK = true;

        std::function<void(QPDFObjectHandle)> readStreams =
            [&](QPDFObjectHandle obj) {
            if (obj.isNull()) { return; }
            if (obj.isIndirect()) {
                QPDFObjGen og = obj.getObjGen();
                if (seen.count(og)) { return; }
                seen.insert(og);
            }
            if (obj.isStream()) {
                Pl_Discard discard;
                bool attempted = false;
                if (!obj.pipeStreamData(&discard, &attempted, 0, qpdf_dl_all,
                                        /*suppress_warnings=*/true,
                                        /*will_retry=*/false)) {
                    streamsOK = false;
                }
                // Der /Length-Eintrag muss zu dem passen, was wirklich da
                // ist – sonst liest jeder andere Betrachter über das Ende
                // hinaus.
                //
                // Nicht bei verschlüsselten Dokumenten: Dort nennt /Length die
                // Länge der VERSCHLÜSSELTEN Bytes, während hier die
                // entschlüsselten ankommen. Bei AES unterscheiden die sich
                // immer (Initialisierungsvektor plus Auffüllung) – die Prüfung
                // würde jedes verschlüsselte PDF für beschädigt erklären.
                QPDFObjectHandle dict = obj.getDict();
                QPDFObjectHandle length = dict.getKey("/Length");
                if (length.isInteger() && !doc->qpdf.isEncrypted()) {
                    Pl_Buffer raw("raw");
                    bool rawAttempted = false;
                    if (obj.pipeStreamData(&raw, &rawAttempted, 0, qpdf_dl_none,
                                           true, false)) {
                        std::unique_ptr<Buffer> b(raw.getBuffer());
                        if (b && static_cast<long long>(b->getSize())
                                != length.getIntValue()) {
                            streamsOK = false;
                        }
                    }
                }
                readStreams(dict);
            } else if (obj.isDictionary()) {
                for (auto const& key : obj.getKeys()) {
                    readStreams(obj.getKey(key));
                }
            } else if (obj.isArray()) {
                int n = obj.getArrayNItems();
                for (int i = 0; i < n; ++i) {
                    readStreams(obj.getArrayItem(i));
                }
            }
        };

        for (auto& page : pages) {
            QPDFObjectHandle po = page.getObjectHandle();
            readStreams(po);

            // Ein Verweis auf ein Objekt, das es nicht gibt, ist nach der
            // Norm ein Null-Objekt – formal zulässig, praktisch eine leere
            // Seite. Steht ein /Contents-Eintrag da, muss er auch zu etwas
            // führen. (Ganz ohne /Contents ist eine Seite legitim leer.)
            if (po.hasKey("/Contents")) {
                QPDFObjectHandle contents = po.getKey("/Contents");
                bool usable = contents.isStream();
                if (!usable && contents.isArray()) {
                    int n = contents.getArrayNItems();
                    usable = n > 0;
                    for (int i = 0; i < n && usable; ++i) {
                        if (!contents.getArrayItem(i).isStream()) {
                            usable = false;
                        }
                    }
                }
                if (!usable) { streamsOK = false; }
            }

            // Ein Bild, dessen Daten für die angegebenen Maße nicht
            // ausreichen, wird beim Anzeigen abgeschnitten oder mit Müll
            // gefüllt. Geprüft wird nur, was sich hier vollständig
            // dekodieren lässt – JPEG und Konsorten bleiben komprimiert,
            // ihre Bytezahl sagt über die Pixelzahl nichts aus.
            QPDFObjectHandle res = po.getKey("/Resources");
            QPDFObjectHandle xobjs = res.isDictionary()
                ? res.getKey("/XObject") : QPDFObjectHandle::newNull();
            if (xobjs.isDictionary()) {
                for (auto const& key : xobjs.getKeys()) {
                    QPDFObjectHandle x = xobjs.getKey(key);
                    if (!x.isStream()) { continue; }
                    QPDFObjectHandle d = x.getDict();
                    if (d.getKey("/Subtype").isName()
                        && d.getKey("/Subtype").getName() != "/Image") {
                        continue;
                    }
                    QPDFObjectHandle w = d.getKey("/Width");
                    QPDFObjectHandle h = d.getKey("/Height");
                    QPDFObjectHandle bpc = d.getKey("/BitsPerComponent");
                    if (!w.isInteger() || !h.isInteger() || !bpc.isInteger()) {
                        continue;
                    }
                    if (has_opaque_image_filter(d)) { continue; }

                    long long comps = color_space_components(d.getKey("/ColorSpace"));
                    if (comps <= 0) { continue; }
                    long long rowBits = w.getIntValue() * comps * bpc.getIntValue();
                    long long expected = ((rowBits + 7) / 8) * h.getIntValue();
                    if (expected <= 0) { continue; }

                    Pl_Buffer samples("samples");
                    bool attempted = false;
                    if (!x.pipeStreamData(&samples, &attempted, 0, qpdf_dl_all,
                                          true, false)) {
                        streamsOK = false;
                        continue;
                    }
                    std::unique_ptr<Buffer> b(samples.getBuffer());
                    if (b && static_cast<long long>(b->getSize()) < expected) {
                        streamsOK = false;
                    }
                }
            }
        }

        if (!streamsOK) { return PDFCORE_ERR_CHECK_FAILED; }

        // Warnungen sind KEIN Fehlschlag.
        //
        // Das war der Preis der vertieften Prüfung: Wer jeden Stream liest,
        // löst auch jede Warnung aus, die beim blossen Öffnen ausblieb. Drei
        // einwandfreie Dokumente des Korpus fielen daraufhin durch – ein
        // IRS-Formular mit unstimmiger Hint-Tabelle, eine Publikation mit
        // einem Stream ohne sauberes Ende. qpdf selbst sagt dazu „operation
        // succeeded with warnings" und beendet sich mit Code 3, den dieses
        // Projekt an anderer Stelle ausdrücklich als in Ordnung behandelt.
        //
        // Diese Dateien liessen sich damit gar nicht mehr bearbeiten. Eine
        // Prüfung, die den Nutzer von seinen eigenen Dokumenten aussperrt,
        // ist nicht streng, sondern falsch.
        //
        // Was bleibt, sind die eindeutigen Fälle: ein Stream, der sich nicht
        // lesen lässt; ein /Contents, das ins Leere zeigt; Bilddaten, die für
        // ihre Masse nicht reichen; ein Seitenbaum ohne Seiten. Die stehen
        // oben und melden sich über `streamsOK`.
        (void)warningsBefore;
        return PDFCORE_OK;
    } catch (const QPDFExc&) {
        return PDFCORE_ERR_CHECK_FAILED;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_version(char *buffer, size_t buffer_size)
{
    try {
        std::string v(QPDF::QPDFVersion());
        if (buffer && buffer_size > 0) {
            size_t n = v.size() < buffer_size - 1 ? v.size() : buffer_size - 1;
            std::memcpy(buffer, v.c_str(), n);
            buffer[n] = '\0';
        }
        return static_cast<int>(v.size());
    } catch (...) {
        return -1;
    }
}

void pdfcore_close(pdfcore_document_t *doc)
{
    delete doc;
}

// ============================================================================
// Epic Phase 7 – read-only semantische Inspection
// ============================================================================

namespace {

QPDFObjectHandle resolve_inheritable(QPDFObjectHandle page, std::string const& key)
{
    QPDFObjectHandle current = page;
    int depth = 0;
    while (!current.isNull() && depth < 64) {
        if (current.hasKey(key)) {
            return current.getKey(key);
        }
        current = current.getKey("/Parent");
        ++depth;
    }
    return QPDFObjectHandle();
}

namespace {
QPDFObjectHandle dict_of(QPDFObjectHandle obj)
{
    if (obj.isStream()) { return obj.getDict(); }
    return obj;
}
} // namespace

bool box_to_doubles(QPDFObjectHandle box, double out[4])
{
    if (box.isNull() || !box.isArray()) { return false; }
    try {
        auto v = box.getArrayAsVector();
        if (v.size() != 4) { return false; }
        for (int i = 0; i < 4; ++i) {
            out[i] = v[static_cast<size_t>(i)].getNumericValue();
        }
        return true;
    } catch (...) {
        return false;
    }
}

void collect_outline_labels(std::vector<QPDFOutlineObjectHelper> kids,
                            std::vector<std::string>& out, int depth)
{
    if (depth > 32) { return; }
    for (auto& k : kids) {
        out.push_back(k.getTitle());
        collect_outline_labels(k.getKids(), out, depth + 1);
    }
}

/// Masterplan Finding 6 – Sammelt alle Einträge eines Names-Trees als
/// (Name, Wert)-Paare in Baumreihenfolge. Ergänzt das reine Zählen, weil der
/// vollständige Snapshot die NAMEN braucht, nicht nur ihre Anzahl.
void collect_name_tree_entries(
    QPDFObjectHandle node, int depth,
    std::vector<std::pair<std::string, QPDFObjectHandle>>& out)
{
    if (node.isNull() || !node.isDictionary() || depth > 32) { return; }
    QPDFObjectHandle names = node.getKey("/Names");
    if (names.isArray()) {
        auto v = names.getArrayAsVector();
        for (size_t i = 0; i + 1 < v.size(); i += 2) {
            if (!v[i].isString()) { continue; }
            // Text-Strings können UTF-16BE sein und NUL-Bytes enthalten;
            // die NUL-terminierte Listen-API würde sie abschneiden.
            out.emplace_back(v[i].getUTF8Value(), v[i + 1]);
        }
    }
    QPDFObjectHandle kids = node.getKey("/Kids");
    if (kids.isArray()) {
        for (auto const& kid : kids.getArrayAsVector()) {
            collect_name_tree_entries(kid, depth + 1, out);
        }
    }
}

/// Löst ein Destination-Objekt (Array, oder Dict mit /D) auf die 0-basierte
/// Zielseite auf. -1 = unauflösbar.
int destination_page_index(QPDF& qpdf, QPDFObjectHandle dest)
{
    if (dest.isNull()) { return -1; }
    if (dest.isDictionary() && dest.hasKey("/D")) { dest = dest.getKey("/D"); }
    QPDFObjectHandle pageRef;
    if (dest.isArray()) {
        auto v = dest.getArrayAsVector();
        if (!v.empty()) { pageRef = v[0]; }
    } else if (dest.isString() || dest.isName()) {
        std::string name = dest.isName() ? dest.getName() : dest.getStringValue();
        if (!name.empty() && name.front() == '/') { name.erase(name.begin()); }
        QPDFObjectHandle resolved = lookup_named_dest(qpdf, name);
        if (resolved.isDictionary() && resolved.hasKey("/D")) {
            resolved = resolved.getKey("/D");
        }
        if (resolved.isArray()) {
            auto v = resolved.getArrayAsVector();
            if (!v.empty()) { pageRef = v[0]; }
        }
    }
    if (pageRef.isNull()) { return -1; }
    // Direkte Integer-Seitennummer (selten, aber gültig).
    if (pageRef.isInteger()) { return static_cast<int>(pageRef.getNumericValue()); }
    if (!pageRef.isIndirect()) { return -1; }
    QPDFObjGen og = pageRef.getObjGen();
    auto pages = qpdf.getAllPages();
    for (size_t i = 0; i < pages.size(); ++i) {
        if (pages[i].getObjGen() == og) { return static_cast<int>(i); }
    }
    return -1;
}

/// Voll qualifizierter Feldname über die /Parent-Kette (PDF 32000-1, 12.7.3.2).
std::string qualified_field_name(QPDFObjectHandle field)
{
    std::vector<std::string> parts;
    QPDFObjectHandle node = field;
    int guard = 0;
    while (!node.isNull() && node.isDictionary() && guard++ < 32) {
        QPDFObjectHandle t = node.getKey("/T");
        if (t.isString()) { parts.push_back(t.getUTF8Value()); }
        node = node.getKey("/Parent");
    }
    std::string name;
    for (auto it = parts.rbegin(); it != parts.rend(); ++it) {
        if (!name.empty()) { name += "."; }
        name += *it;
    }
    return name;
}

/// Erbt /FT und /Ff über die /Parent-Kette (Widget-Kinder tragen sie oft nicht).
QPDFObjectHandle inherited_field_key(QPDFObjectHandle field, char const* key)
{
    QPDFObjectHandle node = field;
    int guard = 0;
    while (!node.isNull() && node.isDictionary() && guard++ < 32) {
        QPDFObjectHandle v = node.getKey(key);
        if (!v.isNull()) { return v; }
        node = node.getKey("/Parent");
    }
    return QPDFObjectHandle::newNull();
}

/// Ersetzt Zeichen, die das Zeilenformat der Listen-API zerstören würden.
/// Ohne das könnte ein Feldwert mit „|" oder Zeilenumbruch eine Zeile in
/// zwei zerlegen und der Swift-Parser läse Müll.
std::string sanitize_list_field(std::string s)
{
    for (auto& ch : s) {
        if (ch == '|' || ch == '\n' || ch == '\r') { ch = ' '; }
    }
    return s;
}

/// Serialisiert einen Feldwert deterministisch (String/Name/Zahl/Bool/Array).
std::string field_value_string(QPDFObjectHandle v)
{
    if (v.isNull()) { return ""; }
    if (v.isString()) { return v.getUTF8Value(); }
    if (v.isName()) {
        std::string n = v.getName();
        if (!n.empty() && n.front() == '/') { n.erase(n.begin()); }
        return n;
    }
    if (v.isBool()) { return v.getBoolValue() ? "true" : "false"; }
    if (v.isInteger() || v.isReal()) { return v.unparse(); }
    if (v.isArray()) {
        std::string joined;
        for (auto const& item : v.getArrayAsVector()) {
            if (!joined.empty()) { joined += ","; }
            joined += field_value_string(item);
        }
        return joined;
    }
    return "";
}

/// Zählt Einträge eines PDF-Names-Trees (/Names-Arrays: [name, val, name, val…]).
int count_name_tree_entries(QPDFObjectHandle node, int depth)
{
    if (node.isNull() || depth > 32) { return 0; }
    int total = 0;
    QPDFObjectHandle names = node.getKey("/Names");
    if (names.isArray()) {
        auto v = names.getArrayAsVector();
        total += static_cast<int>(v.size()) / 2;
    }
    QPDFObjectHandle kids = node.getKey("/Kids");
    if (kids.isArray()) {
        for (auto const& kid : kids.getArrayAsVector()) {
            total += count_name_tree_entries(kid, depth + 1);
        }
    }
    return total;
}

} // namespace

int pdfcore_page_info(pdfcore_document_t *doc, int page_index,
                      pdfcore_page_info_t *out)
{
    if (!doc || !out || page_index < 0) { return -1; }
    try {
        QPDFPageDocumentHelper helper(doc->qpdf);
        auto pages = helper.getAllPages();
        if (page_index >= static_cast<int>(pages.size())) { return -1; }
        QPDFPageObjectHelper ph = pages[static_cast<size_t>(page_index)];

        struct pdfcore_page_info info{};
        info.index = page_index;
        if (!box_to_doubles(ph.getMediaBox(), info.media_box)) { return -1; }
        QPDFObjectHandle crop = ph.getCropBox();
        if (!box_to_doubles(crop, info.crop_box)) {
            std::memcpy(info.crop_box, info.media_box, sizeof(info.crop_box));
        }

        // /Rotate inkl. Vererbung über die /Parent-Kette.
        info.rotation = 0;
        QPDFObjectHandle rot = resolve_inheritable(ph, "/Rotate");
        if (!rot.isNull() && rot.isInteger()) {
            int r = static_cast<int>(rot.getNumericValue());
            r %= 360;
            if (r < 0) { r += 360; }
            info.rotation = r;
        }
        *out = info;
        return 0;
    } catch (...) {
        return -1;
    }
}

int pdfcore_annotation_counts(pdfcore_document_t *doc,
                              int *total, int *links, int *widgets)
{
    if (!doc) { return -1; }
    try {
        int t = 0, l = 0, w = 0;
        for (auto const& ph : doc->qpdf.getAllPages()) {
            QPDFObjectHandle annots = ph.getKey("/Annots");
            if (!annots.isArray()) { continue; }
            for (auto const& a : annots.getArrayAsVector()) {
                if (a.isNull() || !a.isDictionary()) { continue; }
                ++t;
                QPDFObjectHandle st = a.getKey("/Subtype");
                if (st.isName()) {
                    std::string n = st.getName();
                    if (n == "/Link") { ++l; }
                    else if (n == "/Widget") { ++w; }
                }
            }
        }
        if (total) { *total = t; }
        if (links) { *links = l; }
        if (widgets) { *widgets = w; }
        return 0;
    } catch (...) {
        return -1;
    }
}

int pdfcore_page_annotation_counts(pdfcore_document_t *doc, int page_index,
                                   int *total, int *links, int *widgets)
{
    if (!doc || page_index < 0) { return -1; }
    try {
        auto pages = doc->qpdf.getAllPages();
        if (page_index >= static_cast<int>(pages.size())) { return -1; }
        int t = 0, l = 0, w = 0;
        QPDFObjectHandle annots =
            pages[static_cast<size_t>(page_index)].getKey("/Annots");
        if (annots.isArray()) {
            for (auto const& a : annots.getArrayAsVector()) {
                if (a.isNull() || !a.isDictionary()) { continue; }
                ++t;
                QPDFObjectHandle st = a.getKey("/Subtype");
                if (!st.isName()) { continue; }
                if (st.getName() == "/Link") { ++l; }
                else if (st.getName() == "/Widget") { ++w; }
            }
        }
        if (total) { *total = t; }
        if (links) { *links = l; }
        if (widgets) { *widgets = w; }
        return 0;
    } catch (...) {
        return -1;
    }
}

// ============================================================================
// Epic Phase 21 – Bild-XObject-Inspektion (Helpers)
// ============================================================================

namespace {

struct ImagePlacement {
    int pageIndex;
    std::string name;
    double w = 0, h = 0;
    int bpc = 0;
    std::string cs;
    std::string filters;
    bool smask = false;
    int mask = 0;   // 0 keine, 1 Schablone, 2 Farbschlüssel
    bool imageMask = false;
    std::string decodeArray;
    long long rawLength = -1;
    QPDFObjGen objGen{};
    double placedW = 0;   // Platzierung in pt (aus cm/Do-Scan, Phase 23b)
    double placedH = 0;
};

std::string strip_slash(std::string s)
{
    if (!s.empty() && s.front() == '/') { s.erase(s.begin()); }
    return s;
}

void walk_resources(QPDFObjectHandle res, int pageIdx, int depth,
                    std::vector<ImagePlacement>& out)
{
    if (res.isNull() || !res.isDictionary() || depth > 16) { return; }
    QPDFObjectHandle resDict = dict_of(res);
    QPDFObjectHandle xobjs = resDict.getKey("/XObject");
    if (xobjs.isNull() || !xobjs.isDictionary()) { return; }
    for (auto const& key : xobjs.getKeys()) {
        QPDFObjectHandle xo = xobjs.getKey(key);
        if (xo.isNull()) { continue; }
        QPDFObjectHandle st = dict_of(xo).getKey("/Subtype");
        if (!st.isName()) { continue; }
        std::string subtype = st.getName();
        if (subtype == "/Image") {
            ImagePlacement p;
            p.pageIndex = pageIdx;
            p.name = key;
            p.w = dict_of(xo).getKey("/Width").getNumericValue();
            p.h = dict_of(xo).getKey("/Height").getNumericValue();
            p.bpc = static_cast<int>(
                dict_of(xo).getKey("/BitsPerComponent").getNumericValue());
            QPDFObjectHandle cso = dict_of(xo).getKey("/ColorSpace");
            if (cso.isName()) {
                p.cs = strip_slash(cso.getName());
            } else if (cso.isArray()) {
                auto av = cso.getArrayAsVector();
                if (!av.empty() && av[0].isName()) {
                    p.cs = strip_slash(av[0].getName());
                    // Bei ICCBased die Komponentenzahl anhängen: Sie steht im
                    // Profil (/N) und entscheidet, ob sich das Bild überhaupt
                    // aufbauen lässt. Ohne sie war ICCBased pauschal
                    // ausgeschlossen – 11,5 MB im Korpus.
                    long long n = color_space_components(cso);
                    if (n > 0) { p.cs += ":" + std::to_string(n); }
                }
            }
            QPDFObjectHandle f = dict_of(xo).getKey("/Filter");
            if (f.isName()) {
                p.filters = strip_slash(f.getName());
            } else if (f.isArray()) {
                auto fv = f.getArrayAsVector();
                for (size_t fi = 0; fi < fv.size(); ++fi) {
                    if (fi) { p.filters += "+"; }
                    p.filters += strip_slash(fv[fi].getName());
                }
            }
            QPDFObjectHandle xd = dict_of(xo);
            p.smask = xd.hasKey("/SMask");
            // 0 = keine, 1 = Schablone (Stream), 2 = Farbschlüssel (Array).
            //
            // Die Unterscheidung zählt: Eine Schablone wird auf das Bild
            // skaliert und ist unproblematisch. Ein Farbschlüssel benennt
            // Farbwerte im Original und überlebt keine verlustbehaftete
            // Neukodierung.
            {
                QPDFObjectHandle mk = xd.getKey("/Mask");
                p.mask = mk.isNull() ? 0 : (mk.isArray() ? 2 : 1);
            }
            QPDFObjectHandle im = xd.getKey("/ImageMask");
            p.imageMask = im.isBool() && im.getBoolValue();
            // Die WERTE, nicht nur ihr Vorhandensein: Wer das Bild neu
            // kodieren will, muss die Abbildung anwenden können.
            {
                QPDFObjectHandle dec = xd.getKey("/Decode");
                p.decodeArray.clear();
                if (dec.isArray()) {
                    int n = dec.getArrayNItems();
                    for (int i = 0; i < n; ++i) {
                        QPDFObjectHandle v = dec.getArrayItem(i);
                        if (!(v.isInteger() || v.isReal())) { p.decodeArray.clear(); break; }
                        char buf[32];
                        std::snprintf(buf, sizeof(buf), "%.4f", v.getNumericValue());
                        if (!p.decodeArray.empty()) { p.decodeArray += ","; }
                        p.decodeArray += buf;
                    }
                }
            }
            QPDFObjectHandle len = xd.getKey("/Length");
            if (len.isInteger()) {
                p.rawLength = static_cast<long long>(len.getNumericValue());
            }
            p.objGen = xo.getObjGen();
            out.push_back(p);
        } else if (subtype == "/Form") {
            // dict_of: Form-XObjects sind STREAMS – getKey direkt auf dem
            // Stream liefert in qpdf 12 null (Warnung „operation for
            // dictionary attempted on object of type stream"). Ohne dict_of
            // wurden Bilder in (verschachtelten) Formen nie gefunden.
            walk_resources(dict_of(xo).getKey("/Resources"), pageIdx, depth + 1, out);
        }
    }
}

// ============================================================================
// Phase 23c – Form-XObject-Ressourcen (Platzierungsgeometrie in Formen)
// ============================================================================

/// Eine Ressourcen-Beziehung innerhalb einer Form: die Form selbst (mit
/// Eltern und /Matrix-Skalierung) oder ein /Image-Eintrag in ihrer Map.
struct FormResourceEntry {
    int pageIndex;
    QPDFObjGen form;     // Form, deren /Resources den Eintrag trägt
    QPDFObjGen parent;   // Eltern-Form (-1|-1 = direkt in den Seiten-Resources)
    double matrixSX = 1, matrixSY = 1;   // Spaltennormen der /Matrix
    std::string name;
    QPDFObjGen target;
    bool isImage;
};

/// Sammelt je Seite alle errebbaren Form-XObjects samt ihrer direkten
/// /Image-Einträge. Struktur wie walk_resources (dict_of für Stream-Dicts,
/// Tiefe begrenzt); zusätzlich: Zykeln/Doppelbesuche über ein ObjGen-Set
/// (Erster Fund gewinnt) und ein Budget von 64 Formen je Seite.
void collect_form_resources(QPDFObjectHandle res, int pageIdx,
                            QPDFObjGen parentForm,
                            std::set<QPDFObjGen>& visited,
                            std::vector<FormResourceEntry>& out)
{
    if (res.isNull() || !res.isDictionary()) { return; }
    QPDFObjectHandle resDict = dict_of(res);
    QPDFObjectHandle xobjs = resDict.getKey("/XObject");
    if (xobjs.isNull() || !xobjs.isDictionary()) { return; }
    for (auto const& key : xobjs.getKeys()) {
        QPDFObjectHandle xo = xobjs.getKey(key);
        if (xo.isNull()) { continue; }
        QPDFObjectHandle st = dict_of(xo).getKey("/Subtype");
        if (!st.isName() || st.getName() != "/Form") { continue; }
        QPDFObjGen og = xo.getObjGen();
        if (visited.count(og)) { continue; }
        if (visited.size() >= 64) { return; }
        visited.insert(og);

        // /Matrix der Form: Sie bildet das Einheitsquadrat in den Raum des
        // Eltern-Contents ab. Für die Platzierungskette genügen die
        // Spaltennormen – exakt bei achsenparallelen Matrizen (der Regelfall).
        double sx = 1, sy = 1;
        QPDFObjectHandle m = dict_of(xo).getKey("/Matrix");
        if (m.isArray() && m.getArrayNItems() == 6) {
            double v[6] = {1, 0, 0, 1, 0, 0};
            bool ok = true;
            for (int i = 0; i < 6; ++i) {
                QPDFObjectHandle item = m.getArrayItem(i);
                if (item.isInteger() || item.isReal()) {
                    v[i] = item.getNumericValue();
                } else { ok = false; break; }
            }
            if (ok) {
                sx = std::sqrt(v[0] * v[0] + v[1] * v[1]);
                sy = std::sqrt(v[2] * v[2] + v[3] * v[3]);
            }
        }

        // Die Form selbst: Name gilt es im ELTERN-Content zu finden, wenn
        // deren Scan läuft – die Kettenskala kommt von dort.
        FormResourceEntry self;
        self.pageIndex = pageIdx;
        self.form = og;
        self.parent = parentForm;
        self.matrixSX = sx;
        self.matrixSY = sy;
        self.name = key;
        self.target = og;
        self.isImage = false;
        out.push_back(self);

        // Direkte Bilder der Form; verschachtelte Formen per Rekursion.
        QPDFObjectHandle own = dict_of(xo).getKey("/Resources");
        if (own.isNull() || !own.isDictionary()) { continue; }
        QPDFObjectHandle kidXobjs = dict_of(own).getKey("/XObject");
        if (!kidXobjs.isNull() && kidXobjs.isDictionary()) {
            for (auto const& kidKey : kidXobjs.getKeys()) {
                QPDFObjectHandle kid = kidXobjs.getKey(kidKey);
                if (kid.isNull()) { continue; }
                QPDFObjectHandle kidSt = dict_of(kid).getKey("/Subtype");
                if (!kidSt.isName() || kidSt.getName() != "/Image") { continue; }
                FormResourceEntry e;
                e.pageIndex = pageIdx;
                e.form = og;
                e.parent = parentForm;
                e.matrixSX = sx;
                e.matrixSY = sy;
                e.name = kidKey;
                e.target = kid.getObjGen();
                e.isImage = true;
                out.push_back(e);
            }
        }
        collect_form_resources(own, pageIdx, og, visited, out);
    }
}

} // namespace

// ============================================================================
// Epic Phase 23b – cm/Do-Scan über dekodierte Content-Bytes
// ============================================================================

static std::vector<std::string> const& ensure_list(pdfcore_document_t& doc, int list_id)
{
    auto it = doc.stringLists.find(list_id);
    if (it != doc.stringLists.end()) { return it->second; }

    std::vector<std::string> list;
    if (list_id == PDFCORE_LIST_LINKS) {
        for (auto const& ph : doc.qpdf.getAllPages()) {
            QPDFObjectHandle annots = ph.getKey("/Annots");
            if (!annots.isArray()) { continue; }
            for (auto const& a : annots.getArrayAsVector()) {
                if (a.isNull() || !a.isDictionary()) { continue; }
                QPDFObjectHandle action = a.getKey("/A");
                if (!action.isNull() && action.isDictionary()
                    && action.getKey("/S").isName()
                    && action.getKey("/S").getName() == "/URI"
                    && action.getKey("/URI").isString()) {
                    list.push_back(action.getKey("/URI").getUTF8Value());
                }
            }
        }
    } else if (list_id == PDFCORE_LIST_PAGE_LABELS) {
        QPDFObjectHandle pl = doc.qpdf.getRoot().getKey("/PageLabels");
        if (!pl.isNull() && pl.isDictionary()) {
            QPDFObjectHandle nums = pl.getKey("/Nums");
            if (nums.isArray()) {
                auto v = nums.getArrayAsVector();
                for (size_t i = 0; i + 1 < v.size(); i += 2) {
                    int start = static_cast<int>(v[i].getNumericValue());
                    QPDFObjectHandle def = v[i + 1];
                    std::string style, prefix, first;
                    if (def.isDictionary()) {
                        QPDFObjectHandle sObj = def.getKey("/S");
                        if (sObj.isName()) {
                            style = sObj.getName();
                            if (!style.empty() && style.front() == '/') {
                                style.erase(style.begin());
                            }
                        }
                        QPDFObjectHandle pObj = def.getKey("/P");
                        if (pObj.isString()) { prefix = pObj.getUTF8Value(); }
                        QPDFObjectHandle stObj = def.getKey("/St");
                        if (stObj.isInteger()) {
                            first = std::to_string(
                                static_cast<int>(stObj.getNumericValue()));
                        }
                    }
                    list.push_back(std::to_string(start) + "|" + style + "|" +
                                   prefix + "|" + first);
                }
            }
        }
    } else if (list_id == PDFCORE_LIST_IMAGES) {
        auto pages = doc.qpdf.getAllPages();
        std::vector<ImagePlacement> placements;
        int pi = 0;
        for (auto const& pg : pages) {
            walk_resources(
                resolve_inheritable(pg, "/Resources"), pi, 0, placements);
            ++pi;
        }
        std::map<QPDFObjGen, std::set<int>> byObj;
        for (auto const& pl : placements) {
            byObj[pl.objGen].insert(pl.pageIndex);
        }
        for (auto const& pl : placements) {
            bool shared = byObj[pl.objGen].size() > 1;
            std::string cs = pl.cs.empty() ? "None" : pl.cs;
            list.push_back(std::to_string(pl.pageIndex) + "|" + pl.name + "|" +
                std::to_string(static_cast<int>(pl.w)) + "|" +
                std::to_string(static_cast<int>(pl.h)) + "|" +
                std::to_string(pl.bpc) + "|" + cs + "|" + pl.filters + "|" +
                (pl.smask ? "1" : "0") + "|" + (shared ? "1" : "0") + "|" +
                std::to_string(static_cast<int>(pl.placedW)) + "|" +
                std::to_string(static_cast<int>(pl.placedH)) + "|" +
                std::to_string(pl.objGen.getObj()) + "|" +
                std::to_string(pl.objGen.getGen()) + "|" +
                std::to_string(pl.mask) + "|" +
                (pl.imageMask ? "1" : "0") + "|" +
                (pl.decodeArray.empty() ? "-" : pl.decodeArray) + "|" +
                std::to_string(pl.rawLength));
        }
    } else if (list_id == PDFCORE_LIST_FORM_RESOURCES) {
        auto pages = doc.qpdf.getAllPages();
        int pi = 0;
        for (auto const& pg : pages) {
            std::vector<FormResourceEntry> entries;
            std::set<QPDFObjGen> visitedForms;
            collect_form_resources(resolve_inheritable(pg, "/Resources"),
                                   pi, QPDFObjGen(-1, -1),
                                   visitedForms, entries);

            // Formen ohne Bild im Teilbaum tragen nichts zur
            // Platzierungsgeometrie bei und fallen weg. Direkte Bilder
            // markieren, die Markierung läuft die Elternkette hinauf. Die
            // Elternzeiger bilden je Seite einen Wald (jede Form wird nur
            // EINMAL besucht), die rekursive Auswertung ist memoisiert.
            std::map<QPDFObjGen, bool> hasDirectImage;
            std::map<QPDFObjGen, std::vector<QPDFObjGen>> childrenOf;
            for (auto const& e : entries) {
                if (e.isImage) { hasDirectImage[e.form] = true; }
                else { childrenOf[e.parent].push_back(e.form); }
            }
            std::map<QPDFObjGen, bool> marked;
            std::function<bool(QPDFObjGen)> hasImageInSubtree =
                [&](QPDFObjGen f) -> bool {
                auto it = marked.find(f);
                if (it != marked.end()) { return it->second; }
                bool r = hasDirectImage[f];
                for (auto const& c : childrenOf[f]) {
                    if (hasImageInSubtree(c)) { r = true; }
                }
                marked[f] = r;
                return r;
            };

            for (auto const& e : entries) {
                if (!hasImageInSubtree(e.form)) { continue; }
                char scale[2][32];
                std::snprintf(scale[0], sizeof(scale[0]), "%.4f", e.matrixSX);
                std::snprintf(scale[1], sizeof(scale[1]), "%.4f", e.matrixSY);
                list.push_back(std::to_string(e.pageIndex) + "|" +
                    std::to_string(e.form.getObj()) + "|" +
                    std::to_string(e.form.getGen()) + "|" +
                    std::to_string(e.parent.getObj()) + "|" +
                    std::to_string(e.parent.getGen()) + "|" +
                    scale[0] + "|" + scale[1] + "|" +
                    sanitize_list_field(strip_slash(e.name)) + "|" +
                    std::to_string(e.target.getObj()) + "|" +
                    std::to_string(e.target.getGen()) + "|" +
                    (e.isImage ? "1" : "0"));
            }
            ++pi;
        }
    } else if (list_id == PDFCORE_LIST_NAMED_DESTS) {
        // /Names→/Dests (Name Tree) + Legacy /Dests-Dict im Katalog.
        QPDFObjectHandle catalog = doc.qpdf.getRoot();
        std::vector<std::pair<std::string, QPDFObjectHandle>> entries;
        QPDFObjectHandle namesDict = catalog.getKey("/Names");
        if (!namesDict.isNull() && namesDict.isDictionary()) {
            collect_name_tree_entries(namesDict.getKey("/Dests"), 0, entries);
        }
        QPDFObjectHandle oldDests = catalog.getKey("/Dests");
        if (!oldDests.isNull() && oldDests.isDictionary()) {
            for (auto const& key : oldDests.getKeys()) {
                std::string n = key;
                if (!n.empty() && n.front() == '/') { n.erase(n.begin()); }
                entries.emplace_back(n, oldDests.getKey(key));
            }
        }
        // Deterministisch: nach Namen sortieren (Name-Tree-Reihenfolge ist
        // writer-abhängig, der Snapshot darf das nicht sein).
        std::sort(entries.begin(), entries.end(),
                  [](auto const& a, auto const& b) { return a.first < b.first; });
        for (auto const& e : entries) {
            list.push_back(sanitize_list_field(e.first) + "|" +
                std::to_string(destination_page_index(doc.qpdf, e.second)));
        }
    } else if (list_id == PDFCORE_LIST_ATTACHMENTS) {
        QPDFObjectHandle catalog = doc.qpdf.getRoot();
        QPDFObjectHandle namesDict = catalog.getKey("/Names");
        std::vector<std::pair<std::string, QPDFObjectHandle>> entries;
        if (!namesDict.isNull() && namesDict.isDictionary()) {
            collect_name_tree_entries(namesDict.getKey("/EmbeddedFiles"), 0, entries);
        }
        std::sort(entries.begin(), entries.end(),
                  [](auto const& a, auto const& b) { return a.first < b.first; });
        for (auto const& e : entries) {
            long long size = -1;
            std::string checksum = "-";
            QPDFObjectHandle spec = e.second;
            if (!spec.isNull() && spec.isDictionary()) {
                QPDFObjectHandle ef = spec.getKey("/EF");
                if (!ef.isNull() && ef.isDictionary()) {
                    QPDFObjectHandle f = ef.getKey("/F");
                    if (f.isNull()) { f = ef.getKey("/UF"); }
                    if (!f.isNull()) {
                        // Der INHALT zählt, nicht seine Speicherform.
                        //
                        // Zuvor stand hier `/Params /Size`, ersatzweise
                        // `/Length` – also die Länge des KOMPRIMIERTEN
                        // Streams. Die ändert sich, sobald qpdf den Stream
                        // nachpackt, ohne dass ein Byte des Anhangs anders
                        // wäre. Über den Korpus erzeugte das 120 Fehlschläge
                        // auf 24 einwandfreien Dokumenten: „3968 Bytes →
                        // 3773 Bytes" bei bitgleichem Inhalt.
                        //
                        // Gelesen wird deshalb der dekodierte Strom. Dazu
                        // eine Prüfsumme: Gleiche Länge bei anderem Inhalt
                        // wäre sonst unsichtbar.
                        if (f.isStream()) {
                            Pl_Buffer buf("attachment");
                            bool attempted = false;
                            if (f.pipeStreamData(&buf, &attempted, 0, qpdf_dl_all,
                                                 true, false)) {
                                std::unique_ptr<Buffer> b(buf.getBuffer());
                                if (b) {
                                    size = static_cast<long long>(b->getSize());
                                    // FNV-1a, 64 Bit – klein, ohne Abhängigkeit,
                                    // und für „hat sich etwas geändert" genug.
                                    unsigned long long h = 1469598103934665603ULL;
                                    unsigned char const* d = b->getBuffer();
                                    for (size_t i = 0; i < b->getSize(); ++i) {
                                        h ^= d[i];
                                        h *= 1099511628211ULL;
                                    }
                                    checksum = std::to_string(h);
                                }
                            }
                        }
                        if (size < 0) {
                            QPDFObjectHandle params = dict_of(f).getKey("/Params");
                            if (!params.isNull() && params.isDictionary()
                                && params.getKey("/Size").isInteger()) {
                                size = static_cast<long long>(
                                    params.getKey("/Size").getNumericValue());
                            }
                        }
                    }
                }
            }
            list.push_back(sanitize_list_field(e.first) + "|"
                           + std::to_string(size) + "|" + checksum);
        }
    } else if (list_id == PDFCORE_LIST_FORM_FIELDS
               || list_id == PDFCORE_LIST_SIGNATURES) {
        // Feldbaum über /AcroForm→/Fields; fällt auf Widget-Annots zurück,
        // wenn ein Writer das Dokument-Level-/AcroForm weglässt (PDFKit).
        std::vector<std::string> rows;
        std::set<QPDFObjGen> seen;

        auto emit = [&](QPDFObjectHandle field) {
            if (field.isNull() || !field.isDictionary()) { return; }
            QPDFObjectHandle ftObj = inherited_field_key(field, "/FT");
            if (ftObj.isNull() || !ftObj.isName()) { return; }
            std::string ft = ftObj.getName();
            if (!ft.empty() && ft.front() == '/') { ft.erase(ft.begin()); }
            std::string name = qualified_field_name(field);
            if (list_id == PDFCORE_LIST_SIGNATURES) {
                if (ft != "Sig") { return; }
                std::string sub;
                QPDFObjectHandle v = field.getKey("/V");
                if (!v.isNull() && v.isDictionary()) {
                    QPDFObjectHandle sf = v.getKey("/SubFilter");
                    if (sf.isName()) {
                        sub = sf.getName();
                        if (!sub.empty() && sub.front() == '/') { sub.erase(sub.begin()); }
                    }
                }
                rows.push_back(sanitize_list_field(name) + "|"
                               + sanitize_list_field(sub));
                return;
            }
            // Signaturwerte sind Dictionaries – nicht als Wert serialisieren.
            std::string value = (ft == "Sig")
                ? std::string("") : field_value_string(inherited_field_key(field, "/V"));
            QPDFObjectHandle ffObj = inherited_field_key(field, "/Ff");
            long long flags = ffObj.isInteger()
                ? static_cast<long long>(ffObj.getNumericValue()) : 0;
            rows.push_back(sanitize_list_field(name) + "|" + ft + "|"
                           + sanitize_list_field(value) + "|"
                           + std::to_string(flags));
        };

        std::function<void(QPDFObjectHandle, int)> walkField =
            [&](QPDFObjectHandle field, int depth) {
            if (field.isNull() || !field.isDictionary() || depth > 32) { return; }
            if (field.isIndirect()) {
                if (!seen.insert(field.getObjGen()).second) { return; }
            }
            QPDFObjectHandle kids = field.getKey("/Kids");
            bool hasFieldKids = false;
            if (kids.isArray()) {
                for (auto const& kid : kids.getArrayAsVector()) {
                    if (kid.isNull() || !kid.isDictionary()) { continue; }
                    // Kid ist ein echtes Feld, wenn es /T trägt; sonst ist es
                    // nur eine Widget-Repräsentation desselben Feldes.
                    if (kid.hasKey("/T")) {
                        hasFieldKids = true;
                        walkField(kid, depth + 1);
                    }
                }
            }
            if (!hasFieldKids) { emit(field); }
        };

        QPDFObjectHandle acro = doc.qpdf.getRoot().getKey("/AcroForm");
        bool walked = false;
        if (!acro.isNull() && acro.isDictionary()) {
            QPDFObjectHandle fields = acro.getKey("/Fields");
            if (fields.isArray()) {
                for (auto const& f : fields.getArrayAsVector()) {
                    walkField(f, 0);
                }
                walked = true;
            }
        }
        if (!walked || rows.empty()) {
            for (auto const& ph : doc.qpdf.getAllPages()) {
                QPDFObjectHandle annots = ph.getKey("/Annots");
                if (!annots.isArray()) { continue; }
                for (auto const& a : annots.getArrayAsVector()) {
                    if (a.isNull() || !a.isDictionary()) { continue; }
                    QPDFObjectHandle st = a.getKey("/Subtype");
                    if (!(st.isName() && st.getName() == "/Widget")) { continue; }
                    if (a.isIndirect() && !seen.insert(a.getObjGen()).second) { continue; }
                    emit(a);
                }
            }
        }
        std::sort(rows.begin(), rows.end());
        list = std::move(rows);
    } else if (list_id == PDFCORE_LIST_OUTLINE_TREE) {
        QPDFOutlineDocumentHelper oh(doc.qpdf);
        if (oh.hasOutlines()) {
            std::function<void(std::vector<QPDFOutlineObjectHelper>, int)> walk =
                [&](std::vector<QPDFOutlineObjectHelper> kids, int depth) {
                for (auto& k : kids) {
                    std::string label;
                    QPDFObjectHandle t = k.getObjectHandle().getKey("/Title");
                    if (t.isString()) { label = t.getUTF8Value(); }
                    QPDFObjectHandle dest = k.getObjectHandle().getKey("/Dest");
                    if (dest.isNull()) {
                        QPDFObjectHandle action = k.getObjectHandle().getKey("/A");
                        if (!action.isNull() && action.isDictionary()) {
                            dest = action.getKey("/D");
                        }
                    }
                    list.push_back(std::to_string(depth) + "|"
                        + sanitize_list_field(label) + "|"
                        + std::to_string(destination_page_index(doc.qpdf, dest)));
                    walk(k.getKids(), depth + 1);
                }
            };
            walk(oh.getTopLevelOutlines(), 0);
        }
    } else if (list_id == PDFCORE_LIST_LINK_DETAILS) {
        auto pages = doc.qpdf.getAllPages();
        int pageIndex = 0;
        for (auto const& p : pages) {
            QPDFObjectHandle annots = p.getKey("/Annots");
            if (annots.isArray()) {
                for (auto const& a : annots.getArrayAsVector()) {
                    if (a.isNull() || !a.isDictionary()) { continue; }
                    QPDFObjectHandle st = a.getKey("/Subtype");
                    if (!(st.isName() && st.getName() == "/Link")) { continue; }

                    std::string destType = "none";
                    std::string namedDest;
                    QPDFObjectHandle target;

                    QPDFObjectHandle dest = a.getKey("/Dest");
                    if (!dest.isNull()) {
                        target = dest;
                    } else if (a.hasKey("/A")) {
                        QPDFObjectHandle action = a.getKey("/A");
                        if (action.isDictionary() && action.getKey("/S").isName()) {
                            std::string kind = action.getKey("/S").getName();
                            if (kind == "/GoTo") {
                                target = action.getKey("/D");
                            } else if (kind == "/URI") {
                                destType = "uri";
                            }
                        }
                    }

                    if (!target.isNull()) {
                        if (target.isString() || target.isName()) {
                            destType = "named";
                            namedDest = target.isName()
                                ? target.getName() : target.getStringValue();
                            if (!namedDest.empty() && namedDest.front() == '/') {
                                namedDest.erase(namedDest.begin());
                            }
                        } else if (target.isArray()) {
                            destType = "explicit";
                        }
                    }

                    int targetPage = (destType == "uri" || destType == "none")
                        ? -2 : destination_page_index(doc.qpdf, target);

                    // Rahmen auf zwei Nachkommastellen: Ein Link, der um einen
                    // Zehntelpunkt wandert, ist derselbe Link. Einer, der auf
                    // einer anderen Stelle der Seite sitzt, nicht.
                    std::string rect = "-";
                    QPDFObjectHandle r = a.getKey("/Rect");
                    if (r.isArray() && r.getArrayNItems() == 4) {
                        char buf[128];
                        double v[4] = {0, 0, 0, 0};
                        bool ok = true;
                        for (int i = 0; i < 4; ++i) {
                            QPDFObjectHandle item = r.getArrayItem(i);
                            if (item.isInteger() || item.isReal()) {
                                v[i] = item.getNumericValue();
                            } else { ok = false; }
                        }
                        if (ok) {
                            std::snprintf(buf, sizeof(buf), "%.2f,%.2f,%.2f,%.2f",
                                          v[0], v[1], v[2], v[3]);
                            rect = buf;
                        }
                    }

                    list.push_back(std::to_string(pageIndex) + "|" + destType + "|"
                        + std::to_string(targetPage) + "|"
                        + sanitize_list_field(namedDest) + "|" + rect);
                }
            }
            ++pageIndex;
        }
    } else if (list_id == PDFCORE_LIST_OUTLINE_LABELS) {
        QPDFOutlineDocumentHelper oh(doc.qpdf);
        if (oh.hasOutlines()) {
            collect_outline_labels(oh.getTopLevelOutlines(), list, 0);
        }
    }
    return doc.stringLists.emplace(list_id, std::move(list)).first->second;
}

int pdfcore_string_list_count(pdfcore_document_t *doc, int list_id, int *count)
{
    if (!doc || !count) { return -1; }
    try {
        *count = static_cast<int>(ensure_list(*doc, list_id).size());
        return 0;
    } catch (...) {
        return -1;
    }
}

int pdfcore_string_list_get(pdfcore_document_t *doc, int list_id, int index,
                            char *buf, size_t size)
{
    if (!doc) { return -1; }
    try {
        auto const& list = ensure_list(*doc, list_id);
        if (index < 0 || index >= static_cast<int>(list.size())) { return -1; }
        std::string const& s = list[static_cast<size_t>(index)];
        if (buf && size > 0) {
            size_t n = s.size() < size - 1 ? s.size() : size - 1;
            std::memcpy(buf, s.c_str(), n);
            buf[n] = '\0';
        }
        return static_cast<int>(s.size());
    } catch (...) {
        return -1;
    }
}

void pdfcore_string_list_release(pdfcore_document_t *doc, int list_id)
{
    if (!doc) { return; }
    doc->stringLists.erase(list_id);
}

int pdfcore_form_field_count(pdfcore_document_t *doc)
{
    if (!doc) { return -1; }
    try {
        // Benannte Felder zählen – auch wenn ein Writer das Dokument-Level-
        // /AcroForm weglässt (PDFKit tut das bei reinen Widget-Fixtures).
        int count = 0;
        for (auto const& ph : doc->qpdf.getAllPages()) {
            QPDFObjectHandle annots = ph.getKey("/Annots");
            if (!annots.isArray()) { continue; }
            for (auto const& a : annots.getArrayAsVector()) {
                if (a.isNull() || !a.isDictionary()) { continue; }
                QPDFObjectHandle st = a.getKey("/Subtype");
                if (st.isName() && st.getName() == "/Widget" && a.hasKey("/T")) {
                    ++count;
                }
            }
        }
        return count;
    } catch (...) {
        return -1;
    }
}

int pdfcore_named_destination_count(pdfcore_document_t *doc)
{
    if (!doc) { return -1; }
    try {
        QPDFObjectHandle catalog = doc->qpdf.getRoot();
        int total = 0;
        QPDFObjectHandle namesDict = catalog.getKey("/Names");
        if (!namesDict.isNull() && namesDict.isDictionary()) {
            total += count_name_tree_entries(namesDict.getKey("/Dests"), 0);
        }
        QPDFObjectHandle oldDests = catalog.getKey("/Dests");
        if (!oldDests.isNull() && oldDests.isDictionary()) {
            total += static_cast<int>(oldDests.getKeys().size());
        }
        return total;
    } catch (...) {
        return -1;
    }
}

int pdfcore_attachment_count(pdfcore_document_t *doc)
{
    if (!doc) { return -1; }
    try {
        QPDFObjectHandle catalog = doc->qpdf.getRoot();
        QPDFObjectHandle namesDict = catalog.getKey("/Names");
        if (namesDict.isNull() || !namesDict.isDictionary()) { return 0; }
        return count_name_tree_entries(namesDict.getKey("/EmbeddedFiles"), 0);
    } catch (...) {
        return -1;
    }
}

int pdfcore_has_page_labels(pdfcore_document_t *doc)
{
    if (!doc) { return -1; }
    try {
        return doc->qpdf.getRoot().hasKey("/PageLabels") ? 1 : 0;
    } catch (...) {
        return -1;
    }
}

// ============================================================================
// Epic Phase 9 – Page Copy Prototype (nicht Produktionsdefault)
// ============================================================================


/// Gemeinsame Implementierung aller drei Einstiegspunkte (Definition unten).
static int write_pages_impl(const char *const *source_paths,
                            const int *page_indices,
                            const int *rotations,
                            int count,
                            const char *output_path,
                            int remove_dangling_links,
                            void (*on_page)(void *, int, int),
                            int (*should_continue)(void *),
                            void *context);

int pdfcore_write_pages(const char *const *source_paths,
                        const int *page_indices,
                        const int *rotations,
                        int count,
                        const char *output_path,
                        int remove_dangling_links)
{
    return write_pages_impl(source_paths, page_indices, rotations, count,
                            output_path, remove_dangling_links,
                            nullptr, nullptr, nullptr);
}

int pdfcore_write_pages_progress(const char *const *source_paths,
                                 const int *page_indices,
                                 const int *rotations,
                                 int count,
                                 const char *output_path,
                                 int remove_dangling_links,
                                 void (*on_page)(void *context, int done, int total),
                                 void *context)
{
    return write_pages_impl(source_paths, page_indices, rotations, count,
                            output_path, remove_dangling_links,
                            on_page, nullptr, context);
}

int pdfcore_write_pages_cancellable(const char *const *source_paths,
                                    const int *page_indices,
                                    const int *rotations,
                                    int count,
                                    const char *output_path,
                                    int remove_dangling_links,
                                    void (*on_page)(void *context, int done, int total),
                                    int (*should_continue)(void *context),
                                    void *context)
{
    return write_pages_impl(source_paths, page_indices, rotations, count,
                            output_path, remove_dangling_links,
                            on_page, should_continue, context);
}

int pdfcore_write_outlines(pdfcore_document_t *doc,
                           const char *const *titles,
                           const int *page_indices,
                           int count)
{
    if (!doc || count < 0) { return PDFCORE_ERR_OPEN; }
    try {
        QPDF& qpdf = doc->qpdf;
        QPDFObjectHandle catalog = qpdf.getRoot();
        auto pages = qpdf.getAllPages();

        if (count == 0 || !titles || !page_indices) {
            catalog.removeKey("/Outlines");
            return PDFCORE_OK;
        }

        // Erst alle Einträge anlegen, dann verketten: /Prev und /Next
        // brauchen die Nachbarn als indirekte Objekte.
        QPDFObjectHandle outlines = QPDFObjectHandle::newDictionary();
        outlines.replaceKey("/Type", QPDFObjectHandle::newName("/Outlines"));
        QPDFObjectHandle outlinesRef = qpdf.makeIndirectObject(outlines);

        std::vector<QPDFObjectHandle> items;
        for (int i = 0; i < count; ++i) {
            int page = page_indices[i];
            if (page < 0 || page >= static_cast<int>(pages.size())) { continue; }
            QPDFObjectHandle item = QPDFObjectHandle::newDictionary();
            item.replaceKey("/Title",
                            QPDFObjectHandle::newUnicodeString(titles[i] ? titles[i] : ""));
            item.replaceKey("/Parent", outlinesRef);
            QPDFObjectHandle dest = QPDFObjectHandle::newArray();
            dest.appendItem(pages[static_cast<size_t>(page)]);
            dest.appendItem(QPDFObjectHandle::newName("/XYZ"));
            dest.appendItem(QPDFObjectHandle::newNull());
            dest.appendItem(QPDFObjectHandle::newNull());
            dest.appendItem(QPDFObjectHandle::newNull());
            item.replaceKey("/Dest", dest);
            items.push_back(qpdf.makeIndirectObject(item));
        }
        if (items.empty()) {
            catalog.removeKey("/Outlines");
            return PDFCORE_OK;
        }

        for (size_t i = 0; i < items.size(); ++i) {
            if (i > 0) { items[i].replaceKey("/Prev", items[i - 1]); }
            if (i + 1 < items.size()) { items[i].replaceKey("/Next", items[i + 1]); }
        }
        outlinesRef.replaceKey("/First", items.front());
        outlinesRef.replaceKey("/Last", items.back());
        outlinesRef.replaceKey("/Count",
                               QPDFObjectHandle::newInteger(
                                   static_cast<long long>(items.size())));
        catalog.replaceKey("/Outlines", outlinesRef);
        return PDFCORE_OK;
    } catch (const QPDFExc&) {
        return PDFCORE_ERR_OPEN;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_prototype_available(void)
{
    try {
        QPDF probe;
        probe.emptyPDF();
        return 0;
    } catch (...) {
        return -1;
    }
}

namespace {

/// Befund B11 – wird aus der Writer-Pipeline geworfen, wenn der Aufrufer
/// während des Schreibens abbricht. Eigener Typ, damit der Abbruch nicht mit
/// einem echten Fehler (QPDFExc, std::exception) verwechselt wird.
struct WritePagesCancelled {};

/// Befund B11 – Pipeline-Glied vor dem Datei-Output des QPDFWriters.
///
/// Der Writer gibt die Datei in Blöcken aus; vor jedem Block wird der
/// Aufrufer gefragt, ob es weitergehen soll. So greift „Abbrechen" auch in
/// der Schreibphase, in der die Streams wirklich kopiert werden – die
/// Seitenschleife davor kopiert nur Handles und ist in Millisekunden durch.
class Pl_CancelCheck final : public Pipeline {
public:
    Pl_CancelCheck(Pipeline *next, int (*should_continue)(void *), void *context)
        : Pipeline("pdfcore cancel check", next),
          should_continue_(should_continue), context_(context) {}

    void write(unsigned char const *data, size_t len) override {
        if (should_continue_ && !should_continue_(context_)) {
            throw WritePagesCancelled{};
        }
        getNext()->write(data, len);
    }
    void finish() override { getNext()->finish(); }

private:
    int (*should_continue_)(void *);
    void *context_;
};

} // namespace

static int write_pages_impl(const char *const *source_paths,
                            const int *page_indices,
                            const int *rotations,
                            int count,
                            const char *output_path,
                            int remove_dangling_links,
                            void (*on_page)(void *, int, int),
                            int (*should_continue)(void *),
                            void *context)
{
    if (!source_paths || !page_indices || !rotations || count <= 0 || !output_path) {
        return PDFCORE_ERR_OPEN;
    }
    // Abbruch-Abfrage; ohne Callback immer „weiter".
    auto wantsToContinue = [&]() -> bool {
        return !should_continue || should_continue(context) != 0;
    };
    try {
        QPDF out;
        out.emptyPDF();
        QPDFPageDocumentHelper outHelper(out);

        std::vector<std::unique_ptr<QPDF>> sources;
        std::map<std::string, size_t> byPath;
        std::map<std::string, int> byPathTotals;
        // Quelle-Seiten-ObjGen → kopiertes Handle im Ausgabedokument (Phase 11).
        std::map<QPDFObjGen, QPDFObjectHandle> copiedBySourceObjGen;

        auto sourceFor = [&](std::string const& path) -> QPDF& {
            auto it = byPath.find(path);
            if (it != byPath.end()) { return *sources[it->second]; }
            auto owned = std::make_unique<QPDF>();
            owned->processFile(path.c_str());
            // Vererbbare Attribute auf die Seiten materialisieren, damit beim
            // Kopieren nichts verloren geht.
            //
            // Geprüft und widerlegt: Der Aufruf ist NICHT die Ursache des
            // Textverlusts (Befund 15). Ohne ihn bleibt das Ergebnis
            // identisch – 242 statt 470 Wörter.
            QPDFPageDocumentHelper(*owned).pushInheritedAttributesToPage();
            byPathTotals[path] =
                static_cast<int>(QPDFPageDocumentHelper(*owned).getAllPages().size());
            sources.push_back(std::move(owned));
            byPath[path] = sources.size() - 1;
            return *sources.back();
        };

        for (int i = 0; i < count; ++i) {
            // Befund B11 – VOR jeder Seite fragen. Bis hierher ist nichts
            // geschrieben: Alle Quellen und das Ausgabedokument sind lokale
            // Objekte und werden beim Verlassen freigegeben.
            if (!wantsToContinue()) { return PDFCORE_ERR_CANCELLED; }

            std::string path(source_paths[i]);
            QPDF& src = sourceFor(path);
            auto const& srcPages = src.getAllPages();
            int idx = page_indices[i];
            if (idx < 0 || idx >= static_cast<int>(srcPages.size())) {
                return PDFCORE_ERR_CHECK_FAILED;
            }

            QPDFObjectHandle original = srcPages[static_cast<size_t>(idx)];

            // Seiten über QPDFPageDocumentHelper kopieren, NICHT über
            // copyForeignObject.
            //
            // `copyForeignObject` kopiert den Objektbaum der Seite. Was dabei
            // verloren geht, sieht man nicht im Rendering, sondern im Text:
            // An einem arXiv-Paper wurde aus „In this paper, we introduce the
            // Inertial Manifold…" nach der Assemblierung
            // „Inthispaper,weintroducetheInertialManifold…", und die
            // ff-Ligatur in „Differential" wurde zu „Di!erential". Die Seite
            // sah unverändert aus, war aber nicht mehr durchsuchbar –
            // gezählt: 31 /ToUnicode-CMaps in der Quelle, 21 danach, während
            // die Zahl der Font-Objekte von 75 auf 93 stieg.
            //
            // `qpdf --pages` auf derselben Datei erhält den Text vollständig;
            // es benutzt intern diesen Weg. QPDFPageDocumentHelper::addPage
            // erkennt eine Seite aus einem fremden Dokument und übernimmt die
            // Kopie samt Ressourcenauflösung selbst.
            // Geprüft und verworfen: `removeUnreferencedResources()` vor dem
            // Kopieren verschlechtert das Ergebnis messbar – die
            // /ToUnicode-CMaps sanken von 21 auf 18, der Textverlust blieb
            // (Befund 15).
            outHelper.addPage(QPDFPageObjectHelper(original), false);
            QPDFObjectHandle copied = out.getAllPages().back();
            copiedBySourceObjGen[original.getObjGen()] = copied;

            // Effektive Basis-Rotation der Quelle + Plan-Rotation.
            int base = 0;
            QPDFObjectHandle rot = resolve_inheritable(original, "/Rotate");
            if (!rot.isNull() && rot.isInteger()) {
                base = static_cast<int>(rot.getNumericValue());
            }
            int combined = ((base + rotations[i]) % 360 + 360) % 360;
            copied.replaceKey("/Rotate", QPDFObjectHandle::newInteger(combined));

            // Fortschritt melden, nachdem die Seite wirklich kopiert ist.
            if (on_page) { on_page(context, i + 1, count); }
        }

        outHelper.pushInheritedAttributesToPage();

        // AcroForm rekonstruieren.
        //
        // `copyForeignObject` bringt die Widget-Annotationen mit, aber nicht
        // den Dokument-Level-/AcroForm-Baum. Ohne ihn verlieren die Widgets
        // ihre über /Parent geerbten /FT- und /T-Werte: Die Felder heißen
        // dann nicht mehr, haben keinen Typ und sind praktisch weg.
        // Aufgebaut wird aus den TATSÄCHLICH kopierten Widgets, damit keine
        // Felder von nicht übernommenen Seiten zurückbleiben.
        {
            std::set<QPDFObjGen> rootFields;
            std::vector<QPDFObjectHandle> fields;
            for (auto const& page : out.getAllPages()) {
                QPDFObjectHandle annots = page.getKey("/Annots");
                if (!annots.isArray()) { continue; }
                for (auto const& a : annots.getArrayAsVector()) {
                    if (a.isNull() || !a.isDictionary()) { continue; }
                    QPDFObjectHandle st = a.getKey("/Subtype");
                    if (!(st.isName() && st.getName() == "/Widget")) { continue; }
                    // Zur Wurzel der Feldkette aufsteigen: Das ist der
                    // Eintrag, der in /AcroForm→/Fields gehört.
                    QPDFObjectHandle node = a;
                    int guard = 0;
                    while (guard++ < 32) {
                        QPDFObjectHandle parent = node.getKey("/Parent");
                        if (parent.isNull() || !parent.isDictionary()) { break; }
                        // Die Seite selbst ist kein Feld-Parent.
                        QPDFObjectHandle parentType = parent.getKey("/Type");
                        if (parentType.isName() && parentType.getName() == "/Page") { break; }
                        node = parent;
                    }
                    if (!node.isIndirect()) { continue; }
                    if (rootFields.insert(node.getObjGen()).second) {
                        fields.push_back(node);
                    }
                }
            }

            // --- Namenskollisionen auflösen -----------------------------
            //
            // Zwei Quelldokumente können ein Feld gleichen Namens tragen.
            // Bleiben beide so, überschreiben sich Eingaben gegenseitig – es
            // sind aus Sicht des Formulars dasselbe Feld.
            //
            // Umbenannt wird auf FELD-Ebene, nicht auf Widget-Ebene: Ein Feld
            // mit mehreren Erscheinungsstellen ist EIN Feld (Plan 4.5). Die
            // Sammlung oben steigt zur Feldwurzel auf und dedupliziert über
            // die Objektidentität – zwei Widgets desselben Feldes ergeben
            // deshalb genau einen Eintrag und werden nie getrennt.
            //
            // Zuvor lief dieser Schritt über `PDFDocument.write(to:)` in
            // Swift. Ein PDFKit-Schreibvorgang zerstört die
            // /ToUnicode-Abbildungen von Type1-Fonts – gemessen beim
            // Zusammenführen zweier Formulare: 2 CMaps vorher, 0 danach
            // (Befund 15).
            {
                std::map<std::string, int> seen;
                for (auto& field : fields) {
                    QPDFObjectHandle t = field.getKey("/T");
                    if (!t.isString()) { continue; }
                    std::string name = t.getUTF8Value();

                    auto it = seen.find(name);
                    if (it == seen.end()) {
                        seen[name] = 1;
                        continue;
                    }
                    // Nächsten freien Namen suchen: name_2, name_3, …
                    int suffix = it->second + 1;
                    std::string candidate;
                    do {
                        candidate = name + "_" + std::to_string(suffix);
                        ++suffix;
                    } while (seen.count(candidate) > 0);
                    it->second = suffix - 1;
                    seen[candidate] = 1;
                    field.replaceKey("/T", QPDFObjectHandle::newUnicodeString(candidate));
                }
            }

            if (!fields.empty()) {
                QPDFObjectHandle acro = QPDFObjectHandle::newDictionary();
                QPDFObjectHandle fieldArray = QPDFObjectHandle::newArray();
                for (auto const& f : fields) { fieldArray.appendItem(f); }
                acro.replaceKey("/Fields", fieldArray);

                // /DR und /DA aus der ersten Quelle übernehmen – ohne
                // Ressourcen und Default-Appearance rendern Felder nicht.
                for (auto const& src : sources) {
                    QPDFObjectHandle srcAcro = src->getRoot().getKey("/AcroForm");
                    if (srcAcro.isNull() || !srcAcro.isDictionary()) { continue; }
                    for (char const* key : {"/DR", "/DA", "/Q", "/NeedAppearances",
                                            "/SigFlags"}) {
                        QPDFObjectHandle v = srcAcro.getKey(key);
                        if (v.isNull() || acro.hasKey(key)) { continue; }
                        // copyForeignObject verlangt ein INDIREKTES Objekt.
                        // /DA und /Q stehen fast immer direkt im Dictionary –
                        // sie werden deshalb über ein indirektes Hilfsobjekt
                        // übertragen statt direkt kopiert.
                        if (v.isIndirect()) {
                            acro.replaceKey(key, out.copyForeignObject(v));
                        } else {
                            QPDFObjectHandle wrapper =
                                src->makeIndirectObject(v);
                            acro.replaceKey(key, out.copyForeignObject(wrapper));
                        }
                    }
                    break;
                }
                out.getRoot().replaceKey("/AcroForm", out.makeIndirectObject(acro));
            }
        }

        // --- Named Destinations übertragen ---------------------------------
        //
        // Ohne das Zielverzeichnis ist JEDER interne Verweis unauflösbar. Die
        // dangling-Politik unten entfernt ihn daraufhin – und ein Dokument
        // verliert sämtliche Querverweise, obwohl beide Seiten übernommen
        // wurden. Gemessen an einem CVPR-Paper: 187 Link-Annotationen in der
        // Quelle, 2 nach `merge`; `qpdf --pages` auf derselben Datei erhält
        // alle 187.
        //
        // Übernommen wird ein Ziel nur, wenn die Seite, auf die es zeigt,
        // auch im Ausgabedokument liegt. Ein Ziel auf eine nicht kopierte
        // Seite wäre selbst dangling und würde den Verweis nur scheinbar
        // retten.
        {
            std::set<QPDFObjGen> outputPageGens;
            for (auto const& op : out.getAllPages()) {
                outputPageGens.insert(op.getObjGen());
            }

            QPDFObjectHandle destNames = QPDFObjectHandle::newArray();
            std::set<std::string> seenNames;

            // Rekursiv durch den Namensbaum der Quelle.
            std::function<void(QPDF&, QPDFObjectHandle, int)> collect =
                [&](QPDF& src, QPDFObjectHandle node, int depth) {
                if (node.isNull() || !node.isDictionary() || depth > 32) { return; }
                QPDFObjectHandle arr = node.getKey("/Names");
                if (arr.isArray()) {
                    auto v = arr.getArrayAsVector();
                    for (size_t i = 0; i + 1 < v.size(); i += 2) {
                        if (!v[i].isString()) { continue; }
                        std::string name = v[i].getStringValue();
                        QPDFObjectHandle dest = v[i + 1];
                        // Ein /D-Wrapper ist zulässig: <</D [page /XYZ …]>>
                        if (dest.isDictionary() && dest.hasKey("/D")) {
                            dest = dest.getKey("/D");
                        }
                        if (!dest.isArray()) { continue; }
                        auto dv = dest.getArrayAsVector();
                        if (dv.empty() || !dv[0].isIndirect()) { continue; }

                        // Zeigt das Ziel auf eine kopierte Seite?
                        auto it = copiedBySourceObjGen.find(dv[0].getObjGen());
                        if (it == copiedBySourceObjGen.end()) { continue; }
                        if (!outputPageGens.count(it->second.getObjGen())) { continue; }
                        if (!seenNames.insert(name).second) { continue; }

                        // Zielarray im AUSGABE-Dokument neu aufbauen: Das
                        // erste Element ist die kopierte Seite, der Rest
                        // (Zoomangabe) wird übernommen.
                        QPDFObjectHandle newDest = QPDFObjectHandle::newArray();
                        newDest.appendItem(it->second);
                        for (size_t k = 1; k < dv.size(); ++k) {
                            newDest.appendItem(dv[k].isIndirect()
                                ? out.copyForeignObject(dv[k])
                                : dv[k].shallowCopy());
                        }
                        destNames.appendItem(QPDFObjectHandle::newString(name));
                        destNames.appendItem(newDest);
                    }
                }
                QPDFObjectHandle kids = node.getKey("/Kids");
                if (kids.isArray()) {
                    for (auto const& kid : kids.getArrayAsVector()) {
                        collect(src, kid, depth + 1);
                    }
                }
            };

            // Ein Ziel aus einem /Dests-Eintrag übernehmen (beide Formate
            // teilen sich diese Logik).
            auto takeDest = [&](std::string const& name, QPDFObjectHandle dest) {
                if (dest.isDictionary() && dest.hasKey("/D")) {
                    dest = dest.getKey("/D");
                }
                if (!dest.isArray()) { return; }
                auto dv = dest.getArrayAsVector();
                if (dv.empty() || !dv[0].isIndirect()) { return; }
                auto it = copiedBySourceObjGen.find(dv[0].getObjGen());
                if (it == copiedBySourceObjGen.end()) { return; }
                if (!outputPageGens.count(it->second.getObjGen())) { return; }
                if (!seenNames.insert(name).second) { return; }

                QPDFObjectHandle newDest = QPDFObjectHandle::newArray();
                newDest.appendItem(it->second);
                for (size_t k = 1; k < dv.size(); ++k) {
                    newDest.appendItem(dv[k].isIndirect()
                        ? out.copyForeignObject(dv[k])
                        : dv[k].shallowCopy());
                }
                destNames.appendItem(QPDFObjectHandle::newString(name));
                destNames.appendItem(newDest);
            };

            for (auto const& src : sources) {
                // Form 1 (PDF 1.2+): /Root /Names /Dests – ein Namensbaum.
                QPDFObjectHandle names = src->getRoot().getKey("/Names");
                if (!names.isNull() && names.isDictionary()) {
                    collect(*src, names.getKey("/Dests"), 0);
                }

                // Form 2 (PDF 1.1): /Root /Dests – ein flaches Wörterbuch.
                //
                // Ohne diesen Zweig blieben die Ziele solcher Dokumente
                // zurück, jeder interne Verweis wurde unauflösbar, und die
                // dangling-Politik entfernte ihn folgerichtig: An
                // `1409.1556.pdf` überlebten von 275 Link-Annotationen ganze
                // 3. `lookup_named_dest` kennt beide Formate seit jeher – die
                // Übertragung tat es nicht.
                QPDFObjectHandle legacy = src->getRoot().getKey("/Dests");
                if (!legacy.isNull() && legacy.isDictionary()) {
                    for (auto const& key : legacy.getKeys()) {
                        std::string name = key;
                        if (!name.empty() && name.front() == '/') {
                            name.erase(name.begin());
                        }
                        takeDest(name, legacy.getKey(key));
                    }
                }
            }

            if (destNames.getArrayNItems() > 0) {
                QPDFObjectHandle destsNode = QPDFObjectHandle::newDictionary();
                destsNode.replaceKey("/Names", destNames);
                QPDFObjectHandle namesDict = out.getRoot().getKey("/Names");
                if (!namesDict.isDictionary()) {
                    namesDict = QPDFObjectHandle::newDictionary();
                }
                namesDict.replaceKey("/Dests", out.makeIndirectObject(destsNode));
                out.getRoot().replaceKey("/Names", out.makeIndirectObject(namesDict));
            }
        }

        if (remove_dangling_links) {
            // Phase-11-Policy direkt im Ausgabedokument.
            auto pages = out.getAllPages();
            int removedTotal = 0;
            for (auto& p : pages) {
                QPDFObjectHandle annots = p.getKey("/Annots");
                if (!annots.isArray()) { continue; }
                auto items = annots.getArrayAsVector();
                std::vector<size_t> toErase;
                for (size_t i = 0; i < items.size(); ++i) {
                    auto const& a = items[i];
                    if (a.isNull() || !a.isDictionary()) { continue; }
                    QPDFObjectHandle st = a.getKey("/Subtype");
                    if (!(st.isName() && st.getName() == "/Link")) { continue; }
                    bool internalLink = false;
                    QPDFObjectHandle target;
                    if (a.hasKey("/Dest")) { internalLink = true; target = a.getKey("/Dest"); }
                    else if (a.hasKey("/A")) {
                        QPDFObjectHandle action = a.getKey("/A");
                        if (action.isDictionary()
                            && action.getKey("/S").isName()
                            && action.getKey("/S").getName() == "/GoTo") {
                            internalLink = true;
                            target = action.getKey("/D");
                        }
                    }
                    if (!internalLink) { continue; }
                    bool dangling = true;
                    if (target.isArray()) {
                        auto v = target.getArrayAsVector();
                        if (!v.empty() && v[0].isIndirect()) {
                            QPDFObjGen og = v[0].getObjGen();
                            for (auto const& op : out.getAllPages()) {
                                if (op.getObjGen() == og) { dangling = false; break; }
                            }
                        }
                    } else if (target.isString() || target.isName()) {
                        // Named Destination: Ziel muss auflösbar UND im Output vorhanden sein.
                        std::string name = target.isName()
                            ? target.getName() : target.getStringValue();
                        if (!name.empty() && name.front() == '/') { name.erase(name.begin()); }
                        QPDFObjectHandle v = lookup_named_dest(out, name);
                        if (v.isArray()) {
                            auto vv = v.getArrayAsVector();
                            if (!vv.empty() && vv[0].isIndirect()) {
                                QPDFObjGen og = vv[0].getObjGen();
                                for (auto const& op : out.getAllPages()) {
                                    if (op.getObjGen() == og) { dangling = false; break; }
                                }
                            }
                        }
                    }
                    if (dangling) { toErase.push_back(i); }
                }
                for (auto it = toErase.rbegin(); it != toErase.rend(); ++it) {
                    annots.eraseItem(static_cast<int>(*it));
                    ++removedTotal;
                }
            }
            (void)removedTotal;
        }

        if (!wantsToContinue()) { return PDFCORE_ERR_CANCELLED; }

        // Schreiben in eine Temp-Datei neben dem Ziel; erst nach Erfolg wird
        // umbenannt. Ein Abbruch oder Fehler mittendrin lässt deshalb nie
        // eine halbe Datei unter dem Zielpfad zurück.
        //
        // Befund B11: Der Output läuft über eine eigene Pipeline
        // (Pl_CancelCheck → Pl_StdioFile), nicht über setOutputFilename –
        // nur so lässt sich der Writer in der Schreibphase unterbrechen.
        // Die Pipeline-Kette ist dieselbe wie bei setOutputFilename
        // (dort steht ebenfalls ein Pl_StdioFile am Ende); die Bytes des
        // Ergebnisses sind identisch, bis auf das zweite /ID-Wort, in das
        // qpdf ohnehin Uhrzeit und Dateinamen mischt.
        std::string tmp = std::string(output_path) + ".pdfcore-tmp";
        FILE *tmpFile = QUtil::safe_fopen(tmp.c_str(), "wb");
        bool cancelled = false;
        try {
            Pl_StdioFile fileOut("pdfcore tmp output", tmpFile);
            Pl_CancelCheck cancelCheck(&fileOut, should_continue, context);
            QPDFWriter writer(out);
            writer.setOutputPipeline(&cancelCheck);
            writer.write();
        } catch (const WritePagesCancelled&) {
            cancelled = true;
        } catch (...) {
            fclose(tmpFile);
            std::remove(tmp.c_str());
            throw;
        }
        fclose(tmpFile);
        if (cancelled) {
            std::remove(tmp.c_str());
            return PDFCORE_ERR_CANCELLED;
        }
        std::remove(output_path);
        if (std::rename(tmp.c_str(), output_path) != 0) {
            std::remove(tmp.c_str());
            return PDFCORE_ERR_INTERNAL;
        }
        return PDFCORE_OK;
    } catch (const QPDFExc&) {
        return PDFCORE_ERR_OPEN;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Epic Phase 11 – Internal Links & Dangling-Policy
// ============================================================================

namespace {


} // namespace

int pdfcore_internal_link_targets(pdfcore_document_t *doc,
                                  int **out_indices, int *count)
{
    if (!doc || !out_indices || !count) { return -1; }
    *count = 0;
    try {
        auto pages = doc->qpdf.getAllPages();
        std::vector<std::pair<int, int>> results; // (pageIndexOfAnnot, target)

        int pageIndex = 0;
        for (auto const& p : pages) {
            QPDFObjectHandle annots = p.getKey("/Annots");
            if (annots.isArray()) {
                for (auto const& a : annots.getArrayAsVector()) {
                    if (a.isNull() || !a.isDictionary()) { continue; }
                    QPDFObjectHandle st = a.getKey("/Subtype");
                    if (!(st.isName() && st.getName() == "/Link")) { continue; }

                    QPDFObjectHandle dest = a.getKey("/Dest");
                    QPDFObjectHandle action;
                    bool isInternal = false;
                    QPDFObjectHandle target;

                    if (!dest.isNull()) { isInternal = true; target = dest; }
                    else if (a.hasKey("/A")) {
                        action = a.getKey("/A");
                        if (action.isDictionary()
                            && action.getKey("/S").isName()
                            && action.getKey("/S").getName() == "/GoTo") {
                            isInternal = true;
                            target = action.getKey("/D");
                        }
                    }

                    if (!isInternal) {
                        results.emplace_back(pageIndex, -2);   // extern
                        continue;
                    }

                    QPDFObjectHandle pageRef;
                    if (target.isArray()) {
                        auto v = target.getArrayAsVector();
                        if (!v.empty()) { pageRef = v[0]; }
                    } else if (target.isString() || target.isName()) {
                        std::string name = target.isName()
                            ? target.getName() : target.getStringValue();
                        if (!name.empty() && name.front() == '/') { name.erase(name.begin()); }
                        pageRef = lookup_named_dest(doc->qpdf, name);
                        if (pageRef.isArray()) {
                            auto v = pageRef.getArrayAsVector();
                            if (!v.empty()) { pageRef = v[0]; }
                        }
                    }

                    int resolved = -1;
                    if (!pageRef.isNull() && pageRef.isIndirect()) {
                        QPDFObjGen og = pageRef.getObjGen();
                        for (size_t pi = 0; pi < pages.size(); ++pi) {
                            if (pages[pi].getObjGen() == og) {
                                resolved = static_cast<int>(pi);
                                break;
                            }
                        }
                    }
                    results.emplace_back(pageIndex, resolved);
                }
            }
            ++pageIndex;
        }

        int n = static_cast<int>(results.size());
        auto arr = static_cast<int *>(malloc(sizeof(int) * (n > 0 ? n : 1)));
        if (!arr) { return -1; }
        for (int i = 0; i < n; ++i) { arr[i] = results[static_cast<size_t>(i)].second; }
        *out_indices = arr;
        *count = n;
        return 0;
    } catch (...) {
        return -1;
    }
}

int pdfcore_remove_dangling_link_annots(pdfcore_document_t *doc, int *removed)
{
    if (!doc) { return -1; }
    if (removed) { *removed = 0; }
    try {
        int removedTotal = 0;
        for (auto& p : doc->qpdf.getAllPages()) {
            QPDFObjectHandle annots = p.getKey("/Annots");
            if (!annots.isArray()) { continue; }
            auto items = annots.getArrayAsVector();
            std::vector<size_t> toErase;
            for (size_t i = 0; i < items.size(); ++i) {
                auto const& a = items[i];
                if (a.isNull() || !a.isDictionary()) { continue; }
                QPDFObjectHandle st = a.getKey("/Subtype");
                if (!(st.isName() && st.getName() == "/Link")) { continue; }

                bool internalLink = false;
                QPDFObjectHandle target;
                if (a.hasKey("/Dest")) { internalLink = true; target = a.getKey("/Dest"); }
                else if (a.hasKey("/A")) {
                    QPDFObjectHandle action = a.getKey("/A");
                    if (action.isDictionary()
                        && action.getKey("/S").isName()
                        && action.getKey("/S").getName() == "/GoTo") {
                        internalLink = true;
                        target = action.getKey("/D");
                    }
                }
                if (!internalLink) { continue; }

                QPDFObjectHandle pageRef;
                if (target.isArray()) {
                    auto v = target.getArrayAsVector();
                    if (!v.empty()) { pageRef = v[0]; }
                } else if (target.isString() || target.isName()) {
                    std::string name = target.isName()
                        ? target.getName() : target.getStringValue();
                    if (!name.empty() && name.front() == '/') { name.erase(name.begin()); }
                    pageRef = lookup_named_dest(doc->qpdf, name);
                    if (pageRef.isArray()) {
                        auto v = pageRef.getArrayAsVector();
                        if (!v.empty()) { pageRef = v[0]; }
                    }
                }

                bool dangling = true;
                if (!pageRef.isNull() && pageRef.isIndirect()) {
                    QPDFObjGen og = pageRef.getObjGen();
                    for (auto const& op : doc->qpdf.getAllPages()) {
                        if (op.getObjGen() == og) { dangling = false; break; }
                    }
                }
                if (dangling) { toErase.push_back(i); }
            }
            // Von hinten löschen, Indizes bleiben stabil.
            for (auto it = toErase.rbegin(); it != toErase.rend(); ++it) {
                annots.eraseItem(static_cast<int>(*it));
                ++removedTotal;
            }
        }
        if (removed) { *removed = removedTotal; }
        return 0;
    } catch (...) {
        return -1;
    }
}

int pdfcore_remove_page_thumbs(pdfcore_document_t *doc, int *removed)
{
    if (!doc) { return -1; }
    if (removed) { *removed = 0; }
    try {
        int removedTotal = 0;
        for (auto const& p : doc->qpdf.getAllPages()) {
            // Nur direkte Page-Dicts anfassen; geerbte /Thumb gibt es nicht
            // (Thumb ist page-level, nicht vererbbar). Die Kopie teilt das
            // Objekt (Handle-Semantik) – removeKey wirkt auf die Seite.
            // removeKey ohne den Schlüssel wäre ein No-op, aber hasKey
            // macht die Zählung exakt.
            QPDFObjectHandle page = p;
            if (page.hasKey("/Thumb")) {
                page.removeKey("/Thumb");
                ++removedTotal;
            }
        }
        if (removed) { *removed = removedTotal; }
        return 0;
    } catch (...) {
        return -1;
    }
}


int pdfcore_save(pdfcore_document_t *doc, const char *path)
{
    if (!doc || !path) { return PDFCORE_ERR_OPEN; }
    try {
        // Nie in die Quelldatei schreiben – qpdf liest lazy daraus.
        std::string tmp = std::string(path) + ".pdfcore-tmp";
        {
            QPDFWriter writer(doc->qpdf);
            writer.setOutputFilename(tmp.c_str());
            writer.write();
        }
        std::remove(path);
        if (std::rename(tmp.c_str(), path) != 0) {
            std::remove(tmp.c_str());
            return PDFCORE_ERR_INTERNAL;
        }
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

/* Phase V2-9 (Masterplan §15.6) – finaler Write mit Writer-Optionen.
 *
 * EIN Write statt images.pdf (Standard-Writer) + qpdf-CLI-Struktur-Pass:
 * Die Optionen bilden die CLI-Flags des Struktur-Passes 1:1 ab:
 *
 *   object_streams_generate  1 = --object-streams=generate
 *                            0 = --object-streams=disable (Kompatibilität)
 *   recompress_flate         1 = --recompress-flate
 *   compression_level        --compression-level=N (Pl_Flate, statisch;
 *                            < 0 = qpdf-Standard belassen)
 *   linearize                1 = --linearize
 *
 * Dekodierstufe und Stream-Verpackung bleiben auf den QPDFWriter-Defaults
 * (qpdf_dl_generalized + compress) – exakt die Werte, die der CLI-Pass
 * ohne --decode-Level/--compress-streams-Argument benutzt. /Producer und
 * Metadatenpolitik sind BRIDGESACHE (pdfcore_set_producer /
 * pdfcore_strip_metadata laufen davor am Dokument); der Writer ändert
 * /Info nicht – Parität zum CLI-Pass.
 *
 * Bewusst NICHT abgebildet: QPDF_ZOPFLI (FlatePolicy .maximum, §15.7) –
 * der Zopfli-Pfad fällt in Swift auf den Zwei-Write-Pfad zurück.
 *
 * Thread-Hinweis: Pl_Flate::setCompressionLevel ist prozessglobal – der
 * Level wird nach dem Write auf Z_DEFAULT_COMPRESSION ZURÜCKGESETZT, damit
 * Folgelaufe im selben Prozess (z. B. Flate-Encodes des Candidate-
 * Schedulers) den Level 9 nicht erben (gemessen: +45 s je Kandidatenlauf). */
int pdfcore_save_with_options(pdfcore_document_t *doc, const char *path,
                              int object_streams_generate,
                              int recompress_flate,
                              int compression_level,
                              int linearize)
{
    if (!doc || !path) { return PDFCORE_ERR_OPEN; }
    try {
        // Nie in die Quelldatei schreiben – qpdf liest lazy daraus.
        std::string tmp = std::string(path) + ".pdfcore-tmp";
        {
            QPDFWriter writer(doc->qpdf);
            writer.setOutputFilename(tmp.c_str());
            if (linearize) { writer.setLinearization(true); }
            writer.setObjectStreamMode(object_streams_generate
                                           ? qpdf_o_generate : qpdf_o_disable);
            if (recompress_flate) { writer.setRecompressFlate(true); }
            if (compression_level >= 0) {
                Pl_Flate::setCompressionLevel(compression_level);
            }
            writer.write();
            // Level zurücksetzen (prozessglobal!): Sonst erben Folgelaufe im
            // selben Prozess den Level 9 – gemessen +45 s Kandidatenzeit je
            // Lauf durch langsamere Flate-Encodes im Scheduler.
            Pl_Flate::setCompressionLevel(Z_DEFAULT_COMPRESSION);
        }
        std::remove(path);
        if (std::rename(tmp.c_str(), path) != 0) {
            std::remove(tmp.c_str());
            return PDFCORE_ERR_INTERNAL;
        }
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_write_page_labels(pdfcore_document_t *doc,
                              const char *const *encodings, int count)
{
    if (!doc || count < 0 || (count > 0 && !encodings)) { return PDFCORE_ERR_OPEN; }
    try {
        QPDFObjectHandle nums = QPDFObjectHandle::newArray();
        for (int i = 0; i < count; ++i) {
            std::string enc(encodings[i]);
            // Format: start|style|prefix|first
            auto split = [&](char sep) -> std::string {
                size_t pos = enc.find(sep);
                std::string token = enc.substr(0, pos);
                enc = (pos == std::string::npos) ? "" : enc.substr(pos + 1);
                return token;
            };
            int start = std::stoi(split('|'));
            std::string style = split('|');
            std::string prefix = split('|');
            std::string first = split('|');

            QPDFObjectHandle dict = QPDFObjectHandle::newDictionary();
            if (!style.empty()) {
                dict.replaceKey("/S", QPDFObjectHandle::newName(style.empty() ? std::string() : std::string("/") + style));
            }
            if (!prefix.empty()) {
                dict.replaceKey("/P", QPDFObjectHandle::newString(prefix));
            }
            if (!first.empty()) {
                dict.replaceKey("/St", QPDFObjectHandle::newInteger(std::stoi(first)));
            }
            nums.appendItem(QPDFObjectHandle::newInteger(start));
            nums.appendItem(dict);
        }
        if (nums.getArrayAsVector().empty()) { return PDFCORE_OK; }

        QPDFObjectHandle plDict = QPDFObjectHandle::newDictionary();
        plDict.replaceKey("/Nums", nums);
        doc->qpdf.getRoot().replaceKey("/PageLabels", plDict);
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_set_producer(pdfcore_document_t *doc, const char *producer)
{
    if (!doc || !producer) { return PDFCORE_ERR_OPEN; }
    try {
        QPDFObjectHandle trailer = doc->qpdf.getTrailer();
        QPDFObjectHandle info = trailer.getKey("/Info");
        bool replacedWholeInfo = false;
        if (info.isNull() || !info.isDictionary()) {
            info = QPDFObjectHandle::newDictionary();
            trailer.replaceKey("/Info", info);
            replacedWholeInfo = true;
        }
        info.replaceKey("/Producer", QPDFObjectHandle::newString(producer));
        (void)replacedWholeInfo;
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}


// ============================================================================
// Epic Phase 22 – Compression Write Prototype
// ============================================================================

int pdfcore_replace_image(pdfcore_document_t *doc,
                          const char *image_name,
                          const unsigned char *jpeg, size_t jpeg_len,
                          int new_width, int new_height)
{
    if (!doc || !image_name || !jpeg || jpeg_len == 0) { return PDFCORE_ERR_OPEN; }
    try {
        std::string want = image_name;
        // Dict-Keys tragen bei qpdf den führenden Slash – beide Formen erlauben.
        if (!want.empty() && want.front() != '/') { want = "/" + want; }
        bool created = false;
        bool replacedAny = false;
        QPDFObjectHandle newStream;

        auto pages = doc->qpdf.getAllPages();
        for (auto const& p : pages) {
            QPDFObjectHandle res = resolve_inheritable(p, "/Resources");
            if (res.isNull() || !res.isDictionary()) { continue; }
            QPDFObjectHandle xobjs = res.getKey("/XObject");
            if (xobjs.isNull() || !xobjs.isDictionary()) { continue; }
            if (!xobjs.hasKey(want)) { continue; }

            QPDFObjectHandle old = xobjs.getKey(want);
            QPDFObjectHandle stOld = dict_of(old).getKey("/Subtype");
            if (!(stOld.isName() && stOld.getName() == "/Image")) { continue; }

            if (!created) {
                std::string data(reinterpret_cast<const char *>(jpeg), jpeg_len);
                newStream = QPDFObjectHandle::newStream(&doc->qpdf, data);
                QPDFObjectHandle d = newStream.getDict();
                for (char const* key : {"/Type", "/Width", "/Height",
                                        "/BitsPerComponent", "/ColorSpace"}) {
                    QPDFObjectHandle v = dict_of(old).getKey(key);
                    if (!v.isNull()) { d.replaceKey(key, v.shallowCopy()); }
                }
                d.replaceKey("/Subtype",
                             QPDFObjectHandle::newName("/Image"));
                d.replaceKey("/Filter",
                             QPDFObjectHandle::newName("/DCTDecode"));
                if (new_width > 0) {
                    d.replaceKey("/Width", QPDFObjectHandle::newInteger(new_width));
                }
                if (new_height > 0) {
                    d.replaceKey("/Height", QPDFObjectHandle::newInteger(new_height));
                }
                created = true;
            }
            xobjs.replaceKey(want, newStream);
            replacedAny = true;
        }
        return replacedAny ? PDFCORE_OK : PDFCORE_ERR_CHECK_FAILED;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Masterplan Schritt 1/2 – Objektbasierter Bildzugriff
// ============================================================================

namespace {

/// Sucht ein Bild-XObject anhand seiner Objektidentität.
/// Gibt ein Null-Handle zurück, wenn es das Objekt nicht gibt oder es kein
/// Bild-XObject ist – niemals ein „ähnliches" Objekt.
QPDFObjectHandle find_image_object(QPDF& qpdf, int objNumber, int generation)
{
    QPDFObjGen want(objNumber, generation);
    for (auto& obj : qpdf.getAllObjects()) {
        if (obj.getObjGen() != want) { continue; }
        QPDFObjectHandle d = dict_of(obj);
        QPDFObjectHandle st = d.getKey("/Subtype");
        if (st.isName() && st.getName() == "/Image") { return obj; }
        return QPDFObjectHandle::newNull();
    }
    return QPDFObjectHandle::newNull();
}

/// Eigenschaften, die eine JPEG-Ersetzung unzulässig machen.
///
/// MASKEN SIND KEINE davon – entgegen der ersten Fassung.
///
/// Die alte Annahme war, Bild und Maske müssten gemeinsam umgerechnet
/// werden, damit sie zusammenpassen. Das verlangt die Norm nicht: Nach
/// PDF 32000-1 §8.9.6.4 muss eine weiche Maske NICHT dieselben Masse haben
/// wie ihr Basisbild – sie wird auf dessen Grösse skaliert. Dasselbe gilt
/// für eine Schablonenmaske über /Mask als Stream.
///
/// Die Annahme war teuer: Über den Korpus gemessen sind Bilder mit Maske
/// 143,5 MB, also 40 % aller Bilddaten – der grösste einzelne Posten, den
/// wir gar nicht angefasst haben. Logos, Diagramme und freigestellte Fotos
/// fallen alle in diese Gruppe.
///
/// Was WIRKLICH blockiert:
bool blocks_jpeg_replacement(QPDFObjectHandle imageDict, bool decodeApplied)
{
    // /Mask als ARRAY ist Farbschlüssel-Maskierung: Die Werte benennen
    // Farbbereiche im Farbraum und in der Bittiefe des Basisbildes. Eine
    // verlustbehaftete Neukodierung verschiebt genau diese Werte – die
    // Maskierung träfe danach andere Bildpunkte. Als Stream (Schablone) ist
    // /Mask dagegen unproblematisch, weil auch sie skaliert wird.
    QPDFObjectHandle mask = imageDict.getKey("/Mask");
    if (mask.isArray()) { return true; }

    // /Decode wird gesondert behandelt: Der Aufrufer erklärt über
    // `decode_applied`, dass er die Abbildung beim Dekodieren angewendet hat.
    // Ohne diese Erklärung bleibt es eine Sperre – ein unangewendetes
    // /Decode kehrt Bilder um oder verschiebt Tonwerte.

    if (imageDict.hasKey("/Decode") && !decodeApplied) { return true; }

    // Das Bild IST eine 1-Bit-Schablone – die kann JPEG nicht darstellen.
    QPDFObjectHandle im = imageDict.getKey("/ImageMask");
    if (im.isBool() && im.getBoolValue()) { return true; }

    return false;
}


/// Gemeinsamer Kern beider Ersetzungsvarianten. `filterName` ist der Filter
/// des NEUEN Streams; die Bytes müssen bereits so kodiert sein.
///
/// `preserveSourceColorSpace` (Phase 6C): übernimmt einen nicht-trivialen
/// /ColorSpace (ICCBased & Co.) auch beim VERLUSTBEHAFTETEN Ersatz, wenn die
/// Komponentenzahl passt. Der Flate-Ersatz tut das immer – dort sind die
/// übergebenen Bytes die Werte des ursprünglichen Farbraums. Beim JPEG-
/// Ersatz ist die Voraussetzung dieselbe, aber nur der CMYK-Pfad erfüllt
/// sie: Der YCCK-Kodierer gibt die CMYK-Werte der Quelle unverändert zurück
/// (abgesehen von der Quantisierung), während der RGB-Kodierer sRGB liefert,
/// weil das Profil beim Dekodieren bereits angewendet wurde.
int replace_image_stream(pdfcore_document_t *doc,
                         int obj_number, int generation,
                         const unsigned char *bytes, size_t len,
                         int new_width, int new_height,
                         int components, char const* filterName,
                         bool decodeApplied, bool pngPredictor = false,
                         bool preserveSourceColorSpace = false)
{
    QPDFObjectHandle target = find_image_object(doc->qpdf, obj_number, generation);
    if (target.isNull()) { return PDFCORE_ERR_CHECK_FAILED; }

    QPDFObjectHandle oldDict = dict_of(target);
    if (blocks_jpeg_replacement(oldDict, decodeApplied)) { return PDFCORE_ERR_CHECK_FAILED; }

    QPDFObjectHandle newDict = QPDFObjectHandle::newDictionary();
    newDict.replaceKey("/Type", QPDFObjectHandle::newName("/XObject"));
    newDict.replaceKey("/Subtype", QPDFObjectHandle::newName("/Image"));
    newDict.replaceKey("/Filter", QPDFObjectHandle::newName(filterName));
    newDict.replaceKey("/BitsPerComponent", QPDFObjectHandle::newInteger(8));
    // Der Farbraum folgt der Komponentenzahl der übergebenen Bytes.
    //
    // Vorher gab es nur „grau oder RGB". Damit liessen sich CMYK-Bilder gar
    // nicht ersetzen – 42,4 MB im Korpus, durchweg Druckmaterial. Sie nach
    // RGB umzurechnen wäre falsch: Bei Druckdaten ändert das die Farben.
    // Verkleinert man sie dagegen verlustfrei im eigenen Farbraum, bleibt
    // jede Farbe, wie sie war, und die Ersparnis aus der Auflösung bleibt.
    // Ist der Farbraum der Quelle KEIN einfacher Name – etwa ICCBased –,
    // wird er unverändert übernommen, sofern die Komponentenzahl passt.
    //
    // Ihn durch /DeviceRGB zu ersetzen wäre eine Farbveränderung: Das Profil
    // beschreibt, wie die Werte zu deuten sind. Ghostscript wirft es weg;
    // wir behalten es. Die Ersparnis kommt aus der Auflösung, nicht aus dem
    // Weglassen des Profils.
    // NUR beim verlustfreien Ersatz: Dort sind die übergebenen Bytes die
    // Werte des ursprünglichen Farbraums, das Profil beschreibt sie weiterhin
    // richtig.
    //
    // Beim JPEG-Ersatz gilt das NICHT: Der Kodierer liefert sRGB, weil das
    // Profil beim Dekodieren bereits angewendet wurde. Ein weiterhin
    // genanntes Profil würde dieselben Werte ein zweites Mal umdeuten.
    QPDFObjectHandle oldSpace = oldDict.getKey("/ColorSpace");
    bool keptOriginalSpace = false;
    bool lossless = std::string(filterName) == "/FlateDecode";
    // Phase 6C: `preserveSourceColorSpace` erlaubt die Übernahme auch für
    // den CMYK-JPEG-Ersatz – der Kommentar oben erklärt den Unterschied
    // zwischen Flate, RGB-JPEG und CMYK-JPEG.
    if ((lossless || preserveSourceColorSpace)
        && !oldSpace.isNull() && !oldSpace.isName()) {
        if (color_space_components(oldSpace) == components) {
            newDict.replaceKey("/ColorSpace", oldSpace);
            keptOriginalSpace = true;
        }
    }
    if (!keptOriginalSpace) {
        char const* space = "/DeviceRGB";
        if (components == 1) { space = "/DeviceGray"; }
        else if (components == 4) { space = "/DeviceCMYK"; }
        newDict.replaceKey("/ColorSpace", QPDFObjectHandle::newName(space));
    }
    newDict.replaceKey("/Width", QPDFObjectHandle::newInteger(
        new_width > 0 ? new_width
                      : static_cast<int>(oldDict.getKey("/Width").getNumericValue())));
    newDict.replaceKey("/Height", QPDFObjectHandle::newInteger(
        new_height > 0 ? new_height
                       : static_cast<int>(oldDict.getKey("/Height").getNumericValue())));

    // PDF-standardisierter adaptiver PNG-Prädiktor. Die Stream-Bytes tragen
    // vor jeder Bildzeile den Filtertyp 0...4; Flate komprimiert dadurch
    // Differenzen statt absoluter Farbwerte. Reader stellen daraus exakt die
    // ursprünglichen Pixel wieder her.
    if (lossless && pngPredictor) {
        QPDFObjectHandle parms = QPDFObjectHandle::newDictionary();
        parms.replaceKey("/Predictor", QPDFObjectHandle::newInteger(15));
        parms.replaceKey("/Colors", QPDFObjectHandle::newInteger(components));
        parms.replaceKey("/BitsPerComponent", QPDFObjectHandle::newInteger(8));
        parms.replaceKey("/Columns", QPDFObjectHandle::newInteger(
            new_width > 0 ? new_width
                          : static_cast<int>(oldDict.getKey("/Width").getNumericValue())));
        newDict.replaceKey("/DecodeParms", parms);
    }

    // Die Maskenbeziehung MUSS mitkommen – sonst verliert das Bild seine
    // Transparenz und ein freigestelltes Logo bekommt einen Kasten.
    for (char const* key : {"/SMask", "/Mask", "/SMaskInData"}) {
        QPDFObjectHandle v = oldDict.getKey(key);
        if (!v.isNull()) { newDict.replaceKey(key, v); }
    }

    // Übernommen wird die REFERENZ, nicht eine Kopie.
    //
    // Hier stand `v.shallowCopy()`. Das wirft bei Streams: „stream objects
    // cannot be cloned". Und `/Metadata` IST ein Stream – XMP-Daten hängen
    // regelmässig an Bildobjekten. Jedes Bild mit Metadaten liess sich damit
    // gar nicht ersetzen; die Kompression brach mit einem Fehler ab, dessen
    // Ursache im Auffang-catch verschwand.
    //
    // Der Fehler lag lange unentdeckt, weil kein Korpusdokument ihn traf.
    // Erst der 12-MB-Bundesregister-Auszug hat ihn sichtbar gemacht – neun
    // Fehlschläge auf zwei Dokumenten im Korpuslauf.
    //
    // Eine Kopie war ohnehin unnötig: Das alte Wörterbuch wird verworfen,
    // die Werte dürfen geteilt werden. Bei indirekten Objekten ist die
    // Referenz sogar das einzig Richtige.
    for (char const* key : {"/Intent", "/Interpolate", "/Metadata",
                            "/StructParent", "/OC"}) {
        QPDFObjectHandle v = oldDict.getKey(key);
        if (!v.isNull()) { newDict.replaceKey(key, v); }
    }

    std::string data(reinterpret_cast<const char *>(bytes), len);
    target.replaceStreamData(
        data, QPDFObjectHandle::newNull(), QPDFObjectHandle::newNull());
    QPDFObjectHandle streamDict = target.getDict();
    for (auto const& key : streamDict.getKeys()) {
        if (!newDict.hasKey(key) && key != "/Length") {
            streamDict.removeKey(key);
        }
    }
    for (auto const& key : newDict.getKeys()) {
        streamDict.replaceKey(key, newDict.getKey(key));
    }
    // Unsere Flate-Streams sind bereits optimiert (zlib + ggf. PNG-
    // Prädiktor). Der finale Writer (`--recompress-flate`) dekodierte sie
    // sonst und komprimierte ohne Prädiktor neu – geplant 38 KB, im Dokument
    // 48 KB (2026-10-01). DCT dekodiert er ohnehin nicht.
    if (std::strcmp(filterName, "/FlateDecode") == 0) {
        target.setFilterOnWrite(false);
    }
    return PDFCORE_OK;
}

} // namespace

int pdfcore_deduplicate_images(pdfcore_document_t *doc, int *merged)
{
    if (!doc) { return PDFCORE_ERR_OPEN; }
    if (merged) { *merged = 0; }
    try {
        // Schlüssel = Wörterbuch + Prüfsumme der ROHEN Stream-Bytes.
        //
        // Roh, nicht dekodiert: Zwei JPEG-Ströme mit identischen Bytes sind
        // dasselbe Bild. Sie erst zu dekodieren wäre langsamer und brächte
        // nichts – und für Filter, die wir nicht auflösen können, ginge es
        // gar nicht.
        std::map<std::string, QPDFObjectHandle> firstSeen;
        int rewritten = 0;

        for (auto& page : QPDFPageDocumentHelper(doc->qpdf).getAllPages()) {
            QPDFObjectHandle res = page.getObjectHandle().getKey("/Resources");
            if (!res.isDictionary()) { continue; }
            QPDFObjectHandle xobjs = res.getKey("/XObject");
            if (!xobjs.isDictionary()) { continue; }

            for (auto const& name : xobjs.getKeys()) {
                QPDFObjectHandle x = xobjs.getKey(name);
                if (!x.isStream() || !x.isIndirect()) { continue; }
                QPDFObjectHandle d = x.getDict();
                QPDFObjectHandle sub = d.getKey("/Subtype");
                if (!(sub.isName() && sub.getName() == "/Image")) { continue; }

                Pl_Buffer raw("raw");
                bool attempted = false;
                if (!x.pipeStreamData(&raw, &attempted, 0, qpdf_dl_none,
                                      true, false)) {
                    continue;   // nicht lesbar – dann lieber nichts tun
                }
                std::unique_ptr<Buffer> b(raw.getBuffer());
                if (!b) { continue; }

                unsigned long long h = 1469598103934665603ULL;
                unsigned char const* p = b->getBuffer();
                for (size_t i = 0; i < b->getSize(); ++i) {
                    h ^= p[i];
                    h *= 1099511628211ULL;
                }

                // Das Wörterbuch gehört in den Schlüssel: Gleiche Pixel mit
                // verschiedenem /Decode oder /SMask sind verschiedene Bilder.
                std::string key = d.unparse() + "|" + std::to_string(h)
                    + "|" + std::to_string(b->getSize());

                auto it = firstSeen.find(key);
                if (it == firstSeen.end()) {
                    firstSeen.emplace(key, x);
                    continue;
                }
                // Schon bekannt – auf das erste Objekt zeigen lassen.
                if (it->second.getObjGen() != x.getObjGen()) {
                    xobjs.replaceKey(name, it->second);
                    ++rewritten;
                }
            }
        }

        if (merged) { *merged = rewritten; }
        return PDFCORE_OK;
    } catch (const QPDFExc&) {
        return PDFCORE_ERR_CHECK_FAILED;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_replace_image_object(pdfcore_document_t *doc,
                                 int obj_number, int generation,
                                 const unsigned char *jpeg, size_t jpeg_len,
                                 int new_width, int new_height,
                                 int grayscale, int decode_applied)
{
    if (!doc || !jpeg || jpeg_len == 0) { return PDFCORE_ERR_OPEN; }
    try {
        return replace_image_stream(doc, obj_number, generation, jpeg, jpeg_len,
                                    new_width, new_height,
                                    grayscale ? 1 : 3, "/DCTDecode",
                                    decode_applied != 0);
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_replace_image_object_flate(pdfcore_document_t *doc,
                                       int obj_number, int generation,
                                       const unsigned char *flate, size_t flate_len,
                                       int new_width, int new_height,
                                       int components, int png_predictor,
                                       int decode_applied)
{
    if (!doc || !flate || flate_len == 0) { return PDFCORE_ERR_OPEN; }
    try {
        return replace_image_stream(doc, obj_number, generation, flate, flate_len,
                                    new_width, new_height, components,
                                    "/FlateDecode", decode_applied != 0,
                                    png_predictor != 0);
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_replace_image_object_cmyk(pdfcore_document_t *doc,
                                      int obj_number, int generation,
                                      const unsigned char *jpeg, size_t jpeg_len,
                                      int new_width, int new_height,
                                      int decode_applied)
{
    if (!doc || !jpeg || jpeg_len == 0) { return PDFCORE_ERR_OPEN; }
    try {
        // Vier Kanäle, DCTDecode – und der nicht-triviale /ColorSpace der
        // Quelle (ICCBased-4) bleibt stehen, siehe replace_image_stream.
        return replace_image_stream(doc, obj_number, generation, jpeg, jpeg_len,
                                    new_width, new_height, 4, "/DCTDecode",
                                    decode_applied != 0, false,
                                    /*preserveSourceColorSpace=*/true);
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_get_image_object_data(pdfcore_document_t *doc,
                                  int obj_number, int generation,
                                  int decoded,
                                  char **out, size_t *len)
{
    if (!doc || !out || !len) { return PDFCORE_ERR_OPEN; }
    *out = nullptr; *len = 0;
    try {
        QPDFObjectHandle target = find_image_object(doc->qpdf, obj_number, generation);
        if (target.isNull()) { return PDFCORE_ERR_CHECK_FAILED; }

        std::shared_ptr<Buffer> buf;
        if (decoded) {
            // pipeStreamData meldet über den Rückgabewert, ob ALLE Filter
            // aufgelöst werden konnten. Nur dann sind die Bytes echte Pixel.
            Pl_Buffer collector("image");
            bool filtered = target.pipeStreamData(
                &collector, nullptr, 0, qpdf_dl_all, false, false);
            if (!filtered) { return PDFCORE_ERR_CHECK_FAILED; }
            buf = std::shared_ptr<Buffer>(collector.getBuffer());
        } else {
            buf = target.getRawStreamData();
        }
        if (!buf) { return PDFCORE_ERR_CHECK_FAILED; }

        size_t n = buf->getSize();
        char *copy = static_cast<char *>(malloc(n > 0 ? n : 1));
        if (!copy) { return PDFCORE_ERR_INTERNAL; }
        if (n > 0) { std::memcpy(copy, buf->getBuffer(), n); }
        *out = copy;
        *len = n;
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_structure_profile(pdfcore_document_t *doc)
{
    if (!doc) { return -1; }
    try {
        int flags = 0;
        // Objekt-Streams über die Xref-Tabelle: Typ-2-Einträge liegen in
        // einem ObjStm. Früher löste getAllObjects() JEDES Objekt der Datei
        // auf (Statistik-Jahrbuch: Sekunden allein für die Schnellschätzung).
        for (auto const& entry : doc->qpdf.getXRefTable()) {
            if (entry.second.getType() == 2) {
                flags |= 1;
                break;
            }
        }
        if (doc->qpdf.isLinearized()) { flags |= 2; }

        // Ein unkomprimierter Content-Stream ist der stärkste Hinweis
        // darauf, dass der Struktur-Pass noch viel holen kann.
        int inspected = 0;
        for (auto const& page : doc->qpdf.getAllPages()) {
            if (inspected++ >= 8) { break; }   // Stichprobe genügt
            QPDFObjectHandle contents = page.getKey("/Contents");
            std::vector<QPDFObjectHandle> streams;
            if (contents.isStream()) { streams.push_back(contents); }
            else if (contents.isArray()) { streams = contents.getArrayAsVector(); }
            for (auto const& stream : streams) {
                if (!stream.isStream()) { continue; }
                if (!stream.getDict().hasKey("/Filter")) {
                    flags |= 4;
                    break;
                }
            }
            if (flags & 4) { break; }
        }
        return flags;
    } catch (...) {
        return -1;
    }
}

int pdfcore_strip_metadata(pdfcore_document_t *doc, int keep_producer)
{
    if (!doc) { return PDFCORE_ERR_OPEN; }
    try {
        QPDFObjectHandle trailer = doc->qpdf.getTrailer();
        QPDFObjectHandle info = trailer.getKey("/Info");
        if (!info.isNull() && info.isDictionary()) {
            std::string producer;
            QPDFObjectHandle p = info.getKey("/Producer");
            if (keep_producer && p.isString()) { producer = p.getStringValue(); }
            for (auto const& key : info.getKeys()) {
                info.removeKey(key);
            }
            if (keep_producer && !producer.empty()) {
                info.replaceKey("/Producer", QPDFObjectHandle::newString(producer));
            }
        }
        QPDFObjectHandle catalog = doc->qpdf.getRoot();
        if (catalog.hasKey("/Metadata")) { catalog.removeKey("/Metadata"); }
        if (catalog.hasKey("/PieceInfo")) { catalog.removeKey("/PieceInfo"); }
        // Seitenbezogene Anwendungsdaten mitentfernen – sie enthalten
        // regelmäßig Erzeuger-/Bearbeitungsspuren.
        for (auto const& page : doc->qpdf.getAllPages()) {
            QPDFObjectHandle p = page;
            if (p.hasKey("/PieceInfo")) { p.removeKey("/PieceInfo"); }
            if (p.hasKey("/Metadata")) { p.removeKey("/Metadata"); }
        }
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Epic Phase 23 – JPEG-Passthrough-Lesezugriff
// ============================================================================

int pdfcore_get_image_jpeg(pdfcore_document_t *doc, int page_index,
                           const char *image_name,
                           char **out, size_t *len)
{
    if (!doc || !image_name || !out || !len) { return PDFCORE_ERR_OPEN; }
    *out = nullptr; *len = 0;
    try {
        std::string want = image_name;
        if (!want.empty() && want.front() != '/') { want = "/" + want; }

        auto pages = doc->qpdf.getAllPages();
        if (page_index < 0 || page_index >= static_cast<int>(pages.size())) {
            return PDFCORE_ERR_CHECK_FAILED;
        }
        QPDFObjectHandle res =
            resolve_inheritable(pages[static_cast<size_t>(page_index)], "/Resources");
        if (res.isNull() || !res.isDictionary()) { return PDFCORE_ERR_CHECK_FAILED; }
        QPDFObjectHandle xobjs = res.getKey("/XObject");
        if (xobjs.isNull() || !xobjs.isDictionary()) { return PDFCORE_ERR_CHECK_FAILED; }
        if (!xobjs.hasKey(want)) { return PDFCORE_ERR_CHECK_FAILED; }

        QPDFObjectHandle img = xobjs.getKey(want);
        QPDFObjectHandle st = dict_of(img).getKey("/Subtype");
        if (!(st.isName() && st.getName() == "/Image")) {
            return PDFCORE_ERR_CHECK_FAILED;
        }

        // Nur exakt DCTDecode als EINZIGER Filter → Bytes sind JPEG.
        QPDFObjectHandle f = dict_of(img).getKey("/Filter");
        bool dctOnly = false;
        if (f.isName()) {
            dctOnly = (f.getName() == "/DCTDecode");
        } else if (f.isArray()) {
            auto fv = f.getArrayAsVector();
            dctOnly = (fv.size() == 1 && fv[0].isName()
                       && fv[0].getName() == "/DCTDecode");
        }
        if (!dctOnly) { return PDFCORE_ERR_CHECK_FAILED; }

        auto buf = img.getRawStreamData();
        if (!buf) { return PDFCORE_ERR_INTERNAL; }
        size_t n = buf->getSize();
        char *copy = static_cast<char *>(malloc(n > 0 ? n : 1));
        if (!copy) { return PDFCORE_ERR_INTERNAL; }
        std::memcpy(copy, buf->getBuffer(), n);
        *out = copy;
        *len = n;
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_get_page_content(pdfcore_document_t *doc, int page_index,
                             char **out, size_t *len)
{
    if (!doc || !out || !len || page_index < 0) { return PDFCORE_ERR_OPEN; }
    *out = nullptr; *len = 0;
    try {
        auto pages = doc->qpdf.getAllPages();
        if (page_index >= static_cast<int>(pages.size())) {
            return PDFCORE_ERR_CHECK_FAILED;
        }
        QPDFObjectHandle page = pages[static_cast<size_t>(page_index)];
        QPDFObjectHandle c = page.getKey("/Contents");
        std::vector<QPDFObjectHandle> streams;
        if (c.isArray()) {
            for (auto const& part : c.getArrayAsVector()) { streams.push_back(part); }
        } else if (c.isStream()) {
            streams.push_back(c);
        }
        std::string combined;
        for (auto& s : streams) {
            if (!s.isStream()) { continue; }
            auto buf = s.getStreamData(qpdf_dl_generalized);
            if (buf) { combined.append(reinterpret_cast<const char*>(buf->getBuffer()),
                                       static_cast<size_t>(buf->getSize())); }
        }
        char *copy = static_cast<char *>(malloc(combined.size() + 1));
        if (!copy) { return PDFCORE_ERR_INTERNAL; }
        std::memcpy(copy, combined.data(), combined.size());
        copy[combined.size()] = '\0';
        *out = copy;
        *len = combined.size();
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Phase 1b – JPEG-Backend (mozjpeg)
// ============================================================================

namespace {

/* libjpeg bricht über error_exit ab, ohne zurückzukehren. Das setjmp hier
 * fängt den Abbruch und macht daraus einen Fehlercode – es verlässt nie eine
 * Exception oder ein longjmp diese Übersetzungseinheit. */
struct jpeg_jmp_context {
    jpeg_error_mgr pub;
    jmp_buf env;
};

void jpeg_jump_on_error(j_common_ptr cinfo)
{
    longjmp(reinterpret_cast<jpeg_jmp_context *>(cinfo->err)->env, 1);
}

char *malloc_copy(const unsigned char *src, size_t n)
{
    char *copy = static_cast<char *>(malloc(n > 0 ? n : 1));
    if (!copy) { return nullptr; }
    if (n > 0) { std::memcpy(copy, src, n); }
    return copy;
}

} // namespace

int pdfcore_jpeg_repack(const unsigned char *jpeg, size_t jpeg_len,
                        int progressive, unsigned char **out, size_t *out_len)
{
    if (!jpeg || jpeg_len == 0 || !out || !out_len) { return PDFCORE_JPEG_REPACK_ERR; }
    *out = nullptr; *out_len = 0;

    jpeg_decompress_struct srcinfo;
    jpeg_compress_struct dstinfo;
    jpeg_jmp_context jerr;
    unsigned char *outbuffer = nullptr;
    unsigned long outsize = 0;
    std::memset(&srcinfo, 0, sizeof(srcinfo));
    std::memset(&dstinfo, 0, sizeof(dstinfo));

    if (setjmp(jerr.env)) {
        jpeg_destroy_decompress(&srcinfo);
        jpeg_destroy_compress(&dstinfo);
        if (outbuffer) { free(outbuffer); }
        return PDFCORE_JPEG_REPACK_ERR;
    }

    srcinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = jpeg_jump_on_error;
    jpeg_create_decompress(&srcinfo);

    dstinfo.err = srcinfo.err;
    jpeg_create_compress(&dstinfo);

    jpeg_mem_src(&srcinfo, jpeg, static_cast<unsigned long>(jpeg_len));
    jpeg_read_header(&srcinfo, TRUE);

    // Skip-Regel: SOF2 IST bereits die Zielverpackung – Koeffizienten und
    // Scans stehen schon so drin wie der Repack sie schreiben würde.
    if (srcinfo.progressive_mode) {
        jpeg_destroy_decompress(&srcinfo);
        jpeg_destroy_compress(&dstinfo);
        return PDFCORE_JPEG_REPACK_SKIP;
    }

    jvirt_barray_ptr *coef_arrays = jpeg_read_coefficients(&srcinfo);

    // Koeffizienten unverändert übernehmen. jpeg_copy_critical_parameters
    // startet mit den mozjpeg-Defaults (optimierte Huffman-Tabellen,
    // progressive Scans mit Scan-Optimierung) und kopiert Quantisierungs-
    // tabellen, Abtastfaktoren und Farbraum aus der Quelle.
    jpeg_copy_critical_parameters(&srcinfo, &dstinfo);
    dstinfo.optimize_coding = TRUE;
    if (!progressive) {
        // „Maximale Kompatibilität": Baseline ohne Progressive-Scans.
        dstinfo.scan_info = nullptr;
        dstinfo.num_scans = 0;
        jpeg_c_set_bool_param(&dstinfo, JBOOLEAN_OPTIMIZE_SCANS, FALSE);
    }

    jpeg_mem_dest(&dstinfo, &outbuffer, &outsize);
    jpeg_write_coefficients(&dstinfo, coef_arrays);
    jpeg_finish_compress(&dstinfo);

    jpeg_destroy_compress(&dstinfo);
    jpeg_destroy_decompress(&srcinfo);

    char *copy = malloc_copy(outbuffer, outsize);
    free(outbuffer);
    if (!copy) { return PDFCORE_JPEG_REPACK_ERR; }
    *out = reinterpret_cast<unsigned char *>(copy);
    *out_len = outsize;
    return PDFCORE_JPEG_REPACK_OK;
}

int pdfcore_jpeg_encode(const unsigned char *pixels, size_t pixels_len,
                        int width, int height, int components,
                        int quality, unsigned char **out, size_t *out_len)
{
    if (!pixels || !out || !out_len) { return PDFCORE_ERR_INTERNAL; }
    if (width <= 0 || height <= 0 || quality < 1) { return PDFCORE_ERR_INTERNAL; }
    // Grau und RGB direkt; CMYK & Co. bewusst ablehnen – dort entscheidet
    // der Aufrufer über das Fallback-Backend (Adobe-APP14-Konvention).
    size_t needed = static_cast<size_t>(width) * static_cast<size_t>(height);
    if (components == 3) { needed *= 3; }
    else if (components != 1) { return PDFCORE_ERR_INTERNAL; }
    if (pixels_len < needed) { return PDFCORE_ERR_INTERNAL; }

    *out = nullptr; *out_len = 0;

    jpeg_compress_struct cinfo;
    jpeg_jmp_context jerr;
    unsigned char *outbuffer = nullptr;
    unsigned long outsize = 0;
    std::memset(&cinfo, 0, sizeof(cinfo));

    if (setjmp(jerr.env)) {
        jpeg_destroy_compress(&cinfo);
        if (outbuffer) { free(outbuffer); }
        return PDFCORE_ERR_INTERNAL;
    }

    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = jpeg_jump_on_error;
    jpeg_create_compress(&cinfo);

    // Profil explizit setzen (ist der Bibliotheksdefault): progressive Scans
    // mit Scan-Optimierung, Trellis-Quantisierung, optimierte Huffman-Tabellen.
    jpeg_c_set_int_param(&cinfo, JINT_COMPRESS_PROFILE, JCP_MAX_COMPRESSION);
    cinfo.image_width = static_cast<JDIMENSION>(width);
    cinfo.image_height = static_cast<JDIMENSION>(height);
    cinfo.input_components = components;
    cinfo.in_color_space = components == 1 ? JCS_GRAYSCALE : JCS_RGB;
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, std::min(quality, 100), TRUE);

    jpeg_mem_dest(&cinfo, &outbuffer, &outsize);
    jpeg_start_compress(&cinfo, TRUE);
    size_t stride = static_cast<size_t>(width) * static_cast<size_t>(components);
    while (cinfo.next_scanline < cinfo.image_height) {
        JSAMPROW row = const_cast<JSAMPROW>(
            pixels + static_cast<size_t>(cinfo.next_scanline) * stride);
        jpeg_write_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);

    char *copy = malloc_copy(outbuffer, outsize);
    free(outbuffer);
    if (!copy) { return PDFCORE_ERR_INTERNAL; }
    *out = reinterpret_cast<unsigned char *>(copy);
    *out_len = outsize;
    return PDFCORE_OK;
}

// MARK: - Phase 6C – verlustbehafteter CMYK-Re-Encode (mozjpeg)

int pdfcore_jpeg_encode_cmyk(const unsigned char *pixels, size_t pixels_len,
                             int width, int height,
                             int quality, unsigned char **out, size_t *out_len)
{
    if (!pixels || !out || !out_len) { return PDFCORE_ERR_INTERNAL; }
    if (width <= 0 || height <= 0 || quality < 1) { return PDFCORE_ERR_INTERNAL; }
    size_t needed = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
    if (pixels_len < needed) { return PDFCORE_ERR_INTERNAL; }

    *out = nullptr; *out_len = 0;

    jpeg_compress_struct cinfo;
    jpeg_jmp_context jerr;
    unsigned char *outbuffer = nullptr;
    unsigned char *swapped = nullptr;
    unsigned long outsize = 0;
    std::memset(&cinfo, 0, sizeof(cinfo));

    if (setjmp(jerr.env)) {
        jpeg_destroy_compress(&cinfo);
        if (outbuffer) { free(outbuffer); }
        if (swapped) { free(swapped); }
        return PDFCORE_ERR_INTERNAL;
    }

    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = jpeg_jump_on_error;
    jpeg_create_compress(&cinfo);

    // Profil explizit setzen (ist der Bibliotheksdefault): progressive Scans
    // mit Scan-Optimierung, Trellis-Quantisierung, optimierte Huffman-Tabellen.
    jpeg_c_set_int_param(&cinfo, JINT_COMPRESS_PROFILE, JCP_MAX_COMPRESSION);
    cinfo.image_width = static_cast<JDIMENSION>(width);
    cinfo.image_height = static_cast<JDIMENSION>(height);
    cinfo.input_components = 4;
    cinfo.in_color_space = JCS_CMYK;
    jpeg_set_defaults(&cinfo);
    // Adobe-Konvention: YCCK, transform 2. jpeg_set_colorspace setzt den
    // Adobe-APP14-Marker samt Transform-Byte selbst (jcmarker.c: 2 für
    // JCS_YCCK, 0 für JCS_CMYK) – genau die Konvention, die auch die Leser
    // im Feld erwarten.
    jpeg_set_colorspace(&cinfo, JCS_YCCK);
    jpeg_set_quality(&cinfo, std::min(quality, 100), TRUE);
    // 4:4:4 – keine Subsampling-Faktoren auf irgendeiner der vier Platten.
    // Die Entscheidung steht im Header: Druckfarbenplatten sind gleichwertig,
    // und CMYK-JPEGs im Feld sind üblicherweise ebenfalls ungesampelt.
    for (int ci = 0; ci < cinfo.num_components; ++ci) {
        cinfo.comp_info[ci].h_samp_factor = 1;
        cinfo.comp_info[ci].v_samp_factor = 1;
    }

    jpeg_mem_dest(&cinfo, &outbuffer, &outsize);

    // Adobe-Konvention, YCCK (transform 2): Die Datei trägt YCC über den
    // UNINVERTIERTEN CMY-Werten und den K-Kanal INVERTIERT (255 - K).
    // Adobe-konforme Leser (ImageIO/CoreGraphics, PDFKit, Acrobat, pdf.js)
    // nehmen CMY unverändert aus dem YCC-Umlauf und invertieren K zurück.
    // libjpegs cmyk_ycck_convert invertiert C/M/Y dagegen SELBST vor dem
    // YCC-Umlauf und lässt K unangetastet – der Shim gleicht beides aus,
    // indem er ALLE VIER Komponenten vor der Übergabe invertiert: Die
    // Doppelinversion von C/M/Y hebt sich auf, K landet invertiert in der
    // Datei. Bodenwahrheit: Re-Encode eines echten Adobe-CMYK-JPEG
    // (IPCC/CVF-Korpus, transform 0) durch diesen Weg dekodiert ImageIO
    // wieder farbgleich zum Original.
    swapped = static_cast<unsigned char *>(malloc(needed));
    if (!swapped) {
        jpeg_destroy_compress(&cinfo);
        return PDFCORE_ERR_INTERNAL;
    }
    for (size_t i = 0; i < needed; ++i) {
        swapped[i] = static_cast<unsigned char>(0xFF - pixels[i]);
    }

    jpeg_start_compress(&cinfo, TRUE);
    size_t stride = static_cast<size_t>(width) * 4;
    while (cinfo.next_scanline < cinfo.image_height) {
        JSAMPROW row = const_cast<JSAMPROW>(
            swapped + static_cast<size_t>(cinfo.next_scanline) * stride);
        jpeg_write_scanlines(&cinfo, &row, 1);
    }
    free(swapped);
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);

    char *copy = malloc_copy(outbuffer, outsize);
    free(outbuffer);
    if (!copy) { return PDFCORE_ERR_INTERNAL; }
    *out = reinterpret_cast<unsigned char *>(copy);
    *out_len = outsize;
    return PDFCORE_OK;
}

// MARK: - Phase 4b – JPX/JPEG2000-Eingabedekodierung (OpenJPEG)

namespace {

void jpx_quiet_message(const char *, void *)
{
    // Openjpeg schreibt Fehler auf stderr – im App-/Testlauf Lärm ohne Wert,
    // der Fehlerfall wird über den Rückgabecode gemeldet.
}

/// In-Memory-Stream über die ÖFFENTLICHE opj_stream_create-API.
/// (opj_stream_create_memory_stream ist in OpenJPEG 2.5 nicht exportiert.)
struct jpx_mem_source {
    const unsigned char *data;
    OPJ_SIZE_T size;
    OPJ_SIZE_T pos;
};

OPJ_SIZE_T jpx_mem_read(void *dst, OPJ_SIZE_T n, void *user)
{
    jpx_mem_source *src = static_cast<jpx_mem_source *>(user);
    if (!src || src->pos >= src->size || n == 0) {
        return static_cast<OPJ_SIZE_T>(-1);   // EOF-Signal
    }
    OPJ_SIZE_T avail = src->size - src->pos;
    if (n > avail) { n = avail; }
    std::memcpy(dst, src->data + src->pos, n);
    src->pos += n;
    return n;
}

OPJ_OFF_T jpx_mem_skip(OPJ_OFF_T n, void *user)
{
    jpx_mem_source *src = static_cast<jpx_mem_source *>(user);
    if (!src || n < 0) { return -1; }
    OPJ_SIZE_T remaining = src->size - src->pos;
    OPJ_SIZE_T ask = static_cast<OPJ_SIZE_T>(n);
    if (ask > remaining) {
        // Über das Ende hinaus skippen ist bei unseekable Strömen ein
        // Fehler; wir melden ihn, statt still am EOF vorbeizurutschen.
        return -1;
    }
    src->pos += ask;
    return n;
}

OPJ_BOOL jpx_mem_seek(OPJ_OFF_T n, void *user)
{
    jpx_mem_source *src = static_cast<jpx_mem_source *>(user);
    if (!src || n < 0 || static_cast<OPJ_SIZE_T>(n) > src->size) { return OPJ_FALSE; }
    src->pos = static_cast<OPJ_SIZE_T>(n);
    return OPJ_TRUE;
}

void jpx_put_u32(std::vector<unsigned char> &out, OPJ_UINT32 v)
{
    out.push_back(static_cast<unsigned char>(v & 0xFF));
    out.push_back(static_cast<unsigned char>((v >> 8) & 0xFF));
    out.push_back(static_cast<unsigned char>((v >> 16) & 0xFF));
    out.push_back(static_cast<unsigned char>((v >> 24) & 0xFF));
}

/// Quelle als JP2-Datei (mit Boxen) oder nackter Codestream? Die jP-
/// Signaturbox steht in JP2-/JPX-Dateien immer zuerst.
bool jpx_has_jp2_signature(const unsigned char *data, size_t len)
{
    static const unsigned char sig[12] = {
        0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20,   /* "jP  " */
        0x0D, 0x0A, 0x87, 0x0A
    };
    return len >= 12 && std::memcmp(data, sig, 12) == 0;
}

} // namespace

int pdfcore_jpx_decode(const unsigned char *data, size_t data_len,
                       int reduce, unsigned char **out, size_t *out_len)
{
    if (!data || data_len == 0 || !out || !out_len) { return PDFCORE_ERR_INTERNAL; }
    *out = nullptr; *out_len = 0;

    opj_codec_t *codec = nullptr;
    opj_stream_t *stream = nullptr;
    opj_image_t *image = nullptr;
    jpx_mem_source source{ data, static_cast<OPJ_SIZE_T>(data_len), 0 };

    auto fail = [&](int code) {
        if (image) { opj_image_destroy(image); }
        if (stream) { opj_stream_destroy(stream); }
        if (codec) { opj_destroy_codec(codec); }
        return code;
    };

    /* Codec-Instanz je Aufruf – openjpeg ist instanzweise nicht threadsafe,
     * ein frischer Codec je Aufruf macht die Funktion frei benutzbar. */
    int format = jpx_has_jp2_signature(data, data_len) ? OPJ_CODEC_JP2
                                                       : OPJ_CODEC_J2K;
    codec = opj_create_decompress(static_cast<OPJ_CODEC_FORMAT>(format));
    if (!codec) { return fail(PDFCORE_ERR_INTERNAL); }
    opj_set_error_handler(codec, jpx_quiet_message, nullptr);

    opj_dparameters_t params;
    opj_set_default_decoder_parameters(&params);
    params.cp_reduce = reduce < 0 ? 0 : (reduce > 30 ? 30u
                                    : static_cast<OPJ_UINT32>(reduce));
    if (!opj_setup_decoder(codec, &params)) { return fail(PDFCORE_ERR_INTERNAL); }

    stream = opj_stream_create(1 << 16, OPJ_TRUE);
    if (!stream) { return fail(PDFCORE_ERR_INTERNAL); }
    opj_stream_set_read_function(stream, jpx_mem_read);
    opj_stream_set_skip_function(stream, jpx_mem_skip);
    opj_stream_set_seek_function(stream, jpx_mem_seek);
    opj_stream_set_user_data(stream, &source, nullptr);
    opj_stream_set_user_data_length(stream, source.size);

    if (!opj_read_header(stream, codec, &image) || !image) {
        return fail(PDFCORE_ERR_CHECK_FAILED);
    }
    /* Ganze Adresse (0,0,0,0) = gesamtes Bild dekodieren. */
    if (!opj_set_decode_area(codec, image, 0, 0, 0, 0) ||
        !opj_decode(codec, stream, image) ||
        !opj_end_decompress(codec, stream)) {
        return fail(PDFCORE_ERR_CHECK_FAILED);
    }

    int comps = image->numcomps;
    if (comps < 1 || comps > 4) { return fail(PDFCORE_ERR_CHECK_FAILED); }
    for (int c = 0; c < comps; ++c) {
        /* prec > 16 ist in PDF unrealistisch; ohne Daten keine Ausgabe. */
        if (image->comps[c].prec < 1 || image->comps[c].prec > 16 ||
            image->comps[c].w < 1 || image->comps[c].h < 1 ||
            !image->comps[c].data) {
            return fail(PDFCORE_ERR_CHECK_FAILED);
        }
    }

    /* Referenzraster = Masse der Komponente 0 (nach cp_reduce). Alle
     * anderen Komponenten werden notfalls darauf hochgerechnet. */
    OPJ_UINT32 refW = image->comps[0].w;
    OPJ_UINT32 refH = image->comps[0].h;
    bool uniform = true;
    for (int c = 1; c < comps; ++c) {
        if (image->comps[c].w != refW || image->comps[c].h != refH) { uniform = false; }
    }

    size_t payloadLen = static_cast<size_t>(refW) * static_cast<size_t>(refH)
                        * static_cast<size_t>(comps);

    std::vector<unsigned char> buffer;
    buffer.reserve(32 + static_cast<size_t>(comps) * 24 + payloadLen);
    buffer.push_back('J'); buffer.push_back('P');
    buffer.push_back('X'); buffer.push_back('D');
    buffer.push_back(1);                      /* Version */
    buffer.push_back(static_cast<unsigned char>(comps));
    buffer.push_back(static_cast<unsigned char>(image->comps[0].prec));
    buffer.push_back(image->comps[0].sgnd ? 1 : 0);
    jpx_put_u32(buffer, uniform ? 1u : 0u);
    jpx_put_u32(buffer, refW);
    jpx_put_u32(buffer, refH);
    jpx_put_u32(buffer, 32);
    jpx_put_u32(buffer, static_cast<OPJ_UINT32>(32 + comps * 24));
    jpx_put_u32(buffer, static_cast<OPJ_UINT32>(payloadLen));
    for (int c = 0; c < comps; ++c) {
        jpx_put_u32(buffer, image->comps[c].w);
        jpx_put_u32(buffer, image->comps[c].h);
        jpx_put_u32(buffer, image->comps[c].dx);
        jpx_put_u32(buffer, image->comps[c].dy);
        jpx_put_u32(buffer, image->comps[c].prec);
        jpx_put_u32(buffer, image->comps[c].sgnd ? 1u : 0u);
    }
    const size_t payloadOffset = buffer.size();

    /* Planar (je Komponente eigenes w/h) → interleaved 8-bit Zielpuffer.
     * prec ≤ 8 roh, 9..16 um (prec-8) geschoben, vorzeichenbehaftete Werte
     * bekommen vorher den Offset 2^(prec-1). */
    buffer.resize(payloadOffset + payloadLen);
    for (int c = 0; c < comps; ++c) {
        const opj_image_comp &comp = image->comps[c];
        OPJ_UINT32 shift = comp.prec > 8 ? comp.prec - 8 : 0;
        OPJ_INT32 offset = comp.sgnd ? static_cast<OPJ_INT32>(1u << (comp.prec - 1)) : 0;
        const OPJ_INT32 *srcData = comp.data;
        OPJ_UINT32 compW = comp.w, compH = comp.h;
        for (OPJ_UINT32 y = 0; y < refH; ++y) {
            OPJ_UINT32 srcY = compH == refH ? y : y * compH / refH;
            for (OPJ_UINT32 x = 0; x < refW; ++x) {
                OPJ_UINT32 srcX = compW == refW ? x : x * compW / refW;
                OPJ_INT32 v = srcData[static_cast<size_t>(srcY) * compW + srcX];
                v += offset;
                v >>= static_cast<int>(shift);
                if (v < 0) { v = 0; }
                if (v > 255) { v = 255; }
                buffer[payloadOffset
                       + (static_cast<size_t>(y) * refW + x) * comps + c]
                    = static_cast<unsigned char>(v);
            }
        }
    }

    opj_image_destroy(image);
    opj_stream_destroy(stream);
    opj_destroy_codec(codec);

    char *copy = malloc_copy(buffer.data(), buffer.size());
    if (!copy) { return PDFCORE_ERR_INTERNAL; }
    *out = reinterpret_cast<unsigned char *>(copy);
    *out_len = buffer.size();
    return PDFCORE_OK;
}

int pdfcore_replace_image_stream_bytes(pdfcore_document_t *doc,
                                       int obj_number, int generation,
                                       const unsigned char *bytes, size_t len)
{
    if (!doc || !bytes || len == 0) { return PDFCORE_ERR_OPEN; }
    try {
        QPDFObjectHandle target = find_image_object(doc->qpdf, obj_number, generation);
        if (target.isNull()) { return PDFCORE_ERR_CHECK_FAILED; }

        // Nur ein rein DCTDecode-kodierter Stream trägt rohe JPEG-Bytes;
        // alles andere wird nicht angefasst (gleiche Politik wie der
        // JPEG-Passthrough beim Lesen).
        QPDFObjectHandle f = dict_of(target).getKey("/Filter");
        bool dctOnly = false;
        if (f.isName()) {
            dctOnly = (f.getName() == "/DCTDecode");
        } else if (f.isArray()) {
            auto fv = f.getArrayAsVector();
            dctOnly = (fv.size() == 1 && fv[0].isName()
                       && fv[0].getName() == "/DCTDecode");
        }
        if (!dctOnly) { return PDFCORE_ERR_CHECK_FAILED; }

        // replaceStreamData erhält den BISHERIGEN Filter und DecodeParms
        // zurück: Ein leeres Handle würde /Filter durch null ERSETZEN – der
        // Key fiele beim Schreiben weg und der JPEG-Strom verlöre seinen
        // Filter. So bleibt das Wörterbuch exakt, wie es war, bis auf /Length.
        std::string data(reinterpret_cast<const char *>(bytes), len);
        target.replaceStreamData(data, dict_of(target).getKey("/Filter"),
                                 dict_of(target).getKey("/DecodeParms"));
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Phase 3-Followup – Zopfli-Repack einzelner Flate-Streams (nur Max-Preset).
// Konventionen siehe pdfcore.h. Der Repack operiert auf der ROHEN
// zlib-Stufe: inflate (ohne Predictor – der ist reine Dekodier-Semantik
// und bleibt im Wörterbuch gültig), dann Zopfli-DEFLATE. Dekodierte Bytes
// sind dadurch bitidentisch; nur die Verpackung schrumpft.
// ============================================================================

namespace {

/* Findet ein beliebiges Stream-Objekt anhand seiner Objektidentität. */
QPDFObjectHandle find_stream_object(QPDF& qpdf, int objNumber, int generation)
{
    QPDFObjGen want(objNumber, generation);
    for (auto& obj : qpdf.getAllObjects()) {
        if (obj.getObjGen() != want) { continue; }
        return obj.isStream() ? obj : QPDFObjectHandle::newNull();
    }
    return QPDFObjectHandle::newNull();
}

/* true, wenn /Filter EXAKT /FlateDecode ist (Name oder Ein-Element-Array). */
bool filter_is_flate_only(QPDFObjectHandle streamDict)
{
    QPDFObjectHandle f = streamDict.getKey("/Filter");
    if (f.isName()) { return f.getName() == "/FlateDecode"; }
    if (f.isArray()) {
        auto fv = f.getArrayAsVector();
        return fv.size() == 1 && fv[0].isName()
            && fv[0].getName() == "/FlateDecode";
    }
    return false;
}

} // namespace

int pdfcore_zlib_inflate(const unsigned char *data, size_t data_len,
                         size_t max_content_bytes,
                         unsigned char **out, size_t *out_len)
{
    if (!data || data_len == 0 || !out || !out_len) { return PDFCORE_ERR_OPEN; }
    *out = nullptr; *out_len = 0;

    z_stream stream;
    std::memset(&stream, 0, sizeof(stream));
    if (inflateInit(&stream) != Z_OK) { return PDFCORE_ERR_INTERNAL; }

    std::vector<unsigned char> content;
    unsigned char chunk[65536];
    stream.next_in = const_cast<Bytef *>(data);
    stream.avail_in = static_cast<uInt>(data_len);
    int status = Z_OK;
    while (true) {
        stream.next_out = chunk;
        stream.avail_out = sizeof(chunk);
        status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR) {
            break;
        }
        size_t produced = sizeof(chunk) - stream.avail_out;
        content.insert(content.end(), chunk, chunk + produced);
        if (content.size() > max_content_bytes) {
            // Speicherschutz: Ein kleiner zlib-Strom kann gigantisch
            // aufblähen. Solche Streams überspringt der Aufrufer.
            inflateEnd(&stream);
            return PDFCORE_ERR_CHECK_FAILED;
        }
        if (status == Z_STREAM_END) {
            char *copy = malloc_copy(content.data(), content.size());
            inflateEnd(&stream);
            if (!copy) { return PDFCORE_ERR_INTERNAL; }
            *out = reinterpret_cast<unsigned char *>(copy);
            *out_len = content.size();
            return PDFCORE_OK;
        }
        if (status == Z_BUF_ERROR && produced == 0) { break; }
    }
    inflateEnd(&stream);
    return PDFCORE_ERR_CHECK_FAILED;
}

int pdfcore_zopfli_compress(const unsigned char *data, size_t data_len,
                            unsigned char **out, size_t *out_len)
{
    if (!data || data_len == 0 || !out || !out_len) { return PDFCORE_ERR_OPEN; }
    *out = nullptr; *out_len = 0;

    ZopfliOptions options;
    ZopfliInitOptions(&options);
    // Voreinstellungen des zopfli-CLI (numiterations 15) – der Kompromiss
    // aus Größe und Laufzeit, den die Phase-3a-Messung zugrunde legt.
    unsigned char *buffer = nullptr;
    size_t size = 0;
    ZopfliCompress(&options, ZOPFLI_FORMAT_ZLIB,
                   data, data_len, &buffer, &size);
    if (!buffer || size == 0) { return PDFCORE_ERR_INTERNAL; }
    char *copy = malloc_copy(buffer, size);
    free(buffer);
    if (!copy) { return PDFCORE_ERR_INTERNAL; }
    *out = reinterpret_cast<unsigned char *>(copy);
    *out_len = size;
    return PDFCORE_OK;
}

int pdfcore_flate_stream_list(pdfcore_document_t *doc, size_t min_raw_bytes,
                              char ***out, int *count)
{
    if (!doc || !out || !count) { return PDFCORE_ERR_OPEN; }
    *out = nullptr; *count = 0;
    try {
        std::vector<std::string> entries;
        for (auto& obj : doc->qpdf.getAllObjects()) {
            if (!obj.isStream()) { continue; }
            QPDFObjectHandle dict = obj.getDict();
            if (!filter_is_flate_only(dict)) { continue; }
            // ObjStm und XRef schreibt der qpdf-Writer ohnehin selbst neu –
            // dort wäre jede Mühe verloren.
            QPDFObjectHandle type = dict.getKey("/Type");
            if (type.isName()
                && (type.getName() == "/ObjStm" || type.getName() == "/XRef")) {
                continue;
            }
            size_t rawLen = 0;
            if (auto raw = obj.getRawStreamData()) { rawLen = raw->getSize(); }
            if (rawLen < min_raw_bytes) { continue; }
            QPDFObjGen og = obj.getObjGen();
            entries.push_back(std::to_string(og.getObj())
                              + "|" + std::to_string(og.getGen())
                              + "|" + std::to_string(rawLen));
        }
        if (entries.empty()) { return PDFCORE_OK; }
        char **array = static_cast<char **>(calloc(entries.size(), sizeof(char *)));
        if (!array) { return PDFCORE_ERR_INTERNAL; }
        for (size_t i = 0; i < entries.size(); ++i) {
            array[i] = strdup(entries[i].c_str());
            if (!array[i]) {
                pdfcore_free_strings(array, static_cast<int>(i));
                return PDFCORE_ERR_INTERNAL;
            }
        }
        *out = array;
        *count = static_cast<int>(entries.size());
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_get_stream_bytes(pdfcore_document_t *doc,
                             int obj_number, int generation,
                             unsigned char **out, size_t *len)
{
    if (!doc || !out || !len) { return PDFCORE_ERR_OPEN; }
    *out = nullptr; *len = 0;
    try {
        QPDFObjectHandle target = find_stream_object(doc->qpdf, obj_number, generation);
        if (target.isNull()) { return PDFCORE_ERR_CHECK_FAILED; }
        auto buf = target.getRawStreamData();
        if (!buf) { return PDFCORE_ERR_INTERNAL; }
        size_t n = buf->getSize();
        char *copy = static_cast<char *>(malloc(n > 0 ? n : 1));
        if (!copy) { return PDFCORE_ERR_INTERNAL; }
        if (n > 0) { std::memcpy(copy, buf->getBuffer(), n); }
        *out = reinterpret_cast<unsigned char *>(copy);
        *len = n;
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_get_object_stream_bytes(pdfcore_document_t *doc,
                                    int obj_number, int generation,
                                    int decoded,
                                    char **out, size_t *len)
{
    if (!doc || !out || !len) { return PDFCORE_ERR_OPEN; }
    *out = nullptr; *len = 0;
    try {
        QPDFObjectHandle target = find_stream_object(doc->qpdf, obj_number, generation);
        if (target.isNull()) { return PDFCORE_ERR_CHECK_FAILED; }

        std::shared_ptr<Buffer> buf;
        if (decoded) {
            // pipeStreamData meldet über den Rückgabewert, ob ALLE Filter
            // aufgelöst werden konnten. Nur dann sind die Bytes der Inhalt –
            // niemals Ersatzdaten liefern.
            Pl_Buffer collector("object-stream");
            bool filtered = target.pipeStreamData(
                &collector, nullptr, 0, qpdf_dl_all, false, false);
            if (!filtered) { return PDFCORE_ERR_CHECK_FAILED; }
            buf = std::shared_ptr<Buffer>(collector.getBuffer());
        } else {
            buf = target.getRawStreamData();
        }
        if (!buf) { return PDFCORE_ERR_CHECK_FAILED; }

        size_t n = buf->getSize();
        char *copy = static_cast<char *>(malloc(n > 0 ? n : 1));
        if (!copy) { return PDFCORE_ERR_INTERNAL; }
        if (n > 0) { std::memcpy(copy, buf->getBuffer(), n); }
        *out = copy;
        *len = n;
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_replace_stream_bytes(pdfcore_document_t *doc,
                                 int obj_number, int generation,
                                 const unsigned char *bytes, size_t len)
{
    if (!doc || !bytes || len == 0) { return PDFCORE_ERR_OPEN; }
    try {
        QPDFObjectHandle target = find_stream_object(doc->qpdf, obj_number, generation);
        if (target.isNull()) { return PDFCORE_ERR_CHECK_FAILED; }
        if (!filter_is_flate_only(target.getDict())) {
            return PDFCORE_ERR_CHECK_FAILED;
        }
        // Wörterbuch UNVERÄNDERT – inklusive /DecodeParms: Der Predictor
        // wirkt auf den Inhalt, nicht auf die Verpackung, und bleibt damit
        // gültig. replaceStreamData mit den bisherigen Keys (gleiche
        // Begründung wie pdfcore_replace_image_stream_bytes).
        std::string data(reinterpret_cast<const char *>(bytes), len);
        target.replaceStreamData(data, target.getDict().getKey("/Filter"),
                                 target.getDict().getKey("/DecodeParms"));
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

void pdfcore_free_strings(char **arr, int count)
{
    if (!arr) { return; }
    for (int i = 0; i < count; ++i) { free(arr[i]); }
    free(arr);
}

// ============================================================================
// Phase 2b – Bilevel: CCITT G4 (libtiff, in-memory) + lossless JBIG2
// (jbig2enc + Leptonica). Konventionen siehe pdfcore.h.
// ============================================================================

namespace {

/* In-Memory-Datei für TIFFClientOpen – der Puffer wächst per realloc. */
struct tiff_memfile {
    unsigned char *buffer;
    size_t len;
    size_t cap;
    toff_t offset;
};

tsize_t tiff_mem_read(thandle_t handle, tdata_t dst, tsize_t n)
{
    tiff_memfile *mem = static_cast<tiff_memfile *>(handle);
    if (mem->offset >= static_cast<toff_t>(mem->len)) { return 0; }
    size_t available = mem->len - static_cast<size_t>(mem->offset);
    size_t take = static_cast<size_t>(n) < available ? static_cast<size_t>(n) : available;
    std::memcpy(dst, mem->buffer + mem->offset, take);
    mem->offset += take;
    return static_cast<tsize_t>(take);
}

tsize_t tiff_mem_write(thandle_t handle, tdata_t src, tsize_t n)
{
    tiff_memfile *mem = static_cast<tiff_memfile *>(handle);
    size_t end = static_cast<size_t>(mem->offset) + static_cast<size_t>(n);
    if (end > mem->cap) {
        size_t grown = end * 2 + 1024;
        unsigned char *next = static_cast<unsigned char *>(std::realloc(mem->buffer, grown));
        if (!next) { return 0; }
        mem->buffer = next;
        mem->cap = grown;
    }
    std::memcpy(mem->buffer + mem->offset, src, static_cast<size_t>(n));
    mem->offset += static_cast<toff_t>(n);
    if (end > mem->len) { mem->len = end; }
    return n;
}

toff_t tiff_mem_seek(thandle_t handle, toff_t offset, int whence)
{
    tiff_memfile *mem = static_cast<tiff_memfile *>(handle);
    switch (whence) {
        case SEEK_SET: mem->offset = offset; break;
        case SEEK_CUR: mem->offset += offset; break;
        case SEEK_END: mem->offset = static_cast<toff_t>(mem->len) + offset; break;
        default: return static_cast<toff_t>(-1);
    }
    return mem->offset;
}

int tiff_mem_close(thandle_t) { return 0; }

toff_t tiff_mem_size(thandle_t handle)
{
    return static_cast<toff_t>(static_cast<tiff_memfile *>(handle)->len);
}

int tiff_mem_map(thandle_t, tdata_t *, toff_t *) { return 0; }
void tiff_mem_unmap(thandle_t, tdata_t, toff_t) {}

/* Ein G4-Strom wird als EIN Strip geschrieben (RowsPerStrip = Höhe). */
bool g4_strip_payload(tiff_memfile &mem, unsigned char **out, size_t *out_len)
{
    TIFF *reader = TIFFClientOpen("pdfcore-g4", "r",
                                  reinterpret_cast<thandle_t>(&mem),
                                  tiff_mem_read, tiff_mem_write, tiff_mem_seek,
                                  tiff_mem_close, tiff_mem_size,
                                  tiff_mem_map, tiff_mem_unmap);
    if (!reader) { return false; }
    uint64_t *counts = nullptr;
    uint64_t *offsets = nullptr;
    bool ok = TIFFNumberOfStrips(reader) == 1
        && TIFFGetField(reader, TIFFTAG_STRIPBYTECOUNTS, &counts) != 0
        && TIFFGetField(reader, TIFFTAG_STRIPOFFSETS, &offsets) != 0
        && counts != nullptr && offsets != nullptr
        && counts[0] > 0
        && static_cast<size_t>(offsets[0]) + static_cast<size_t>(counts[0]) <= mem.len;
    if (ok) {
        char *copy = malloc_copy(mem.buffer + offsets[0],
                                 static_cast<size_t>(counts[0]));
        if (copy) {
            *out = reinterpret_cast<unsigned char *>(copy);
            *out_len = static_cast<size_t>(counts[0]);
        } else {
            ok = false;
        }
    }
    TIFFClose(reader);
    return ok;
}

/* Reihenbytes invertieren – Übersetzung zwischen der Bilevel-Pixelfolge
 * (1 = schwarz) und der Belegung des Fax-Codecs (0 = weiss / 1 = schwarz
 * MINISWHITE: der Codec rechnet mit 0-Bits als weissen Läufen). */
void complement_rows(unsigned char *rows, size_t row_bytes, int height)
{
    const size_t total = row_bytes * static_cast<size_t>(height);
    for (size_t i = 0; i < total; ++i) { rows[i] = static_cast<unsigned char>(~rows[i]); }
}

/* Bilevel-Pixelfolge (1 = schwarz, MSB-first je Byte) in ein Leptonica-1bpp-
 * Pix übernehmen. Pixel x sitzt im Bit 31-(x&31) des Wortes x/32 – je Wort
 * Big-Endian-Belegung, auf Little-Endian-Maschinen also Bytetausch. Bits
 * über der Bildbreite werden auf weiss (0) gezogen, damit der Symbol- und
 * Generic-Encoder keine Phantompixel am Zeilenende sieht. */
void fill_lept_pix(Pix *pix, const unsigned char *pixels, int width, int height)
{
    const size_t row_bytes = (static_cast<size_t>(width) + 7) / 8;
    const int trailing_mask_shift = width & 7;
    l_uint32 *data = pixGetData(pix);
    const l_int32 wpl = pixGetWpl(pix);
    for (int y = 0; y < height; ++y) {
        const unsigned char *src = pixels + static_cast<size_t>(y) * row_bytes;
        l_uint32 *row = data + static_cast<size_t>(y) * wpl;
        size_t x = 0;
        for (l_int32 word = 0; word < wpl; ++word) {
            l_uint32 value = 0;
            for (l_int32 b = 0; b < 4; ++b, ++x) {
                unsigned char byte = x < row_bytes ? src[x] : 0;
                if (trailing_mask_shift != 0
                    && x == row_bytes - 1) {
                    byte &= static_cast<unsigned char>(0xFFu << (8 - trailing_mask_shift));
                }
                value = (value << 8) | byte;
            }
            row[word] = value;
        }
    }
    pixSetPadBits(pix, 0);
}

/* Wörterbuch-Aufbau für die Bilevel-Ersetzung – strukturell derselbe Weg wie
 * replace_image_stream, aber mit BitsPerComponent 1 und den Phase-2b-
 * DecodeParms. `decode_parms` wird als vollständiges Dictionary übergeben. */
int replace_image_bilevel(pdfcore_document_t *doc,
                          int obj_number, int generation,
                          const unsigned char *bytes, size_t len,
                          int width, int height,
                          char const *filterName,
                          QPDFObjectHandle decode_parms)
{
    QPDFObjectHandle target = find_image_object(doc->qpdf, obj_number, generation);
    if (target.isNull()) { return PDFCORE_ERR_CHECK_FAILED; }

    QPDFObjectHandle oldDict = dict_of(target);
    // Explicit identity Decode is equivalent to the default for 1-bit
    // DeviceGray. Inversion and every other Decode remain protected.
    QPDFObjectHandle decode = oldDict.getKey("/Decode");
    QPDFObjectHandle bpc = oldDict.getKey("/BitsPerComponent");
    QPDFObjectHandle cs = oldDict.getKey("/ColorSpace");
    bool identityDecode = bpc.isInteger() && bpc.getIntValue() == 1 &&
        cs.isName() && cs.getName() == "/DeviceGray" &&
        decode.isArray() && decode.getArrayNItems() == 2 &&
        decode.getArrayItem(0).isNumber() && decode.getArrayItem(1).isNumber() &&
        decode.getArrayItem(0).getNumericValue() == 0.0 &&
        decode.getArrayItem(1).getNumericValue() == 1.0;
    if (blocks_jpeg_replacement(oldDict, identityDecode)) {
        return PDFCORE_ERR_CHECK_FAILED;
    }

    QPDFObjectHandle newDict = QPDFObjectHandle::newDictionary();
    newDict.replaceKey("/Type", QPDFObjectHandle::newName("/XObject"));
    newDict.replaceKey("/Subtype", QPDFObjectHandle::newName("/Image"));
    newDict.replaceKey("/Filter", QPDFObjectHandle::newName(filterName));
    newDict.replaceKey("/BitsPerComponent", QPDFObjectHandle::newInteger(1));
    newDict.replaceKey("/ColorSpace", QPDFObjectHandle::newName("/DeviceGray"));
    newDict.replaceKey("/Width", QPDFObjectHandle::newInteger(width));
    newDict.replaceKey("/Height", QPDFObjectHandle::newInteger(height));
    if (decode_parms.isDictionary()) {
        newDict.replaceKey("/DecodeParms", decode_parms);
    }

    // Masken- und Erklärbeziehungen mitnehmen (wie beim JPEG-Ersatz): Eine
    // 1-bit-Bildfläche mit /SMask behält ihre Transparenz.
    for (char const* key : {"/SMask", "/Mask", "/SMaskInData"}) {
        QPDFObjectHandle v = oldDict.getKey(key);
        if (!v.isNull()) { newDict.replaceKey(key, v); }
    }
    for (char const* key : {"/Intent", "/Interpolate", "/Metadata",
                            "/StructParent", "/OC"}) {
        QPDFObjectHandle v = oldDict.getKey(key);
        if (!v.isNull()) { newDict.replaceKey(key, v); }
    }

    std::string data(reinterpret_cast<const char *>(bytes), len);
    target.replaceStreamData(
        data, QPDFObjectHandle::newNull(), QPDFObjectHandle::newNull());
    QPDFObjectHandle streamDict = target.getDict();
    for (auto const& key : streamDict.getKeys()) {
        if (!newDict.hasKey(key) && key != "/Length") {
            streamDict.removeKey(key);
        }
    }
    for (auto const& key : newDict.getKeys()) {
        streamDict.replaceKey(key, newDict.getKey(key));
    }
    return PDFCORE_OK;
}

} // namespace

int pdfcore_g4_encode(const unsigned char *pixels, size_t pixels_len,
                      int width, int height,
                      unsigned char **out, size_t *out_len)
{
    if (!pixels || !out || !out_len) { return PDFCORE_ERR_INTERNAL; }
    *out = nullptr; *out_len = 0;
    if (width <= 0 || height <= 0) { return PDFCORE_ERR_INTERNAL; }
    const size_t row_bytes = (static_cast<size_t>(width) + 7) / 8;
    if (pixels_len < row_bytes * static_cast<size_t>(height)) { return PDFCORE_ERR_INTERNAL; }

    tiff_memfile mem = {};
    TIFF *tif = TIFFClientOpen("pdfcore-g4", "w",
                               reinterpret_cast<thandle_t>(&mem),
                               tiff_mem_read, tiff_mem_write, tiff_mem_seek,
                               tiff_mem_close, tiff_mem_size,
                               tiff_mem_map, tiff_mem_unmap);
    if (!tif) { std::free(mem.buffer); return PDFCORE_ERR_INTERNAL; }

    bool ok = true;
    std::vector<unsigned char> scratch(row_bytes);
    ok = TIFFSetField(tif, TIFFTAG_IMAGEWIDTH, static_cast<uint32_t>(width))
      && TIFFSetField(tif, TIFFTAG_IMAGELENGTH, static_cast<uint32_t>(height))
      && TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, 1)
      && TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE, 1)
      && TIFFSetField(tif, TIFFTAG_COMPRESSION, COMPRESSION_CCITTFAX4)
      && TIFFSetField(tif, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_MINISWHITE)
      && TIFFSetField(tif, TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT)
      && TIFFSetField(tif, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG)
      && TIFFSetField(tif, TIFFTAG_ROWSPERSTRIP, static_cast<uint32_t>(height));
    for (int y = 0; ok && y < height; ++y) {
        std::memcpy(scratch.data(), pixels + static_cast<size_t>(y) * row_bytes, row_bytes);
        complement_rows(scratch.data(), row_bytes, 1);
        if (TIFFWriteScanline(tif, scratch.data(), static_cast<uint32_t>(y), 0) < 0) {
            ok = false;
        }
    }
    if (ok) { ok = TIFFWriteDirectory(tif) != 0; }
    TIFFClose(tif);

    if (ok) {
        mem.offset = 0;
        ok = g4_strip_payload(mem, out, out_len);
    }
    std::free(mem.buffer);
    if (!ok) {
        if (*out) { std::free(*out); *out = nullptr; *out_len = 0; }
        return PDFCORE_ERR_INTERNAL;
    }
    return PDFCORE_OK;
}

/* Synthetischer TIFF-Wrapper um einen nackten T6-Strom: libtiff liest
 * Faxdaten nur aus TIFF-Struktur heraus. Layout: 8-Byte-Header (II, IFD
 * bei 8), IFD mit neun Tags, Nutzdaten als einziger Strip ab Offset 122. */
bool g4_wrap_for_decode(const unsigned char *g4, size_t g4_len,
                        int width, int height, tiff_memfile *mem)
{
    const size_t payload_offset = 122;
    if (payload_offset + g4_len < payload_offset) { return false; }
    mem->cap = payload_offset + g4_len;
    mem->buffer = static_cast<unsigned char *>(malloc(mem->cap));
    if (!mem->buffer) { return false; }
    mem->len = mem->cap;
    mem->offset = 0;

    unsigned char *b = mem->buffer;
    b[0] = 'I'; b[1] = 'I'; b[2] = 42; b[3] = 0;
    b[4] = 8; b[5] = 0; b[6] = 0; b[7] = 0;   /* IFD-Offset */
    auto put16 = [&](size_t at, unsigned v) {
        b[at] = v & 0xFF; b[at + 1] = (v >> 8) & 0xFF;
    };
    auto put32 = [&](size_t at, unsigned long v) {
        b[at] = v & 0xFF; b[at + 1] = (v >> 8) & 0xFF;
        b[at + 2] = (v >> 16) & 0xFF; b[at + 3] = (v >> 24) & 0xFF;
    };
    put16(8, 9);                              /* Anzahl IFD-Einträge */
    size_t at = 10;
    auto entry = [&](unsigned tag, unsigned type, unsigned long value) {
        put16(at, tag); put16(at + 2, type);
        put32(at + 4, 1);                     /* count */
        put32(at + 8, value);
        at += 12;
    };
    entry(256, 4, static_cast<unsigned long>(width));        /* ImageWidth */
    entry(257, 4, static_cast<unsigned long>(height));       /* ImageLength */
    entry(258, 3, 1);                                        /* BitsPerSample */
    entry(259, 3, 4);                                        /* CCITTFax4 */
    entry(262, 3, 0);                                        /* MINISWHITE */
    entry(273, 4, payload_offset);                           /* StripOffsets */
    entry(278, 4, static_cast<unsigned long>(height));       /* RowsPerStrip */
    entry(279, 4, static_cast<unsigned long>(g4_len));       /* StripByteCounts */
    entry(284, 3, 1);                                        /* PlanarConfig */
    put32(at, 0);                             /* keine weitere IFD */
    std::memcpy(mem->buffer + payload_offset, g4, g4_len);
    return true;
}

int pdfcore_g4_decode(const unsigned char *g4, size_t g4_len,
                      int width, int height,
                      unsigned char **out, size_t *out_len)
{
    if (!g4 || g4_len == 0 || !out || !out_len) {
        return PDFCORE_ERR_INTERNAL;
    }
    *out = nullptr; *out_len = 0;
    if (width <= 0 || height <= 0) { return PDFCORE_ERR_INTERNAL; }
    const size_t row_bytes = (static_cast<size_t>(width) + 7) / 8;

    tiff_memfile mem = {};
    if (!g4_wrap_for_decode(g4, g4_len, width, height, &mem)) {
        std::free(mem.buffer);
        return PDFCORE_ERR_INTERNAL;
    }
    TIFF *tif = TIFFClientOpen("pdfcore-g4", "r",
                               reinterpret_cast<thandle_t>(&mem),
                               tiff_mem_read, tiff_mem_write, tiff_mem_seek,
                               tiff_mem_close, tiff_mem_size,
                               tiff_mem_map, tiff_mem_unmap);
    if (!tif) { std::free(mem.buffer); return PDFCORE_ERR_INTERNAL; }

    unsigned char *rows = static_cast<unsigned char *>(
        malloc(row_bytes * static_cast<size_t>(height)));
    bool ok = rows != nullptr;
    for (int y = 0; ok && y < height; ++y) {
        if (TIFFReadScanline(tif, rows + static_cast<size_t>(y) * row_bytes,
                             static_cast<uint32_t>(y), 0) < 0) {
            ok = false;
        }
    }
    TIFFClose(tif);
    std::free(mem.buffer);
    if (!ok) {
        std::free(rows);
        return PDFCORE_ERR_INTERNAL;
    }
    // Zurück zur Bilevel-Pixelfolge (1 = schwarz) – spiegelbildlich zur
    // Umkehrung beim Encode. Die Bits ÜBER der Bildbreite zieht der
    // Fax-Dekodierer nicht zuverlässig auf weiss (fillruns stoppt bei
    // `width`), deshalb werden sie anschliessend maskiert – sonst trüge
    // der Vergleichspuffer Müll im Zeilenende.
    complement_rows(rows, row_bytes, height);
    const int valid_bits = width & 7;
    if (valid_bits != 0) {
        const unsigned char pad_mask =
            static_cast<unsigned char>(0xFFu << (8 - valid_bits));
        for (int y = 0; y < height; ++y) {
            rows[static_cast<size_t>(y) * row_bytes + row_bytes - 1] &= pad_mask;
        }
    }
    *out = rows;
    *out_len = row_bytes * static_cast<size_t>(height);
    return PDFCORE_OK;
}

/* V2-3c – synthetischer TIFF-Wrapper für G3-/G4-Ströme: wie
 * g4_wrap_for_decode, aber mit wählbarer Kompression und T4Options
 * (2D-Bit für K > 0). Zehn IFD-Einträge, Nutzdaten ab Offset 134. */
bool ccitt_wrap_for_decode(const unsigned char *data, size_t data_len,
                           int width, int height,
                           unsigned short compression,
                           unsigned long t4options,
                           tiff_memfile *mem)
{
    const size_t payload_offset = 134;
    if (payload_offset + data_len < payload_offset) { return false; }
    mem->cap = payload_offset + data_len;
    mem->buffer = static_cast<unsigned char *>(malloc(mem->cap));
    if (!mem->buffer) { return false; }
    mem->len = mem->cap;
    mem->offset = 0;

    unsigned char *b = mem->buffer;
    b[0] = 'I'; b[1] = 'I'; b[2] = 42; b[3] = 0;
    b[4] = 8; b[5] = 0; b[6] = 0; b[7] = 0;   /* IFD-Offset */
    auto put16 = [&](size_t at, unsigned v) {
        b[at] = v & 0xFF; b[at + 1] = (v >> 8) & 0xFF;
    };
    auto put32 = [&](size_t at, unsigned long v) {
        b[at] = v & 0xFF; b[at + 1] = (v >> 8) & 0xFF;
        b[at + 2] = (v >> 16) & 0xFF; b[at + 3] = (v >> 24) & 0xFF;
    };
    put16(8, 10);                             /* Anzahl IFD-Einträge */
    size_t at = 10;
    auto entry = [&](unsigned tag, unsigned type, unsigned long value) {
        put16(at, tag); put16(at + 2, type);
        put32(at + 4, 1);                     /* count */
        put32(at + 8, value);
        at += 12;
    };
    entry(256, 4, static_cast<unsigned long>(width));        /* ImageWidth */
    entry(257, 4, static_cast<unsigned long>(height));       /* ImageLength */
    entry(258, 3, 1);                                        /* BitsPerSample */
    entry(259, 3, compression);                              /* G3/G4 */
    entry(262, 3, 0);                                        /* MINISWHITE */
    entry(273, 4, payload_offset);                           /* StripOffsets */
    entry(278, 4, static_cast<unsigned long>(height));       /* RowsPerStrip */
    entry(279, 4, static_cast<unsigned long>(data_len));     /* StripByteCounts */
    entry(284, 3, 1);                                        /* PlanarConfig */
    entry(292, 4, t4options);                                /* T4Options (G3) */
    put32(at, 0);                             /* keine weitere IFD */
    std::memcpy(mem->buffer + payload_offset, data, data_len);
    return true;
}

int pdfcore_ccitt_decode(const unsigned char *data, size_t data_len,
                         const pdfcore_ccitt_parms_t *parms,
                         unsigned char **out, size_t *out_len)
{
    if (!data || data_len == 0 || !parms || !out || !out_len) {
        return PDFCORE_ERR_INTERNAL;
    }
    *out = nullptr; *out_len = 0;
    const int width = parms->columns;
    const int height = parms->rows;
    if (width <= 0 || height <= 0) { return PDFCORE_ERR_INTERNAL; }
    /* Defensive Verdopplung der Swift-Politik: nur G4 (K -1), G3 1D (K 0)
     * und G3 2D (K 1..64). Byte-Align und damaged rows lehnt Swift ab;
     * auch hier keine Ausnahme. */
    if (parms->k < -1 || parms->k > 64) { return PDFCORE_ERR_INTERNAL; }
    if (parms->byte_aligned != 0 || parms->damaged_rows != 0) {
        return PDFCORE_ERR_INTERNAL;
    }

    const bool g4 = parms->k < 0;
    const unsigned short compression = g4 ? COMPRESSION_CCITTFAX4
                                          : COMPRESSION_CCITTFAX3;
    const unsigned long t4options =
        (!g4 && parms->k > 0) ? GROUP3OPT_2DENCODING : 0ul;

    tiff_memfile mem = {};
    if (!ccitt_wrap_for_decode(data, data_len, width, height,
                               compression, t4options, &mem)) {
        std::free(mem.buffer);
        return PDFCORE_ERR_INTERNAL;
    }
    TIFF *tif = TIFFClientOpen("pdfcore-ccitt", "r",
                               reinterpret_cast<thandle_t>(&mem),
                               tiff_mem_read, tiff_mem_write, tiff_mem_seek,
                               tiff_mem_close, tiff_mem_size,
                               tiff_mem_map, tiff_mem_unmap);
    if (!tif) { std::free(mem.buffer); return PDFCORE_ERR_INTERNAL; }

    /* Fax-Modus nur für G3 explizit; G4 bleibt exakt auf dem Pfad von
     * pdfcore_g4_decode (kein FAXMODE – libtiff-Default). Ohne EOL-Codes
     * (PDF-Default) ohne EOL-Synchronisation dekodieren, mit EOLs im
     * T.4-Stil (EOL vor jeder Zeile) ohne RTC-Erwartung. Empirisch gegen
     * die vendored libtiff verifiziert: 2D OHNE EOLs dekodiert nicht
     * ("Uncompressed data not supported") – deshalb verlangt die Swift-
     * Politik EndOfLine für K > 0. */
    if (!g4) {
        const int faxmode = parms->end_of_line
            ? FAXMODE_NORTC
            : (FAXMODE_NOEOL | FAXMODE_NORTC);
        if (TIFFSetField(tif, TIFFTAG_FAXMODE, faxmode) == 0) {
            TIFFClose(tif);
            std::free(mem.buffer);
            return PDFCORE_ERR_INTERNAL;
        }
    }

    const size_t row_bytes = (static_cast<size_t>(width) + 7) / 8;
    unsigned char *rows = static_cast<unsigned char *>(
        malloc(row_bytes * static_cast<size_t>(height)));
    bool ok = rows != nullptr;
    for (int y = 0; ok && y < height; ++y) {
        if (TIFFReadScanline(tif, rows + static_cast<size_t>(y) * row_bytes,
                             static_cast<uint32_t>(y), 0) < 0) {
            ok = false;
        }
    }
    TIFFClose(tif);
    std::free(mem.buffer);
    if (!ok) {
        std::free(rows);
        return PDFCORE_ERR_INTERNAL;
    }
    /* Zurück zur Bilevel-Pixelfolge (1 = schwarz) – konsistent mit dem, was
     * ein Leser ANZEIGT: Der Fax-Dekodierer füllt weisse Läufe mit 0-Bits
     * und schwarze mit 1-Bits; ohne BlackIs1 ist diese Belegung bereits die
     * sichtbare Tinte. BlackIs1 true erklärt den Strom für invertiert –
     * dann kehrt die Extraktion um (genau wie der Leser). Ein zum Flag
     * passender Strom liefert so dieselbe Tinten-1-Folge. Pad-Bits werden
     * anschliessend auf weiss (0) gezogen. */
    if (parms->black_is_1) {
        complement_rows(rows, row_bytes, height);
    }
    const int valid_bits = width & 7;
    if (valid_bits != 0) {
        const unsigned char pad_mask =
            static_cast<unsigned char>(0xFFu << (8 - valid_bits));
        for (int y = 0; y < height; ++y) {
            rows[static_cast<size_t>(y) * row_bytes + row_bytes - 1] &= pad_mask;
        }
    }
    *out = rows;
    *out_len = row_bytes * static_cast<size_t>(height);
    return PDFCORE_OK;
}

/* Liest /DecodeParms eines Bild-XObjects (V2-3c). Bekannte Schlüssel
 * erhalten ihre PDF-Defaults; ein fremder Schlüssel wird als
 * known_keys_only = 0 gemeldet – die Verweigerungspolitik liegt in Swift. */
int pdfcore_get_image_ccitt_parms(pdfcore_document_t *doc,
                                  int obj_number, int generation,
                                  pdfcore_ccitt_parms_t *out)
{
    if (!doc || !out) { return PDFCORE_ERR_OPEN; }
    try {
        *out = {};
        QPDFObjectHandle target = find_image_object(doc->qpdf, obj_number,
                                                    generation);
        if (target.isNull()) { return PDFCORE_ERR_CHECK_FAILED; }
        QPDFObjectHandle dict = dict_of(target);

        /* Terminale Filterkette muss CCITTFaxDecode sein (Name oder Array). */
        QPDFObjectHandle filter = dict.getKey("/Filter");
        if (filter.isName()) {
            if (filter.getName() != "/CCITTFaxDecode") {
                return PDFCORE_ERR_CHECK_FAILED;
            }
        } else if (filter.isArray() && filter.getArrayNItems() == 1) {
            QPDFObjectHandle last = filter.getArrayItem(0);
            if (!last.isName() || last.getName() != "/CCITTFaxDecode") {
                return PDFCORE_ERR_CHECK_FAILED;
            }
        } else {
            return PDFCORE_ERR_CHECK_FAILED;
        }

        QPDFObjectHandle parms = dict.getKey("/DecodeParms");
        if (parms.isArray()) {
            if (parms.getArrayNItems() != 1) { return PDFCORE_ERR_CHECK_FAILED; }
            parms = parms.getArrayItem(0);
        }
        if (parms.isNull()) {
            /* Kein /DecodeParms: /K ist Pflicht – ohne ihn nicht
             * rekonstruierbar. present = 0 signalisiert das der Politik. */
            out->present = 0;
            return PDFCORE_OK;
        }
        if (!parms.isDictionary()) { return PDFCORE_ERR_CHECK_FAILED; }
        out->present = 1;

        static const char const *known_keys[] = {
            "/K", "/Columns", "/Rows", "/BlackIs1", "/EncodedByteAlign",
            "/EndOfLine", "/EndOfBlock", "/DamagedRowsBeforeError",
        };
        out->known_keys_only = 1;
        for (auto const& key : parms.getKeys()) {
            bool known = false;
            for (char const* candidate : known_keys) {
                if (key == candidate) { known = true; break; }
            }
            if (!known) { out->known_keys_only = 0; }
        }

        QPDFObjectHandle k = parms.getKey("/K");
        if (!k.isInteger()) { return PDFCORE_ERR_CHECK_FAILED; }
        out->k = static_cast<int>(k.getIntValue());

        QPDFObjectHandle columns = parms.getKey("/Columns");
        if (!columns.isInteger()) { return PDFCORE_ERR_CHECK_FAILED; }
        out->columns = static_cast<int>(columns.getIntValue());

        QPDFObjectHandle rows = parms.getKey("/Rows");
        if (!rows.isInteger()) { return PDFCORE_ERR_CHECK_FAILED; }
        out->rows = static_cast<int>(rows.getIntValue());

        auto boolOrDefault = [&](char const* key) -> int {
            QPDFObjectHandle v = parms.getKey(key);
            return (v.isBool() && v.getBoolValue()) ? 1 : 0;
        };
        out->black_is_1 = boolOrDefault("/BlackIs1");
        out->end_of_line = boolOrDefault("/EndOfLine");
        out->end_of_block = boolOrDefault("/EndOfBlock");
        out->byte_aligned = boolOrDefault("/EncodedByteAlign");

        QPDFObjectHandle damaged = parms.getKey("/DamagedRowsBeforeError");
        out->damaged_rows = damaged.isInteger()
            ? static_cast<int>(damaged.getIntValue()) : 0;
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_ccitt_encode_fixture(const unsigned char *pixels, size_t pixels_len,
                                 int width, int height,
                                 int k, int end_of_line,
                                 unsigned char **out, size_t *out_len)
{
    if (!pixels || !out || !out_len) { return PDFCORE_ERR_INTERNAL; }
    *out = nullptr; *out_len = 0;
    if (width <= 0 || height <= 0 || k < -1 || k > 64) {
        return PDFCORE_ERR_INTERNAL;
    }
    const size_t row_bytes = (static_cast<size_t>(width) + 7) / 8;
    if (pixels_len < row_bytes * static_cast<size_t>(height)) {
        return PDFCORE_ERR_INTERNAL;
    }

    const bool g4 = k < 0;
    tiff_memfile mem = {};
    TIFF *tif = TIFFClientOpen("pdfcore-ccitt-fixture", "w",
                               reinterpret_cast<thandle_t>(&mem),
                               tiff_mem_read, tiff_mem_write, tiff_mem_seek,
                               tiff_mem_close, tiff_mem_size,
                               tiff_mem_map, tiff_mem_unmap);
    if (!tif) { std::free(mem.buffer); return PDFCORE_ERR_INTERNAL; }

    bool ok = TIFFSetField(tif, TIFFTAG_IMAGEWIDTH, static_cast<uint32_t>(width))
      && TIFFSetField(tif, TIFFTAG_IMAGELENGTH, static_cast<uint32_t>(height))
      && TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, 1)
      && TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE, 1)
      && TIFFSetField(tif, TIFFTAG_COMPRESSION,
                      g4 ? COMPRESSION_CCITTFAX4 : COMPRESSION_CCITTFAX3)
      && TIFFSetField(tif, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_MINISWHITE)
      && TIFFSetField(tif, TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT)
      && TIFFSetField(tif, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG)
      && TIFFSetField(tif, TIFFTAG_ROWSPERSTRIP, static_cast<uint32_t>(height));
    if (!g4) {
        ok = ok
          && TIFFSetField(tif, TIFFTAG_GROUP3OPTIONS,
                          k > 0 ? GROUP3OPT_2DENCODING : 0ul) != 0
          && TIFFSetField(tif, TIFFTAG_FAXMODE,
                          end_of_line ? FAXMODE_NORTC
                                      : (FAXMODE_NOEOL | FAXMODE_NORTC)) != 0;
    }
    std::vector<unsigned char> scratch(row_bytes);
    for (int y = 0; ok && y < height; ++y) {
        std::memcpy(scratch.data(),
                    pixels + static_cast<size_t>(y) * row_bytes, row_bytes);
        /* FAX-NATIV: Der Eingabepuffer trägt 1 = Tinte, der Fax-Codec
         * belegt schwarze Läufe mit 1-Bits – also OHNE Komplement schreiben
         * (anders als pdfcore_g4_encode, dessen eigener Output die
         * komplementierte Konvention mit /BlackIs1 true verwendet).
         * Die Fixture entspricht damit einem realen Standard-Stream mit
         * PDF-Default (Abtastwert 1 = schwarz). */
        if (TIFFWriteScanline(tif, scratch.data(), static_cast<uint32_t>(y), 0) < 0) {
            ok = false;
        }
    }
    if (ok) { ok = TIFFWriteDirectory(tif) != 0; }
    TIFFClose(tif);

    if (ok) {
        mem.offset = 0;
        ok = g4_strip_payload(mem, out, out_len);
    }
    std::free(mem.buffer);
    if (!ok) {
        if (*out) { std::free(*out); *out = nullptr; *out_len = 0; }
        return PDFCORE_ERR_INTERNAL;
    }
    return PDFCORE_OK;
}

int pdfcore_jbig2_encode(const unsigned char *pixels, size_t pixels_len,
                         int width, int height,
                         unsigned char **page_out, size_t *page_len,
                         unsigned char **globals_out, size_t *globals_len)
{
    if (!pixels || !page_out || !page_len) { return PDFCORE_ERR_INTERNAL; }
    *page_out = nullptr; *page_len = 0;
    if (globals_out) { *globals_out = nullptr; *globals_len = 0; }
    if (width <= 0 || height <= 0) { return PDFCORE_ERR_INTERNAL; }
    const size_t row_bytes = (static_cast<size_t>(width) + 7) / 8;
    if (pixels_len < row_bytes * static_cast<size_t>(height)) { return PDFCORE_ERR_INTERNAL; }

    Pix *pix = pixCreate(width, height, 1);
    if (!pix) { return PDFCORE_ERR_INTERNAL; }
    fill_lept_pix(pix, pixels, width, height);

    // refine_level = -1 ist HART: Refinement-Coding ist der bekannte
    // Acrobat-Crasher und wird in keinem Pfad dieser Bridge aktiviert.
    struct jbig2ctx *ctx = jbig2_init(0.92f, 0.5f, 72, 72, false, -1);
    if (!ctx) { pixDestroy(&pix); return PDFCORE_ERR_INTERNAL; }
    jbig2_add_page(ctx, pix);
    pixDestroy(&pix);

    int sym_len = 0;
    int raw_page_len = 0;
    uint8_t *globals = jbig2_pages_complete(ctx, &sym_len);
    uint8_t *page = jbig2_produce_page(ctx, 0, -1, -1, &raw_page_len);
    jbig2_destroy(ctx);

    bool ok = page != nullptr && raw_page_len > 0;
    if (ok) {
        char *page_copy = malloc_copy(page, static_cast<size_t>(raw_page_len));
        if (page_copy) {
            *page_out = reinterpret_cast<unsigned char *>(page_copy);
            *page_len = static_cast<size_t>(raw_page_len);
        } else {
            ok = false;
        }
    }
    if (ok && globals_out && globals != nullptr && sym_len > 0) {
        char *globals_copy = malloc_copy(globals, static_cast<size_t>(sym_len));
        if (globals_copy) {
            *globals_out = reinterpret_cast<unsigned char *>(globals_copy);
            *globals_len = static_cast<size_t>(sym_len);
        } else {
            ok = false;
            std::free(*page_out); *page_out = nullptr; *page_len = 0;
        }
    }
    std::free(page);
    std::free(globals);
    if (!ok) {
        if (*page_out) { std::free(*page_out); *page_out = nullptr; *page_len = 0; }
        if (globals_out) { std::free(*globals_out); *globals_out = nullptr; *globals_len = 0; }
        return PDFCORE_ERR_INTERNAL;
    }
    return PDFCORE_OK;
}

int pdfcore_jbig2_encode_generic(const unsigned char *pixels, size_t pixels_len,
                                 int width, int height,
                                 unsigned char **out, size_t *out_len)
{
    if (!pixels || !out || !out_len) { return PDFCORE_ERR_INTERNAL; }
    *out = nullptr; *out_len = 0;
    if (width <= 0 || height <= 0) { return PDFCORE_ERR_INTERNAL; }
    const size_t row_bytes = (static_cast<size_t>(width) + 7) / 8;
    if (pixels_len < row_bytes * static_cast<size_t>(height)) { return PDFCORE_ERR_INTERNAL; }

    Pix *pix = pixCreate(width, height, 1);
    if (!pix) { return PDFCORE_ERR_INTERNAL; }
    fill_lept_pix(pix, pixels, width, height);

    int raw_len = 0;
    uint8_t *raw = jbig2_encode_generic(pix, false, 72, 72, false, &raw_len);
    pixDestroy(&pix);
    if (!raw || raw_len <= 0) {
        std::free(raw);
        return PDFCORE_ERR_INTERNAL;
    }
    char *copy = malloc_copy(raw, static_cast<size_t>(raw_len));
    std::free(raw);
    if (!copy) { return PDFCORE_ERR_INTERNAL; }
    *out = reinterpret_cast<unsigned char *>(copy);
    *out_len = static_cast<size_t>(raw_len);
    return PDFCORE_OK;
}

int pdfcore_replace_image_object_ccitt(pdfcore_document_t *doc,
                                       int obj_number, int generation,
                                       const unsigned char *g4, size_t g4_len,
                                       int width, int height)
{
    if (!doc || !g4 || g4_len == 0 || width <= 0 || height <= 0) {
        return PDFCORE_ERR_OPEN;
    }
    try {
        QPDFObjectHandle parms = QPDFObjectHandle::newDictionary();
        parms.replaceKey("/K", QPDFObjectHandle::newInteger(-1));
        parms.replaceKey("/Columns", QPDFObjectHandle::newInteger(width));
        parms.replaceKey("/Rows", QPDFObjectHandle::newInteger(height));
        parms.replaceKey("/BlackIs1", QPDFObjectHandle::newBool(true));
        return replace_image_bilevel(doc, obj_number, generation,
                                     g4, g4_len, width, height,
                                     "/CCITTFaxDecode", parms);
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_replace_image_object_jbig2(pdfcore_document_t *doc,
                                       int obj_number, int generation,
                                       const unsigned char *page_data, size_t page_len,
                                       const unsigned char *globals, size_t globals_len,
                                       int width, int height)
{
    if (!doc || !page_data || page_len == 0 || width <= 0 || height <= 0) {
        return PDFCORE_ERR_OPEN;
    }
    try {
        QPDFObjectHandle parms = QPDFObjectHandle::newNull();
        if (globals && globals_len > 0) {
            // Globals als EIGENES indirektes Stream-Objekt – unkomprimiert,
            // genau wie jbig2topdf.py sie referenziert.
            QPDFObjectHandle globalsStream = doc->qpdf.newStream(
                std::string(reinterpret_cast<const char *>(globals), globals_len));
            parms = QPDFObjectHandle::newDictionary();
            parms.replaceKey("/JBIG2Globals", doc->qpdf.makeIndirectObject(globalsStream));
        }
        return replace_image_bilevel(doc, obj_number, generation,
                                     page_data, page_len, width, height,
                                     "/JBIG2Decode", parms);
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Phase 3b (Roadmap) – Content-Hash-Dedup über alle indirekten Objekte.
//
// Merge-Dokumente tragen dasselbe Bild, denselben Content-Stream, dasselbe
// Font-Dict oft mehrfach als getrennte Objekte. Dieser Pass hashet jeden
// Stream (dekomprimiert), vergleicht die Wörterbücher nach Whitelist und
// hängt Referenzen auf das kanonische Objekt (niedrigste Objektnummer) um.
// Verlustfrei: kein Byte wird neu kodiert; verwaiste Objekte verwirft der
// Writer. Die Regeln sind bewusst konservativ (Whitelist-Ansatz) – was nicht
// sicher vergleichbar ist, bleibt getrennt.
// ============================================================================

namespace {

/// SHA-256 als Hexstring (CommonCrypto aus libSystem).
std::string dedup_sha256(unsigned char const* data, size_t len)
{
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    static unsigned char const empty[1] = { 0 };
    CC_SHA256(data ? data : empty, static_cast<CC_LONG>(len), digest);
    static char const* digits = "0123456789abcdef";
    std::string hex;
    hex.reserve(CC_SHA256_DIGEST_LENGTH * 2);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        hex.push_back(digits[digest[i] >> 4]);
        hex.push_back(digits[digest[i] & 15]);
    }
    return hex;
}

/// Schlüssel, deren Werte beim Stream-Vergleich übereinstimmen müssen.
/// V2-8 (§14.5) – ICC-Dedup: /N (Komponentenzahl), /Range (Ausgabeklemmung)
/// und /Alternate (Fallback-Farbraum nicht-ICC-fähiger Leser) sind der
/// SEMANTISCHE Vertrag eines /ICCBased-Farbraumstroms. Zwei Profile sind nur
/// dann austauschbar, wenn die Programmbytes UND dieser Vertrag gleich sind.
/// Die drei Schlüssel kommen in Stream-Dicts praktisch nur bei ICCBased vor;
/// Funktionsströme (Typ 0/2/3/4) tragen zwar teils /Range, scheitern aber an
/// ihren übrigen nicht whitelisted Schlüsseln (/Domain, /C0 …) und bleiben
/// damit weiterhin konservativ getrennt.
bool dedup_is_compare_key(std::string const& key)
{
    static std::set<std::string> const keys = {
        "/Type", "/Subtype", "/Width", "/Height", "/BitsPerComponent",
        "/ColorSpace", "/SMask", "/Mask", "/Decode", "/Intent",
        "/Interpolate", "/Name", "/BBox", "/Resources",
        "/N", "/Range", "/Alternate" };
    return keys.count(key) != 0;
}

/// Vom Vergleich ausgenommene Schlüssel: /Length führt der Writer neu,
/// /Filter und /DecodeParms (/DP als Kurzform) dürfen abweichen, wenn die
/// DEKODIERTEN Bytes identisch sind.
bool dedup_is_ignored_key(std::string const& key)
{
    return key == "/Length" || key == "/Filter"
        || key == "/DecodeParms" || key == "/DP";
}

/// Kanonische Serialisierung für Objektvergleiche.
///
/// Bewusst eigene Umsetzung statt unparse(): Indirekte Referenzen werden bei
/// ihrer Objektnummer belassen – zwei Werte, die auf verschiedene (auch
/// inhaltsgleiche) Objekte zeigen, gelten als verschieden. Die Rekursion
/// läuft nur über direkte Container; Zyklen laufen in PDF über Referenzen und
/// werden hier nie aufgelöst. Längenpräfixe halten die Form eindeutig.
///
/// `topLevel` markiert das zu vergleichende Objekt selbst: Objekte aus
/// getAllObjects() sind stets indirekt, dürfen aber inhaltlich zerlegt
/// werden – nur NESTED Referenzen bleiben bei ihrer Nummer.
bool dedup_canonical(QPDFObjectHandle const& value, int depth, std::string& out,
                     bool topLevel = false)
{
    if (depth > 32) { return false; }
    if (value.isNull()) { out += "N"; return true; }
    if (!topLevel && value.isIndirect()) {
        out += "R" + std::to_string(value.getObjectID())
             + ":" + std::to_string(value.getGeneration()) + ";";
        return true;
    }
    if (value.isBool()) { out += value.getBoolValue() ? "B1;" : "B0;"; return true; }
    if (value.isInteger()) {
        out += "I" + std::to_string(value.getIntValue()) + ";";
        return true;
    }
    if (value.isReal()) { out += "F" + value.getRealValue() + ";"; return true; }
    if (value.isName()) {
        std::string const& name = value.getName();
        out += "n" + std::to_string(name.size()) + ":" + name + ";";
        return true;
    }
    if (value.isString()) {
        std::string const& s = value.getStringValue();
        out += "s" + std::to_string(s.size()) + ":" + s + ";";
        return true;
    }
    if (value.isDictionary()) {
        // getKeys() liefert ein sortiertes set – die Reihenfolge ist damit
        // für gleiche Dicts gleich. Benannte Kopie: Iteration über das
        // Temporary selbst ist hier nicht haltbar (siehe dedup_redirect).
        std::set<std::string> const keys = value.getKeys();
        out += "D{";
        for (auto const& key : keys) {
            out += key;
            if (!dedup_canonical(value.getKey(key), depth + 1, out)) {
                return false;
            }
        }
        out += "}";
        return true;
    }
    if (value.isArray()) {
        std::vector<QPDFObjectHandle> const items = value.getArrayAsVector();
        out += "A[";
        for (auto const& item : items) {
            if (!dedup_canonical(item, depth + 1, out)) { return false; }
        }
        out += "]";
        return true;
    }
    // Unbekannter Typ – nicht sicher vergleichbar.
    return false;
}

/// Enthält /DecodeParms (oder /DP) eine /JBIG2Globals-Referenz? Globals
/// sind kontextabhängig: Gleiche Seitenströme mit fremdem Symbolwörterbuch
/// rendern verschieden – solche Streams werden nie zusammengeführt.
bool dedup_has_jbig2_globals(QPDFObjectHandle const& dict)
{
    for (char const* key : { "/DecodeParms", "/DP" }) {
        QPDFObjectHandle parms = dict.getKey(key);
        if (parms.isDictionary() && parms.hasKey("/JBIG2Globals")) { return true; }
        if (parms.isArray()) {
            std::vector<QPDFObjectHandle> const entries =
                parms.getArrayAsVector();
            for (auto const& p : entries) {
                if (p.isDictionary() && p.hasKey("/JBIG2Globals")) { return true; }
            }
        }
    }
    return false;
}

/// Whitelist-Serial des Stream-Dicts: nur die Vergleichsschlüssel, in
/// fester Reihenfolge. Liefert false, wenn ein Schlüssel außerhalb von
/// Whitelist und den ausgenommenen Einträgen vorkommt – dann ist das Dict
/// nicht sicher vergleichbar.
bool dedup_stream_dict_part(QPDFObjectHandle const& dict, std::string& out)
{
    for (auto const& key : dict.getKeys()) {
        if (!dedup_is_compare_key(key) && !dedup_is_ignored_key(key)) {
            return false;
        }
    }
    for (char const* key : { "/Type", "/Subtype", "/Width", "/Height",
                             "/BitsPerComponent", "/ColorSpace", "/SMask",
                             "/Mask", "/Decode", "/Intent", "/Interpolate",
                             "/Name", "/BBox", "/Resources",
                             "/N", "/Range", "/Alternate" }) {
        if (!dict.hasKey(key)) { continue; }
        out += key;
        if (!dedup_canonical(dict.getKey(key), 0, out)) { return false; }
    }
    return true;
}

/// Kanonische Form von /Filter und /DecodeParms – gehört nur dann in den
/// Schlüssel, wenn rohe (nicht dekodierte) Bytes verglichen werden.
bool dedup_filter_part(QPDFObjectHandle const& dict, std::string& out)
{
    if (!dedup_canonical(dict.getKey("/Filter"), 0, out)) { return false; }
    if (!dedup_canonical(dict.getKey("/DecodeParms"), 0, out)) { return false; }
    if (!dedup_canonical(dict.getKey("/DP"), 0, out)) { return false; }
    return true;
}

struct dedup_stream_fingerprint {
    bool valid = false;
    bool decoded = false;      // true: dekodierte Bytes gehasht
    std::string hash;
    std::string filterPart;    // nur bei rohen Bytes gefüllt
    long long rawSize = 0;     // gespeicherte Bytes – Basis der Schätzung
};

/// Fingerabdruck eines Streams: möglichst dekomprimiert hashen, sonst auf
/// rohe Bytes inklusive Filter-Form ausweichen. pipeStreamData meldet über
/// den Rückgabewert, ob ALLE Filter aufgelöst wurden (Muster wie oben).
dedup_stream_fingerprint dedup_fingerprint_stream(QPDFObjectHandle stream)
{
    dedup_stream_fingerprint fp;
    try {
        // Die gespeicherten (rohen) Bytes sind die Basis der Größenschätzung,
        // unabhängig davon, worüber gehasht wird.
        std::shared_ptr<Buffer> raw = stream.getRawStreamData();
        if (raw) {
            fp.rawSize = static_cast<long long>(raw->getSize());
        }
        Pl_Buffer collector("dedup");
        if (stream.pipeStreamData(&collector, nullptr, 0, qpdf_dl_all,
                                  /*suppress_warnings=*/true, false)) {
            std::shared_ptr<Buffer> b(collector.getBuffer());
            if (b) {
                fp.decoded = true;
                fp.hash = dedup_sha256(b->getBuffer(), b->getSize());
                fp.valid = true;
                return fp;
            }
        }
        if (!raw || !fp.rawSize) { return fp; }
        QPDFObjectHandle dict = stream.getDict();
        if (!dedup_filter_part(dict, fp.filterPart)) { return fp; }
        fp.hash = dedup_sha256(raw->getBuffer(), raw->getSize());
        fp.valid = true;
        return fp;
    } catch (...) {
        fp.valid = false;
        return fp;
    }
}

/// Ersetzt in direkt besessenen Containern Referenzen auf Duplikate durch
/// das kanonische Objekt. Rekursion nur über direkte Container – indirekte
/// Objekte werden separat besucht; die Tiefe ist gekappt.
void dedup_redirect(QPDFObjectHandle container,
                    std::map<QPDFObjGen, QPDFObjectHandle> const& canonical,
                    int depth)
{
    if (depth > 64) { return; }
    if (container.isDictionary()) {
        // Benannte Kopie der Schlüssel: (a) überlebt replaceKey während des
        // Laufs, (b) Iteration über das getKeys()-Temporary selbst ist auf
        // dieser Toolchain nicht haltbar (Baum-Zugriff auf toten Speicher).
        std::set<std::string> const keys = container.getKeys();
        for (auto const& key : keys) {
            QPDFObjectHandle value = container.getKey(key);
            if (value.isNull()) { continue; }
            if (value.isIndirect()) {
                auto it = canonical.find(value.getObjGen());
                if (it != canonical.end()) { container.replaceKey(key, it->second); }
                continue;
            }
            if (value.isDictionary() || value.isArray()) {
                dedup_redirect(value, canonical, depth + 1);
            }
        }
    } else if (container.isArray()) {
        int n = container.getArrayNItems();
        for (int i = 0; i < n; ++i) {
            QPDFObjectHandle value = container.getArrayItem(i);
            if (value.isNull()) { continue; }
            if (value.isIndirect()) {
                auto it = canonical.find(value.getObjGen());
                if (it != canonical.end()) { container.setArrayItem(i, it->second); }
                continue;
            }
            if (value.isDictionary() || value.isArray()) {
                dedup_redirect(value, canonical, depth + 1);
            }
        }
    }
}

/// Objekte des Seitenbaums sammeln – sie werden nie zusammengeführt. Zwei
/// identische Page-Dicts gehören zu VERSCHIEDENEN Seiten; ein Merge würde
/// Seiten unterschlagen. Der Walk läuft über /Kids und deckt damit auch
/// Knoten ohne gültiges /Type ab.
void dedup_protect_page_tree(QPDFObjectHandle const& node,
                             std::set<QPDFObjGen>& out)
{
    if (node.isNull() || !node.isDictionary()) { return; }
    if (node.isIndirect()) { out.insert(node.getObjGen()); }
    QPDFObjectHandle kids = node.getKey("/Kids");
    if (kids.isArray()) {
        std::vector<QPDFObjectHandle> const children = kids.getArrayAsVector();
        for (auto const& kid : children) {
            dedup_protect_page_tree(kid, out);
        }
    }
}

} // namespace

int pdfcore_deduplicate_document(pdfcore_document_t *doc,
                                 pdfcore_dedup_stats_t *stats)
{
    if (!doc) { return PDFCORE_ERR_OPEN; }
    if (stats) {
        stats->merged_streams = 0;
        stats->merged_objects = 0;
        stats->estimated_bytes_saved = 0;
    }
    try {
        // Fallback: verschlüsselte Dokumente bleiben unangetastet.
        if (doc->qpdf.getTrailer().hasKey("/Encrypt")) { return PDFCORE_OK; }

        // Alle indirekten Objekte aufsteigend – die erste Begegnung eines
        // Schlüssels ist das kanonische Objekt (niedrigste Objektnummer).
        std::vector<QPDFObjectHandle> objects = doc->qpdf.getAllObjects();
        std::sort(objects.begin(), objects.end(),
                  [](QPDFObjectHandle const& a, QPDFObjectHandle const& b) {
                      QPDFObjGen ga = a.getObjGen();
                      QPDFObjGen gb = b.getObjGen();
                      if (ga.getObj() != gb.getObj()) {
                          return ga.getObj() < gb.getObj();
                      }
                      return ga.getGen() < gb.getGen();
                  });

        QPDFObjectHandle root = doc->qpdf.getRoot();
        std::set<QPDFObjGen> protectedObjects;
        if (root.isIndirect()) { protectedObjects.insert(root.getObjGen()); }
        dedup_protect_page_tree(root.getKey("/Pages"), protectedObjects);

        std::map<std::string, QPDFObjectHandle> canonicalByKey;
        std::map<QPDFObjGen, QPDFObjectHandle> canonicalByObjGen;
        int mergedStreams = 0;
        int mergedObjects = 0;
        long long savedBytes = 0;

        for (auto const& obj : objects) {
            QPDFObjGen og = obj.getObjGen();

            if (!obj.isStream()) {
                // Nur Dicts und Arrays – Skalare liegen praktisch immer
                // direkt und bräuchten keine Referenz.
                if (!obj.isDictionary() && !obj.isArray()) { continue; }
                // Katalog und Seitenbaum niemals anfassen (siehe oben).
                if (protectedObjects.count(og)) { continue; }
                if (obj.isDictionary()) {
                    // Formularfelder (/T) und Name-Tree-Knoten (/Names,
                    // /Limits, /Kids) haben dokumentspezifische Semantik –
                    // konservativ außen vor.
                    if (obj.hasKey("/T") || obj.hasKey("/Names")
                        || obj.hasKey("/Limits") || obj.hasKey("/Kids")) {
                        continue;
                    }
                }
                std::string serial;
                if (!dedup_canonical(obj, 0, serial, true)) { continue; }
                auto it = canonicalByKey.find(serial);
                if (it == canonicalByKey.end()) {
                    canonicalByKey.emplace(serial, obj);
                    continue;
                }
                canonicalByObjGen[og] = it->second;
                ++mergedObjects;
                savedBytes += static_cast<long long>(serial.size());
                continue;
            }

            // Streams: qpdf-Interna und JBIG2Globals-Kandidaten bleiben draußen.
            QPDFObjectHandle dict = obj.getDict();
            QPDFObjectHandle type = dict.getKey("/Type");
            std::string t = type.isName() ? type.getName() : std::string();
            if (t == "/ObjStm" || t == "/XRef") { continue; }
            if (dedup_has_jbig2_globals(dict)) { continue; }

            dedup_stream_fingerprint fp = dedup_fingerprint_stream(obj);
            std::string dictPart;
            if (!fp.valid || !dedup_stream_dict_part(dict, dictPart)) { continue; }

            std::string key = fp.decoded
                ? "D|" + fp.hash + "|" + dictPart
                : "R|" + fp.filterPart + "|" + fp.hash + "|" + dictPart;
            auto it = canonicalByKey.find(key);
            if (it == canonicalByKey.end()) {
                canonicalByKey.emplace(key, obj);
                continue;
            }
            canonicalByObjGen[og] = it->second;
            ++mergedStreams;
            savedBytes += fp.rawSize;
        }

        if (!canonicalByObjGen.empty()) {
            // Referenzen über alle Objekte und den Trailer umbiegen. Der
            // Writer verwirft anschließend die verwaisten Objekte.
            for (auto const& obj : objects) {
                dedup_redirect(obj, canonicalByObjGen, 0);
            }
            dedup_redirect(doc->qpdf.getTrailer(), canonicalByObjGen, 0);
        }

        if (stats) {
            stats->merged_streams = mergedStreams;
            stats->merged_objects = mergedObjects;
            stats->estimated_bytes_saved = savedBytes;
        }
        return PDFCORE_OK;
    } catch (const QPDFExc&) {
        return PDFCORE_ERR_CHECK_FAILED;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Phase 5a (Roadmap) – Font-Attribution, Font-Dedup, Unused-Font-GC.
//
// Merge-Dokumente tragen denselben Font mehrfach als getrennte Objekte;
// der Document-Dedup fasst sie nicht zusammen, weil ihre /ToUnicode-,
// /FontDescriptor- und /FontFile-Referenzen auf VERSCHIEDENE Objektnummern
// zeigen. Dieser Pass vergleicht stattdessen die SEMANTISCHE Form: Der
// FontFile-Programmstrom per SHA-256 (dekodierte Bytes), der Rest des Dicts
// inline serialisiert – gleiche Inhalte gelten damit über verschiedene
// Objektnummern hinweg als gleich. Danach beräumt die GC Font-Einträge, die
// kein Tf ihres Contents je benutzt. Beides verlustfrei: Es wird kein Byte
// neu kodiert, nur umgehängt und aus Resources-Maps getragen; verwaiste
// Objekte verwirft der Writer. Die Regeln sind bewusst konservativ – was
// nicht sicher vergleichbar oder vollständig scanbar ist, bleibt getrennt.
// ============================================================================

namespace {

bool font5_is_font_dict(QPDFObjectHandle const& obj)
{
    if (!obj.isDictionary()) { return false; }
    QPDFObjectHandle type = obj.getKey("/Type");
    return type.isName() && type.getName() == "/Font";
}

/// FontDescriptor eines Font-Dicts – bei Type0 über /DescendantFonts[0].
QPDFObjectHandle font5_descriptor_of(QPDFObjectHandle const& dict)
{
    QPDFObjectHandle desc = dict.getKey("/FontDescriptor");
    if (desc.isDictionary()) { return desc; }
    QPDFObjectHandle kids = dict.getKey("/DescendantFonts");
    if (kids.isArray()) {
        std::vector<QPDFObjectHandle> const entries = kids.getArrayAsVector();
        for (auto const& entry : entries) {
            QPDFObjectHandle d = entry.getKey("/FontDescriptor");
            if (d.isDictionary()) { return d; }
        }
    }
    return QPDFObjectHandle::newNull();
}

/// FontFile-/FontFile2-/FontFile3-Programmstrom (oder Null).
QPDFObjectHandle font5_file_stream(QPDFObjectHandle const& dict)
{
    QPDFObjectHandle desc = font5_descriptor_of(dict);
    if (desc.isNull()) { return QPDFObjectHandle::newNull(); }
    for (char const* key : { "/FontFile", "/FontFile2", "/FontFile3" }) {
        QPDFObjectHandle file = desc.getKey(key);
        if (file.isStream()) { return file; }
    }
    return QPDFObjectHandle::newNull();
}

/// Dekodierte Stream-Bytes (alle Filter aufgelöst). false = nicht sicher
/// lesbar – Verbraucher mit solchen Streams gelten als unscanbar.
bool font5_stream_bytes(QPDFObjectHandle stream, std::string& out)
{
    try {
        Pl_Buffer collector("font5");
        if (!stream.pipeStreamData(&collector, nullptr, 0, qpdf_dl_all,
                                   /*suppress_warnings=*/true, false)) {
            return false;
        }
        std::shared_ptr<Buffer> b(collector.getBuffer());
        if (!b) { return false; }
        out.assign(reinterpret_cast<char const*>(b->getBuffer()), b->getSize());
        return true;
    } catch (...) {
        return false;
    }
}

/// V2-8 – Dekodierte CONTENT-Bytes nur bei vollständig auflösbarer
/// Filterkette. Wichtig: qpdf pipeStreamData meldet für NICHT auflösbare
/// Filter (fremde Namen, Bildcodecs) trotzdem Erfolg und liefert die ROHEN
/// Bytes – ein Scan über komprimiertem Müll würde jede Benutzung verlieren
/// und die GC/das Subsetting würden Glyphen tilgen, die längst benutzt
/// werden. Nur die Inhaltsfilter, die qpdf wirklich dekodiert, gelten als
/// scanbar; alles andere macht den Verbraucher konservativ unscanbar.
bool font6_content_stream_bytes(QPDFObjectHandle stream, std::string& out)
{
    QPDFObjectHandle filter = stream.getDict().getKey("/Filter");
    std::vector<std::string> names;
    if (filter.isName()) {
        names.push_back(filter.getName());
    } else if (filter.isArray()) {
        for (auto const& item : filter.getArrayAsVector()) {
            if (!item.isName()) { return false; }
            names.push_back(item.getName());
        }
    } else if (!filter.isNull()) {
        return false;
    }
    for (auto const& name : names) {
        if (!(name == "/FlateDecode" || name == "/LZWDecode"
              || name == "/ASCIIHexDecode" || name == "/ASCII85Decode"
              || name == "/RunLengthDecode")) {
            return false;
        }
    }
    return font5_stream_bytes(stream, out);
}

/// Budget der V2-5-Konkatenation (§11.7-Fix): Die /Contents-Streams eines
/// Verbrauchers werden ZUSAMMEN gescannt (Tf-Nutzung darf über Array-Grenzen
/// geteilt sein – statab_2012). Der Wert deckelt den Spitzenverbrauch und
/// folgt den bestehenden Pass-Budgets (Zopfli-Inhalte 64 MB, CandidateStore
/// 64 MB): Seiteninhalte dieser Größenklasse sind real Vektor-Extremfälle,
/// für die die GC dann konservativ unberäumt bleibt.
size_t const font5_concat_budget_bytes = 64 * 1024 * 1024;

/// Semantische Serialisierung eines Font-Dicts. Der Unterschied zum
/// Document-Dedup: Indirekte Dicts und Arrays (Encoding, FontDescriptor,
/// DescendantFonts, CIDSystemInfo) werden INHALTLICH eingebettet, Streams
/// (ToUnicode, CIDToGIDMap, FontFile) durch ihren dekodierten Byte-Hash
/// vertreten – gleiche Inhalte gelten damit über verschiedene Objektnummern
/// hinweg als gleich. Alles andere folgt der kanonischen Form; Tiefe und
/// unbekannte Typen brechen ab (dann bleibt der Font unangetastet).
bool font5_serial(QPDFObjectHandle const& value, std::string& out, int depth)
{
    if (depth > 16) { return false; }
    if (value.isNull()) { out += "N;"; return true; }
    if (value.isBool()) { out += value.getBoolValue() ? "B1;" : "B0;"; return true; }
    if (value.isInteger()) {
        out += "I" + std::to_string(value.getIntValue()) + ";";
        return true;
    }
    if (value.isReal()) { out += "F" + value.getRealValue() + ";"; return true; }
    if (value.isName()) {
        std::string const& name = value.getName();
        out += "n" + std::to_string(name.size()) + ":" + name + ";";
        return true;
    }
    if (value.isString()) {
        std::string const& s = value.getStringValue();
        out += "s" + std::to_string(s.size()) + ":" + s + ";";
        return true;
    }
    if (value.isStream()) {
        // FontFile, /ToUnicode, CIDToGIDMap-Strom: der Inhalt zählt, nicht
        // die Verpackung.
        dedup_stream_fingerprint fp = dedup_fingerprint_stream(value);
        if (!fp.valid) { return false; }
        out += fp.decoded ? "SD|" : "SR|";
        out += fp.hash + ";";
        return true;
    }
    if (value.isArray()) {
        out += "A[";
        for (auto const& item : value.getArrayAsVector()) {
            if (!font5_serial(item, out, depth + 1)) { return false; }
        }
        out += "]";
        return true;
    }
    if (value.isDictionary()) {
        // getKeys() liefert sortierte Schlüssel – gleiche Dicts serialisieren
        // gleich (Muster wie im Document-Dedup).
        std::set<std::string> const keys = value.getKeys();
        out += "D{";
        for (auto const& key : keys) {
            out += key;
            if (!font5_serial(value.getKey(key), out, depth + 1)) { return false; }
        }
        out += "}";
        return true;
    }
    // Restliche indirekte Referenzen (Skalare): bei ihrer Objektnummer
    // bleiben – zwei Werte, die auf verschiedene Objekte zeigen, gelten
    // als verschieden.
    if (value.isIndirect()) {
        out += "R" + std::to_string(value.getObjectID())
             + ":" + std::to_string(value.getGeneration()) + ";";
        return true;
    }
    return false;
}

// --- Erreichbarkeit und Tf-Benutzung ---------------------------------------

struct font5_bucket {
    /// Die /Font-Subdicts dieses Buckets – bei indirekten Maps genau eines,
    /// bei direkten (je Verbraucher eigenen) alle Kopien mit gleichem Inhalt.
    std::vector<QPDFObjectHandle> maps;
    std::set<std::string> usedNames;
    bool allScanned = true;
};

struct font5_walk {
    std::map<std::string, font5_bucket> buckets;
    /// Bekannte Referenzierungen je Font-Objekt – Basis der Schätzung: Erst
    /// wenn ALLE entfernt wurden, ist das Programm wirklich verwaist.
    std::map<QPDFObjGen, int> bindings;
    std::set<QPDFObjGen> protectedFonts;   // /AcroForm/DR
    std::set<QPDFObjGen> type3Seen;
    std::vector<QPDFObjectHandle> type3Queue;
    /// Tf-Namen je Form-XObject mit eigenen /Resources (Cache): Mehrfach-
    /// aufrufer bekommen dieselben Namen gespiegelt, ohne den Content
    /// erneut zu dekodieren.
    std::map<QPDFObjGen, std::set<std::string>> formNames;
};

/// Registriert eine /Font-Map unter ihrer Identität: indirekt nach ObjGen,
/// direkt nach kanonischem Serial (gleiche Inhalte teilen den Bucket –
/// Benutzung wird über alle Verbraucher vereinigt, Removal erfolgt je Kopie).
std::string font5_bucket_key(QPDFObjectHandle const& fontMap, bool* ok)
{
    *ok = true;
    if (fontMap.isIndirect()) {
        return "I:" + std::to_string(fontMap.getObjectID())
             + ":" + std::to_string(fontMap.getGeneration());
    }
    std::string serial;
    if (!dedup_canonical(fontMap, 0, serial, true)) {
        *ok = false;
        return std::string();
    }
    return "S:" + serial;
}

/// Trägt eine Font-Map in ihren Bucket ein: Bindings zählen, Type3-Fonts
/// landen im Schutz-Queue.
void font5_register_map(QPDFObjectHandle const& fontMap, font5_walk& w)
{
    std::set<std::string> const keys = fontMap.getKeys();
    for (auto const& name : keys) {
        QPDFObjectHandle value = fontMap.getKey(name);
        if (!value.isIndirect()) { continue; }
        QPDFObjGen og = value.getObjGen();
        w.bindings[og] += 1;
        if (w.protectedFonts.count(og) || w.type3Seen.count(og)) { continue; }
        if (font5_is_font_dict(value)) {
            QPDFObjectHandle subtype = value.getKey("/Subtype");
            if (subtype.isName() && subtype.getName() == "/Type3") {
                // Type3: Glyphenprozeduren nutzen Font-Ressourcen auf eigene
                // Weise – solche Fonts werden nie beräumt, aber ihre
                // /Resources mit den CharProcs gescannt.
                w.type3Seen.insert(og);
                w.type3Queue.push_back(value);
            }
        }
    }
}

/// Inline-Bild überspringen (2026-10-15, NASA-Bericht Seite 7): Nach `BI`
/// folgt ein Dict, dann `ID`, EIN Whitespace und Binärdaten bis `EI`. Die
/// Binärdaten enthalten alles – „(", „%", „<<" –, und die Token-Scanner
/// lasen sie als Literal-String oder Kommentar und verloren jede Referenz
/// dahinter (8 519 CCITT-Stencils, Schriften und ein XObject beräumt, die
/// Seite verlor Text). `i` steht hinter `BI`; bei Erfolg hinter `EI`.
///
/// `EI` gilt nur, wenn davor Whitespace steht, dahinter Whitespace/EOF und
/// die nächsten Bytes wie Operatoren aussehen (druckbares ASCII): Ein
/// zufälliges „ EI " in Binärdaten geht sonst als Ende durch. Ohne gültiges
/// `EI` bleibt `i` auf dem Ende – konservativer als Binärdaten zu deuten.
static bool pdfcore_skip_inline_image(std::string const& bytes, size_t& i)
{
    size_t const n = bytes.size();
    auto isWS = [](unsigned char c) {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
            || c == 0;
    };
    auto isDelim = [&](unsigned char c) {
        return isWS(c) || c == '/' || c == '[' || c == ']' || c == '<'
            || c == '>' || c == '(' || c == ')' || c == '{' || c == '}'
            || c == '%';
    };
    // Bis zum Operator `ID` (eigenes Token).
    size_t p = i;
    bool found = false;
    while (p + 1 < n) {
        if (bytes[p] == 'I' && bytes[p + 1] == 'D'
            && (p == 0 || isDelim(static_cast<unsigned char>(bytes[p - 1])))
            && (p + 2 >= n || isWS(static_cast<unsigned char>(bytes[p + 2])))) {
            found = true;
            break;
        }
        ++p;
    }
    if (!found) { i = n; return false; }
    p += 2;
    if (p < n) { ++p; }   // genau ein Whitespace vor den Daten
    while (p + 1 < n) {
        if (bytes[p] == 'E' && bytes[p + 1] == 'I'
            && isWS(static_cast<unsigned char>(bytes[p - 1]))
            && (p + 2 >= n || isDelim(static_cast<unsigned char>(bytes[p + 2])))) {
            bool plausible = true;
            size_t const probeEnd = std::min(n, p + 2 + 24);
            for (size_t q = p + 2; q < probeEnd; ++q) {
                unsigned char c = static_cast<unsigned char>(bytes[q]);
                if (!(isWS(c) || (c >= 0x20 && c <= 0x7e))) {
                    plausible = false;
                    break;
                }
            }
            if (plausible) { i = p + 2; return true; }
        }
        ++p;
    }
    i = n;
    return false;
}

// Vorwärtsdeklaration – Form-XObjects rekursieren.
bool font5_walk_consumer(std::vector<QPDFObjectHandle> const& contents,
                         QPDFObjectHandle const& resources,
                         font5_walk& w, int depth,
                         std::vector<std::set<std::string>*>* mirror,
                         std::set<std::string>* collected);

/// Tokenisiert Content-Bytes: /Name … Tf → benutzter Ressourcenname;
/// /Name … Do → Form-XObject wird als eigener Verbraucher gegangen.
///
/// `mirror` trägt die Mengen OBERGEORDNETER Scopes mit: Ein Name, den ein
/// Form-XObject per Tf belegt, belegt denselben Namen im Namensraum des
/// Aufrufers mit (nicht-konforme Writer lösen Form-Fonts über die
/// Seitenressourcen auf). Überprotection ist hier die sichere Richtung.
void font5_scan_tokens(std::string const& bytes,
                       QPDFObjectHandle const& resources,
                       std::set<std::string>& usedNames,
                       std::vector<std::set<std::string>*>* mirror,
                       font5_walk& w, int depth)
{
    size_t i = 0;
    size_t const n = bytes.size();
    std::string lastName;
    while (i < n) {
        unsigned char ch = static_cast<unsigned char>(bytes[i]);
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f'
            || ch == 0) {
            ++i;
            continue;
        }
        if (ch == '%') {
            while (i < n && bytes[i] != '\n' && bytes[i] != '\r') { ++i; }
            continue;
        }
        if (ch == '/') {
            size_t start = ++i;
            while (i < n) {
                unsigned char c = static_cast<unsigned char>(bytes[i]);
                bool delim = (c == ' ' || c == '\t' || c == '\n' || c == '\r'
                    || c == '\f' || c == 0 || c == '/' || c == '(' || c == ')'
                    || c == '<' || c == '>' || c == '[' || c == ']' || c == '{'
                    || c == '}' || c == '%');
                if (delim) { break; }
                ++i;
            }
            // Ressourcen-Map-Schlüssel tragen den führenden Slash.
            lastName = "/" + bytes.substr(start, i - start);
            continue;
        }
        if (ch == '(') {
            // Literal-String mit Verschachtelung und Escapes überspringen.
            int stringDepth = 1;
            ++i;
            while (i < n && stringDepth > 0) {
                char c = bytes[i];
                if (c == '\\') { i += 2; continue; }
                if (c == '(') { ++stringDepth; }
                else if (c == ')') { --stringDepth; }
                ++i;
            }
            continue;
        }
        if (ch == '<') {
            if (i + 1 < n && bytes[i + 1] == '<') {
                // Dict überspringen – er ist nie Operand eines Tf.
                int dictDepth = 1;
                i += 2;
                while (i < n && dictDepth > 0) {
                    if (bytes[i] == '<' && i + 1 < n && bytes[i + 1] == '<') {
                        ++dictDepth; i += 2;
                    } else if (bytes[i] == '>' && i + 1 < n
                               && bytes[i + 1] == '>') {
                        --dictDepth; i += 2;
                    } else { ++i; }
                }
                continue;
            }
            while (i < n && bytes[i] != '>') { ++i; }
            if (i < n) { ++i; }
            continue;
        }
        if (ch == '>' || ch == '[' || ch == ']' || ch == '{' || ch == '}') {
            ++i;
            continue;
        }
        if ((ch >= '0' && ch <= '9') || ch == '+' || ch == '-' || ch == '.') {
            while (i < n) {
                char c = bytes[i];
                if ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'
                    || c == 'e' || c == 'E') {
                    ++i;
                } else {
                    break;
                }
            }
            continue;
        }
        if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')
            || ch == '\'' || ch == '"' || ch == '*') {
            size_t start = i;
            while (i < n) {
                char c = bytes[i];
                bool tokenChar = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                    || (c >= '0' && c <= '9') || c == '*' || c == '\''
                    || c == '"' || static_cast<unsigned char>(c) >= 128;
                if (!tokenChar) { break; }
                ++i;
            }
            std::string op = bytes.substr(start, i - start);
            if (op == "BI") {
                pdfcore_skip_inline_image(bytes, i);
                lastName.clear();
                continue;
            }
            if (op == "Tf" && !lastName.empty()) {
                // Ein Name vor Tf belegt die Font-Ressource – konservativ
                // genügt jede Begegnung, Scoping-Fehler gehen Richtung
                // „benutzt“ und schützen den Eintrag.
                usedNames.insert(lastName);
                if (mirror) {
                    for (auto* set : *mirror) { set->insert(lastName); }
                }
            } else if (op == "Do" && !lastName.empty()) {
                // Form-XObject auflösen und als eigenen Verbraucher gehen.
                if (depth < 16 && !resources.isNull() && resources.isDictionary()) {
                    QPDFObjectHandle xobjects = resources.getKey("/XObject");
                    if (xobjects.isDictionary()) {
                        QPDFObjectHandle form = xobjects.getKey(lastName);
                        if (form.isStream()) {
                            QPDFObjectHandle subtype = dict_of(form).getKey("/Subtype");
                            if (subtype.isName() && subtype.getName() == "/Form") {
                                QPDFObjectHandle own = dict_of(form).getKey("/Resources");
                                bool hasOwn = !own.isNull() && own.isDictionary();
                                QPDFObjGen fog = form.getObjGen();
                                if (!hasOwn) {
                                    // Ohne eigene Ressourcen hängt der
                                    // Namensraum am Aufrufer: gegen DIESEN
                                    // Stand scannen (kein Cache möglich).
                                    std::vector<std::set<std::string>*> none;
                                    std::vector<QPDFObjectHandle> one = { form };
                                    font5_walk_consumer(one, resources, w,
                                                        depth + 1, &none, nullptr);
                                } else {
                                    auto cached = w.formNames.find(fog);
                                    if (cached != w.formNames.end()) {
                                        // Zweitaufrufer: die bekannten Namen
                                        // in den eigenen Scope und die
                                        // Aufruferkette spiegeln.
                                        usedNames.insert(cached->second.begin(),
                                                         cached->second.end());
                                        if (mirror) {
                                            for (auto* set : *mirror) {
                                                set->insert(cached->second.begin(),
                                                            cached->second.end());
                                            }
                                        }
                                    } else {
                                        std::vector<std::set<std::string>*>
                                            childMirror;
                                        if (mirror) { childMirror = *mirror; }
                                        childMirror.push_back(&usedNames);
                                        std::set<std::string> collected;
                                        std::vector<QPDFObjectHandle> one = { form };
                                        font5_walk_consumer(one, own, w, depth + 1,
                                                            &childMirror, &collected);
                                        // Auch bei Scan-Fehlern cachen –
                                        // unvollständige Namen schützen nur
                                        // zu viel, nie zu wenig.
                                        w.formNames.emplace(fog, std::move(collected));
                                    }
                                }
                            }
                        }
                    }
                }
            }
            lastName.clear();
            continue;
        }
        ++i;
    }
}

/// Geht die Content-Streams eines Verbrauchers gegen seine (bereits
/// aufgelösten, ggf. geerbten) Ressourcen. Liefert false, wenn ein Content
/// nicht vollständig dekodiert werden konnte – der Bucket bleibt dann
/// unberäumt (konservativ). `collected` (optional) erhält alle Tf-Namen
/// dieses Verbrauchers – Basis des Form-Namenscaches.
bool font5_walk_consumer(std::vector<QPDFObjectHandle> const& contents,
                         QPDFObjectHandle const& resources,
                         font5_walk& w, int depth,
                         std::vector<std::set<std::string>*>* mirror,
                         std::set<std::string>* collected)
{
    if (depth > 16) { return false; }
    QPDFObjectHandle fontMap;
    if (!resources.isNull() && resources.isDictionary()) {
        fontMap = resources.getKey("/Font");
    }
    bool hasMap = !fontMap.isNull() && fontMap.isDictionary();
    std::set<std::string> usedNames;
    bool scanned = true;
    if (hasMap) {
        // V2-5-Fix (§11.7, statab_2012): Die Contents-Streams einer Seite
        // bzw. Form bilden laut PDF 32000 EINEN logischen Content – Token
        // dürfen Operand und Operator über ARRAY-Grenzen tragen. Der frühere
        // Scan je Eintrag verlor den Namen am Ende von Stream k und sah
        // „1 Tf" am Anfang von Stream k+1 ohne Namen: Die Nutzung einer
        // Schrift wurde nicht erkannt, die GC trug sie zu Recht Nicht-.
        //
        // Deshalb: KONKATENATION aller Streams mit Trenn-Byte (Leerzeichen),
        // damit Token nicht über die Grenze verschmelzen. Schlägt ein Stream
        // fehl oder sprengt die Summe das Budget, gilt der Verbraucher als
        // unscanbar (konservativ: seine Map bleibt unberäumt) – gescannt
        // wird der zusammenhängende Teil trotzdem, Überprotection ist die
        // sichere Richtung.
        std::string bytes;
        for (auto const& stream : contents) {
            std::string part;
            if (!stream.isStream() || !font5_stream_bytes(stream, part)) {
                scanned = false;
                continue;
            }
            if (part.empty()) { continue; }
            if (!bytes.empty()) { bytes.push_back(' '); }
            if (bytes.size() + part.size() > font5_concat_budget_bytes) {
                scanned = false;
                break;
            }
            bytes += part;
        }
        if (!bytes.empty()) {
            font5_scan_tokens(bytes, resources, usedNames, mirror, w, depth);
        }
    }
    if (hasMap) {
        bool ok = false;
        std::string key = font5_bucket_key(fontMap, &ok);
        if (ok) {
            if (w.buckets.find(key) == w.buckets.end()) {
                font5_bucket fresh;
                w.buckets.emplace(key, std::move(fresh));
            }
            font5_bucket& bucket = w.buckets[key];
            // Dieselbe Map darf mehrfach begegnen (direkte Kopien mit gleichem
            // Serial, in-memory geteilte Handles) – nur einmal eintragen.
            bool alreadyListed = false;
            for (auto const& listed : bucket.maps) {
                if (listed.isSameObjectAs(fontMap)) {
                    alreadyListed = true;
                    break;
                }
            }
            if (!alreadyListed) {
                bucket.maps.push_back(fontMap);
                font5_register_map(fontMap, w);
            }
            bucket.allScanned = bucket.allScanned && scanned;
            bucket.usedNames.insert(usedNames.begin(), usedNames.end());
        }
    }
    if (collected) { *collected = usedNames; }
    return scanned;
}

/// Effektive /Resources einer Seite inklusive Vererbung über /Parent.
QPDFObjectHandle font5_inherited_resources(QPDFObjectHandle const& page)
{
    QPDFObjectHandle node = page;
    for (int i = 0; i < 64 && !node.isNull() && node.isDictionary(); ++i) {
        QPDFObjectHandle res = node.getKey("/Resources");
        if (!res.isNull()) { return res; }
        node = node.getKey("/Parent");
    }
    return QPDFObjectHandle::newNull();
}

/// Alle /Contents-Streams einer Seite.
std::vector<QPDFObjectHandle> font5_page_contents(QPDFObjectHandle const& page)
{
    std::vector<QPDFObjectHandle> out;
    QPDFObjectHandle c = page.getKey("/Contents");
    if (c.isStream()) {
        out.push_back(c);
    } else if (c.isArray()) {
        for (auto const& item : c.getArrayAsVector()) {
            if (item.isStream()) { out.push_back(item); }
        }
    }
    return out;
}

} // namespace

int pdfcore_font_audit(pdfcore_document_t *doc,
                       pdfcore_font_audit_stats_t *stats)
{
    if (!doc) { return PDFCORE_ERR_OPEN; }
    if (stats) {
        stats->font_objects = 0;
        stats->font_file_streams = 0;
        stats->duplicate_font_refs_removed = 0;
        stats->unused_fonts_removed = 0;
        stats->estimated_bytes_saved = 0;
    }
    try {
        // Fallback: verschlüsselte Dokumente bleiben unangetastet.
        if (doc->qpdf.getTrailer().hasKey("/Encrypt")) { return PDFCORE_OK; }

        std::vector<QPDFObjectHandle> objects = doc->qpdf.getAllObjects();
        std::sort(objects.begin(), objects.end(),
                  [](QPDFObjectHandle const& a, QPDFObjectHandle const& b) {
                      QPDFObjGen ga = a.getObjGen();
                      QPDFObjGen gb = b.getObjGen();
                      if (ga.getObj() != gb.getObj()) {
                          return ga.getObj() < gb.getObj();
                      }
                      return ga.getGen() < gb.getGen();
                  });

        // --- 1. Inventar + Dedup -------------------------------------------
        // Aufsteigend: die erste Begegnung eines semantischen Schlüssels ist
        // das kanonische Objekt (niedrigste Objektnummer).
        std::map<std::string, QPDFObjectHandle> canonicalByKey;
        std::map<QPDFObjGen, QPDFObjectHandle> canonicalByObjGen;
        std::map<QPDFObjGen, long long> fileRawSizeByOg;
        std::map<QPDFObjGen, QPDFObjGen> fileByFontDict;
        std::set<QPDFObjGen> fileStreams;
        // Ein FontFile kann über mehrere Dicts (Type0 + DescendantFonts)
        // verwaisten – in die Schätzung zählt es trotzdem nur EINMAL.
        std::set<QPDFObjGen> countedOrphanedFiles;
        int fontObjects = 0;
        long long savedBytes = 0;

        for (auto const& obj : objects) {
            try {
            if (!font5_is_font_dict(obj)) { continue; }
            ++fontObjects;
            if (!obj.isIndirect()) {
                // Direkte Font-Dicts können nicht umgehängt werden.
                continue;
            }
            QPDFObjectHandle subtype = obj.getKey("/Subtype");
            if (subtype.isName() && subtype.getName() == "/Type3") {
                // Type3-Fonts: Glyphenprozeduren und eingebettete
                // Resources sind zu speziell – nie anfassen.
                continue;
            }
            QPDFObjectHandle file = font5_file_stream(obj);
            if (!file.isNull()) {
                QPDFObjGen fog = file.getObjGen();
                fileByFontDict[obj.getObjGen()] = fog;
                if (fileStreams.insert(fog).second) {
                    std::shared_ptr<Buffer> raw = file.getRawStreamData();
                    fileRawSizeByOg[fog] =
                        raw ? static_cast<long long>(raw->getSize()) : 0;
                }
            }
            std::string key;
            if (!font5_serial(obj, key, 0)) { continue; }
            auto it = canonicalByKey.find(key);
            if (it == canonicalByKey.end()) {
                canonicalByKey.emplace(key, obj);
                continue;
            }
            canonicalByObjGen[obj.getObjGen()] = it->second;
            // Das Programm des Duplikats wird beim Schreiben verwaisten –
            // seine rohe Größe ist die Schätzbasis.
            QPDFObjectHandle dupFile = font5_file_stream(obj);
            if (!dupFile.isNull()
                && countedOrphanedFiles.insert(dupFile.getObjGen()).second) {
                auto size = fileRawSizeByOg.find(dupFile.getObjGen());
                if (size != fileRawSizeByOg.end()) {
                    savedBytes += size->second;
                }
            }
            } catch (const std::exception& e) {
                throw;
            }
        }
        if (stats) {
            stats->font_objects = fontObjects;
            stats->font_file_streams = static_cast<int>(fileStreams.size());
        }

        if (!canonicalByObjGen.empty()) {
            // Referenzen über alle Objekte und den Trailer umbiegen (Muster
            // wie im Document-Dedup); der Writer verwirft die Verwaisten.
            for (auto const& obj : objects) {
                dedup_redirect(obj, canonicalByObjGen, 0);
            }
            dedup_redirect(doc->qpdf.getTrailer(), canonicalByObjGen, 0);
            if (stats) {
                stats->duplicate_font_refs_removed =
                    static_cast<int>(canonicalByObjGen.size());
            }
        }

        // --- 2. Erreichbarkeit + Tf-Benutzung -------------------------------
        font5_walk w;

        // /AcroForm/DR: Feld-DA-Strings nutzen diese Fonts ohne Seitenevent –
        // sie bleiben grundsätzlich stehen.
        QPDFObjectHandle root = doc->qpdf.getRoot();
        QPDFObjectHandle acro = root.getKey("/AcroForm");
        if (acro.isDictionary()) {
            QPDFObjectHandle dr = acro.getKey("/DR");
            if (dr.isDictionary()) {
                QPDFObjectHandle fm = dr.getKey("/Font");
                if (fm.isDictionary()) {
                    std::set<std::string> const keys = fm.getKeys();
                    for (auto const& name : keys) {
                        QPDFObjectHandle value = fm.getKey(name);
                        if (value.isIndirect()) {
                            w.protectedFonts.insert(value.getObjGen());
                        }
                    }
                }
            }
        }

        // Seiten: Contents (inkl. Vererbung), Annotations-Appearances.
        std::vector<QPDFPageObjectHelper> pages =
            QPDFPageDocumentHelper(doc->qpdf).getAllPages();
        for (auto const& ph : pages) {
            QPDFObjectHandle page = ph.getObjectHandle();
            QPDFObjectHandle resources = font5_inherited_resources(page);
            if (!resources.isNull() && !resources.isDictionary()) {
                resources = QPDFObjectHandle::newNull();
            }
            font5_walk_consumer(font5_page_contents(page), resources, w, 0,
                                nullptr, nullptr);

            QPDFObjectHandle annots = page.getKey("/Annots");
            if (!annots.isArray()) { continue; }
            for (auto const& annot : annots.getArrayAsVector()) {
                if (!annot.isDictionary()) { continue; }
                QPDFObjectHandle ap = annot.getKey("/AP");
                if (!ap.isDictionary()) { continue; }
                for (char const* key : { "/N", "/D", "/R" }) {
                    QPDFObjectHandle appearance = ap.getKey(key);
                    std::vector<QPDFObjectHandle> streams;
                    if (appearance.isStream()) {
                        streams.push_back(appearance);
                    } else if (appearance.isArray()) {
                        for (auto const& item : appearance.getArrayAsVector()) {
                            if (item.isStream()) { streams.push_back(item); }
                        }
                    }
                    for (auto const& stream : streams) {
                        QPDFObjectHandle own = dict_of(stream).getKey("/Resources");
                        if (!own.isNull() && !own.isDictionary()) {
                            own = QPDFObjectHandle::newNull();
                        }
                        if (own.isNull()) { own = resources; }
                        std::vector<QPDFObjectHandle> one = { stream };
                        font5_walk_consumer(one, own, w, 1, nullptr, nullptr);
                    }
                }
            }
        }

        // Type3-CharProcs: ihre Tf-Namen belegen die Ressourcen DES TYPE3.
        while (!w.type3Queue.empty()) {
            QPDFObjectHandle t3 = w.type3Queue.back();
            w.type3Queue.pop_back();
            QPDFObjectHandle res = t3.getKey("/Resources");
            if (!res.isNull() && !res.isDictionary()) { res = QPDFObjectHandle::newNull(); }
            std::vector<QPDFObjectHandle> charProcs;
            QPDFObjectHandle cp = t3.getKey("/CharProcs");
            if (cp.isDictionary()) {
                std::set<std::string> const keys = cp.getKeys();
                for (auto const& name : keys) {
                    QPDFObjectHandle proc = cp.getKey(name);
                    if (proc.isStream()) { charProcs.push_back(proc); }
                }
            }
            font5_walk_consumer(charProcs, res, w, 1, nullptr, nullptr);
        }

        // --- 3. GC: unbenutzte Einträge aus den Font-Maps tragen ------------
        int removedEntries = 0;
        for (auto& entry : w.buckets) {
            font5_bucket& bucket = entry.second;
            if (!bucket.allScanned) { continue; }
            for (auto& fontMap : bucket.maps) {
                if (!fontMap.isDictionary()) { continue; }
                // Benannte Kopie der Schlüssel: removeKey während des Laufs
                // (Muster wie im Document-Dedup).
                std::set<std::string> const keys = fontMap.getKeys();
                for (auto const& name : keys) {
                    if (bucket.usedNames.count(name)) { continue; }
                    QPDFObjectHandle value = fontMap.getKey(name);
                    if (!value.isIndirect()) {
                        // Nur Referenzen werden beräumt – direkte Dicts
                        // bleiben (konservativ).
                        continue;
                    }
                    QPDFObjGen og = value.getObjGen();
                    if (w.protectedFonts.count(og)) { continue; }
                    if (!font5_is_font_dict(value)) { continue; }
                    QPDFObjectHandle subtype = value.getKey("/Subtype");
                    if (subtype.isName() && subtype.getName() == "/Type3") {
                        continue;
                    }
                    fontMap.removeKey(name);
                    ++removedEntries;
                    auto binding = w.bindings.find(og);
                    if (binding != w.bindings.end()
                        && --(binding->second) == 0) {
                        // Erst wenn ALLE Referenzierungen entfernt sind, ist
                        // das Programm wirklich verwaist.
                        auto fileOg = fileByFontDict.find(og);
                        if (fileOg != fileByFontDict.end()
                            && countedOrphanedFiles.insert(fileOg->second).second) {
                            auto size = fileRawSizeByOg.find(fileOg->second);
                            if (size != fileRawSizeByOg.end()) {
                                savedBytes += size->second;
                            }
                        }
                    }
                }
            }
        }

        if (stats) {
            stats->unused_fonts_removed = removedEntries;
            stats->estimated_bytes_saved = savedBytes;
        }
        return PDFCORE_OK;
    } catch (const QPDFExc&) {
        return PDFCORE_ERR_CHECK_FAILED;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Phase 5b (Roadmap) – Font-Subsetting über HarfBuzz hb-subset.
//
// Der Pass schreibt Fontprogramme neu und ist damit der riskanteste Eingriff
// der Pipeline. Alles folgt einer Whitelist: Nur Simple-TrueType-Fonts mit
// /FontFile2 und sauber auflösbarem Code→Unicode-Pfad sowie Type0-Fonts mit
// Identity-H/V, CIDFontType2-Nachfolger und /CIDToGIDMap Identity werden
// subsettet. Codes, /Encoding//Differences und /ToUnicode bleiben unverändert
// – nur die Glyphen im Programm verschwinden; /Widths bzw. /W werden auf die
// benutzten Codes eingedampft, FontFile2 ersetzt (/Length1 neu).
//
// Benutzung wird aus dem Content ermittelt (Tf-Kontext mit q/Q-Stack,
// Strings von Tj/TJ/'/"): Simple-Fonts sammeln Byte-Codes, Identity-H
// 2-Byte-CIDs (= GIDs). Unscanbarer Content, fehlende Benutzung oder
// unauflösbare Encodings führen dazu, dass der Font KOMPLETT bleibt.
//
// Subset-Konfiguration (dokumentierte Defaults von hb-subset 11.x): Hints
// bleiben (kein NO_HINTING), GSUB/GPOS/GDEF bleiben und werden auf die
// Default-Feature-Menge gekürzt (rvrn ccmp liga locl mark mkmk rlig frac
// numr dnom calt clig curs kern rclt valt vert vkrn vpal vrt2 ltra ltrm
// rtla rtlm rand jalt chws vchw halt vhal …), glyphtreue GIDs durch
// RETAIN_GIDS im CID-Fall, keine Namens-/CFF-Sonderbehandlung, recognized
// Layout-/AAT-Exotik (morx mort kerx kern JSTF DSIG EBDT EBLC EBSC SVG
// PCLT LTSH Graphite) fällt nach hb-Default weg – für PDF-Textfonts ohne
// Wirkung. retain-gids ist im Simple-Fall aus (kleiner), im Identity-H-Fall
// an (Pflicht: CID==GID).
// ============================================================================

namespace {

// --- Code→Unicode-Auflösung (Annex D / AGL) ---------------------------------

/// WinAnsiEncoding: Code → Unicode, 0 = im Encoding nicht belegt.
/// 0x20–0x7E und 0xA0–0xFF decken sich mit ASCII/Latin-1, 0x80–0x9F sind
/// die cp1252-Spezialitäten, 0x81/0x8D/0x8F/0x90/0x9D sind unbesetzt.
uint32_t font6_winansi_unicode(unsigned char code)
{
    if (code >= 0x20 && code <= 0x7E) { return code; }
    if (code >= 0xA0) { return code; }
    switch (code) {
    case 0x80: return 0x20AC; case 0x82: return 0x201A;
    case 0x83: return 0x0192; case 0x84: return 0x201E;
    case 0x85: return 0x2026; case 0x86: return 0x2020;
    case 0x87: return 0x2021; case 0x88: return 0x02C6;
    case 0x89: return 0x2030; case 0x8A: return 0x0160;
    case 0x8B: return 0x2039; case 0x8C: return 0x0152;
    case 0x8E: return 0x017D; case 0x91: return 0x2018;
    case 0x92: return 0x2019; case 0x93: return 0x201C;
    case 0x94: return 0x201D; case 0x95: return 0x2022;
    case 0x96: return 0x2013; case 0x97: return 0x2014;
    case 0x98: return 0x02DC; case 0x99: return 0x2122;
    case 0x9A: return 0x0161; case 0x9B: return 0x203A;
    case 0x9C: return 0x0153; case 0x9E: return 0x017E;
    case 0x9F: return 0x0178; default: return 0;
    }
}

/// AGL-empfohlene Glyphennamen → Unicode (Kompakttabelle: ASCII-Punktion,
/// Latin-1-Buchstaben, gebräuchliche Interpunktions-/Symboleinträge).
/// Namen außerhalb der Tabelle lassen den Font konservativ ganz bleiben.
struct font6_name_entry { char const* name; uint32_t unicode; };

uint32_t font6_agl_lookup(std::string const& name)
{
    static font6_name_entry const table[] = {
        {"space", 0x0020}, {"nbspace", 0x00A0}, {"exclam", 0x0021},
        {"quotedbl", 0x0022}, {"numbersign", 0x0023}, {"dollar", 0x0024},
        {"percent", 0x0025}, {"ampersand", 0x0026}, {"quotesingle", 0x0027},
        {"quoteright", 0x2019}, {"parenleft", 0x0028}, {"parenright", 0x0029},
        {"asterisk", 0x002A}, {"plus", 0x002B}, {"comma", 0x002C},
        {"hyphen", 0x002D}, {"period", 0x002E}, {"slash", 0x002F},
        {"colon", 0x003A}, {"semicolon", 0x003B}, {"less", 0x003C},
        {"equal", 0x003D}, {"greater", 0x003E}, {"question", 0x003F},
        {"at", 0x0040}, {"bracketleft", 0x005B}, {"backslash", 0x005C},
        {"bracketright", 0x005D}, {"asciicircum", 0x005E},
        {"underscore", 0x005F}, {"grave", 0x0060}, {"quoteleft", 0x2018},
        {"braceleft", 0x007B}, {"bar", 0x007C}, {"braceright", 0x007D},
        {"asciitilde", 0x007E},
        {"Agrave", 0x00C0}, {"Aacute", 0x00C1}, {"Acircumflex", 0x00C2},
        {"Atilde", 0x00C3}, {"Adieresis", 0x00C4}, {"Aring", 0x00C5},
        {"AE", 0x00C6}, {"Ccedilla", 0x00C7}, {"Egrave", 0x00C8},
        {"Eacute", 0x00C9}, {"Ecircumflex", 0x00CA}, {"Edieresis", 0x00CB},
        {"Igrave", 0x00CC}, {"Iacute", 0x00CD}, {"Icircumflex", 0x00CE},
        {"Idieresis", 0x00CF}, {"Eth", 0x00D0}, {"Ntilde", 0x00D1},
        {"Ograve", 0x00D2}, {"Oacute", 0x00D3}, {"Ocircumflex", 0x00D4},
        {"Otilde", 0x00D5}, {"Odieresis", 0x00D6}, {"Oslash", 0x00D8},
        {"Ugrave", 0x00D9}, {"Uacute", 0x00DA}, {"Ucircumflex", 0x00DB},
        {"Udieresis", 0x00DC}, {"Yacute", 0x00DD}, {"Thorn", 0x00DE},
        {"germandbls", 0x00DF}, {"agrave", 0x00E0}, {"aacute", 0x00E1},
        {"acircumflex", 0x00E2}, {"atilde", 0x00E3}, {"adieresis", 0x00E4},
        {"aring", 0x00E5}, {"ae", 0x00E6}, {"ccedilla", 0x00E7},
        {"egrave", 0x00E8}, {"eacute", 0x00E9}, {"ecircumflex", 0x00EA},
        {"edieresis", 0x00EB}, {"igrave", 0x00EC}, {"iacute", 0x00ED},
        {"icircumflex", 0x00EE}, {"idieresis", 0x00EF}, {"eth", 0x00F0},
        {"ntilde", 0x00F1}, {"ograve", 0x00F2}, {"oacute", 0x00F3},
        {"ocircumflex", 0x00F4}, {"otilde", 0x00F5}, {"odieresis", 0x00F6},
        {"oslash", 0x00F8}, {"ugrave", 0x00F9}, {"uacute", 0x00FA},
        {"ucircumflex", 0x00FB}, {"udieresis", 0x00FC}, {"yacute", 0x00FD},
        {"thorn", 0x00FE}, {"ydieresis", 0x00FF},
        {"Scaron", 0x0160}, {"scaron", 0x0161}, {"Zcaron", 0x017D},
        {"zcaron", 0x017E}, {"florin", 0x0192}, {"OE", 0x0152}, {"oe", 0x0153},
        {"endash", 0x2013}, {"emdash", 0x2014}, {"quotedblleft", 0x201C},
        {"quotedblright", 0x201D}, {"bullet", 0x2022}, {"ellipsis", 0x2026},
        {"perthousand", 0x2030}, {"guillemotleft", 0x00AB},
        {"guillemotright", 0x00BB}, {"guilsinglleft", 0x2039},
        {"guilsinglright", 0x203A}, {"trademark", 0x2122},
        {"copyright", 0x00A9}, {"registered", 0x00AE}, {"degree", 0x00B0},
        {"plusminus", 0x00B1}, {"multiply", 0x00D7}, {"divide", 0x00F7},
        {"onesuperior", 0x00B9}, {"twosuperior", 0x00B2},
        {"threesuperior", 0x00B3}, {"onequarter", 0x00BC},
        {"onehalf", 0x00BD}, {"threequarters", 0x00BE},
        {"brokenbar", 0x00A6}, {"section", 0x00A7}, {"dieresis", 0x00A8},
        {"ordfeminine", 0x00AA},
        {"logicalnot", 0x00AC}, {"registeredserif", 0x00AE},
        {"macron", 0x00AF}, {"cent", 0x00A2}, {"sterling", 0x00A3},
        {"currency", 0x00A4}, {"yen", 0x00A5}, {"ordmasculine", 0x00BA},
        {"acute", 0x00B4}, {"mu", 0x00B5}, {"paragraph", 0x00B6},
        {"periodcentered", 0x00B7}, {"cedilla", 0x00B8},
        {"superscriptone", 0x00B9},
        {"superscripttwo", 0x00B2}, {"superscriptthree", 0x00B3},
        {"fi", 0xFB01}, {"fl", 0xFB02}, {"euro", 0x20AC},
        {"dotaccent", 0x02D9}, {"ring", 0x02DA}, {"circumflex", 0x02C6},
        {"caron", 0x02C7}, {"breve", 0x02D8}, {"tilde", 0x02DC},
        {"Lslash", 0x0141}, {"lslash", 0x0142}, {"Sacute", 0x015A},
        {"sacute", 0x015B}, {"Zacute", 0x0179}, {"zacute", 0x017A},
        {"Zdotaccent", 0x017B}, {"zdotaccent", 0x017C},
    };
    static std::map<std::string, uint32_t> const lookup = [] {
        std::map<std::string, uint32_t> m;
        for (auto const& e : table) { m[e.name] = e.unicode; }
        // A-Z a-z sind der Buchstabe selbst, Ziffern die AGL-Namen.
        for (unsigned c = 'A'; c <= 'Z'; ++c) { m[std::string(1, char(c))] = c; }
        for (unsigned c = 'a'; c <= 'z'; ++c) { m[std::string(1, char(c))] = c; }
        char const* digits[] = {"zero", "one", "two", "three", "four",
                                "five", "six", "seven", "eight", "nine"};
        for (int d = 0; d < 10; ++d) { m[digits[d]] = (uint32_t)('0' + d); }
        return m;
    }();
    auto it = lookup.find(name);
    return it == lookup.end() ? 0 : it->second;
}

/// AGL-Name auflösen: /uniXXXX und /uXXXX[XX] nach AGL-Spezifikation,
/// sonst Kompakttabelle. 0 = unauflösbar.
uint32_t font6_agl_unicode(std::string const& rawName)
{
    std::string name = rawName;
    if (!name.empty() && name.front() == '/') { name.erase(name.begin()); }
    if (name.empty()) { return 0; }
    auto hex_run = [&](size_t begin, size_t end, uint32_t& v) -> bool {
        v = 0;
        for (size_t i = begin; i < end; ++i) {
            char c = name[i];
            v <<= 4;
            if (c >= '0' && c <= '9') { v |= (uint32_t)(c - '0'); }
            else if (c >= 'A' && c <= 'F') { v |= (uint32_t)(c - 'A' + 10); }
            else if (c >= 'a' && c <= 'f') { v |= (uint32_t)(c - 'a' + 10); }
            else { return false; }
        }
        return true;
    };
    if (name.size() == 8 && name.compare(0, 3, "uni") == 0) {
        uint32_t v = 0;
        if (hex_run(3, 7, v) && v > 0) { return v; }
    }
    if (name.size() >= 5 && name.size() <= 7 && name.compare(0, 1, "u") == 0) {
        uint32_t v = 0;
        if (hex_run(1, name.size(), v) && v > 0 && v <= 0x10FFFF) { return v; }
    }
    return font6_agl_lookup(name);
}

// --- ToUnicode-CMap (bfchar/bfrange) ----------------------------------------

bool font6_hex_nibble(char c, unsigned& v)
{
    if (c >= '0' && c <= '9') { v = (unsigned)(c - '0'); return true; }
    if (c >= 'A' && c <= 'F') { v = (unsigned)(c - 'A' + 10); return true; }
    if (c >= 'a' && c <= 'f') { v = (unsigned)(c - 'a' + 10); return true; }
    return false;
}

/// UTF-16BE-Hexstring → Codepoints (Surrogatpaare kombiniert). Liefert den
/// ERSTEN Codepoint – Ligatur-Mehrzeicheneinträge fallen auf das Hauptzeichen
/// zusammen, was die Glyphenauswahl über cmap konservativ annähert.
uint32_t font6_utf16be_first(std::string const& hex)
{
    std::vector<unsigned> values;
    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        unsigned hi = 0, lo = 0;
        if (!font6_hex_nibble(hex[i], hi) || !font6_hex_nibble(hex[i + 1], lo)) {
            return 0;
        }
        values.push_back((hi << 4) | lo);
    }
    if (values.empty()) { return 0; }
    if (values[0] >= 0xD800 && values[0] <= 0xDBFF && values.size() >= 2
        && values[1] >= 0xDC00 && values[1] <= 0xDFFF) {
        return 0x10000u + ((values[0] - 0xD800u) << 10) + (values[1] - 0xDC00u);
    }
    return values[0];
}

/// ToUnicode-CMap → Code→Unicode (nur 1-Byte-Codes; Simple-Fonts).
/// bfchar-Paare und bfrange (fortlaufende und Array-Form) werden gelesen;
/// alles andere im CMap-Body (Namen, dictionaries, Kommentare) wird
/// übersprungen. Mehrdeutige oder überlange Einträge fallen weg.
std::map<unsigned, uint32_t> font6_parse_tounicode(std::string const& b)
{
    std::map<unsigned, uint32_t> out;
    size_t i = 0;
    size_t const n = b.size();
    enum { none, bfchar, bfrange } mode = none;
    std::vector<std::string> hexes;      // laufende Eintragssammlung
    std::vector<std::string> arrayHexes; // bfrange-Array-Form
    bool inArray = false;

    auto first_codepoint = [&](std::string const& hex) -> uint32_t {
        return font6_utf16be_first(hex);
    };
    auto hex_byte = [&](std::string const& hex, unsigned& value) -> bool {
        if (hex.size() != 2) { return false; }
        unsigned hi = 0, lo = 0;
        if (!font6_hex_nibble(hex[0], hi) || !font6_hex_nibble(hex[1], lo)) {
            return false;
        }
        value = (hi << 4) | lo;
        return true;
    };
    auto interpret_bfchar = [&]() {
        for (size_t p = 0; p + 1 < hexes.size(); p += 2) {
            unsigned code = 0;
            if (hex_byte(hexes[p], code)) {
                uint32_t u = first_codepoint(hexes[p + 1]);
                if (u != 0) { out.emplace(code, u); }
            }
        }
    };
    auto interpret_bfrange_sequential = [&]() {
        if (hexes.size() < 3) { return; }
        unsigned lo = 0, hi = 0;
        if (!hex_byte(hexes[0], lo) || !hex_byte(hexes[1], hi)) { return; }
        if (hi < lo || hi - lo > 65535) { return; }
        uint32_t start = first_codepoint(hexes[2]);
        if (start == 0) { return; }
        for (unsigned code = lo; code <= hi; ++code) {
            out.emplace(code, start + (code - lo));
        }
    };
    auto interpret_bfrange_array = [&]() {
        if (hexes.size() < 2) { return; }
        unsigned lo = 0, hi = 0;
        if (!hex_byte(hexes[0], lo) || !hex_byte(hexes[1], hi)) { return; }
        if (hi < lo) { return; }
        for (size_t k = 0; k < arrayHexes.size() && lo + k <= hi; ++k) {
            uint32_t u = first_codepoint(arrayHexes[k]);
            if (u != 0) { out.emplace(lo + (unsigned)k, u); }
        }
    };
    auto reset_entry = [&]() {
        hexes.clear(); arrayHexes.clear(); inArray = false;
    };

    while (i < n) {
        while (i < n && (b[i] == ' ' || b[i] == '\t' || b[i] == '\n'
                         || b[i] == '\r' || b[i] == '\f' || b[i] == 0)) { ++i; }
        if (i >= n) { break; }
        char c = b[i];
        if (c == '%') {
            while (i < n && b[i] != '\n' && b[i] != '\r') { ++i; }
            continue;
        }
        if (c == '/') {
            // Name überspringen (z. B. /CIDInit) – ihn zu lesen brächte nichts.
            ++i;
            while (i < n && !isspace(static_cast<unsigned char>(b[i]))
                   && b[i] != '<' && b[i] != '>' && b[i] != '['
                   && b[i] != ']' && b[i] != '/' && b[i] != '%') { ++i; }
            continue;
        }
        if (c == '<') {
            std::string hex;
            ++i;
            while (i < n && b[i] != '>') { hex += b[i]; ++i; }
            if (i < n) { ++i; }
            if (mode != none && !inArray) {
                // Fortlaufende bfrange-Form: mit dem vierten Hexstring beginnt
                // ein neuer Eintrag – den vorigen zuerst auswerten.
                if (mode == bfrange && hexes.size() == 3) {
                    interpret_bfrange_sequential();
                    reset_entry();
                }
                hexes.push_back(std::move(hex));
            } else if (mode != none && inArray) {
                arrayHexes.push_back(std::move(hex));
            }
            continue;
        }
        if (c == '[') {
            ++i;
            if (mode == bfrange && hexes.size() == 2) {
                inArray = true; arrayHexes.clear();
            } else {
                reset_entry();
            }
            continue;
        }
        if (c == ']') {
            ++i;
            if (mode == bfrange && inArray) {
                interpret_bfrange_array();
                reset_entry();
            }
            continue;
        }
        if (c == '>') { ++i; continue; }
        // Wort (Keyword) lesen
        size_t start = i;
        while (i < n && !isspace(static_cast<unsigned char>(b[i]))
               && b[i] != '/' && b[i] != '<' && b[i] != '>' && b[i] != '['
               && b[i] != ']' && b[i] != '%') { ++i; }
        std::string word = b.substr(start, i - start);
        if (word == "beginbfchar") { mode = bfchar; reset_entry(); }
        else if (word == "endbfchar") {
            if (mode == bfchar) { interpret_bfchar(); }
            mode = none; reset_entry();
        }
        else if (word == "beginbfrange") { mode = bfrange; reset_entry(); }
        else if (word == "endbfrange") {
            if (mode == bfrange) { interpret_bfrange_sequential(); }
            mode = none; reset_entry();
        }
        else if (mode == bfrange && !inArray && hexes.size() == 3) {
            // Drittes Element war kein Hexstring/Array: fortlaufende Form
            // ist komplett, bevor das nächste <lo> beginnt.
            interpret_bfrange_sequential();
            reset_entry();
        }
    }
    return out;
}

// --- Benutzung aus Content ermitteln ----------------------------------------

/// Benutzung gesamt: Codes/CIDs je Font-Dict-Objekt plus Fonts, deren
/// Content nicht vollständig scanbar war (diese bleiben komplett stehen).
/// V2-8 (§14.4): `pages` hält je Font-Dict die Seiten, von denen aus der
/// Content den Font erreicht (Seiten-, Form- und Annotation-Walk) – Basis
/// der Render-Stichprobe im selektiven Subsetting. Fonts ohne Seitentreffer
/// (z. B. nur über Type3-CharProcs benutzt) tragen eine leere Menge.
struct font6_usage {
    std::map<QPDFObjGen, std::set<unsigned>> codes;
    std::set<QPDFObjGen> unscannable;
    std::map<QPDFObjGen, std::set<int>> pages;
};

/// Rohe String-Bytes je Font-Typ interpretieren: Simple = Byte je Code,
/// Type0/Identity = 2-Byte-Wörter (CID == GID; hängendes Byte entfällt).
void font6_codes_from_bytes(std::string const& raw, bool cid,
                            std::set<unsigned>& out)
{
    if (!cid) {
        for (char c : raw) { out.insert((unsigned)(unsigned char)c); }
        return;
    }
    for (size_t i = 0; i + 1 < raw.size(); i += 2) {
        out.insert(((unsigned)(unsigned char)raw[i] << 8)
                   | (unsigned)(unsigned char)raw[i + 1]);
    }
}

/// Benutzung EINES Content-Verbrauchers: Tf-Namen → rohe String-Bytes.
/// `unbound` nimmt Strings ohne aktiven Font auf (der Aufrufer bucht sie
/// auf alle Fonts seiner Map – überprotektiv, nie zu wenig).
struct font6_consumer_usage {
    std::map<std::string, std::string> byName;
    std::string unbound;
};

/// Literal-String ab '(' lesen (Verschachtelung, Escapes, Oktal).
void font6_read_literal(std::string const& b, size_t& i, size_t n,
                        std::string& out)
{
    ++i;   // '('
    int depth = 1;
    while (i < n && depth > 0) {
        char c = b[i];
        if (c == '\\') {
            ++i;
            if (i >= n) { break; }
            char e = b[i];
            switch (e) {
            case 'n': out += '\n'; ++i; break;
            case 'r': out += '\r'; ++i; break;
            case 't': out += '\t'; ++i; break;
            case 'b': out += '\b'; ++i; break;
            case 'f': out += '\f'; ++i; break;
            case '(': case ')': case '\\': out += e; ++i; break;
            case '\r': ++i; if (i < n && b[i] == '\n') { ++i; } break;
            case '\n': ++i; break;
            default:
                if (e >= '0' && e <= '7') {
                    int v = 0; int digits = 0;
                    while (i < n && digits < 3 && b[i] >= '0' && b[i] <= '7') {
                        v = v * 8 + (b[i] - '0');
                        ++i;
                        ++digits;
                    }
                    out += static_cast<char>(v);
                } else {
                    out += e;
                    ++i;
                }
                break;
            }
            continue;
        }
        if (c == '(') { ++depth; }
        else if (c == ')') {
            --depth;
            ++i;
            if (depth == 0) { break; }
            continue;
        }
        out += c;
        ++i;
    }
}

// Vorwärtsdeklaration – Do-Rekursion über Form-XObjects.
// `page` trägt den 0-basierten Seitenindex des Walks (-1 ohne Seitenkontext,
// z. B. Type3-CharProcs) – V2-8 (§14.4) Render-Stichprobe.
bool font6_walk_consumer(std::vector<QPDFObjectHandle> const& contents,
                         QPDFObjectHandle const& resources,
                         font6_usage& usage, int depth, int page = -1);

/// Tokenisiert Content-Bytes: Strings sammeln, Tf-Kontext mit q/Q-Stack
/// (Textzustand ist Grafikzustand), Textanzeige-Operatoren buchen die
/// Strings auf den aktiven Font, Do löst Form-XObjects rekursiv auf.
void font6_scan_tokens(std::string const& bytes,
                       QPDFObjectHandle const& resources,
                       font6_consumer_usage& out, font6_usage& usage,
                       int depth, int page)
{
    size_t i = 0;
    size_t const n = bytes.size();
    std::string lastName;
    std::vector<std::string> fontStack;   // q/Q – Tf ist Grafikzustand
    std::string currentFont;
    std::vector<std::string> pending;

    auto flush = [&]() {
        if (pending.empty()) { return; }
        std::string& sink = currentFont.empty()
            ? out.unbound : out.byName[currentFont];
        for (auto const& s : pending) { sink += s; }
        pending.clear();
    };
    auto clearPending = [&]() { pending.clear(); };

    while (i < n) {
        unsigned char ch = static_cast<unsigned char>(bytes[i]);
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f'
            || ch == 0) {
            ++i;
            continue;
        }
        if (ch == '%') {
            while (i < n && bytes[i] != '\n' && bytes[i] != '\r') { ++i; }
            continue;
        }
        if (ch == '/') {
            size_t start = ++i;
            while (i < n) {
                unsigned char c = static_cast<unsigned char>(bytes[i]);
                bool delim = (c == ' ' || c == '\t' || c == '\n' || c == '\r'
                    || c == '\f' || c == 0 || c == '/' || c == '(' || c == ')'
                    || c == '<' || c == '>' || c == '[' || c == ']' || c == '{'
                    || c == '}' || c == '%');
                if (delim) { break; }
                ++i;
            }
            lastName = bytes.substr(start, i - start);
            continue;
        }
        if (ch == '(') {
            std::string s;
            font6_read_literal(bytes, i, n, s);
            pending.push_back(std::move(s));
            continue;
        }
        if (ch == '<') {
            if (i + 1 < n && bytes[i + 1] == '<') {
                // Dict – nie Operand eines Textanzeige-Operators.
                int dictDepth = 1;
                i += 2;
                while (i < n && dictDepth > 0) {
                    if (bytes[i] == '<' && i + 1 < n && bytes[i + 1] == '<') {
                        ++dictDepth; i += 2;
                    } else if (bytes[i] == '>' && i + 1 < n
                               && bytes[i + 1] == '>') {
                        --dictDepth; i += 2;
                    } else { ++i; }
                }
                clearPending();
                continue;
            }
            std::string hex;
            ++i;
            while (i < n && bytes[i] != '>') { hex += bytes[i]; ++i; }
            if (i < n) { ++i; }
            // Paare bilden; ungerader Restnibble entfällt.
            std::string raw;
            for (size_t k = 0; k + 1 < hex.size(); k += 2) {
                unsigned hi = 0, lo = 0;
                if (font6_hex_nibble(hex[k], hi)
                    && font6_hex_nibble(hex[k + 1], lo)) {
                    raw += static_cast<char>((hi << 4) | lo);
                }
            }
            pending.push_back(std::move(raw));
            continue;
        }
        if (ch == '>' || ch == '[' || ch == ']' || ch == '{' || ch == '}') {
            ++i;
            continue;
        }
        if ((ch >= '0' && ch <= '9') || ch == '+' || ch == '-' || ch == '.') {
            while (i < n) {
                char c = bytes[i];
                if ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'
                    || c == 'e' || c == 'E') {
                    ++i;
                } else {
                    break;
                }
            }
            continue;
        }
        if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')
            || ch == '\'' || ch == '"' || ch == '*') {
            size_t start = i;
            while (i < n) {
                char c = bytes[i];
                bool tokenChar = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                    || (c >= '0' && c <= '9') || c == '*' || c == '\''
                    || c == '"' || static_cast<unsigned char>(c) >= 128;
                if (!tokenChar) { break; }
                ++i;
            }
            std::string op = bytes.substr(start, i - start);
            if (op == "Tj" || op == "TJ" || op == "'" || op == "\"") {
                flush();
            } else if (op == "Tf") {
                clearPending();
                currentFont = lastName;
            } else if (op == "q") {
                clearPending();
                fontStack.push_back(currentFont);
            } else if (op == "Q") {
                clearPending();
                if (!fontStack.empty()) {
                    currentFont = fontStack.back();
                    fontStack.pop_back();
                }
            } else if (op == "Do" && !lastName.empty()) {
                clearPending();
                if (depth < 16 && !resources.isNull()
                    && resources.isDictionary()) {
                    QPDFObjectHandle xobjects = resources.getKey("/XObject");
                    if (xobjects.isDictionary()) {
                        QPDFObjectHandle form = xobjects.getKey("/" + lastName);
                        if (form.isStream()) {
                            QPDFObjectHandle subtype = dict_of(form).getKey("/Subtype");
                            if (subtype.isName()
                                && subtype.getName() == "/Form") {
                                QPDFObjectHandle own = dict_of(form).getKey("/Resources");
                                if (own.isNull() || !own.isDictionary()) {
                                    own = resources;   // Namensraum erben
                                }
                                std::vector<QPDFObjectHandle> one = { form };
                                font6_walk_consumer(one, own, usage,
                                                    depth + 1, page);
                            }
                        }
                    }
                }
            } else {
                clearPending();
            }
            lastName.clear();
            continue;
        }
        ++i;
    }
}

/// Auflösen EINES Verbrauchers: Content scannen, Namen über die /Font-Map
/// des Verbrauchers auf Font-Dict-Objekte buchen (die Deutung der Bytes –
/// Simple-Byte-Codes oder 2-Byte-CIDs – folgt dem /Subtype), unscanbare
/// Contents markieren alle Fonts der Map als unscanbar. Liefert die
/// Scan-Vollständigkeit.
bool font6_walk_consumer(std::vector<QPDFObjectHandle> const& contents,
                         QPDFObjectHandle const& resources,
                         font6_usage& usage, int depth, int page)
{
    if (depth > 16) { return false; }
    QPDFObjectHandle fontMap;
    bool hasMap = false;
    if (!resources.isNull() && resources.isDictionary()) {
        fontMap = resources.getKey("/Font");
        hasMap = !fontMap.isNull() && fontMap.isDictionary();
    }
    if (!hasMap) { return true; }   // ohne Font-Map kann hier nichts genutzt werden

    font6_consumer_usage local;
    bool scanned = true;
    if (hasMap) {
        // V2-5-Fix – dieselbe Konkatenations-Regel wie in font5_walk_consumer:
        // Tf-Kontext und String-Operanden (Tj/TJ/'/") dürfen über
        // /Contents-Array-Grenzen geteilt sein; je-Stream-Scannen verliert
        // die Zustände an der Grenze. Trenn-Byte gegen Tokenverschmelzung,
        // Budget wie bestehende Scans; Überschreitung = unscanbar
        // (konservativ: die Fonts bleiben komplett stehen). V2-8: Nur
        // vollständig auflösbare Filterketten sind scanbar (siehe
        // font6_content_stream_bytes – Rohbytes sind kein Scan).
        std::string bytes;
        for (auto const& stream : contents) {
            std::string part;
            if (!stream.isStream()
                || !font6_content_stream_bytes(stream, part)) {
                scanned = false;
                continue;
            }
            if (part.empty()) { continue; }
            if (!bytes.empty()) { bytes.push_back(' '); }
            if (bytes.size() + part.size() > font5_concat_budget_bytes) {
                scanned = false;
                break;
            }
            bytes += part;
        }
        if (!bytes.empty()) {
            font6_scan_tokens(bytes, resources, local, usage, depth, page);
        }
    }

    std::set<std::string> const keys = fontMap.getKeys();
    for (auto const& name : keys) {
        QPDFObjectHandle value = fontMap.getKey(name);
        if (!value.isIndirect()) { continue; }
        // V2-8 (§14.4) – Seitenherkunft je Font-Dict festhalten (für die
        // Render-Stichprobe des selektiven Subsettings).
        if (page >= 0) {
            usage.pages[value.getObjGen()].insert(page);
        }
        bool cid = false;
        QPDFObjectHandle subtype = value.getKey("/Subtype");
        if (subtype.isName() && subtype.getName() == "/Type0") { cid = true; }
        std::string key = name;
        if (!key.empty() && key.front() == '/') { key.erase(key.begin()); }
        auto it = local.byName.find(key);
        if (it != local.byName.end() && !it->second.empty()) {
            std::set<unsigned> codes;
            font6_codes_from_bytes(it->second, cid, codes);
            std::set<unsigned>& target = usage.codes[value.getObjGen()];
            target.insert(codes.begin(), codes.end());
        }
        if (!local.unbound.empty()) {
            std::set<unsigned> codes;
            font6_codes_from_bytes(local.unbound, cid, codes);
            std::set<unsigned>& target = usage.codes[value.getObjGen()];
            target.insert(codes.begin(), codes.end());
        }
        if (!scanned) {
            usage.unscannable.insert(value.getObjGen());
        }
    }
    return scanned;
}

// --- Subset-Ausführung über hb-subset ---------------------------------------

/// Führt hb_subset_or_fail über die Sets-API (HarfBuzz 11.x) aus.
/// `unicodes`: zu erhaltende Unicode-Codepoints (Simple-Pfad, cmap-closure),
/// `glyphs`: zu erhaltende GIDs (Identity-H-Pfad; > glyphCount wird verworfen
/// – solche CIDs waren .notdef und bleiben es). retainGids hält die
/// Glyphennummerierung stabil – Pflicht, damit CID==GID bestehen bleibt.
bool font6_run_subset(std::string const& program,
                      std::set<unsigned> const& unicodes,
                      std::set<unsigned> const& glyphs,
                      bool retainGids, std::string& out)
{
    out.clear();
    hb_blob_t* blob = hb_blob_create(program.data(),
                                     static_cast<unsigned int>(program.size()),
                                     HB_MEMORY_MODE_READONLY, nullptr, nullptr);
    if (!blob) { return false; }
    hb_face_t* face = hb_face_create(blob, 0);
    bool ok = false;
    do {
        // TTC/Sammlungen und kaputte Programme: konservativ behalten.
        if (hb_face_count(blob) != 1) { break; }
        unsigned glyphCount = hb_face_get_glyph_count(face);
        if (glyphCount == 0) { break; }
        hb_subset_input_t* input = hb_subset_input_create_or_fail();
        if (!input) { break; }
        if (retainGids) {
            hb_subset_input_set_flags(input, HB_SUBSET_FLAGS_RETAIN_GIDS);
        }
        if (!unicodes.empty()) {
            hb_set_t* set = hb_subset_input_unicode_set(input);
            for (unsigned u : unicodes) { hb_set_add(set, u); }
        }
        if (!glyphs.empty()) {
            hb_set_t* set = hb_subset_input_glyph_set(input);
            for (unsigned g : glyphs) {
                if (g < glyphCount) { hb_set_add(set, g); }
            }
        }
        hb_face_t* result = hb_subset_or_fail(face, input);
        hb_subset_input_destroy(input);
        if (!result) { break; }
        hb_blob_t* outBlob = hb_face_reference_blob(result);
        unsigned len = outBlob ? hb_blob_get_length(outBlob) : 0;
        char const* data = outBlob ? hb_blob_get_data(outBlob, nullptr) : nullptr;
        if (data && len > 0) { out.assign(data, data + len); ok = true; }
        if (outBlob) { hb_blob_destroy(outBlob); }
        hb_face_destroy(result);
    } while (false);
    hb_face_destroy(face);
    hb_blob_destroy(blob);
    return ok && !out.empty();
}

/// /W auf benutzte CIDs einkürzen. false = Array nicht sicher parsebar –
/// dann bleibt der Font komplett stehen (alles-oder-nichts je Font).
/// Rebuild als Läufe: c [w] bzw. c1 c2 [w…], Originalwerte unverändert.
bool font6_rewrite_w(QPDFObjectHandle const& w,
                     std::set<unsigned> const& used,
                     std::vector<QPDFObjectHandle>& out)
{
    std::vector<QPDFObjectHandle> const items = w.getArrayAsVector();
    size_t i = 0;
    // Segmente: StartCID + Breitenliste (Klammer- und Skalarform normalisiert).
    std::vector<std::pair<unsigned, std::vector<QPDFObjectHandle>>> segments;
    while (i < items.size()) {
        QPDFObjectHandle a = items[i];
        if (!a.isInteger() || a.getIntValue() < 0) { return false; }
        unsigned c = static_cast<unsigned>(a.getIntValue());
        if (i + 1 >= items.size()) { return false; }
        QPDFObjectHandle b = items[i + 1];
        if (b.isArray()) {
            // c [w…] – einzelner CID oder Bereichsbeginn in Klammerform
            std::vector<QPDFObjectHandle> const ws = b.getArrayAsVector();
            if (ws.empty()) { return false; }
            for (auto const& x : ws) {
                if (!x.isInteger() && !x.isReal()) { return false; }
            }
            segments.push_back({c, ws});
            i += 2;
            continue;
        }
        if (!b.isInteger() || b.getIntValue() < 0
            || b.getIntValue() < static_cast<long long>(c)) {
            return false;
        }
        unsigned last = static_cast<unsigned>(b.getIntValue());
        if (i + 2 >= items.size()) { return false; }
        QPDFObjectHandle d = items[i + 2];
        if (d.isArray()) {
            std::vector<QPDFObjectHandle> const ws = d.getArrayAsVector();
            if (static_cast<long long>(ws.size())
                != static_cast<long long>(last) - static_cast<long long>(c) + 1) {
                return false;
            }
            for (auto const& x : ws) {
                if (!x.isInteger() && !x.isReal()) { return false; }
            }
            segments.push_back({c, ws});
            i += 3;
            continue;
        }
        if (!d.isInteger() && !d.isReal()) { return false; }
        segments.push_back({c, std::vector<QPDFObjectHandle>{d}});
        i += 3;
    }
    // Rebuild: nur benutzte CIDs, zusammenhängende zu Läufen gefasst.
    for (auto const& seg : segments) {
        unsigned base = seg.first;
        size_t count = seg.second.size();
        size_t idx = 0;
        while (idx < count) {
            if (!used.count(base + static_cast<unsigned>(idx))) { ++idx; continue; }
            size_t runStart = idx;
            while (idx + 1 < count
                   && used.count(base + static_cast<unsigned>(idx + 1))) {
                ++idx;
            }
            std::vector<QPDFObjectHandle> ws(
                seg.second.begin() + static_cast<long>(runStart),
                seg.second.begin() + static_cast<long>(idx) + 1);
            out.push_back(QPDFObjectHandle::newInteger(
                base + static_cast<unsigned>(runStart)));
            if (ws.size() > 1) {
                out.push_back(QPDFObjectHandle::newInteger(
                    base + static_cast<unsigned>(idx)));
            }
            out.push_back(QPDFObjectHandle::newArray(ws));
            ++idx;
        }
    }
    return true;
}

/// Subsettet EINEN Font-Dict (alles-oder-nichts). false = Font bleibt
/// unangetastet. Bei Erfolg trägt `savedBytes` die gesparten Programmbytes.
/// `dict` ist eine Kopie des Handles – qpdf-Handles teilen das Objekt,
/// Mutationen wirken am Dokument.
///
/// V2-8 (§14.1): `mutate = false` macht den Lauf zum TROCKENEN PLANEN –
/// Whitelist, Benutzung und hb-subset laufen vollständig, aber es wird keine
/// Mutation vorgenommen; das Ergebnis ist die ehrliche Ersparnisschätzung
/// der Candidate-Liste (derselbe Code wie die Ausführung, Finding 11).
/// `originalProgramBytes` (optional) erhält die dekodierte Größe des
/// Fontprogramms VOR dem Subset – Basis der relativen Aktivierungspolitik.
bool font6_subset_one(QPDF& qpdf, QPDFObjectHandle dict,
                      std::set<unsigned> const& used, long long threshold,
                      long long& savedBytes, bool mutate = true,
                      long long* originalProgramBytes = nullptr)
{
    if (originalProgramBytes) { *originalProgramBytes = 0; }
    try {
        QPDFObjectHandle subtype = dict.getKey("/Subtype");
        if (!subtype.isName()) { return false; }
        std::string const st = subtype.getName();
        if (used.empty()) { return false; }   // ohne Benutzung nichts tun

        bool cidMode = false;
        QPDFObjectHandle file;          // FontFile2-Programmstrom
        QPDFObjectHandle descriptor;    // Dict, das /FontFile2 trägt
        QPDFObjectHandle descendant;    // CIDFontType2 bei Type0

        if (st == "/TrueType") {
            descriptor = font5_descriptor_of(dict);
            if (!descriptor.isDictionary()) { return false; }
            file = descriptor.getKey("/FontFile2");
            if (!file.isStream()) { return false; }
        } else if (st == "/Type0") {
            cidMode = true;
            QPDFObjectHandle enc = dict.getKey("/Encoding");
            if (!enc.isName()) { return false; }
            std::string const encName = enc.getName();
            if (encName != "/Identity-H" && encName != "/Identity-V") {
                return false;   // vordefinierte CJK-CMaps: konservativ behalten
            }
            QPDFObjectHandle kids = dict.getKey("/DescendantFonts");
            if (!kids.isArray()) { return false; }
            std::vector<QPDFObjectHandle> const entries = kids.getArrayAsVector();
            if (entries.empty() || !entries[0].isDictionary()) { return false; }
            descendant = entries[0];
            QPDFObjectHandle dst = descendant.getKey("/Subtype");
            if (!dst.isName() || dst.getName() != "/CIDFontType2") { return false; }
            QPDFObjectHandle ddesc = descendant.getKey("/FontDescriptor");
            if (!ddesc.isDictionary()) { return false; }
            descriptor = ddesc;
            file = ddesc.getKey("/FontFile2");
            if (!file.isStream()) { return false; }
            QPDFObjectHandle gidMap = descendant.getKey("/CIDToGIDMap");
            if (gidMap.isStream()) { return false; }   // Nicht-Identity-Mapping
            // Name /Identity oder fehlender Eintrag = Identity (Spec-Default)
        } else {
            return false;   // Type1/CFF/Type3/OpenType/…: Phase 5b fasst sie nicht an
        }

        // Programm dekodieren und sfnt-Whitelist: nur echte TrueType-Kapsel
        // (kein TTC, kein OTTO/CFF-Wrapper).
        std::string program;
        if (!font5_stream_bytes(file, program)) { return false; }
        if (program.size() < 12) { return false; }
        if (originalProgramBytes) {
            *originalProgramBytes = static_cast<long long>(program.size());
        }
        uint32_t version =
            (static_cast<uint32_t>(static_cast<unsigned char>(program[0])) << 24)
            | (static_cast<uint32_t>(static_cast<unsigned char>(program[1])) << 16)
            | (static_cast<uint32_t>(static_cast<unsigned char>(program[2])) << 8)
            | static_cast<uint32_t>(static_cast<unsigned char>(program[3]));
        if (version != 0x00010000u && version != 0x74727565u /*'true'*/) {
            return false;
        }

        // --- Simple-Pfad: Encoding/ToUnicode auflösen, Widths prüfen ------
        long long firstChar = 0, lastChar = 0;
        std::vector<QPDFObjectHandle> widths;
        unsigned newFirst = 0, newLast = 0;
        bool widthsShrink = false;
        std::set<unsigned> unicodes;

        if (!cidMode) {
            QPDFObjectHandle fc = dict.getKey("/FirstChar");
            QPDFObjectHandle lc = dict.getKey("/LastChar");
            QPDFObjectHandle w = dict.getKey("/Widths");
            if (!fc.isInteger() || !lc.isInteger() || fc.getIntValue() < 0
                || lc.getIntValue() < 0 || !w.isArray()) {
                return false;
            }
            firstChar = fc.getIntValue();
            lastChar = lc.getIntValue();
            if (lastChar < firstChar || lastChar - firstChar > 65535) { return false; }
            widths = w.getArrayAsVector();
            if (static_cast<long long>(widths.size())
                != lastChar - firstChar + 1) {
                return false;
            }
            bool have = false;
            for (unsigned code : used) {
                if (code <= 255 && static_cast<long long>(code) >= firstChar
                    && static_cast<long long>(code) <= lastChar) {
                    if (!have || code < newFirst) { newFirst = code; }
                    if (!have || code > newLast) { newLast = code; }
                    have = true;
                }
            }
            if (!have) { return false; }   // Benutzung komplett außerhalb: unklar
            widthsShrink = (newFirst != firstChar) || (newLast != lastChar);

            // Encoding: /Encoding-Name oder Dict (/BaseEncoding + /Differences).
            // Eingebettete /Encoding-Streams und unbekannte Basen: behalten.
            std::map<unsigned, std::string> differences;
            bool winAnsi = false;
            QPDFObjectHandle enc = dict.getKey("/Encoding");
            if (enc.isName()) {
                winAnsi = (enc.getName() == "/WinAnsiEncoding");
            } else if (enc.isDictionary()) {
                QPDFObjectHandle base = enc.getKey("/BaseEncoding");
                winAnsi = base.isName() && base.getName() == "/WinAnsiEncoding";
                QPDFObjectHandle diffs = enc.getKey("/Differences");
                if (diffs.isArray()) {
                    long long code = -1;
                    for (auto const& item : diffs.getArrayAsVector()) {
                        if (item.isInteger()) {
                            code = item.getIntValue();
                        } else if (item.isName() && code >= 0 && code <= 255) {
                            differences[static_cast<unsigned>(code)] =
                                item.getName();
                            ++code;
                        } else {
                            ++code;   // Lücke zählt weiter
                        }
                    }
                }
            } else if (!enc.isNull()) {
                return false;   // /Encoding-Stream: nicht sicher handhabbar
            }

            QPDFObjectHandle tu = dict.getKey("/ToUnicode");
            std::map<unsigned, uint32_t> codeToUni;
            bool hasToUnicode = false;
            if (tu.isStream()) {
                std::string cmapBytes;
                if (font5_stream_bytes(tu, cmapBytes)) {
                    codeToUni = font6_parse_tounicode(cmapBytes);
                    hasToUnicode = true;
                }
            }

            if (hasToUnicode) {
                // Je benutztem Code: ToUnicode, sonst Base-Encoding, sonst
                // Differences-Name. Unauflösbar → Font bleibt ganz.
                for (unsigned code : used) {
                    uint32_t u = 0;
                    auto mapped = codeToUni.find(code);
                    if (mapped != codeToUni.end()) {
                        u = mapped->second;
                    } else {
                        auto diff = differences.find(code);
                        if (diff != differences.end()) {
                            u = font6_agl_unicode(diff->second);
                        } else if (winAnsi && code <= 255) {
                            u = font6_winansi_unicode(
                                static_cast<unsigned char>(code));
                        }
                    }
                    if (u == 0) { return false; }
                    unicodes.insert(u);
                    if (code <= 0xFF) {
                        // Symbolische (3,0)-Variante mitnehmen – ohne Schaden,
                        // falls der Renderer über den PUA-Bereich mappt.
                        unicodes.insert(0xF000u | code);
                    }
                }
            } else {
                // Ohne ToUnicode: volle Code-Raum-Abdeckung 0–255 über
                // WinAnsi + Differences (Sicherheitsnetz gegen Scanlücken).
                if (!winAnsi) { return false; }
                for (unsigned code = 0; code <= 255; ++code) {
                    uint32_t u = 0;
                    auto diff = differences.find(code);
                    if (diff != differences.end()) {
                        u = font6_agl_unicode(diff->second);
                        if (u == 0) { return false; }   // fremder Name: behalten
                    } else {
                        u = font6_winansi_unicode(
                            static_cast<unsigned char>(code));
                    }
                    if (u != 0) { unicodes.insert(u); }
                    unicodes.insert(0xF000u | code);
                }
            }
        }

        // --- CID-Pfad: /W parsebar? (Vorprüfung, Mutation später) ---------
        std::vector<QPDFObjectHandle> newW;
        bool rewriteW = false;
        if (cidMode) {
            QPDFObjectHandle w = dict.getKey("/W");
            if (w.isArray()) {
                if (!font6_rewrite_w(w, used, newW)) { return false; }
                rewriteW = true;
            }
            // fehlendes /W: Breiten kommen aus hmtx – nichts zu tun
        }

        // --- Subset ausführen ----------------------------------------------
        std::string subset;
        if (!font6_run_subset(program, unicodes, used, cidMode, subset)) {
            return false;
        }
        if (subset.size() >= program.size()) { return false; }   // Never-Grow je Font
        long long saving = static_cast<long long>(program.size())
            - static_cast<long long>(subset.size());
        if (saving < threshold) { return false; }

        // --- Mutationen (erst nach vollständig verifizierter Planung) ------
        // V2-8: im Trockenlauf (mutate = false) entfällt dieser Block –
        // geplant wurde trotzdem vollständig, die Schätzung ist echt.
        if (mutate) {
        std::string content(subset);
        QPDFObjectHandle newFile = qpdf.newStream(content);
        newFile.getDict().replaceKey(
            "/Length1", QPDFObjectHandle::newInteger(
                static_cast<long long>(subset.size())));
        QPDFObjectHandle indirect = qpdf.makeIndirectObject(newFile);
        descriptor.replaceKey("/FontFile2", indirect);

        if (cidMode) {
            if (rewriteW) {
                dict.replaceKey("/W", QPDFObjectHandle::newArray(newW));
            }
        } else {
            if (widthsShrink) {
                std::vector<QPDFObjectHandle> trimmed(
                    widths.begin() + static_cast<long>(newFirst - firstChar),
                    widths.begin() + static_cast<long>(newLast - firstChar) + 1);
                dict.replaceKey("/Widths", QPDFObjectHandle::newArray(trimmed));
                dict.replaceKey("/FirstChar",
                                QPDFObjectHandle::newInteger(newFirst));
                dict.replaceKey("/LastChar",
                                QPDFObjectHandle::newInteger(newLast));
                if (descriptor.isDictionary()
                    && !descriptor.hasKey("/MissingWidth")) {
                    // Codes außerhalb des neuen FirstChar/LastChar fallen auf
                    // MissingWidth – Vorgabe laut Spec ist ohnehin 0.
                    descriptor.replaceKey("/MissingWidth",
                                          QPDFObjectHandle::newInteger(0));
                }
            }
        }
        }
        savedBytes = saving;
        return true;
    } catch (...) {
        return false;
    }
}

} // namespace

// ============================================================================
// Phase V2-8 (Masterplan §14.1/§21) – Selektives Font-Subsetting.
//
// Die drei Eintritte teilen sich EINE Basis (Inventar, Schutz, Benutzung):
//
//   pdfcore_font_subset           – alles Subsettette (Phase 5b, unverändert)
//   pdfcore_font_subset_candidates– Trockenplanung je Font (mutate=false),
//                                   liefert ObjGen + ehrliche Ersparnis +
//                                   安全-Klassifikation (safe vs. Behalte-Grund)
//   pdfcore_font_subset_selected  – subsettet NUR die genannten Objekte;
//                                   verweigert der Kern konservativ, bleibt
//                                   der Font stehen (kept)
// ============================================================================

namespace {

/// Gemeinsame Basis: Font-Dicts, FontFile-Referenzzähler, /AcroForm/DR-
/// Schutz, Nachfolger-Menge und die Benutzung aus dem Content. Rückgabe
/// false = verschlüsseltes Dokument – alle Eintritte laufen dann leer.
struct font6_context {
    std::map<QPDFObjGen, QPDFObjectHandle> fontDicts;   // nur indirekte
    std::map<QPDFObjGen, int> fileRefs;
    std::set<QPDFObjGen> protectedFonts;                // /AcroForm/DR
    std::set<QPDFObjGen> descendants;
    font6_usage usage;
};

bool font6_build_context(pdfcore_document_t *doc, font6_context& ctx)
{
    if (doc->qpdf.getTrailer().hasKey("/Encrypt")) { return false; }

    std::vector<QPDFObjectHandle> objects = doc->qpdf.getAllObjects();

    {
        QPDFObjectHandle acro = doc->qpdf.getRoot().getKey("/AcroForm");
        if (acro.isDictionary()) {
            QPDFObjectHandle dr = acro.getKey("/DR");
            if (dr.isDictionary()) {
                QPDFObjectHandle fm = dr.getKey("/Font");
                if (fm.isDictionary()) {
                    std::set<std::string> const keys = fm.getKeys();
                    for (auto const& name : keys) {
                        QPDFObjectHandle value = fm.getKey(name);
                        if (value.isIndirect()) {
                            ctx.protectedFonts.insert(value.getObjGen());
                        }
                    }
                }
            }
        }
    }

    for (auto const& obj : objects) {
        if (!font5_is_font_dict(obj)) { continue; }
        QPDFObjectHandle subtype = obj.getKey("/Subtype");
        bool isType0 = subtype.isName() && subtype.getName() == "/Type0";
        if (isType0 && obj.isDictionary()) {
            QPDFObjectHandle kids = obj.getKey("/DescendantFonts");
            if (kids.isArray()) {
                for (auto const& entry : kids.getArrayAsVector()) {
                    if (entry.isIndirect()) {
                        ctx.descendants.insert(entry.getObjGen());
                    }
                }
            }
        }
        if (obj.isIndirect()) {
            ctx.fontDicts.emplace(obj.getObjGen(), obj);
        }
    }
    // Referenzzähler in einem ZWEITEN Durchlauf: erst jetzt ist die
    // Nachfolger-Menge vollständig – sonst zählt ein CIDFontType2, der
    // zufällig vor seinem Type0-Dict liegt, sein Programm doppelt und
    // der Teilungs-Schutz sperrt fälschlich (auftragsabhängig).
    for (auto const& obj : objects) {
        if (!font5_is_font_dict(obj)) { continue; }
        if (ctx.descendants.count(obj.getObjGen())) { continue; }
        QPDFObjectHandle file = font5_file_stream(obj);
        if (!file.isNull()) {
            ctx.fileRefs[file.getObjGen()] += 1;
        }
    }

    // Benutzung ermitteln (Seiten, Annotations-Appearances, Type3-CharProcs).
    std::vector<QPDFObjectHandle> type3Queue;
    {
        std::vector<QPDFPageObjectHelper> pages =
            QPDFPageDocumentHelper(doc->qpdf).getAllPages();
        int pageIndex = 0;
        for (auto const& ph : pages) {
            QPDFObjectHandle page = ph.getObjectHandle();
            QPDFObjectHandle resources = font5_inherited_resources(page);
            if (!resources.isNull() && !resources.isDictionary()) {
                resources = QPDFObjectHandle::newNull();
            }
            font6_walk_consumer(font5_page_contents(page), resources,
                                ctx.usage, 0, pageIndex);
            QPDFObjectHandle annots = page.getKey("/Annots");
            if (annots.isArray()) {
                for (auto const& annot : annots.getArrayAsVector()) {
                    if (!annot.isDictionary()) { continue; }
                    QPDFObjectHandle ap = annot.getKey("/AP");
                    if (!ap.isDictionary()) { continue; }
                    for (char const* key : { "/N", "/D", "/R" }) {
                        QPDFObjectHandle appearance = ap.getKey(key);
                        std::vector<QPDFObjectHandle> streams;
                        if (appearance.isStream()) {
                            streams.push_back(appearance);
                        } else if (appearance.isArray()) {
                            for (auto const& item :
                                 appearance.getArrayAsVector()) {
                                if (item.isStream()) { streams.push_back(item); }
                            }
                        }
                        for (auto const& stream : streams) {
                            QPDFObjectHandle own =
                                dict_of(stream).getKey("/Resources");
                            if (!own.isNull() && !own.isDictionary()) {
                                own = QPDFObjectHandle::newNull();
                            }
                            if (own.isNull()) { own = resources; }
                            std::vector<QPDFObjectHandle> one = { stream };
                            font6_walk_consumer(one, own, ctx.usage, 1,
                                                pageIndex);
                        }
                    }
                }
            }
            ++pageIndex;
        }
        // Type3-CharProcs: ihr Content kann ANDERE Fonts nutzen – die
        // Benutzung zählt mit; die Type3-Fonts selbst bleiben unangetastet.
        for (auto const& obj : objects) {
            if (!font5_is_font_dict(obj)) { continue; }
            QPDFObjectHandle subtype = obj.getKey("/Subtype");
            if (subtype.isName() && subtype.getName() == "/Type3") {
                type3Queue.push_back(obj);
            }
        }
        while (!type3Queue.empty()) {
            QPDFObjectHandle t3 = type3Queue.back();
            type3Queue.pop_back();
            QPDFObjectHandle res = t3.getKey("/Resources");
            if (!res.isNull() && !res.isDictionary()) {
                res = QPDFObjectHandle::newNull();
            }
            std::vector<QPDFObjectHandle> charProcs;
            QPDFObjectHandle cp = t3.getKey("/CharProcs");
            if (cp.isDictionary()) {
                std::set<std::string> const keys = cp.getKeys();
                for (auto const& name : keys) {
                    QPDFObjectHandle proc = cp.getKey(name);
                    if (proc.isStream()) { charProcs.push_back(proc); }
                }
            }
            font6_walk_consumer(charProcs, res, ctx.usage, 1);
        }
    }
    return true;
}

/// 安全-Klassifikation EINES Font-Dicts: 0 = subsetting-safe, sonst der
/// dokumentierte Behalte-Grund (Codes siehe pdfcore.h).
int font6_classify(font6_context const& ctx, QPDFObjGen og,
                   QPDFObjectHandle const& dict)
{
    QPDFObjectHandle subtype = dict.getKey("/Subtype");
    if (subtype.isName() && subtype.getName() == "/Type3") { return 1; }
    if (ctx.protectedFonts.count(og) != 0) { return 2; }
    if (ctx.descendants.count(og) != 0) { return 3; }
    if (ctx.usage.unscannable.count(og) != 0) { return 5; }
    // Geteilte Fontprogramme bleiben ganz: Ein Subset basiert auf der
    // Benutzung EINES Dicts; ein zweiter Nutzer bräche.
    QPDFObjectHandle file = font5_file_stream(dict);
    if (!file.isNull()) {
        auto fit = ctx.fileRefs.find(file.getObjGen());
        if (fit != ctx.fileRefs.end() && fit->second > 1) { return 4; }
    }
    return 0;
}

/// Codes/CIDs EINES Font-Dicts aus der ermittelten Benutzung.
std::set<unsigned> font6_used_codes(font6_context const& ctx, QPDFObjGen og)
{
    auto it = ctx.usage.codes.find(og);
    return it != ctx.usage.codes.end() ? it->second : std::set<unsigned>();
}

} // namespace

int pdfcore_font_subset(pdfcore_document_t *doc,
                        long long min_bytes_saved_threshold,
                        pdfcore_font_subset_stats_t *stats)
{
    if (!doc) { return PDFCORE_ERR_OPEN; }
    if (stats) {
        stats->subsetted_fonts = 0;
        stats->kept_fonts = 0;
        stats->estimated_bytes_saved = 0;
    }
    try {
        font6_context ctx;
        if (!font6_build_context(doc, ctx)) { return PDFCORE_OK; }

        int subsetted = 0;
        int kept = 0;
        long long savedBytes = 0;
        for (auto const& entry : ctx.fontDicts) {
            QPDFObjGen og = entry.first;
            QPDFObjectHandle dict = entry.second;
            if (font6_classify(ctx, og, dict) != 0) { ++kept; continue; }
            long long saved = 0;
            if (font6_subset_one(doc->qpdf, dict,
                                 font6_used_codes(ctx, og),
                                 min_bytes_saved_threshold, saved)) {
                ++subsetted;
                savedBytes += saved;
            } else {
                ++kept;
            }
        }

        // --- NEVER-BREAK: Strukturprüfung nach allen Mutationen ------------
        if (subsetted > 0 && pdfcore_check(doc) != PDFCORE_OK) {
            return PDFCORE_ERR_CHECK_FAILED;
        }

        if (stats) {
            stats->subsetted_fonts = subsetted;
            stats->kept_fonts = kept;
            stats->estimated_bytes_saved = savedBytes;
        }
        return PDFCORE_OK;
    } catch (const QPDFExc&) {
        return PDFCORE_ERR_CHECK_FAILED;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

int pdfcore_font_subset_candidates(pdfcore_document_t *doc,
                                   long long min_bytes_saved_threshold,
                                   pdfcore_font_subset_candidate_t **out,
                                   int *count, int **out_pages,
                                   int *pages_count)
{
    if (!doc || !out || !count || !out_pages || !pages_count) {
        return PDFCORE_ERR_OPEN;
    }
    *out = nullptr;
    *count = 0;
    *out_pages = nullptr;
    *pages_count = 0;
    try {
        font6_context ctx;
        if (!font6_build_context(doc, ctx)) { return PDFCORE_OK; }

        std::vector<pdfcore_font_subset_candidate_t> list;
        std::vector<int> flatPages;
        for (auto const& entry : ctx.fontDicts) {
            QPDFObjGen og = entry.first;
            QPDFObjectHandle dict = entry.second;
            pdfcore_font_subset_candidate_t item;
            std::memset(&item, 0, sizeof(item));
            item.obj_number = og.getObj();
            item.generation = og.getGen();

            int reason = font6_classify(ctx, og, dict);
            item.reason_code = reason;
            item.subsettable = 0;
            item.estimated_bytes_saved = 0;
            item.original_program_bytes = 0;

            if (reason == 0) {
                // V2-8 (§14.1) – TROCKENPLANUNG: Whitelist, Benutzung und
                // hb-subset laufen vollständig; mutiert wird nicht (mutate =
                // false). Die Schätzung ist dieselbe wie bei der Ausführung
                // (Finding 11 – derselbe Code plant und fährt).
                long long saved = 0;
                long long original = 0;
                if (font6_subset_one(doc->qpdf, dict,
                                     font6_used_codes(ctx, og),
                                     min_bytes_saved_threshold, saved,
                                     /*mutate=*/false, &original)) {
                    item.subsettable = 1;
                    item.reason_code = 0;
                    item.estimated_bytes_saved = saved;
                    item.original_program_bytes = original;
                } else {
                    item.reason_code = 6;
                }
            }

            // Seitenherkunft (§14.4) – Basis der Render-Stichprobe.
            item.page_first = static_cast<int>(flatPages.size());
            auto pit = ctx.usage.pages.find(og);
            if (pit != ctx.usage.pages.end()) {
                for (int p : pit->second) { flatPages.push_back(p); }
            }
            item.page_count
                = static_cast<int>(flatPages.size()) - item.page_first;
            list.push_back(item);
        }

        if (list.empty()) { return PDFCORE_OK; }
        *out = static_cast<pdfcore_font_subset_candidate_t *>(
            std::malloc(sizeof(pdfcore_font_subset_candidate_t)
                        * list.size()));
        if (!*out) { return PDFCORE_ERR_INTERNAL; }
        std::memcpy(*out, list.data(),
                    sizeof(pdfcore_font_subset_candidate_t) * list.size());
        *count = static_cast<int>(list.size());
        if (!flatPages.empty()) {
            *out_pages = static_cast<int *>(
                std::malloc(sizeof(int) * flatPages.size()));
            if (!*out_pages) {
                std::free(*out);
                *out = nullptr;
                *count = 0;
                return PDFCORE_ERR_INTERNAL;
            }
            std::memcpy(*out_pages, flatPages.data(),
                        sizeof(int) * flatPages.size());
            *pages_count = static_cast<int>(flatPages.size());
        }
        return PDFCORE_OK;
    } catch (const QPDFExc&) {
        return PDFCORE_ERR_CHECK_FAILED;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

void pdfcore_font_subset_candidates_free(pdfcore_font_subset_candidate_t *out,
                                         int *pages)
{
    std::free(out);
    std::free(pages);
}

int pdfcore_font_subset_selected(pdfcore_document_t *doc,
                                 const int *obj_numbers, const int *generations,
                                 int count, pdfcore_font_subset_stats_t *stats)
{
    if (!doc) { return PDFCORE_ERR_OPEN; }
    if (count > 0 && (!obj_numbers || !generations)) {
        return PDFCORE_ERR_OPEN;
    }
    if (stats) {
        stats->subsetted_fonts = 0;
        stats->kept_fonts = 0;
        stats->estimated_bytes_saved = 0;
    }
    try {
        font6_context ctx;
        if (!font6_build_context(doc, ctx)) { return PDFCORE_OK; }

        int subsetted = 0;
        int kept = 0;
        long long savedBytes = 0;
        for (int i = 0; i < count; ++i) {
            QPDFObjGen og(obj_numbers[i], generations[i]);
            auto it = ctx.fontDicts.find(og);
            QPDFObjectHandle dict;
            if (it != ctx.fontDicts.end()) {
                dict = it->second;
            } else {
                // Objektidentität ist gedriftet (Dedup/Font-Merge zwischen
                // Planung und Ausführung) oder nie existiert: nur anfassen,
                // wenn das Objekt JETZT ein Font-Dict ist – sonst konservativ
                // behalten. Wurde das Dict woanders hin gemergt, sitzt dort
                // ein identisches Programm; der Verlust ist die Ersparnis,
                // niemals die Korrektheit.
                dict = doc->qpdf.getObjectByObjGen(
                    QPDFObjGen(obj_numbers[i], generations[i]));
                if (!font5_is_font_dict(dict)) { ++kept; continue; }
            }
            if (font6_classify(ctx, og, dict) != 0) { ++kept; continue; }
            long long saved = 0;
            // Schwellwert 0: Die Aktivierungspolitik (§14.3) hat der Plan
            // bereits entschieden; hier zählt nur noch der Never-Grow-Schutz
            // des Kernels selbst.
            if (font6_subset_one(doc->qpdf, dict,
                                 font6_used_codes(ctx, og), 0, saved)) {
                ++subsetted;
                savedBytes += saved;
            } else {
                ++kept;
            }
        }

        // --- NEVER-BREAK: Strukturprüfung nach allen Mutationen ------------
        if (subsetted > 0 && pdfcore_check(doc) != PDFCORE_OK) {
            return PDFCORE_ERR_CHECK_FAILED;
        }

        if (stats) {
            stats->subsetted_fonts = subsetted;
            stats->kept_fonts = kept;
            stats->estimated_bytes_saved = savedBytes;
        }
        return PDFCORE_OK;
    } catch (const QPDFExc&) {
        return PDFCORE_ERR_CHECK_FAILED;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Phase V2-8 (Masterplan §14.6) – Resource GC.
// Mechanik und Schutzregeln siehe pdfcore.h (pdfcore_remove_unused_resources).
// ============================================================================

namespace {

/// Kategorien der Resource-Map und ihre zugehörigen Operatoren. Font-Maps
/// gehören bewusst NICHT dazu – die Unused-Font-GC ist Phase 5a (§14.6
/// Inventarliste nennt Font, aber der Font-GC-Pass deckt sie bereits ab;
/// zwei Beräumungen derselben Maps wären Doppelbuchung).
enum rgc_category {
    rgc_xobject = 0,
    rgc_extgstate,
    rgc_colorspace,
    rgc_pattern,
    rgc_shading,
    rgc_properties,
    rgc_category_count
};

char const* rgc_category_key(rgc_category c)
{
    switch (c) {
    case rgc_xobject: return "/XObject";
    case rgc_extgstate: return "/ExtGState";
    case rgc_colorspace: return "/ColorSpace";
    case rgc_pattern: return "/Pattern";
    case rgc_shading: return "/Shading";
    case rgc_properties: return "/Properties";
    default: return "";
    }
}

/// EIN Sub-Map-Bucket: identische Maps (indirekt per ObjGen, direkt per
/// kanonischem Serial – Muster des Font-GC) teilen die Benutzung; Removal
/// erfolgt je Kopie. allScanned=false schützt den ganzen Bucket.
struct rgc_bucket {
    std::vector<QPDFObjectHandle> maps;
    std::set<std::string> usedNames;
    bool allScanned = true;
};

/// Scan-Zustand EINES Walks: Buckets je Kategorie + Schutz.
struct rgc_walk {
    // [Kategorie][BucketKey] → Bucket
    std::map<std::string, rgc_bucket> buckets[rgc_category_count];
    std::set<std::string> visitedConsumers;
    bool protectProperties = false;   // StructTreeRoot / OCProperties / OC
};

/// Bucket-Key einer Map (indirekt per ObjGen, direkt per kanonischem Serial).
bool rgc_bucket_key(QPDFObjectHandle const& sub, std::string& out)
{
    if (sub.isIndirect()) {
        out = "I:" + std::to_string(sub.getObjectID())
            + ":" + std::to_string(sub.getGeneration());
        return true;
    }
    std::string serial;
    if (!dedup_canonical(sub, 0, serial, true)) { return false; }
    out = "S:" + serial;
    return true;
}

/// Registriert die Sub-Maps EINES Resources-Dict in den Buckets.
/// Rückgabe false = eine Map war nicht sicher vergleichbar (fremder Typ,
/// nicht kanonisierbar) – der Aufrufer behandelt den Verbraucher dann als
/// unscanbar (alle Buckets dieses Verbrauchers bleiben stehen).
bool rgc_register_maps(QPDFObjectHandle const& resources, rgc_walk& w)
{
    for (int c = 0; c < rgc_category_count; ++c) {
        QPDFObjectHandle sub = resources.getKey(rgc_category_key(
            static_cast<rgc_category>(c)));
        if (sub.isNull()) { continue; }
        if (!sub.isDictionary()) { return false; }
        std::string key;
        if (!rgc_bucket_key(sub, key)) { return false; }
        rgc_bucket& bucket = w.buckets[c][key];
        bucket.maps.push_back(sub);
    }
    return true;
}

/// Markiert alle Buckets eines Resources-Dicts als unscanbar (Schutz).
void rgc_protect_maps(QPDFObjectHandle const& resources, rgc_walk& w)
{
    for (int c = 0; c < rgc_category_count; ++c) {
        QPDFObjectHandle sub = resources.getKey(rgc_category_key(
            static_cast<rgc_category>(c)));
        if (!sub.isDictionary()) { continue; }
        std::string key;
        if (!rgc_bucket_key(sub, key)) { continue; }
        auto it = w.buckets[c].find(key);
        if (it != w.buckets[c].end()) { it->second.allScanned = false; }
    }
}

/// Normalisierter Map-Schlüssel (ohne führendes '/') – die Content-Scanner
/// liefern Namen ohne Slash, getKeys() mit.
std::string rgc_name(std::string const& raw)
{
    std::string out = raw;
    if (!out.empty() && out.front() == '/') { out.erase(out.begin()); }
    return out;
}

/// Buchet eine Benutzung. Leerer Name → nichts zu tun.
void rgc_mark(rgc_walk& w, rgc_category c, std::string const& mapKey,
              std::string const& name)
{
    if (name.empty()) { return; }
    auto it = w.buckets[c].find(mapKey);
    if (it == w.buckets[c].end()) { return; }
    it->second.usedNames.insert(name);
}

// Vorwärtsdeklaration – Do-/SMask-/Pattern-Rekursion.
bool rgc_walk_consumer(std::vector<QPDFObjectHandle> const& contents,
                       QPDFObjectHandle const& resources, rgc_walk& w,
                       int depth);

/// Rekursive Nutzungsaufnahme aus BENUTZTEN Ressourcen-Objekten:
/// Form-XObjects (Content + eigene/ererbte /Resources), ExtGState-SMask-
/// Gruppen (/G), tiling Patterns (PatternType 1, eigene /Resources und
/// zeichnender Content). NUR BENUTZTE Einträge werden rekuriert –
/// unbenutzte werden ohnehin entfernt, ihre Maps brauchen keine
/// Nutzungsbuchung.
void rgc_walk_object(QPDFObjectHandle const& obj,
                     QPDFObjectHandle const& inheritedResources,
                     rgc_walk& w, int depth)
{
    if (depth > 16) { return; }
    try {
        if (obj.isStream()) {
            QPDFObjectHandle dict = dict_of(obj);
            QPDFObjectHandle subtype = dict.getKey("/Subtype");
            bool isForm = subtype.isName() && subtype.getName() == "/Form";
            // Tiling-Patterns zeichnen eigenen Content und tragen eigene
            // /Resources – ihre Nutzung muss genauso mitgebucht werden.
            QPDFObjectHandle patternType = dict.getKey("/PatternType");
            bool isTiling = patternType.isInteger()
                && patternType.getIntValue() == 1;
            QPDFObjectHandle res = dict.getKey("/Resources");
            if (!res.isNull() && !res.isDictionary()) {
                res = QPDFObjectHandle::newNull();
            }
            if (res.isNull()) { res = inheritedResources; }   // Namensraum erben
            if ((isForm || isTiling) && res.isDictionary()) {
                rgc_register_maps(res, w);
                std::vector<QPDFObjectHandle> one = { obj };
                rgc_walk_consumer(one, res, w, depth + 1);
            }
            return;
        }
        if (obj.isDictionary()) {
            // ExtGState: /SMask → /G (Form-Gruppe) weiterlaufen.
            QPDFObjectHandle smask = obj.getKey("/SMask");
            if (smask.isDictionary()) {
                QPDFObjectHandle group = smask.getKey("/G");
                if (group.isStream()) {
                    rgc_walk_object(group, QPDFObjectHandle::newNull(),
                                    w, depth + 1);
                }
            }
            return;
        }
    } catch (...) {
        // Fehlerhaftes Einzelobjekt: konservativ abbrechen, ohne zu mutieren.
    }
}

/// Tokenisiert Content-Bytes auf Ressourcen-Nutzung. Andere Operatoren als
/// die Kategorien-Operatoren werden übersprungen; Namen landen erst bei den
/// Operatoren in den Buckets. Muster der Text-Scanner (Strings/Dicts
/// überspringen, letzter Name je Token) – bewusst großzügig bei sc(n): Der
/// letzte Name-Operand davor wird als mögliche Pattern-Nutzung gebucht
/// (überprotektiv, nie zu wenig).
void rgc_scan_tokens(std::string const& bytes,
                     std::string const mapKeys[rgc_category_count],
                     rgc_walk& w)
{
    size_t i = 0;
    size_t const n = bytes.size();
    std::string lastName;
    bool lastNameIsName = false;

    auto markName = [&](rgc_category c) {
        if (lastNameIsName) { rgc_mark(w, c, mapKeys[c], lastName); }
    };

    while (i < n) {
        unsigned char ch = static_cast<unsigned char>(bytes[i]);
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f'
            || ch == 0) {
            ++i;
            continue;
        }
        if (ch == '%') {
            while (i < n && bytes[i] != '\n' && bytes[i] != '\r') { ++i; }
            continue;
        }
        if (ch == '/') {
            size_t start = ++i;
            while (i < n) {
                unsigned char c = static_cast<unsigned char>(bytes[i]);
                bool delim = (c == ' ' || c == '\t' || c == '\n' || c == '\r'
                    || c == '\f' || c == 0 || c == '/' || c == '(' || c == ')'
                    || c == '<' || c == '>' || c == '[' || c == ']' || c == '{'
                    || c == '}' || c == '%');
                if (delim) { break; }
                ++i;
            }
            lastName = bytes.substr(start, i - start);
            lastNameIsName = true;
            continue;
        }
        if (ch == '(') {
            std::string s;
            font6_read_literal(bytes, i, n, s);
            lastNameIsName = false;
            continue;
        }
        if (ch == '<') {
            if (i + 1 < n && bytes[i + 1] == '<') {
                int dictDepth = 1;
                i += 2;
                while (i < n && dictDepth > 0) {
                    if (bytes[i] == '<' && i + 1 < n && bytes[i + 1] == '<') {
                        ++dictDepth; i += 2;
                    } else if (bytes[i] == '>' && i + 1 < n
                               && bytes[i + 1] == '>') {
                        --dictDepth; i += 2;
                    } else { ++i; }
                }
                lastNameIsName = false;
                continue;
            }
            while (i < n && bytes[i] != '>') { ++i; }
            if (i < n) { ++i; }
            lastNameIsName = false;
            continue;
        }
        if (ch == '>' || ch == '[' || ch == ']' || ch == '{' || ch == '}') {
            ++i;
            lastNameIsName = false;
            continue;
        }
        if ((ch >= '0' && ch <= '9') || ch == '+' || ch == '-' || ch == '.') {
            while (i < n) {
                char c = bytes[i];
                if ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'
                    || c == 'e' || c == 'E') {
                    ++i;
                } else {
                    break;
                }
            }
            lastNameIsName = false;
            continue;
        }
        if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')
            || ch == '\'' || ch == '"' || ch == '*') {
            size_t start = i;
            while (i < n) {
                char c = bytes[i];
                bool tokenChar = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                    || (c >= '0' && c <= '9') || c == '*' || c == '\''
                    || c == '"' || static_cast<unsigned char>(c) >= 128;
                if (!tokenChar) { break; }
                ++i;
            }
            std::string op = bytes.substr(start, i - start);
            if (op == "BI") {
                pdfcore_skip_inline_image(bytes, i);
                lastNameIsName = false;
                continue;
            }
            if (op == "Do") { markName(rgc_xobject); }
            else if (op == "gs") { markName(rgc_extgstate); }
            else if (op == "sh") { markName(rgc_shading); }
            else if (op == "cs" || op == "CS") { markName(rgc_colorspace); }
            else if (op == "scn" || op == "SCN" || op == "sc" || op == "SC") {
                markName(rgc_pattern);
            } else if (op == "BDC" || op == "DP") {
                markName(rgc_properties);
            }
            lastNameIsName = false;
            continue;
        }
        ++i;
    }
}

/// Auflösen EINES Verbrauchers: Content scannen (Konkatenations-Regel des
/// V2-5-Fix), Namen über die Kategorie-Maps buchen, benutzte Formen
/// rekursiv auflösen. Liefert die Scan-Vollständigkeit.
bool rgc_walk_consumer(std::vector<QPDFObjectHandle> const& contents,
                       QPDFObjectHandle const& resources, rgc_walk& w,
                       int depth)
{
    if (depth > 16) { return false; }
    if (resources.isNull() || !resources.isDictionary()) { return true; }
    if (!rgc_register_maps(resources, w)) { return false; }

    // Bucket-Keys dieses Verbrauchers (für die Buchung der Namen).
    std::string mapKeys[rgc_category_count];
    bool keysOk = true;
    for (int c = 0; c < rgc_category_count; ++c) {
        QPDFObjectHandle sub = resources.getKey(rgc_category_key(
            static_cast<rgc_category>(c)));
        if (!sub.isDictionary()) { continue; }
        if (!rgc_bucket_key(sub, mapKeys[c])) { keysOk = false; }
    }

    // A shared Form can occur under different inherited resource maps.
    // Cache the ordered content identities together with all effective map
    // keys, never the Form identity alone. Mark before descent to break cycles.
    std::string consumerKey;
    bool cacheable = keysOk && !contents.empty();
    for (auto const& stream : contents) {
        if (!stream.isIndirect()) { cacheable = false; break; }
        consumerKey += std::to_string(stream.getObjectID()) + ":"
            + std::to_string(stream.getGeneration()) + ";";
    }
    for (auto const& key : mapKeys) {
        consumerKey += std::to_string(key.size()) + ":" + key;
    }
    if (cacheable && !w.visitedConsumers.insert(consumerKey).second) {
        return true;
    }

    // Content konkatenieren (V2-5: Zustände dürfen Array-Grenzen teilen;
    // V2-8: nur vollständig auflösbare Filterketten sind scanbar).
    std::string bytes;
    bool scanned = true;
    for (auto const& stream : contents) {
        std::string part;
        if (!stream.isStream()
            || !font6_content_stream_bytes(stream, part)) {
            scanned = false;
            continue;
        }
        if (part.empty()) { continue; }
        if (!bytes.empty()) { bytes.push_back(' '); }
        if (bytes.size() + part.size() > font5_concat_budget_bytes) {
            scanned = false;
            break;
        }
        bytes += part;
    }
    if (!bytes.empty() && keysOk) {
        rgc_scan_tokens(bytes, mapKeys, w);
    }

    if (!scanned || !keysOk) {
        rgc_protect_maps(resources, w);
        return false;
    }

    // Benutzte Einträge rekursiv auflösen (Formen, SMask-Gruppen, tiling
    // Patterns) – deren Maps brauchen ihre eigene Nutzungsbuchung.
    if (keysOk) {
        for (int c = 0; c < rgc_category_count; ++c) {
            auto it = w.buckets[c].find(mapKeys[c]);
            if (it == w.buckets[c].end() || it->second.usedNames.empty()) {
                continue;
            }
            QPDFObjectHandle sub = resources.getKey(rgc_category_key(
                static_cast<rgc_category>(c)));
            if (!sub.isDictionary()) { continue; }
            for (auto const& name : it->second.usedNames) {
                QPDFObjectHandle value = sub.getKey("/" + name);
                if (!value.isIndirect()) { continue; }
                rgc_walk_object(value, resources, w, depth + 1);
            }
        }
    }
    return scanned;
}

/// Rohbytes eines entfernteten Werts schätzen: Streams direkt, in Arrays/
/// Dicts indirekte Stream-Kinder (z. B. [/ICCBased …]-Farbräume).
long long rgc_estimate_bytes(QPDFObjectHandle const& value, int depth)
{
    if (depth > 8) { return 0; }
    try {
        if (value.isStream()) {
            QPDFObjectHandle stream = value;   // getRawStreamData ist nicht const
            std::shared_ptr<Buffer> raw = stream.getRawStreamData();
            return raw ? static_cast<long long>(raw->getSize()) : 0;
        }
        if (value.isArray()) {
            long long total = 0;
            for (auto const& item : value.getArrayAsVector()) {
                total += rgc_estimate_bytes(item, depth + 1);
            }
            return total;
        }
        if (value.isDictionary()) {
            long long total = 0;
            std::set<std::string> const keys = value.getKeys();
            for (auto const& key : keys) {
                total += rgc_estimate_bytes(value.getKey(key), depth + 1);
            }
            return total;
        }
    } catch (...) {
        return 0;
    }
    return 0;
}

} // namespace

int pdfcore_remove_unused_resources(pdfcore_document_t *doc,
                                    pdfcore_resource_gc_stats_t *stats)
{
    if (!doc) { return PDFCORE_ERR_OPEN; }
    if (stats) {
        stats->xobjects_removed = 0;
        stats->extgstates_removed = 0;
        stats->colorspaces_removed = 0;
        stats->patterns_removed = 0;
        stats->shadings_removed = 0;
        stats->properties_removed = 0;
        stats->estimated_bytes_saved = 0;
    }
    try {
        // Fallback: verschlüsselte Dokumente bleiben unangetastet.
        if (doc->qpdf.getTrailer().hasKey("/Encrypt")) { return PDFCORE_OK; }

        QPDFObjectHandle root = doc->qpdf.getRoot();

        rgc_walk w;
        // Struktur-Tagging und optionale Inhalte referenzieren Properties
        // auf Wegen, die kein BDC-Name abdeckt (MCID-/OC-Vertrag) – solche
        // Dokumente behalten ihre Properties-Maps KOMPLETT.
        if (root.hasKey("/StructTreeRoot") || root.hasKey("/OCProperties")) {
            w.protectProperties = true;
        }

        // /AcroForm/DR: Feld-DA-Strings nutzen die Map ohne Seitenevent –
        // die Default-Ressourcen bleiben grundsätzlich unberäumt.
        {
            QPDFObjectHandle acro = root.getKey("/AcroForm");
            if (acro.isDictionary()) {
                QPDFObjectHandle dr = acro.getKey("/DR");
                if (dr.isDictionary()) {
                    // Registrieren + sofort schützen: Benutzung bleibt leer.
                    if (rgc_register_maps(dr, w)) {
                        rgc_protect_maps(dr, w);
                    }
                }
            }
        }

        // OC-Beliebigkeit: Ein /OC auf EINEM erreichbaren XObject schützt
        // ALLE Properties-Maps (der Marker lebt dort). Strukturierte
        // Erreichbarkeitsanalyse lohnt den Aufwand nicht.
        if (!w.protectProperties) {
            std::vector<QPDFPageObjectHelper> pages =
                QPDFPageDocumentHelper(doc->qpdf).getAllPages();
            bool ocFound = false;
            for (auto const& ph : pages) {
                QPDFObjectHandle page = ph.getObjectHandle();
                QPDFObjectHandle res = font5_inherited_resources(page);
                if (!res.isDictionary()) { continue; }
                QPDFObjectHandle xo = res.getKey("/XObject");
                if (!xo.isDictionary()) { continue; }
                std::set<std::string> const keys = xo.getKeys();
                for (auto const& name : keys) {
                    QPDFObjectHandle value = xo.getKey(name);
                    if (value.isStream() && dict_of(value).hasKey("/OC")) {
                        ocFound = true;
                        break;
                    }
                }
                if (ocFound) { break; }
            }
            if (ocFound) { w.protectProperties = true; }
        }

        // Verbraucher ablaufen: Seiten (inkl. Vererbung), Annotations-
        // Appearances, Type3-CharProcs. Formen rekursiert rgc_walk_consumer
        // selbst über Do.
        {
            std::vector<QPDFPageObjectHelper> pages =
                QPDFPageDocumentHelper(doc->qpdf).getAllPages();
            for (auto const& ph : pages) {
                QPDFObjectHandle page = ph.getObjectHandle();
                QPDFObjectHandle resources = font5_inherited_resources(page);
                if (!resources.isNull() && !resources.isDictionary()) {
                    resources = QPDFObjectHandle::newNull();
                }
                rgc_walk_consumer(font5_page_contents(page), resources, w, 0);

                QPDFObjectHandle annots = page.getKey("/Annots");
                if (!annots.isArray()) { continue; }
                for (auto const& annot : annots.getArrayAsVector()) {
                    if (!annot.isDictionary()) { continue; }
                    QPDFObjectHandle ap = annot.getKey("/AP");
                    if (!ap.isDictionary()) { continue; }
                    for (char const* key : { "/N", "/D", "/R" }) {
                        QPDFObjectHandle appearance = ap.getKey(key);
                        std::vector<QPDFObjectHandle> streams;
                        if (appearance.isStream()) {
                            streams.push_back(appearance);
                        } else if (appearance.isArray()) {
                            for (auto const& item :
                                 appearance.getArrayAsVector()) {
                                if (item.isStream()) { streams.push_back(item); }
                            }
                        }
                        for (auto const& stream : streams) {
                            QPDFObjectHandle own =
                                dict_of(stream).getKey("/Resources");
                            if (!own.isNull() && !own.isDictionary()) {
                                own = QPDFObjectHandle::newNull();
                            }
                            if (own.isNull()) { own = resources; }
                            std::vector<QPDFObjectHandle> one = { stream };
                            rgc_walk_consumer(one, own, w, 1);
                        }
                    }
                }
            }
            // Type3-CharProcs können gs/Do nutzen – mitzählen.
            std::vector<QPDFObjectHandle> objects = doc->qpdf.getAllObjects();
            for (auto const& obj : objects) {
                if (!font5_is_font_dict(obj)) { continue; }
                QPDFObjectHandle subtype = obj.getKey("/Subtype");
                if (!(subtype.isName() && subtype.getName() == "/Type3")) {
                    continue;
                }
                QPDFObjectHandle res = obj.getKey("/Resources");
                if (!res.isNull() && !res.isDictionary()) {
                    res = QPDFObjectHandle::newNull();
                }
                std::vector<QPDFObjectHandle> charProcs;
                QPDFObjectHandle cp = obj.getKey("/CharProcs");
                if (cp.isDictionary()) {
                    std::set<std::string> const keys = cp.getKeys();
                    for (auto const& name : keys) {
                        QPDFObjectHandle proc = cp.getKey(name);
                        if (proc.isStream()) { charProcs.push_back(proc); }
                    }
                }
                rgc_walk_consumer(charProcs, res, w, 1);
            }
        }

        // Beräumen: nur vollständig gescannte Buckets; Properties je nach
        // Schutzpolitik. Font-Maps gehören nicht zu den Kategorien.
        int *counters[rgc_category_count] = {
            stats ? &stats->xobjects_removed : nullptr,
            stats ? &stats->extgstates_removed : nullptr,
            stats ? &stats->colorspaces_removed : nullptr,
            stats ? &stats->patterns_removed : nullptr,
            stats ? &stats->shadings_removed : nullptr,
            stats ? &stats->properties_removed : nullptr,
        };
        long long savedBytes = 0;
        for (int c = 0; c < rgc_category_count; ++c) {
            if (c == rgc_properties && w.protectProperties) { continue; }
            for (auto& pair : w.buckets[c]) {
                rgc_bucket& bucket = pair.second;
                if (!bucket.allScanned) { continue; }
                for (auto& map : bucket.maps) {
                    if (!map.isDictionary()) { continue; }
                    std::set<std::string> const keys = map.getKeys();
                    for (auto const& key : keys) {
                        if (bucket.usedNames.count(rgc_name(key)) != 0) {
                            continue;
                        }
                        QPDFObjectHandle value = map.getKey(key);
                        savedBytes += rgc_estimate_bytes(value, 0);
                        map.removeKey(key);
                        if (counters[c]) { *counters[c] += 1; }
                    }
                }
            }
        }

        if (stats) {
            stats->estimated_bytes_saved = savedBytes;
        }
        return PDFCORE_OK;
    } catch (const QPDFExc&) {
        return PDFCORE_ERR_CHECK_FAILED;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Phase V2-1 (Masterplan §7.5) – Native Byte-Attribution.
// Definitionen und Klassifikationsreihenfolge siehe pdfcore.h. Der Grad an
// Genauigkeit ist bewusst „deterministisch und dokumentiert", nicht
// „vollständig": Jede Kategorie ist vor und nach einem Pass auf DEMSELBEN
// Dokument mit derselben Definition messbar.
// ============================================================================

namespace {

/* Terminale Bildklasse anhand der /Filter-Kette (letzte bekannte Filter
 * entscheidet, ASCII-Transportfilter werden übergangen) – Muster wie
 * image_filter_key in Scripts/byte-attribution.py. */
char const* space_image_class(QPDFObjectHandle dict)
{
    QPDFObjectHandle f = dict.getKey("/Filter");
    std::vector<std::string> filters;
    if (f.isName()) {
        filters.push_back(f.getName());
    } else if (f.isArray()) {
        for (auto const& item : f.getArrayAsVector()) {
            if (item.isName()) { filters.push_back(item.getName()); }
        }
    }
    for (auto it = filters.rbegin(); it != filters.rend(); ++it) {
        if (*it == "/DCTDecode") { return "jpeg"; }
        if (*it == "/JPXDecode") { return "jpx"; }
        if (*it == "/CCITTFaxDecode") { return "ccitt"; }
        if (*it == "/JBIG2Decode") { return "jbig2"; }
        if (*it == "/FlateDecode") { return "flate_image"; }
    }
    return "other_image";
}

/* Objekt-IDs aller /Contents-Streams der Seiten (direkt oder Array,
 * indirekte Auflösung). Nicht erreichbare Verweise fallen still weg –
 * sie tragen ohnehin keine Bytes. */
void collect_page_content_ids(QPDF& qpdf, std::set<QPDFObjGen>& out)
{
    for (auto& page : qpdf.getAllPages()) {
        try {
            QPDFObjectHandle contents = page.getKey("/Contents");
            // Indirekte Objekte löst qpdf transparent auf: isStream() gilt
            // dem referenzierten Objekt, getObjGen() dessen Identität.
            if (contents.isStream()) {
                out.insert(contents.getObjGen());
                continue;
            }
            if (!contents.isArray()) { continue; }
            for (auto const& item : contents.getArrayAsVector()) {
                if (item.isStream()) { out.insert(item.getObjGen()); }
            }
        } catch (...) {
            // Einzelne defekte Seite: Der Rest des Dokuments bleibt messbar.
        }
    }
}

} // namespace

// MARK: - Content-Stream-Minify (verlustfrei, Whitelist-Regeln)
//
// Kompaktiert Seiten-/Contents- und Form-XObject-Streams OHNE jede
// semantische Änderung – ausschließlich:
//   1. Whitespace-Minimierung (ein Space nur dort, wo die Grammatik ihn
//      zum Trennen braucht; Kommentare bleiben unangetastet).
//   2. Zahlen-Normalisierung (Trailing-Nullen, führendes +, führende
//      Nullen – strikt wertexakt, niemals gerundet).
//   3. Leere `q Q`-Paare streichen (Graphics-State-Push/Pop ohne Inhalt
//      ist beweisbar ein No-op).
//
// Alles andere (Operatoren, Operanden-Reihenfolge, Strings, Inline-Images,
// Dictionaries, cm-Faltung, Kommentar-Entfernung) ist bewusst NICHT
// enthalten. Unbekannte Bytes, Inline-Image-Fehlformen, Streams über dem
// Größen-Cap oder ohne Größenvorteil bleiben unangetastet (fail-closed pro
// Stream). Nur Filterketten ohne Filter oder mit EINEM /FlateDecode ohne
// /DecodeParms – alles andere kann die Bridge nicht byteexakt
// zurückschreiben und wird übersprungen (der qpdf-Struktur-Pass packt es
// ohnehin mit Level 9 nach).

namespace {

/// Token-Typen des Minify-Parsers. Strings/Hex/Dicts/Arrays/Inline-Images
/// und Kommentare sind opake Einheiten (verbatim kopiert); nur Zahlen werden
/// normalisiert, nur Top-Level-Operatoren q/Q gefiltert.
enum class MinTok { Num, Op, Name, Str, Hex, Dict, Arr, Inline, Comment };

struct MinToken {
    MinTok type;
    std::string text;
};

/// Bedarf ein Space zwischen zwei Tokens? Alphanumerische Tokens
/// (Zahl/Operator/Name) sowie Inline-Images (enden auf "EI", beginnen mit
/// "BI" – beides Buchstaben!) können miteinander verschmelzen – alles, was
/// mit einem Delimiter beginnt oder endet (Strings, Hex, Dicts, Arrays,
/// Kommentare, Namen nach '/'), trennt sich selbst.
bool minNeedSpace(MinTok prev, MinTok cur)
{
    bool prevAlpha = (prev == MinTok::Num || prev == MinTok::Op
                      || prev == MinTok::Name || prev == MinTok::Inline);
    bool curAlpha = (cur == MinTok::Num || cur == MinTok::Op
                     || cur == MinTok::Inline);
    return prevAlpha && curAlpha;
}

bool minIsWs(unsigned char ch)
{
    return ch == 0 || ch == 9 || ch == 10 || ch == 12 || ch == 13
        || ch == 32;
}

bool minIsDelim(unsigned char ch)
{
    switch (ch) {
    case 0: case 9: case 10: case 12: case 13: case 32:
    case '(': case ')': case '<': case '>': case '[': case ']':
    case '{': case '}': case '/': case '%':
        return true;
    default:
        return false;
    }
}

bool minIsOpChar(unsigned char ch)
{
    return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')
        || (ch >= '0' && ch <= '9') || ch == '*' || ch == '\''
        || ch == '"';
}

/// Wertexakte Zahlen-Normalisierung: führendes +, führende Nullen und
/// Trailing-Nullen fallen; gerundet wird nie. Länger als das Original wird
/// es nie – sonst gilt das Original.
bool minNormNumber(std::string const& t, std::string& out)
{
    size_t i = 0;
    bool neg = false;
    if (i < t.size() && (t[i] == '+' || t[i] == '-')) {
        neg = (t[i] == '-');
        ++i;
    }
    size_t intStart = i;
    while (i < t.size() && t[i] >= '0' && t[i] <= '9') { ++i; }
    std::string intPart = t.substr(intStart, i - intStart);
    std::string fracPart;
    if (i < t.size() && t[i] == '.') {
        ++i;
        size_t fracStart = i;
        while (i < t.size() && t[i] >= '0' && t[i] <= '9') { ++i; }
        fracPart = t.substr(fracStart, i - fracStart);
    }
    // Rest muss leer sein, mindestens eine Ziffer insgesamt.
    if (i != t.size() || (intPart.empty() && fracPart.empty())) {
        return false;
    }
    // Führende Nullen (eine Stelle bleibt).
    size_t nz = intPart.find_first_not_of('0');
    intPart = (nz == std::string::npos) ? "0" : intPart.substr(nz);
    // Trailing-Nullen der Fraktion.
    while (!fracPart.empty() && fracPart.back() == '0') {
        fracPart.pop_back();
    }
    std::string norm;
    if (neg && !(intPart == "0" && fracPart.empty())) { norm.push_back('-'); }
    norm += intPart;
    if (!fracPart.empty()) { norm.push_back('.'); norm += fracPart; }
    // "-0" wird zu "0" (wertexakt, kürzer).
    if (norm.size() < t.size()) { out = norm; return true; }
    out = t;
    return true;
}

struct MinParser {
    std::string const& in;
    size_t pos = 0;
    bool failed = false;

    explicit MinParser(std::string const& bytes) : in(bytes) {}

    void skipWs()
    {
        while (pos < in.size()
               && minIsWs(static_cast<unsigned char>(in[pos]))) {
            ++pos;
        }
    }

    // Literalstring ab '(' (pos zeigt darauf), verbatim inkl. Hülle.
    bool readLiteral(std::string& out)
    {
        size_t start = pos;
        ++pos; // '('
        int depth = 1;
        while (pos < in.size()) {
            unsigned char c = static_cast<unsigned char>(in[pos]);
            if (c == '\\') {
                pos += 2;
                continue;
            }
            if (c == '(') { ++depth; }
            if (c == ')') {
                --depth;
                ++pos;
                if (depth == 0) break;
                continue;
            }
            ++pos;
        }
        if (depth != 0) { return false; }
        out = in.substr(start, pos - start);
        return true;
    }

    // Hexstring ab '<' (kein '<<'), verbatim inkl. Hülle.
    bool readHex(std::string& out)
    {
        size_t start = pos;
        ++pos; // '<'
        while (pos < in.size() && in[pos] != '>') { ++pos; }
        if (pos >= in.size()) { return false; }
        ++pos; // '>'
        out = in.substr(start, pos - start);
        return true;
    }

    // Inline-Image ab "BI"-Operator: "BI … ID <binär> EI", verbatim.
    // Aufruf NACHDEM "BI" als Operator gelesen wurde (Start wird
    // mitgegeben); Fehlform → false (Stream wird übersprungen).
    bool readInline(size_t biStart, std::string& out)
    {
        size_t i = pos;
        size_t const n = in.size();
        auto isWs = [](unsigned char ch) { return minIsWs(ch); };
        // "ID" als eigenständiges Token nach Whitespace finden.
        bool foundID = false;
        size_t dataStart = 0;
        while (i < n) {
            if (isWs(static_cast<unsigned char>(in[i]))) { ++i; continue; }
            if (in[i] == 'I' && i + 1 < n && in[i + 1] == 'D'
                && (i + 2 >= n || minIsDelim(
                        static_cast<unsigned char>(in[i + 2])))) {
                i += 2;
                // Genau EIN Whitespace nach ID gehört zum Tokenizer.
                if (i < n && isWs(static_cast<unsigned char>(in[i]))) { ++i; }
                dataStart = i;
                foundID = true;
                break;
            }
            // Nur Dict-/Namen-Material (…/W 1…) zwischen BI und ID.
            if (minIsOpChar(static_cast<unsigned char>(in[i]))
                || in[i] == '/' || in[i] == '[' || in[i] == ']'
                || (in[i] >= '0' && in[i] <= '9')
                || in[i] == '.' || in[i] == '+' || in[i] == '-'
                || (in[i] == '<' && i + 1 < n && in[i + 1] != '<')
                || in[i] == '>') {
                ++i;
                continue;
            }
            return false;
        }
        if (!foundID) { return false; }
        // Binärdaten bis Whitespace + "EI" + Delimiter/EOF.
        i = dataStart;
        while (i < n) {
            if (isWs(static_cast<unsigned char>(in[i]))) {
                size_t j = i + 1;
                if (j + 1 < n && in[j] == 'E' && in[j + 1] == 'I'
                    && (j + 2 >= n || minIsDelim(
                            static_cast<unsigned char>(in[j + 2])))) {
                    pos = j + 2;
                    out = in.substr(biStart, pos - biStart);
                    return true;
                }
            }
            ++i;
        }
        return false;
    }

    bool parseTokens(std::vector<MinToken>& tokens, char terminator)
    {
        // terminator: 0 = Top-Level (bis EOF), ']' = Array, '>' x2 = Dict.
        while (true) {
            skipWs();
            if (pos >= in.size()) {
                return terminator == 0;
            }
            unsigned char c = static_cast<unsigned char>(in[pos]);
            if (terminator == ']' && c == ']') {
                ++pos;
                return true;
            }
            if (terminator == '>' && c == '>'
                && pos + 1 < in.size() && in[pos + 1] == '>') {
                pos += 2;
                return true;
            }
            if (c == '%') {
                size_t start = pos;
                while (pos < in.size() && in[pos] != '\n'
                       && in[pos] != '\r') {
                    ++pos;
                }
                // Der Zeilenumbruch gehört zum Kommentar-Token: Ohne ihn
                // würde das Folgetoken in den Kommentar hineinlaufen und
                // Inhalt verloren gehen. Am Stream-Ende ohne Umbruch endet
                // das Token (nichts folgt mehr).
                if (pos < in.size()) {
                    if (in[pos] == '\r') {
                        ++pos;
                        if (pos < in.size() && in[pos] == '\n') { ++pos; }
                    } else {
                        ++pos; // '\n'
                    }
                }
                tokens.push_back({ MinTok::Comment,
                                   in.substr(start, pos - start) });
                continue;
            }
            if (c == '(') {
                std::string s;
                if (!readLiteral(s)) { return false; }
                tokens.push_back({ MinTok::Str, s });
                continue;
            }
            if (c == '<') {
                if (pos + 1 < in.size() && in[pos + 1] == '<') {
                    pos += 2;
                    std::vector<MinToken> inner;
                    if (!parseTokens(inner, '>')) { return false; }
                    std::string s = "<<";
                    bool first = true;
                    MinTok prev = MinTok::Comment;
                    for (auto const& t : inner) {
                        if (!first && minNeedSpace(prev, t.type)) {
                            s.push_back(' ');
                        }
                        s += t.text;
                        prev = t.type;
                        first = false;
                    }
                    if (!first
                        && (prev == MinTok::Num || prev == MinTok::Op
                            || prev == MinTok::Name)) {
                        s.push_back(' ');
                    }
                    s += ">>";
                    tokens.push_back({ MinTok::Dict, s });
                    continue;
                }
                std::string s;
                if (!readHex(s)) { return false; }
                tokens.push_back({ MinTok::Hex, s });
                continue;
            }
            if (c == '[') {
                ++pos;
                std::vector<MinToken> inner;
                if (!parseTokens(inner, ']')) { return false; }
                std::string s = "[";
                bool first = true;
                MinTok prev = MinTok::Comment;
                for (auto const& t : inner) {
                    if (!first && minNeedSpace(prev, t.type)) {
                        s.push_back(' ');
                    }
                    s += t.text;
                    prev = t.type;
                    first = false;
                }
                s.push_back(']');
                tokens.push_back({ MinTok::Arr, s });
                continue;
            }
            if (c == '/') {
                size_t start = pos;
                ++pos;
                while (pos < in.size()
                       && !minIsDelim(
                           static_cast<unsigned char>(in[pos]))) {
                    ++pos;
                }
                if (pos - start < 2) { return false; } // "/" allein
                tokens.push_back({ MinTok::Name,
                                   in.substr(start, pos - start) });
                continue;
            }
            if ((c >= '0' && c <= '9') || c == '+' || c == '-'
                || c == '.') {
                // Zahl: optionales Vorzeichen, Ziffern, höchstens EIN Punkt.
                size_t start = pos;
                if (c == '+' || c == '-') { ++pos; }
                bool anyDigit = false;
                bool seenDot = false;
                while (pos < in.size()) {
                    unsigned char d =
                        static_cast<unsigned char>(in[pos]);
                    if (d >= '0' && d <= '9') {
                        anyDigit = true;
                        ++pos;
                    } else if (d == '.' && !seenDot) {
                        seenDot = true;
                        ++pos;
                    } else {
                        break;
                    }
                }
                std::string raw = in.substr(start, pos - start);
                if (!anyDigit) { return false; }
                std::string norm;
                if (!minNormNumber(raw, norm)) { return false; }
                tokens.push_back({ MinTok::Num, norm });
                continue;
            }
            if (minIsOpChar(c)) {
                size_t start = pos;
                while (pos < in.size()
                       && minIsOpChar(
                           static_cast<unsigned char>(in[pos]))) {
                    ++pos;
                }
                std::string op = in.substr(start, pos - start);
                if (op == "BI") {
                    std::string blob;
                    if (!readInline(start, blob)) { return false; }
                    tokens.push_back({ MinTok::Inline, blob });
                } else {
                    tokens.push_back({ MinTok::Op, op });
                }
                continue;
            }
            // Unbekanntes Byte (u. a. '{', '}', '\\', '@', '|') –
            // kein Whitelist-Token: Stream bleibt unangetastet.
            return false;
        }
    }
};

/// Entfernt adjazente Top-Level `q`/`Q`-Paare (Fixpunkt). Kommentare
/// zwischen beiden bleiben erhalten (reine Trennzeichen ohne Semantik).
void minDropEmptySaveRestore(std::vector<MinToken>& tokens)
{
    bool changed = true;
    while (changed) {
        changed = false;
        std::vector<MinToken> out;
        for (size_t i = 0; i < tokens.size(); ++i) {
            if (i + 1 < tokens.size() && tokens[i].type == MinTok::Op
                && tokens[i].text == "q" && tokens[i + 1].type == MinTok::Op
                && tokens[i + 1].text == "Q") {
                ++i; // Beide fallen.
                changed = true;
                continue;
            }
            // Kommentar zwischen q und Q überbrücken.
            if (i + 2 < tokens.size() && tokens[i].type == MinTok::Op
                && tokens[i].text == "q"
                && tokens[i + 1].type == MinTok::Comment
                && tokens[i + 2].type == MinTok::Op
                && tokens[i + 2].text == "Q") {
                out.push_back(tokens[i + 1]);
                i += 2;
                changed = true;
                continue;
            }
            out.push_back(tokens[i]);
        }
        tokens.swap(out);
    }
}

/// Minifiziert EINEN dekodierten Content-Strom. false = unverändert lassen
/// (Fehlform, Cap, kein Vorteil). true + out = kleinere Bytes.
bool minMinifyOne(std::string const& decoded, std::string& out)
{
    MinParser parser(decoded);
    std::vector<MinToken> tokens;
    if (!parser.parseTokens(tokens, 0)) { return false; }
    minDropEmptySaveRestore(tokens);
    std::string compact;
    compact.reserve(decoded.size());
    bool first = true;
    MinTok prev = MinTok::Comment;
    for (auto const& t : tokens) {
        if (!first && minNeedSpace(prev, t.type)) {
            compact.push_back(' ');
        }
        compact += t.text;
        prev = t.type;
        first = false;
    }
    if (compact.size() >= decoded.size()) { return false; }
    out.swap(compact);
    return true;
}

} // namespace

/// Größen-Cap pro Stream (dekodiert): Darüber lohnt kein Halten im Speicher.
long const minContentStreamCapBytes = 8 * 1024 * 1024;

int pdfcore_minify_content_streams(pdfcore_document_t *doc,
                                   int *streamsMinified,
                                   long long *bytesSavedEstimate)
{
    if (!doc) { return -1; }
    if (streamsMinified) { *streamsMinified = 0; }
    if (bytesSavedEstimate) { *bytesSavedEstimate = 0; }
    try {
        // Ziele: Seiten-/Contents + Form-XObjects (Tiling-Patterns bewusst
        // ausgenommen – selten, eigene Semantik, eigener Pass).
        std::set<QPDFObjGen> pageContents;
        collect_page_content_ids(doc->qpdf, pageContents);

        struct Target {
            QPDFObjectHandle stream;
        };
        std::vector<Target> targets;
        std::set<QPDFObjGen> seen;
        for (auto const& og : pageContents) {
            QPDFObjectHandle obj =
                doc->qpdf.getObjectByObjGen(og);
            if (obj.isStream() && seen.insert(og).second) {
                targets.push_back({ obj });
            }
        }
        for (auto& obj : doc->qpdf.getAllObjects()) {
            if (!obj.isStream()) { continue; }
            QPDFObjectHandle sub =
                dict_of(obj).getKey("/Subtype");
            if (!(sub.isName() && sub.getName() == "/Form")) {
                continue;
            }
            if (seen.insert(obj.getObjGen()).second) {
                targets.push_back({ obj });
            }
        }

        int count = 0;
        long long saved = 0;
        for (auto const& target : targets) {
            QPDFObjectHandle stream = target.stream;
            QPDFObjectHandle dict = dict_of(stream);
            QPDFObjectHandle filter = dict.getKey("/Filter");
            bool plain = filter.isNull();
            bool flateOnly = filter_is_flate_only(dict);
            // Nur verpackungsfreie oder reine Flate-Streams – Ketten mit
            // LZW/ASCII85/RunLength kann die Bridge nicht zurückschreiben;
            // /DecodeParms (z. B. Predictor-Semantik) bleibt unberührt.
            if (!plain && !flateOnly) { continue; }
            if (!plain && dict.hasKey("/DecodeParms")) { continue; }

            std::string decoded;
            if (!font6_content_stream_bytes(stream, decoded)) { continue; }
            if (decoded.empty()
                || decoded.size()
                       > static_cast<size_t>(minContentStreamCapBytes)) {
                continue;
            }
            std::string minified;
            if (!minMinifyOne(decoded, minified)) { continue; }

            std::shared_ptr<Buffer> rawBuf = stream.getRawStreamData();
            long long before =
                rawBuf ? static_cast<long long>(rawBuf->getSize()) : 0;

            if (plain) {
                stream.replaceStreamData(minified, filter,
                                         dict.getKey("/DecodeParms"));
                long long after =
                    static_cast<long long>(minified.size());
                if (after < before) {
                    saved += before - after;
                    ++count;
                }
                continue;
            }

            // Flate: mit Level 9 zurückschreiben (wie der Struktur-Pass).
            uLong bound = compressBound(
                static_cast<uLong>(minified.size()));
            std::string packed;
            packed.resize(static_cast<size_t>(bound));
            uLong destLen = bound;
            if (compress2(
                    reinterpret_cast<Bytef*>(&packed[0]), &destLen,
                    reinterpret_cast<Bytef const*>(minified.data()),
                    static_cast<uLong>(minified.size()),
                    Z_BEST_COMPRESSION)
                != Z_OK) {
                continue;
            }
            packed.resize(static_cast<size_t>(destLen));
            stream.replaceStreamData(packed, filter,
                                     dict.getKey("/DecodeParms"));
            long long after = static_cast<long long>(packed.size());
            if (after < before) {
                saved += before - after;
                ++count;
            }
        }
        if (streamsMinified) { *streamsMinified = count; }
        if (bytesSavedEstimate) { *bytesSavedEstimate = saved; }
        return 0;
    } catch (...) {
        return -1;
    }
}
int pdfcore_space_inventory(pdfcore_document_t *doc,
                            long long document_bytes,
                            pdfcore_space_inventory_t *out)
{
    if (!doc || !out) { return PDFCORE_ERR_OPEN; }
    std::memset(out, 0, sizeof(*out));
    try {
        out->document_bytes = document_bytes > 0 ? document_bytes : 0;

        std::set<QPDFObjGen> pageContents;
        collect_page_content_ids(doc->qpdf, pageContents);

        long long attributed = 0;
        for (auto& obj : doc->qpdf.getAllObjects()) {
            try {
            if (!obj.isStream()) { continue; }
            QPDFObjectHandle dict = obj.getDict();
            auto raw = obj.getRawStreamData();
            long long bytes = raw ? static_cast<long long>(raw->getSize()) : 0;

            QPDFObjectHandle type = dict.getKey("/Type");
            std::string typeName
                = type.isName() ? type.getName() : std::string();
            QPDFObjectHandle subtype = dict_of(obj).getKey("/Subtype");
            std::string subName
                = subtype.isName() ? subtype.getName() : std::string();

            char const* target = nullptr;
            if (subName == "/Image") {
                char const* imageClass = space_image_class(dict);
                if (std::strcmp(imageClass, "jpeg") == 0) {
                    out->jpeg_bytes += bytes;
                } else if (std::strcmp(imageClass, "jpx") == 0) {
                    out->jpx_bytes += bytes;
                } else if (std::strcmp(imageClass, "ccitt") == 0) {
                    out->ccitt_bytes += bytes;
                } else if (std::strcmp(imageClass, "jbig2") == 0) {
                    out->jbig2_bytes += bytes;
                } else if (std::strcmp(imageClass, "flate_image") == 0) {
                    out->flate_image_bytes += bytes;
                } else {
                    out->other_image_bytes += bytes;
                }
                attributed += bytes;
                continue;
            }
            if (typeName == "/FontFile" || typeName == "/FontFile2"
                || typeName == "/FontFile3" || dict.hasKey("/Length1")) {
                target = "font_program";
            } else if (typeName == "/Metadata" || subName == "/XML") {
                target = "metadata";
            } else if (typeName == "/EmbeddedFile") {
                target = "embedded_file";
            } else if (typeName == "/ObjStm") {
                target = "object_stream";
            } else if (subName == "/Form"
                       || pageContents.count(obj.getObjGen()) > 0) {
                target = "content_stream";
            }
            if (target == nullptr) { continue; }   // Rest → unattributed

            if (std::strcmp(target, "font_program") == 0) {
                out->font_program_bytes += bytes;
            } else if (std::strcmp(target, "content_stream") == 0) {
                out->content_stream_bytes += bytes;
            } else if (std::strcmp(target, "metadata") == 0) {
                out->metadata_bytes += bytes;
            } else if (std::strcmp(target, "embedded_file") == 0) {
                out->embedded_file_bytes += bytes;
            } else if (std::strcmp(target, "object_stream") == 0) {
                out->object_stream_bytes += bytes;
            }
            attributed += bytes;
            } catch (...) {
                // Einzelnes defektes Objekt: Restbilanz fängt es auf.
            }
        }

        long long residual = out->document_bytes - attributed;
        out->unattributed_bytes = residual > 0 ? residual : 0;
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Masterplan §9.6 (V2-3b) – Exact Palette / Indexed
// ============================================================================

int pdfcore_replace_image_object_indexed(pdfcore_document_t *doc,
                                         int obj_number, int generation,
                                         const unsigned char *indices, size_t indices_len,
                                         const unsigned char *palette, size_t palette_len,
                                         int width, int height,
                                         int bits_per_component,
                                         int palette_components,
                                         int decode_applied)
{
    if (!doc || !indices || indices_len == 0 || !palette || palette_len == 0
        || width <= 0 || height <= 0) {
        return PDFCORE_ERR_OPEN;
    }
    try {
        // Strukturprüfung, bevor irgendetwas berührt wird. Die Bytes müssen
        // exakt zur Beschreibung passen – der Never-Grow und der Verlust-
        // freiheitsbeweis liegen beim Aufrufer (Swift), hier gilt: Was nicht
        // strukturell stimmig ist, wird verweigert, nicht repariert.
        if (bits_per_component != 1 && bits_per_component != 2
            && bits_per_component != 4 && bits_per_component != 8) {
            return PDFCORE_ERR_CHECK_FAILED;
        }
        if (palette_components != 1 && palette_components != 3) {
            return PDFCORE_ERR_CHECK_FAILED;
        }
        if (palette_len % static_cast<size_t>(palette_components) != 0) {
            return PDFCORE_ERR_CHECK_FAILED;
        }
        size_t const entries = palette_len / static_cast<size_t>(palette_components);
        if (entries == 0
            || entries > (static_cast<size_t>(1) << bits_per_component)) {
            // Mehr Einträge als 2^bpc könnten hinter hival zeigen – unbestimmt.
            return PDFCORE_ERR_CHECK_FAILED;
        }
        // Die Länge der Indizes kann der C-Kern nicht gegen die Zeilen-
        // packung prüfen: Die übergebenen Bytes sind bereits FLATE-KODIERT
        // (der Stream trägt /Filter /FlateDecode), die entpackte Länge
        // stünde erst nach dem Inflate fest. Die Zeilenpackung
        // (ceil(width*bpc/8) * height) ist damit Sache des Aufrufers –
        // bewiesen durch dessen bitgenaues Gate.

        QPDFObjectHandle target = find_image_object(doc->qpdf, obj_number, generation);
        if (target.isNull()) { return PDFCORE_ERR_CHECK_FAILED; }
        QPDFObjectHandle oldDict = dict_of(target);
        if (blocks_jpeg_replacement(oldDict, decode_applied != 0)) {
            return PDFCORE_ERR_CHECK_FAILED;
        }

        // Lookup IMMER als String – qpdf schreibt binäre Strings als Hex;
        // höchstens 768 Byte, der String ist die kleinste Form.
        QPDFObjectHandle lookup = QPDFObjectHandle::newString(
            std::string(reinterpret_cast<const char *>(palette), palette_len));
        QPDFObjectHandle indexed = QPDFObjectHandle::newArray();
        indexed.appendItem(QPDFObjectHandle::newName("/Indexed"));
        indexed.appendItem(QPDFObjectHandle::newName(
            palette_components == 1 ? "/DeviceGray" : "/DeviceRGB"));
        indexed.appendItem(QPDFObjectHandle::newInteger(
            static_cast<long long>(entries) - 1));
        indexed.appendItem(lookup);

        // Predictor 15 über die GEPACKTEN Indizes: /Colors 1 (ein Index je
        // Bildpunkt), /BitsPerComponent bpc, /Columns width. Jede PNG-Zeile
        // ist ceil(width*1*bpc/8) Bytes – exakt die Zeilenlänge der
        // byte-ausgerichteten Indizes oben.
        QPDFObjectHandle parms = QPDFObjectHandle::newDictionary();
        parms.replaceKey("/Predictor", QPDFObjectHandle::newInteger(15));
        parms.replaceKey("/Colors", QPDFObjectHandle::newInteger(1));
        parms.replaceKey("/BitsPerComponent",
                         QPDFObjectHandle::newInteger(bits_per_component));
        parms.replaceKey("/Columns", QPDFObjectHandle::newInteger(width));

        QPDFObjectHandle newDict = QPDFObjectHandle::newDictionary();
        newDict.replaceKey("/Type", QPDFObjectHandle::newName("/XObject"));
        newDict.replaceKey("/Subtype", QPDFObjectHandle::newName("/Image"));
        newDict.replaceKey("/Filter", QPDFObjectHandle::newName("/FlateDecode"));
        newDict.replaceKey("/DecodeParms", parms);
        newDict.replaceKey("/ColorSpace", indexed);
        newDict.replaceKey("/BitsPerComponent",
                           QPDFObjectHandle::newInteger(bits_per_component));
        newDict.replaceKey("/Width", QPDFObjectHandle::newInteger(width));
        newDict.replaceKey("/Height", QPDFObjectHandle::newInteger(height));

        // Masken- und Erklärbeziehungen mitnehmen (dieselbe Politik wie beim
        // Bilevel-Ersatz) – die Verweigerung steht oben in
        // blocks_jpeg_replacement (Farbschlüssel-/Stencil-/Decode-Fälle).
        for (char const* key : {"/SMask", "/Mask", "/SMaskInData"}) {
            QPDFObjectHandle v = oldDict.getKey(key);
            if (!v.isNull()) { newDict.replaceKey(key, v); }
        }
        for (char const* key : {"/Intent", "/Interpolate", "/Metadata",
                                "/StructParent", "/OC"}) {
            QPDFObjectHandle v = oldDict.getKey(key);
            if (!v.isNull()) { newDict.replaceKey(key, v); }
        }

        std::string data(reinterpret_cast<const char *>(indices), indices_len);
        target.replaceStreamData(
            data, QPDFObjectHandle::newNull(), QPDFObjectHandle::newNull());
        QPDFObjectHandle streamDict = target.getDict();
        for (auto const& key : streamDict.getKeys()) {
            if (!newDict.hasKey(key) && key != "/Length") {
                streamDict.removeKey(key);
            }
        }
        for (auto const& key : newDict.getKeys()) {
            streamDict.replaceKey(key, newDict.getKey(key));
        }
        // Wie beim Flate-Ersatz: Der Index-Strom ist bereits optimiert.
        target.setFilterOnWrite(false);
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

// ============================================================================
// Phase V2-7 (Masterplan §13.7) – MRC Scan Engine: PDF-Rekonstruktion.
//
// Primitive, transaktionale Ersetzung des Full-Page-Raster-Draws einer
// Scan-Seite durch MRC-Layer:
//
//   Background-Image (JPEG) → Photo-Regionen (JPEG, Sub-Rects) →
//   Foreground-Maske (ImageMask: JBIG2 oder CCITT G4, schwarze Tinte)
//
// Die bestehende nicht-raster Semantik bleibt UNBERÜHRT: Text-Operatoren
// (inkl. unsichtbarer OCR-Layer, §13.2), Annotationen, Forms, Boxes und
// /Rotate werden nicht angefasst – ersetzt wird ausschließlich die
// cm/Do-Sequenz um das dominante Raster. Kein Seitenraster als
// Rekonstruktionsbasis (§13.7), keine lossy Symbol-Substitution (§13.11).
//
// Transaktionalität: ALLE Verweigerungsprüfungen laufen, bevor das erste
// Objekt erzeugt wird. Scheitert eine Prüfung, bleibt das Dokument
// vollständig unangetastet (PDFCORE_ERR_CHECK_FAILED).
// ============================================================================

namespace {

/* MRC-Konkatenationsbudget – dasselbe Maß wie die Font-Scans. Überschreitung
 * = Verweigerung (konservativ KEEP), nie still weiterscannen. */
size_t const mrc_concat_budget_bytes = 64 * 1024 * 1024;

/// Zahl minimal-dezimal für Content-Streams. PDF kennt KEINE
/// Exponentialschreibweise in Zahlen – %.6f mit Nullentrimmung, alles unter
/// 5e-7 wird zu "0". Genauigkeit 1e-6 pt ist um Größenordnungen feiner als
/// jede Scan-Platzierung. */
std::string mrc_num(double v)
{
    if (!(std::fabs(v) >= 5e-7)) { return "0"; }   // inkl. NaN → "0"
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.6f", v);
    std::string s(buf);
    if (s.find('.') != std::string::npos) {
        auto last = s.find_last_not_of('0');
        if (s[last] == '.') { --last; }
        s.erase(last + 1);
    }
    return s;
}

/// Fundstelle des Raster-Draws: die SECHS Zahlen vor "cm" plus das folgende
/// "/Name Do". Spann-Ende ist das Byte NACH dem "Do".
struct MrcDrawMatch {
    bool found = false;
    size_t spanStart = 0;
    size_t spanEnd = 0;
    double matrix[6] = { 1, 0, 0, 1, 0, 0 };
};

/// Scannt die KONKATENIERTEN Content-Bytes nach der cm/Do-Sequenz um `want`
/// (Name MIT führendem Slash). Rückgabe: doCount = Anzahl ALLER "Do"-Aufrufe
/// mit diesem Namen (adjazent zum cm oder nicht); match.found nur bei
/// exakt adjazenter Sequenz "n n n n n n cm /want Do".
///
/// Tokenisierung in der Art der bestehenden Scanner: Strings, Dictionaries,
/// Arrays und Inline-Images (BI…ID…EI) werden übersprungen – ihr Binärmaterial
/// darf keine Operatoren vortäuschen. Zwischen cm und /Name Do sind KEINE
/// weiteren Tokens zulässig (die übliche Scan-Schreibweise); alles andere
/// wird verwiegert, statt geraten zu werden.
void mrc_scan_draw(std::string const& c, std::string const& want,
                   MrcDrawMatch& match, int& doCount)
{
    match = MrcDrawMatch();
    doCount = 0;

    size_t i = 0;
    size_t const n = c.size();

    // Rollendes Fenster der letzten ≤ 6 Zahlen mit der Startposition der
    // ersten davon (Potential-Spann-Anfang).
    double nums[6] = { 0, 0, 0, 0, 0, 0 };
    size_t numPos[6] = { 0, 0, 0, 0, 0, 0 };
    int numCount = 0;
    bool pendingCm = false;     // letzter Operator war "cm"
    size_t cmStart = 0;
    double cmMatrix[6] = { 1, 0, 0, 1, 0, 0 };
    bool awaitDo = false;       // "/want" gesehen, "Do" erwartet

    auto clearWindow = [&]() { numCount = 0; };
    auto clearAll = [&]() { pendingCm = false; awaitDo = false; clearWindow(); };

    auto isWs = [](unsigned char ch) {
        return ch == 0 || ch == 9 || ch == 10 || ch == 12 || ch == 13 || ch == 32;
    };
    auto isDelim = [](unsigned char ch) {
        switch (ch) {
        case 0: case 9: case 10: case 12: case 13: case 32:
        case '(': case ')': case '<': case '>': case '[': case ']':
        case '{': case '}': case '/': case '%':
            return true;
        default:
            return false;
        }
    };

    while (i < n) {
        unsigned char ch = static_cast<unsigned char>(c[i]);
        if (isWs(ch)) { ++i; continue; }
        if (ch == '%') {
            while (i < n && c[i] != '\n' && c[i] != '\r') { ++i; }
            continue;
        }
        if (ch == '(') {
            // Literal-String mit Schachtelung und Escapes überspringen.
            int depth = 1;
            ++i;
            while (i < n && depth > 0) {
                if (c[i] == '\\') { i += 2; continue; }
                if (c[i] == '(') { ++depth; }
                else if (c[i] == ')') { --depth; }
                ++i;
            }
            clearAll();
            continue;
        }
        if (ch == '<') {
            if (i + 1 < n && c[i + 1] == '<') {
                // Dictionary überspringen (balanciert).
                int depth = 1;
                i += 2;
                while (i < n && depth > 0) {
                    if (c[i] == '<' && i + 1 < n && c[i + 1] == '<') { ++depth; i += 2; }
                    else if (c[i] == '>' && i + 1 < n && c[i + 1] == '>') { --depth; i += 2; }
                    else { ++i; }
                }
            } else {
                // Hex-String überspringen.
                ++i;
                while (i < n && c[i] != '>') { ++i; }
                if (i < n) { ++i; }
            }
            clearAll();
            continue;
        }
        if (ch == '[' || ch == ']' || ch == '{' || ch == '}') {
            // Array-/Prozedur-Inhalt überspringen (Operandenlisten für cm
            // enthalten sie nie; konservativ Fenster leeren).
            if (ch == '[') {
                int depth = 1;
                ++i;
                while (i < n && depth > 0) {
                    if (c[i] == '[') { ++depth; }
                    else if (c[i] == ']') { --depth; }
                    ++i;
                }
            } else {
                ++i;
            }
            clearAll();
            continue;
        }
        if (ch == '/') {
            // Name lesen.
            std::string name;
            ++i;
            while (i < n && !isDelim(static_cast<unsigned char>(c[i]))) {
                name.push_back(c[i]);
                ++i;
            }
            if (awaitDo) {
                // Auf "Do" erwartet – ein weiterer Name bricht die Adjazenz.
                clearAll();
            } else {
                pendingCm = pendingCm && ("/" + name == want);
                awaitDo = pendingCm;
                clearWindow();
            }
            continue;
        }
        if ((ch >= '0' && ch <= '9') || ch == '+' || ch == '-' || ch == '.') {
            size_t start = i;
            bool seenDot = false;
            while (i < n) {
                unsigned char d = static_cast<unsigned char>(c[i]);
                if (d >= '0' && d <= '9') { ++i; }
                else if (d == '.' && !seenDot) { seenDot = true; ++i; }
                else if ((d == '+' || d == '-') && i == start) { ++i; }
                else { break; }
            }
            if (i == start) { ++i; clearAll(); continue; }
            if (!pendingCm) {
                double v = std::atof(c.substr(start, i - start).c_str());
                if (numCount == 6) {
                    for (int k = 1; k < 6; ++k) {
                        nums[k - 1] = nums[k];
                        numPos[k - 1] = numPos[k];
                    }
                    numCount = 5;
                }
                nums[numCount] = v;
                numPos[numCount] = start;
                ++numCount;
            }
            continue;
        }
        if (isalpha(ch)) {
            size_t start = i;
            while (i < n && (isalnum(static_cast<unsigned char>(c[i]))
                             || c[i] == '*')) {
                ++i;
            }
            std::string op = c.substr(start, i - start);
            if (op == "cm") {
                if (numCount == 6) {
                    pendingCm = true;
                    cmStart = numPos[0];
                    for (int k = 0; k < 6; ++k) { cmMatrix[k] = nums[k]; }
                }
                clearWindow();
            } else if (op == "BI") {
                // Inline-Image überspringen: "ID" suchen, dann Binärdaten bis
                // whitespace-"EI"-Delimitierer (gleiche Semantik wie der
                // Swift-ContentOperatorScanner).
                bool seenId = false;
                while (i < n) {
                    if (!seenId) {
                        if (c[i] == 'I' && i + 1 < n && c[i + 1] == 'D'
                            && i >= 1 && isWs(static_cast<unsigned char>(c[i - 1]))) {
                            seenId = true;
                            i += 2;
                            if (i < n && isWs(static_cast<unsigned char>(c[i]))) { ++i; }
                            continue;
                        }
                        ++i;
                    } else {
                        if (c[i] == 'E' && i + 1 < n && c[i + 1] == 'I'
                            && i >= 1 && isWs(static_cast<unsigned char>(c[i - 1]))
                            && (i + 2 >= n
                                || isDelim(static_cast<unsigned char>(c[i + 2])))) {
                            i += 2;
                            break;
                        }
                        ++i;
                    }
                }
                clearAll();
            } else if (op == "Do") {
                if (awaitDo) {
                    ++doCount;
                    if (!match.found) {
                        match.found = true;
                        match.spanStart = cmStart;
                        match.spanEnd = i;
                        for (int k = 0; k < 6; ++k) { match.matrix[k] = cmMatrix[k]; }
                    }
                }
                clearAll();
            } else {
                clearAll();
            }
            continue;
        }
        // Unbekanntes Byte – Zustand verwerfen.
        ++i;
        clearAll();
    }
}

/// Liefert einen EINDEUTigen Layer-Namen im XObject-Dict – Kollisionen mit
/// bestehenden Schlüsseln UND bereits vergebenen Layer-Namen sind
/// ausgeschlossen (sonst übernimmt der letzte Layer den Namen des ersten).
std::string mrc_unique_name(QPDFObjectHandle const& xobjs,
                            std::vector<std::string> const& assigned,
                            char const* base)
{
    for (int index = 0; index < 10000; ++index) {
        std::string name = index == 0
            ? std::string("/") + base
            : std::string("/") + base + std::to_string(index);
        if (xobjs.hasKey(name)) { continue; }
        bool taken = false;
        for (auto const& used : assigned) {
            if (used == name) { taken = true; break; }
        }
        if (!taken) { return name; }
    }
    return std::string();
}

/// Erzeugt EINEN Layer-XObject-Stream (indirekt) gemäß kind/is_mask.
QPDFObjectHandle mrc_make_layer(pdfcore_document_t* doc,
                                pdfcore_mrc_layer_t const& layer)
{
    std::string data(reinterpret_cast<const char*>(layer.bytes), layer.len);
    QPDFObjectHandle stream =
        QPDFObjectHandle::newStream(&doc->qpdf, data);
    QPDFObjectHandle indirect = doc->qpdf.makeIndirectObject(stream);
    QPDFObjectHandle d = indirect.getDict();
    d.replaceKey("/Type", QPDFObjectHandle::newName("/XObject"));
    d.replaceKey("/Subtype", QPDFObjectHandle::newName("/Image"));
    d.replaceKey("/Width", QPDFObjectHandle::newInteger(layer.width));
    d.replaceKey("/Height", QPDFObjectHandle::newInteger(layer.height));

    if (layer.is_mask) {
        // Schablonenmaske: 1 Bit, /Decode [0 1] – Abtastwert 1 (Tinte in der
        // Bilevel-Pixelfolge) wird mit der aktuellen Füllfarbe (0 g, schwarz)
        // gemalt. Kein /ColorSpace bei ImageMask.
        d.replaceKey("/ImageMask", QPDFObjectHandle::newBool(true));
        d.replaceKey("/BitsPerComponent", QPDFObjectHandle::newInteger(1));
        QPDFObjectHandle decode = QPDFObjectHandle::newArray();
        decode.appendItem(QPDFObjectHandle::newInteger(0));
        decode.appendItem(QPDFObjectHandle::newInteger(1));
        d.replaceKey("/Decode", decode);
        if (layer.kind == 1) {
            d.replaceKey("/Filter", QPDFObjectHandle::newName("/JBIG2Decode"));
            if (layer.globals && layer.globals_len > 0) {
                QPDFObjectHandle globals = doc->qpdf.makeIndirectObject(
                    QPDFObjectHandle::newStream(&doc->qpdf, std::string(
                        reinterpret_cast<const char*>(layer.globals),
                        layer.globals_len)));
                QPDFObjectHandle parms = QPDFObjectHandle::newDictionary();
                parms.replaceKey("/JBIG2Globals", globals);
                d.replaceKey("/DecodeParms", parms);
            }
        } else {
            d.replaceKey("/Filter", QPDFObjectHandle::newName("/CCITTFaxDecode"));
            QPDFObjectHandle parms = QPDFObjectHandle::newDictionary();
            parms.replaceKey("/K", QPDFObjectHandle::newInteger(-1));
            parms.replaceKey("/Columns",
                             QPDFObjectHandle::newInteger(layer.width));
            parms.replaceKey("/Rows",
                             QPDFObjectHandle::newInteger(layer.height));
            parms.replaceKey("/BlackIs1", QPDFObjectHandle::newBool(true));
            d.replaceKey("/DecodeParms", parms);
        }
        return indirect;
    }

    // Bildlayer (Hintergrund/Photos): 8 Bit, JPEG.
    d.replaceKey("/BitsPerComponent", QPDFObjectHandle::newInteger(8));
    d.replaceKey("/ColorSpace", QPDFObjectHandle::newName(
        layer.components == 1 ? "/DeviceGray" : "/DeviceRGB"));
    d.replaceKey("/Filter", QPDFObjectHandle::newName("/DCTDecode"));
    return indirect;
}

/// Sub-Rect-Verifikation gegen die Bilddimensionen (Pixelraum, oben-links).
bool mrc_rect_valid(pdfcore_mrc_layer_t const& layer, double w, double h)
{
    if (layer.rect[0] == 0 && layer.rect[1] == 0
        && layer.rect[2] == 0 && layer.rect[3] == 0) {
        return true;   // Vollbild
    }
    return layer.rect[0] >= 0 && layer.rect[1] >= 0
        && layer.rect[2] > layer.rect[0] && layer.rect[3] > layer.rect[1]
        && layer.rect[2] <= w + 0.5 && layer.rect[3] <= h + 0.5;
}

} // namespace

int pdfcore_replace_page_image_draw_with_layers(
    pdfcore_document_t *doc,
    int page_index,
    int image_obj_number, int image_generation,
    const char *resource_name,
    const pdfcore_mrc_layer_t *layers, int layer_count)
{
    if (!doc || !resource_name || !layers || layer_count <= 0
        || layer_count > 64) {
        return PDFCORE_ERR_OPEN;
    }
    try {
        // --- 1. Alle Prüfungen VOR der ersten Mutation (transaktional) -----

        std::vector<QPDFObjectHandle> pages = doc->qpdf.getAllPages();
        if (page_index < 0
            || static_cast<size_t>(page_index) >= pages.size()) {
            return PDFCORE_ERR_CHECK_FAILED;
        }
        QPDFObjectHandle page = pages[static_cast<size_t>(page_index)];

        std::string want = resource_name;
        if (!want.empty() && want.front() != '/') { want = "/" + want; }

        // Layer-Semantik: JPEG nie Maske, JBIG2/CCITT in V1 immer Maske.
        for (int i = 0; i < layer_count; ++i) {
            pdfcore_mrc_layer_t const& layer = layers[i];
            if (!layer.bytes || layer.len == 0
                || layer.width <= 0 || layer.height <= 0) {
                return PDFCORE_ERR_CHECK_FAILED;
            }
            if (layer.kind == 0 && layer.is_mask) { return PDFCORE_ERR_CHECK_FAILED; }
            if ((layer.kind == 1 || layer.kind == 2) && !layer.is_mask) {
                return PDFCORE_ERR_CHECK_FAILED;
            }
            if (layer.kind < 0 || layer.kind > 2) { return PDFCORE_ERR_CHECK_FAILED; }
        }

        // Zielbild: Identität + Subtype + Dimensionen (Sub-Rect-Grenzen).
        QPDFObjGen wantObjGen(image_obj_number, image_generation);
        QPDFObjectHandle image = doc->qpdf.getObjectByObjGen(wantObjGen);
        if (image.isNull() || !image.isStream()) { return PDFCORE_ERR_CHECK_FAILED; }
        QPDFObjectHandle imageDict = dict_of(image);
        QPDFObjectHandle st = imageDict.getKey("/Subtype");
        if (!(st.isName() && st.getName() == "/Image")) {
            return PDFCORE_ERR_CHECK_FAILED;
        }
        double imgW = imageDict.getKey("/Width").getNumericValue();
        double imgH = imageDict.getKey("/Height").getNumericValue();
        if (imgW <= 0 || imgH <= 0) { return PDFCORE_ERR_CHECK_FAILED; }
        for (int i = 0; i < layer_count; ++i) {
            if (!mrc_rect_valid(layers[i], imgW, imgH)) {
                return PDFCORE_ERR_CHECK_FAILED;
            }
        }

        // Resources (vererbt aufgelöst) + XObject-Map + Namensauflösung.
        QPDFObjectHandle resources = resolve_inheritable(page, "/Resources");
        if (resources.isNull() || !resources.isDictionary()) {
            return PDFCORE_ERR_CHECK_FAILED;
        }
        QPDFObjectHandle xobjs = resources.getKey("/XObject");
        if (xobjs.isNull() || !xobjs.isDictionary()) {
            return PDFCORE_ERR_CHECK_FAILED;
        }
        QPDFObjectHandle named = xobjs.getKey(want);
        if (named.isNull() || !named.isStream()) { return PDFCORE_ERR_CHECK_FAILED; }
        if (named.getObjGen() != wantObjGen) { return PDFCORE_ERR_CHECK_FAILED; }

        // Mehrfachplatzierung des Namens im Seiten-Content: V1 verweigert
        // (dokumentierte Grenze – nur EIN dominantes Vollbild, §13.4).
        std::string content;
        {
            QPDFObjectHandle c = page.getKey("/Contents");
            std::vector<QPDFObjectHandle> streams;
            if (c.isStream()) { streams.push_back(c); }
            else if (c.isArray()) { streams = c.getArrayAsVector(); }
            for (auto const& stream : streams) {
                std::string part;
                if (!stream.isStream() || !font5_stream_bytes(stream, part)) {
                    return PDFCORE_ERR_CHECK_FAILED;
                }
                if (part.empty()) { continue; }
                if (!content.empty()) { content.push_back(' '); }
                if (content.size() + part.size() > mrc_concat_budget_bytes) {
                    return PDFCORE_ERR_CHECK_FAILED;
                }
                content += part;
            }
        }
        MrcDrawMatch match;
        int doCount = 0;
        mrc_scan_draw(content, want, match, doCount);
        if (!match.found || doCount != 1) { return PDFCORE_ERR_CHECK_FAILED; }

        // --- 2. Mutation: Layer-Streams → Resources → Content --------------

        // Layer in ZEICHNUNGSREIHENFOEGE des Aufrufers (Hintergrund zuerst,
        // Maske zuletzt) unter eindeutigen Namen anlegen.
        std::vector<std::string> names;
        std::vector<QPDFObjectHandle> streams;
        for (int i = 0; i < layer_count; ++i) {
            std::string name = mrc_unique_name(xobjs, names, "MRCL");
            if (name.empty()) { return PDFCORE_ERR_INTERNAL; }
            names.push_back(name);
            streams.push_back(mrc_make_layer(doc, layers[i]));
        }

        // Copy-on-Write für /Resources (geteilte Dicts bleiben unberührt):
        // frisches Dict mit den GLEICHEN Werten, XObject-Map ohne den
        // ersetzten Namen (das Original-Objekt bleibt bestehen und wird –
        // wenn nun unreferenziert – vom Writer verworfen).
        QPDFObjectHandle newResources = QPDFObjectHandle::newDictionary();
        for (auto const& key : resources.getKeys()) {
            newResources.replaceKey(key, resources.getKey(key));
        }
        QPDFObjectHandle newXobjs = QPDFObjectHandle::newDictionary();
        for (auto const& key : xobjs.getKeys()) {
            if (key == want) { continue; }
            newXobjs.replaceKey(key, xobjs.getKey(key));
        }
        for (int i = 0; i < layer_count; ++i) {
            newXobjs.replaceKey(names[i], streams[i]);
        }
        newResources.replaceKey("/XObject", newXobjs);

        // Ersetzungstext: ursprüngliche cm-Transform bewahren (die Layer
        // füllen dieselbe Fläche wie das Raster), Photo-Sub-Rects über eine
        // innere cm-Multiplikation (Bildpixelraum, oben-links → Bildraum),
        // Maske als ImageMask in schwarzer Tinte ÜBER dem Hintergrund.
        std::string replacement = "q\n";
        for (int k = 0; k < 6; ++k) {
            replacement += mrc_num(match.matrix[k]);
            replacement += " ";
        }
        replacement += "cm\n";
        for (int i = 0; i < layer_count; ++i) {
            pdfcore_mrc_layer_t const& layer = layers[i];
            bool fullFrame = layer.rect[0] == 0 && layer.rect[1] == 0
                && layer.rect[2] == 0 && layer.rect[3] == 0;
            if (fullFrame) {
                // Vollbild-Layer teilen die cm-Transform des Rasters.
                if (layer.is_mask) { replacement += "0 g\n"; }
                replacement += names[i] + " Do\n";
            } else {
                // Sub-Rect (Photo-Region): EIGENE q/Q-Klammer – ein cm würde
                // sonst für alle Folgelayer (z. B. die Vollbild-Maske)
                // bestehen bleiben und sie in das Teilrechteck drängen.
                double sx = (layer.rect[2] - layer.rect[0]) / imgW;
                double sy = (layer.rect[3] - layer.rect[1]) / imgH;
                double tx = layer.rect[0] / imgW;
                double ty = (imgH - layer.rect[3]) / imgH;
                replacement += "q " + mrc_num(sx) + " 0 0 " + mrc_num(sy) + " "
                    + mrc_num(tx) + " " + mrc_num(ty) + " cm";
                if (layer.is_mask) { replacement += " 0 g"; }
                replacement += " " + names[i] + " Do Q\n";
            }
        }
        replacement += "Q\n";

        std::string newContent = content.substr(0, match.spanStart)
            + replacement + content.substr(match.spanEnd);
        QPDFObjectHandle contentStream = doc->qpdf.makeIndirectObject(
            QPDFObjectHandle::newStream(&doc->qpdf, newContent));
        page.replaceKey("/Contents", contentStream);
        page.replaceKey("/Resources",
                        doc->qpdf.makeIndirectObject(newResources));

        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}

/* Ink-Overlay (Freihand-Tinte) – siehe Header. Angehängt wird IMMER hinter
 * den bestehenden Content (addPageContents first=false): Die Tinte liegt
 * über Text/Bildern/Annotationen, statt darunter begraben zu werden. */
int pdfcore_append_page_content(pdfcore_document_t *doc,
                                const int *page_indices,
                                const char *const *contents,
                                int count)
{
    if (!doc || !page_indices || !contents || count <= 0) { return -1; }
    try {
        std::vector<QPDFObjectHandle> pages = doc->qpdf.getAllPages();
        for (int i = 0; i < count; ++i) {
            int idx = page_indices[i];
            if (idx < 0 || static_cast<size_t>(idx) >= pages.size()) { return -1; }
            const char *ops = contents[i];
            if (!ops || ops[0] == '\0') { continue; }
            QPDFObjectHandle overlay =
                QPDFObjectHandle::newStream(&(doc->qpdf), std::string(ops));
            pages[static_cast<size_t>(idx)].addPageContents(overlay, false);
        }
        return 0;
    } catch (...) {
        return -1;
    }
}

// MARK: - echtes zlib für Kandidaten-Streams (2026-10-01)

int pdfcore_flate_compress(const unsigned char *data, size_t data_len, int level,
                           unsigned char **out, size_t *out_len)
{
    if (!data || !out || !out_len || data_len == 0) { return PDFCORE_ERR_INTERNAL; }
    *out = nullptr; *out_len = 0;
    uLong bound = compressBound(static_cast<uLong>(data_len));
    unsigned char *buffer = static_cast<unsigned char *>(malloc(bound));
    if (!buffer) { return PDFCORE_ERR_INTERNAL; }
    uLong dest = bound;
    int z = level < 0 ? Z_DEFAULT_COMPRESSION : std::min(level, 9);
    if (compress2(buffer, &dest, data, static_cast<uLong>(data_len), z) != Z_OK) {
        free(buffer);
        return PDFCORE_ERR_INTERNAL;
    }
    *out = buffer;
    *out_len = static_cast<size_t>(dest);
    return PDFCORE_OK;
}

// MARK: - OCR-Textebene (2026-10-01)

int pdfcore_append_ocr_layer(pdfcore_document_t *doc, int page_index,
                             const char *content, size_t content_len)
{
    if (!doc || !content || page_index < 0) { return PDFCORE_ERR_INTERNAL; }
    try {
        QPDFPageDocumentHelper helper(doc->qpdf);
        auto pages = helper.getAllPages();
        if (page_index >= static_cast<int>(pages.size())) { return PDFCORE_ERR_CHECK_FAILED; }
        QPDFPageObjectHelper page = pages[static_cast<size_t>(page_index)];

        // Font-Ressource NUR für diese Seite (copy_if_shared).
        QPDFObjectHandle resources = page.getAttribute("/Resources", true);
        if (!resources.isDictionary()) {
            resources = QPDFObjectHandle::newDictionary();
            page.getObjectHandle().replaceKey("/Resources", resources);
        }
        QPDFObjectHandle fonts = resources.getKey("/Font");
        if (!fonts.isDictionary()) {
            fonts = QPDFObjectHandle::newDictionary();
        } else {
            fonts = fonts.shallowCopy();   // geteiltes Font-Dict nie verändern
        }
        QPDFObjectHandle font = QPDFObjectHandle::newDictionary();
        font.replaceKey("/Type", QPDFObjectHandle::newName("/Font"));
        font.replaceKey("/Subtype", QPDFObjectHandle::newName("/Type1"));
        font.replaceKey("/BaseFont", QPDFObjectHandle::newName("/Helvetica"));
        font.replaceKey("/Encoding", QPDFObjectHandle::newName("/WinAnsiEncoding"));
        fonts.replaceKey("/PDFToolsOCR", doc->qpdf.makeIndirectObject(font));
        resources.replaceKey("/Font", fonts);

        // Bestehenden Inhalt kapseln, Textebene anhängen.
        page.addPageContents(QPDFObjectHandle::newStream(&doc->qpdf, "q\n"), true);
        std::string layer = "Q\n" + std::string(content, content_len);
        page.addPageContents(QPDFObjectHandle::newStream(&doc->qpdf, layer), false);
        return PDFCORE_OK;
    } catch (...) {
        return PDFCORE_ERR_INTERNAL;
    }
}
