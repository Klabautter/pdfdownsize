/* PDFCore – minimale C-ABI über libqpdf (Monster Epic Phase 5).
 *
 * Swift kennt nur diese Header; die gesamte qpdf-C++-API bleibt verborgen.
 * Alle C++-Exceptions werden in Fehlercodes übersetzt und erreichen Swift nie.
 *
 * Threading: pdfcore_* ist nicht threadsafe pro Handle; verschiedene Handles
 * dürfen in verschiedenen Threads genutzt werden (qpdf-interne Locks vorausgesetzt).
 */
#ifndef PDFCORE_H
#define PDFCORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pdfcore_document pdfcore_document_t;

typedef enum {
    PDFCORE_OK = 0,
    PDFCORE_ERR_OPEN = 1,        /* Datei fehlt/lesbar/PDF unlesbar */
    PDFCORE_ERR_PASSWORD = 2,    /* verschlüsselt ohne Passwort */
    PDFCORE_ERR_CHECK_FAILED = 3,/* strukturelle Probleme gefunden */
    PDFCORE_ERR_INTERNAL = 4,    /* unerwarteter Fehler */
    PDFCORE_ERR_CANCELLED = 5    /* Befund B11 – der Aufrufer hat abgebrochen;
                                    Zielpfad unangetastet, Temp-Datei entfernt */
} pdfcore_status;

/* Epic Phase 7 – read-only semantische Inspection. */
typedef struct pdfcore_page_info {
    int index;
    double media_box[4];   /* x0 y0 x1 y1 */
    double crop_box[4];
    int rotation;          /* inkl. geerbtem /Rotate über /Parent-Kette */
} pdfcore_page_info_t;

/// Geometrie+Rotation einer Seite (0-basiert). 0=ok, -1=Fehler.
int pdfcore_page_info(pdfcore_document_t *doc, int page_index,
                      pdfcore_page_info_t *out);

/// Annotationszählung über alle Seiten. 0=ok.
int pdfcore_annotation_counts(pdfcore_document_t *doc,
                              int *total, int *links, int *widgets);

/// Annotationszählung für EINE Seite (0-basiert). 0=ok, -1=Fehler.
/// Dokumentweite Summen allein genügen dem Snapshot nicht: Sie können einen
/// Verlust auf Seite 1 gegen einen Zuwachs auf Seite 2 aufheben.
int pdfcore_page_annotation_counts(pdfcore_document_t *doc, int page_index,
                                   int *total, int *links, int *widgets);

/// Stringlisten (Links/Outline-Labels) als Index-API – kein Zeigeraustausch.
#define PDFCORE_LIST_LINKS           0
#define PDFCORE_LIST_OUTLINE_LABELS  1
#define PDFCORE_LIST_PAGE_LABELS     2   /* Einträge "start|style|prefix|first" */
/* Bild-XObjects. Masterplan Schritt 1: die Objektidentität (objNum/gen) ist
 * Teil der Zeile – ein Bild wird NIE über seinen Resource-Namen adressiert.
 * Format:
 *   "page|name|width|height|bitsPerComponent|colorspace|filters|smask|shared|
 *    placedW|placedH|objNum|gen|mask|imageMask|decode|rawLength"
 * mask: 0 = keine, 1 = Schablone (Stream), 2 = Farbschlüssel (Array). */
#define PDFCORE_LIST_IMAGES          3
/* Masterplan Finding 6 – vollständiger semantischer Snapshot.
 * Alle Listen sind deterministisch sortiert bzw. in Dokumentreihenfolge. */
#define PDFCORE_LIST_NAMED_DESTS     4   /* "name|targetPageIndex" (-1 = unauflösbar) */
/* "name|decodedByteCount|checksum" (-1 / "-" = unbekannt).
 * Gemessen wird der DEKODIERTE Strom: Die gespeicherte Länge ändert sich beim
 * Nachpacken, ohne dass der Anhang ein anderer wäre. */
#define PDFCORE_LIST_ATTACHMENTS     5
#define PDFCORE_LIST_FORM_FIELDS     6   /* "fqName|fieldType|value|flags" */
#define PDFCORE_LIST_SIGNATURES      7   /* "fieldName|subFilter" */
#define PDFCORE_LIST_OUTLINE_TREE    8   /* "depth|label|targetPageIndex" */
/* Final Core Hardening 6.3 – ein Link ist mehr als seine Zielseite.
 * "sourcePage|destType|targetPage|namedDest|x0,y0,x1,y1"
 * destType: explicit | named | uri | none.
 * Ohne Quellseite und Rahmen lässt sich nicht prüfen, ob ein Link noch an
 * derselben Stelle steht – nur, wie viele es sind. */
#define PDFCORE_LIST_LINK_DETAILS    9
/* Phase 23c – Ressourcen-Beziehungen innerhalb von Form-XObjects. Der
 * cm/Do-Scan der SEITEN-Content-Bytes sieht Bilder nicht, die in einer
 * Form liegen (Page → Form → /Image). Diese Liste liefert je Seite, welche
 * Form welche Bilder (bzw. verschachtelten Formen) unter welchem Namen
 * trägt – die Platzierungsgeometrie selbst bleibt der Swift-Scan über die
 * Form-Content-Bytes (pdfcore_get_object_stream_bytes).
 * Format je Eintrag:
 *   "pageIdx|formObj|formGen|parentFormObj|parentFormGen|matrixSX|matrixSY|
 *    name|targetObj|targetGen|isImage"
 * form: die Form, deren /Resources den Eintrag trägt. parentForm: die Form,
 * in DEREN Content diese Form gezeichnet wird (-1|-1 = direkt in den
 * Seiten-Resources). matrixSX/SY: Spaltennormen der /Matrix der Form
 * (1 = keine). name: Resource-Name – bei isImage=1 der Bildname INNERHALB
 * der Form, bei isImage=0 der Name der Form in der ELTERN-Map.
 * target: Objektidentität des Bildes (isImage=1) bzw. der verschachtelten
 * Form (isImage=0). Formen ohne Bild im Teilbaum sind ausgefiltert;
 * Zykeln und Doppelbesuche sind abgeschnitten (Erster Fund gewinnt). */
#define PDFCORE_LIST_FORM_RESOURCES  10

/// list_id gemäß Konstanten oben.
int pdfcore_string_list_count(pdfcore_document_t *doc, int list_id, int *count);

/// Kopiert Eintrag `index` in `buf` (immer NUL-terminiert). Gibt benötigte
/// Länge zurück (ohne NUL), -1 bei Fehler/out of range.
int pdfcore_string_list_get(pdfcore_document_t *doc, int list_id, int index,
                            char *buf, size_t size);

/// Gibt internen Cache einer Liste frei (optional; wird bei close mitgeräumt).
void pdfcore_string_list_release(pdfcore_document_t *doc, int list_id);


// MARK: - Epic Phase 13 – Page Labels schreiben
// Erwartet Einträge im Format "start|style|prefix|first" (style: D,r,R,a,A;
// leer = keine Nummerierung; prefix optional; first optional).
int pdfcore_write_page_labels(pdfcore_document_t *doc,
                              const char *const *encodings, int count);

/// Anzahl benannter Formularfelder (/T auf Widget oder Feld). 0=ok, -1 Fehler.
int pdfcore_form_field_count(pdfcore_document_t *doc);

/// Named Destinations: Einträge in /Names→/Dests-Baum + altes /Dests-Dict. -1=Fehler.
int pdfcore_named_destination_count(pdfcore_document_t *doc);

/// Embedded-Files-Einträge im Names-Baum. -1=Fehler.
int pdfcore_attachment_count(pdfcore_document_t *doc);

/// 1 wenn Katalog /PageLabels existiert, sonst 0. -1=Fehler.
int pdfcore_has_page_labels(pdfcore_document_t *doc);

// MARK: - Epic Phase 9 – Page Copy Prototype

/// Schreibt eine neue PDF aus Seiten mehrerer Quellen (Prototype hinter Flag).
/// Reihenfolge wie Arrays; Rotation = geerbte Basis-Rotation + Zusatzrotation.
/// Statuscodes wie oben; PDFCORE_ERR_CHECK_FAILED bei ungültigem Seitenindex.
int pdfcore_write_pages(const char *const *source_paths,
                        const int *page_indices,
                        const int *rotations,
                        int count,
                        const char *output_path,
                        int remove_dangling_links);

/// Wie oben, meldet aber nach JEDER kopierten Seite den Fortschritt.
/// `on_page(context, kopierte_seiten, gesamt)` – darf NULL sein.
///
/// Ohne diese Rückmeldung sprang der Fortschritt von 0 auf 1: Der Aufrufer
/// sieht bei einem tausendseitigen Dokument minutenlang nichts. Den
/// Fortschritt stattdessen VOR dem Aufruf zu melden wäre eine Attrappe –
/// gemeldet wird, was wirklich geschehen ist.
int pdfcore_write_pages_progress(const char *const *source_paths,
                                 const int *page_indices,
                                 const int *rotations,
                                 int count,
                                 const char *output_path,
                                 int remove_dangling_links,
                                 void (*on_page)(void *context, int done, int total),
                                 void *context);

/// Befund B11 (Review 2026-10-09) – wie `pdfcore_write_pages_progress`,
/// zusätzlich ABBRECHBAR.
///
/// `should_continue(context)` wird VOR jeder zu kopierenden Seite und
/// während des Schreibens (bei jedem Block, den der QPDFWriter ausgibt)
/// gerufen. Liefert es 0, bricht die Funktion ab und meldet
/// PDFCORE_ERR_CANCELLED: Die Temp-Datei (`<output>.pdfcore-tmp`) ist dann
/// entfernt, der Zielpfad unangetastet, alle QPDF-Objekte sind freigegeben.
///
/// Die Prüfung während des Schreibens ist nötig, weil die Seitenschleife nur
/// Objekt-Handles kopiert – die eigentliche Zeit vergeht beim Schreiben der
/// Streams. Ein Abbruch, der nur zwischen den Seiten greift, käme bei einem
/// grossen Dokument erst an, wenn die Datei ohnehin fertig ist.
///
/// Beide Callbacks dürfen NULL sein; ohne `should_continue` verhält sich die
/// Funktion wie `pdfcore_write_pages_progress`.
int pdfcore_write_pages_cancellable(const char *const *source_paths,
                                    const int *page_indices,
                                    const int *rotations,
                                    int count,
                                    const char *output_path,
                                    int remove_dangling_links,
                                    void (*on_page)(void *context, int done, int total),
                                    int (*should_continue)(void *context),
                                    void *context);

/// Schreibt einen FLACHEN Outline-Baum (oberste Ebene) in den Katalog.
///
/// `titles` und `page_indices` sind gleich lang; ein Eintrag zeigt auf die
/// 0-basierte Seite im Dokument. Bestehende Outlines werden ersetzt.
///
/// Grund für diese Funktion: Der Outline-Aufbau lief über PDFKit
/// (`PDFDocument.write(to:)`), und ein einziger solcher Schreibvorgang
/// zerstört die Textextrahierbarkeit – gemessen 470 → 242 Wörter an einem
/// arXiv-Paper, weil /ToUnicode-Abbildungen verlorengehen. Die Bridge kopiert
/// Objekte unverändert.
int pdfcore_write_outlines(pdfcore_document_t *doc,
                           const char *const *titles,
                           const int *page_indices,
                           int count);

/// qpdf-Version als Status-Check für den Prototype-Pfad (0=ok).
int pdfcore_prototype_available(void);

// MARK: - Epic Phase 11 – Internal Links & Dangling-Policy

/// Löst für jeden Link (Seitenreihenfolge) die Zielseite auf.
/// out[i] = 0-basierter Seitenindex im Output, -1 = unauflösbar/dangling,
/// -2 = externer URI-Link (kein Seitentarget). Rückgabe 0=ok.
int pdfcore_internal_link_targets(pdfcore_document_t *doc,
                                  int **out_indices, int *count);

/// Policy Phase 11: entfernt Link-Annotationen, deren Zielseite nicht im
/// Output-Seitenbaum existiert. `removed` erhält die Anzahl. 0=ok.
int pdfcore_remove_dangling_link_annots(pdfcore_document_t *doc, int *removed);

/// Seiten-Thumbnails (/Thumb in Page-Dicts) entfernen. Verlustfrei: Viewer
/// regenerieren Vorschaubilder aus den Seiteninhalten; verwaiste Thumb-
/// Streams verwirft der Writer. `removed` erhält die Anzahl entfernter
/// Einträge. 0=ok, -1 bei ungültigem Handle.
int pdfcore_remove_page_thumbs(pdfcore_document_t *doc, int *removed);

/// Content-Streams kompaktieren (Seiten-/Contents + Form-XObjects, ohne
/// Tiling-Patterns): Whitespace-Minimum, wertexakte Zahlen-Normalisierung,
/// leere `q Q`-Paare. Verlustfrei per Whitelist – Fehlformen, unbekannte
/// Bytes, Streams über 8 MB dekodiert oder ohne Vorteil bleiben stehen.
/// Nur filterlose oder reine Flate-Streams ohne /DecodeParms (stets
/// Never-Grow pro Stream). `streams`/`savedBytes` sind Schätzung über die
/// kodierten Streamgrößen. 0=ok, -1 bei ungültigem Handle.
int pdfcore_minify_content_streams(pdfcore_document_t *doc,
                                   int *streamsMinified,
                                   long long *bytesSavedEstimate);

/// Öffnet ein Dokument. Gibt NULL bei Fehler zurück; `status` (optional) erhält den Code.
pdfcore_document_t *pdfcore_open(const char *path, pdfcore_status *status);

/// Anzahl Seiten, -1 bei ungültigem Handle.
int pdfcore_page_count(pdfcore_document_t *doc);

/// Strukturprüfung (entspricht `qpdf --check`). 0 = ok, sonst Fehlercode.
int pdfcore_check(pdfcore_document_t *doc);

/// qpdf-Version in Puffer schreiben. Gibt benötigte Länge zurück (ohne NUL).
int pdfcore_version(char *buffer, size_t buffer_size);

void pdfcore_close(pdfcore_document_t *doc);

/// Schreibt das (ggf. sanitisierte) Dokument neu. 0=ok.
int pdfcore_save(pdfcore_document_t *doc, const char *path);

/* Phase V2-9 (Masterplan §15.6) – finaler Write mit Writer-Optionen
 * (Single Final Write). Abbild der qpdf-CLI-Struktur-Pass-Flags:
 *   object_streams_generate  1 = generate, 0 = disable (Kompatibilität)
 *   recompress_flate         1 = --recompress-flate
 *   compression_level        --compression-level=N, <0 = qpdf-Standard
 *   linearize                1 = --linearize
 * Metadaten/Producer bleiben Bridgesache (davor am Dokument gesetzt).
 * Bewusst NICHT hier: Zopfli (FlatePolicy .maximum) – dieser Pfad fällt
 * in Swift auf den Zwei-Write-Pfad zurück (§15.7). 0=ok. */
int pdfcore_save_with_options(pdfcore_document_t *doc, const char *path,
                              int object_streams_generate,
                              int recompress_flate,
                              int compression_level,
                              int linearize);

/// Epic Phase 16 – /Info→/Producer setzen (deterministisch).
int pdfcore_set_producer(pdfcore_document_t *doc, const char *producer);

/// Epic Phase 23b – dekodierter Content-Bytes einer Seite (alle /Contents).
/// Gibt malloc'd Buffer zurück; Freigabe mit free().
int pdfcore_get_page_content(pdfcore_document_t *doc, int page_index,
                             char **out, size_t *len);

/// Epic Phase 23 – JPEG-Passthrough: liefert die ROHEN Stream-Bytes eines
/// Bild-XObjects, aber NUR wenn der einzige Filter DCTDecode ist.
/// Sonst PDFCORE_ERR_CHECK_FAILED (kein Passthrough möglich).
int pdfcore_get_image_jpeg(pdfcore_document_t *doc, int page_index,
                           const char *image_name,
                           char **out, size_t *len);

/* Masterplan Schritt 1/2 – Bildersetzung über EINDEUTIGE Objektidentität.
 *
 * Das frühere namensbasierte Replacement war ein Daten-Korruptionsrisiko:
 * "/Im0" auf Seite 1 und "/Im0" auf Seite 2 können VERSCHIEDENE Objekte sein.
 * Ersetzt wird deshalb genau das Objekt (obj_number, generation) – ein
 * geteiltes XObject wird dadurch an allen seinen Platzierungen konsistent
 * aktualisiert, ohne fremde Objekte zu treffen.
 *
 * Dictionary-Preservation-Policy: /Intent und /Interpolate werden übernommen.
 * Die Funktion VERWEIGERT die Ersetzung (PDFCORE_ERR_CHECK_FAILED), wenn das
 * Zielobjekt Eigenschaften trägt, die mit einem JPEG-Ersatz unvereinbar sind
 * (/SMask, /Mask, /Decode, /ImageMask) – auch dann, wenn der Aufrufer sie
 * übersehen hat. Zweite Verteidigungslinie, keine stille Korrektur.
 *
 * grayscale: 1 = die JPEG-Daten sind DeviceGray, 0 = DeviceRGB.
 *
 * decode_applied: 1 = der Aufrufer hat ein vorhandenes /Decode-Array beim
 * Dekodieren bereits angewendet, die übergebenen Bytes tragen also die
 * fertigen Farbwerte. Ohne diese Erklärung verweigert die Funktion die
 * Ersetzung, wenn das Zielobjekt ein /Decode trägt – ein unangewendetes
 * /Decode kehrt Bilder um oder verschiebt Tonwerte.
 */
/* Mehrfach identisch gespeicherte Bilder auf EIN Objekt zusammenführen.
 *
 * Dokumente enthalten dasselbe Bild oft mehrfach – ein Logo auf jeder Seite,
 * ein wiederholter Hintergrund, ein Diagramm in mehreren Kapiteln. Jede Kopie
 * liegt als eigenes Objekt mit denselben Bytes im Dokument. Über den Korpus
 * gemessen sind das 30 MB, also 8 % aller Bilddaten.
 *
 * Zusammengeführt wird nur, was BITGLEICH ist: gleiche Stream-Bytes UND
 * gleiches Wörterbuch. Zwei Bilder mit denselben Pixeln, aber verschiedenem
 * /Decode oder /SMask sind verschiedene Bilder und bleiben getrennt.
 *
 * Verlustfrei: Es wird kein Byte neu kodiert, nur ein Verweis umgehängt.
 * Die verwaisten Objekte entfernt qpdf beim Schreiben.
 *
 * `merged` erhält die Anzahl der umgehängten Verweise. */
int pdfcore_deduplicate_images(pdfcore_document_t *doc, int *merged);

/* Phase 3b (Roadmap) – Content-Hash-Dedup über ALLE indirekten Objekte
 * (Vorbild MuPDF -ggg; qpdf selbst kann das nicht).
 *
 * Streams werden nur zusammengeführt, wenn
 *   (1) die dekomprimierten Bytes identisch sind (SHA-256). Löst libqpdf
 *       einen Filter nicht auf, zählen die rohen Bytes – dann müssen auch
 *       /Filter und /DecodeParms übereinstimmen;
 *   (2) die Wörterbücher nach Whitelist (/Type, /Subtype, /Width, /Height,
 *       /BitsPerComponent, /ColorSpace, /SMask, /Mask, /Decode, /Intent,
 *       /Interpolate, /Name, /BBox, /Resources und – V2-8 §14.5 – /N,
 *       /Range, /Alternate für den ICCBased-/N-/Range-Vertrag) in Menge
 *       und Wert übereinstimmen und KEINE fremden Schlüssel tragen;
 *       /Length und /Filter+/DecodeParms dürfen abweichen;
 *   (3) keine /JBIG2Globals-Referenz vorliegt – Globals sind
 *       kontextabhängig, solche Streams bleiben grundsätzlich getrennt.
 * Nicht-Stream-Objekte (Dicts/Arrays) gelten bei kanonisch gleicher Form
 * als gleich; Katalog, Seitenbaum (/Pages, /Page) und Formularfelder
 * (Schlüssel /T) bleiben unangetastet, /ObjStm und /XRef ebenfalls.
 *
 * Referenzen werden auf das Objekt mit der niedrigsten Objektnummer
 * umgehängt; die verwaisten Objekte verwirft der Writer beim Schreiben.
 * Kein Byte wird neu kodiert – der Pass ist verlustfrei und kann die
 * Ausgabe nie vergrößern. Verschlüsselte Dokumente: Pass läuft leer.
 * `stats` (optional) erhält die Zählung. */
typedef struct pdfcore_dedup_stats {
    int merged_streams;              /* absorbierte doppelte Streams */
    int merged_objects;              /* absorbierte Dict-/Array-Duplikate */
    long long estimated_bytes_saved; /* gesparte Rohbytes (Schätzung) */
} pdfcore_dedup_stats_t;

int pdfcore_deduplicate_document(pdfcore_document_t *doc,
                                 pdfcore_dedup_stats_t *stats);

/* Phase 5a (Roadmap) – Font-Attribution, Font-Dedup und Unused-Font-GC.
 *
 * Ein Font besteht aus dem Font-Dict (/Type /Font), seinem FontDescriptor
 * und – bei eingebetteten Fonts – dem FontFile-/FontFile2-/FontFile3-
 * Programmstrom. Merge-Dokumente tragen denselben Font oft mehrfach als
 * getrennte Objekte; geborene Fonts bleiben davon unberührt, sind aber
 * häufig nie benutzt. Der Pass arbeitet in drei Schritten:
 *
 *   1. Inventar: alle /Font-Dicts und ihre Fontprogramme finden; jedes
 *      FontFile wird per SHA-256 über die DEKODIERTEN Bytes vermerkt
 *      (nicht dekodierbar: rohe Bytes inklusive Filter-Form).
 *   2. Dedup: Font-Dicts mit identischem FontFile-Hash UND identischer
 *      semantischer Dict-Form (BaseFont, Subtype, /Encoding, /Widths bzw.
 *      /W, /CIDToGIDMap, /ToUnicode-Strom-Hash, FontDescriptor, bei Type0
 *      die DescendantFonts) werden auf das Objekt mit der niedrigsten
 *      Objektnummer zusammengeführt – genau wie im Document-Dedup durch
 *      Umhängen aller Referenzen. FontFile-Duplikate ohne Dict-Über-
 *      einstimmung bleiben bewusst getrennt (Semantikrisiko). Type3-Fonts
 *      werden nie zusammengeführt oder beräumt.
 *   3. GC: Font-Einträge in errebbaren /Resources-Maps (Seiten inkl.
 *      Vererbung, Form-XObjects, Annotations-Appearances, Type3-CharProcs),
 *      die von KEINEM Tf-Operator des zugehörigen Contents benutzt werden,
 *      werden aus der Map entfernt; die verwaisten Objekte verwirft der
 *      Writer. Konservativ: eine Map wird nur beräumt, wenn sich ALLE
 *      zugehörigen Contents vollständig scannen ließen; Fonts aus
 *      /AcroForm/DR bleiben grundsätzlich stehen (Feld-DA-Strings nutzen
 *      sie ohne Seitenevent). Am Seitenbaum wird NICHTS geändert – genau
 *      wie im Document-Dedup. Font-Dicts, die in keiner errebbaren Map
 *      hängen, bleiben als unreferenced liegen; der Writer verwirft sie.
 *
 * Verlustfrei und nie vergrößernd; verschlüsselte Dokumente laufen leer.
 * `stats` (optional) erhält die Zählung; unused_fonts_removed zählt die
 * entfernten Map-Einträge, estimated_bytes_saved schätzt über die rohen
 * FontFile-Größen der betroffenen Programme. */
typedef struct pdfcore_font_audit_stats {
    int font_objects;                /* gefundene /Font-Dicts */
    int font_file_streams;           /* FontFile/2/3-Programme (eindeutig) */
    int duplicate_font_refs_removed; /* umgehängte Dict-Referenzen (Dedup) */
    int unused_fonts_removed;        /* entfernte Einträge aus Resources-Maps */
    long long estimated_bytes_saved; /* gesparte Rohbytes (Schätzung) */
} pdfcore_font_audit_stats_t;

int pdfcore_font_audit(pdfcore_document_t *doc,
                       pdfcore_font_audit_stats_t *stats);

/* Phase 5b (Roadmap) – Font-Subsetting über HarfBuzz hb-subset.
 *
 * Der Pass läuft bewusst NACH Font-Dedup und Unused-Font-GC (Reihenfolge
 * Phase 5) und ist der riskanteste Eingriff der Pipeline: Er schreibt
 * Fontprogramme neu. Deshalb gilt ein strikter Whitelist-Ansatz – nur
 * sicher verifizierbare Konstellationen werden angefasst, alles andere
 * bleibt unberührt:
 *
 *   Subsettet werden NUR
 *     (a) Simple-Fonts /Subtype /TrueType mit eingebettetem /FontFile2 und
 *         sauber auflösbarem Code→Unicode-Pfad (ToUnicode-CMap, sonst
 *         /Encoding /WinAnsiEncoding mit voller Code-Raum-Abdeckung 0–255),
 *     (b) Type0-Fonts mit /Encoding /Identity-H bzw. /Identity-V,
 *         /CIDToGIDMap /Identity (oder ohne Eintrag) und
 *         CIDFontType2-Nachfolger mit /FontFile2. Die im Content benutzten
 *         2-Byte-CIDs sind direkt GIDs; der Subset läuft mit
 *         HB_SUBSET_FLAGS_RETAIN_GIDS, damit CID==GID erhalten bleibt und
 *         /W unnummeriert gültig bleibt.
 *
 *   Behalten (nie subsettet): Type3, FontFile (Type1) und FontFile3
 *   (Type1C/CIDFontType0C/OpenType), nicht eingebettete Fonts, geteilte
 *   Fontprogramme (ein FontFile-Objekt, auf das >1 Font-Dict zeigt),
 *   /AcroForm/DR-Fonts, Fonts mit /CIDToGIDMap-Strom, Fonts mit
 *   unscanbarem Content, Fonts ohne ermittelbare Benutzung, Fonts deren
 *   Subset nicht kleiner wäre, und korrupte Programme (hb verwirft sie).
 *
 * Konsistenz der Dicts: Codes und /Encoding//Differences bleiben unver-
 * ändert, /ToUnicode wird nie angefasst – nur die Glyphen im Programm
 * verschwinden. /Widths (Simple) wird auf die benutzten Codes gekürzt
 * (FirstChar/LastChar neu, fehlender /MissingWidth ergänzt), /W (CID)
 * wird auf benutzte CIDs eingedampft. FontFile2 wird durch den Subset
 * ersetzt (/Length1 neu geschrieben).
 *
 * Nach allen Mutationen läuft intern eine Strukturprüfung (pdfcore_check) –
 * scheitert sie, wird PDFCORE_ERR_CHECK_FAILED gemeldet und der Aufrufer
 * verwirft den Pass (Rollback über den Zustand davor).
 *
 * `min_bytes_saved_threshold` hält trivial kleine Gewinne vom Eingriff
 * fern (0 = jeder verifizierbare Gewinn zählt). `stats` (optional) erhält
 * die Zählung; kept_fonts zählt jeden nicht subsetteten Font-Dict. */
typedef struct pdfcore_font_subset_stats {
    int subsetted_fonts;             /* neu geschriebene Fontprogramme */
    int kept_fonts;                  /* konservativ behaltene Font-Dicts */
    long long estimated_bytes_saved; /* gesparte dekodierte Programmbytes */
} pdfcore_font_subset_stats_t;

int pdfcore_font_subset(pdfcore_document_t *doc,
                        long long min_bytes_saved_threshold,
                        pdfcore_font_subset_stats_t *stats);

/* Phase V2-8 (Masterplan §14.1/§21) – SELEKTIVES Font-Subsetting.
 *
 * Drei Eintritte auf EINER Basis (Inventar, Schutz, Benutzung – exakt die
 * Logik des Gesamtpasses oben, herausgezogen):
 *
 *   pdfcore_font_subset            – Gesamtpass (oben, unverändert).
 *   pdfcore_font_subset_candidates – TROCKENPLANUNG: je Font-Dict ein
 *       Kandidateneintrag; für jeden whitelist-geeigneten Font läuft die
 *       Subsetting-Planung VOLLSTÄNDIG (hb-subset inklusive), ohne das
 *       Dokument zu verändern (mutate=false) – die Ersparnisschätzung ist
 *       damit ehrlich, nicht heuristisch (Masterplan Finding 11).
 *   pdfcore_font_subset_selected   – subsettet NUR die genannten Objekte;
 *       verweigert der Kern konservativ (Schutz, Whitelist, geteiltes
 *       Programm, gedriftete Objektidentität), bleibt der Font stehen
 *       (kept). NEVER-BREAK: Strukturprüfung nach allen Mutationen.
 *
 * Kandidatenstruktur: Objektidentität, geschätzte Ersparnis, Größe des
 * Originalprogramms (dekodierte FontFile2-Bytes – Basis der relativen
 * Aktivierungspolitik §14.3), 安全-Klassifikation (subsettable + Grund)
 * und die Seiten, von denen aus der Font erreichbar ist (Basis der
 * Render-Stichprobe §14.4; Seitenliste flach, je Eintrag über
 * page_first/page_count indiziert).
 *
 * reason_code (0 = subsetting-safe, sonst konservativ behalten):
 *   0 safe (Trockenplanung erfolgreich)
 *   1 Type3-Font
 *   2 /AcroForm/DR (Feld-DA-Kontext, kein Seitenevent)
 *   3 CIDFont-Nachfolger (wird über sein Type0-Dict behandelt)
 *   4 geteiltes Fontprogramm (>1 Dict referenziert dasselbe FontFile)
 *   5 unscanbarer Content (Schutz wie im Gesamtpass)
 *   6 Trockenplanung verweigert oder ohne Gewinn (Whitelist, sfnt,
 *     Never-Grow, korrupt)
 *
 * Verschlüsselte Dokumente: alle Eintritte laufen leer. */
typedef struct pdfcore_font_subset_candidate {
    int obj_number;
    int generation;
    long long estimated_bytes_saved;   /* Trockenplanung (mutate=false) */
    long long original_program_bytes;  /* dekodierte FontFile2-Größe */
    int subsettable;                   /* 1 = safe; sonst reason_code */
    int reason_code;                   /* siehe Tabelle oben */
    int page_first;                    /* Index in der flachen Seitenliste */
    int page_count;                    /* Anzahl Seiten ab page_first */
} pdfcore_font_subset_candidate_t;

int pdfcore_font_subset_candidates(pdfcore_document_t *doc,
                                   long long min_bytes_saved_threshold,
                                   pdfcore_font_subset_candidate_t **out,
                                   int *count, int **out_pages,
                                   int *pages_count);

/* Gibt die von pdfcore_font_subset_candidates gelieferten Arrays frei. */
void pdfcore_font_subset_candidates_free(pdfcore_font_subset_candidate_t *out,
                                         int *pages);

int pdfcore_font_subset_selected(pdfcore_document_t *doc,
                                 const int *obj_numbers,
                                 const int *generations, int count,
                                 pdfcore_font_subset_stats_t *stats);

/* Phase V2-8 (Masterplan §14.6) – Resource GC für NICHT-Font-Ressourcen.
 *
 * Entfernt Einträge aus errebbaren /Resources-Sub-Maps, die kein Operator
 * des zugehörigen Contents je benutzt:
 *
 *   /XObject   (Do)              /ExtGState (gs)
 *   /ColorSpace (cs/CS)          /Pattern   (Name vor sc/SC/scn/SCN)
 *   /Shading  (sh)               /Properties (BDC/DP)
 *
 * Font-Maps gehören bewusst NICHT dazu: Ihre GC ist Phase 5a
 * (pdfcore_font_audit); zwei Beräumungen derselben Maps wären Doppel-
 * buchung. Geteilte Sub-Maps (indirekt identisch oder kanonisch gleiche
 * direkte Kopien) teilen ihre Benutzung über alle Verbraucher – Removal
 * erfolgt je Kopie (Muster des Font-GC).
 *
 * Konservativ (Whitelist-Muster der Font-GC):
 *   – eine Map wird nur beräumt, wenn sich ALLE zugehörigen Contents
 *     vollständig scannen ließen (ein unscanbarer Verbraucher schützt
 *     seine ganze Map; Budget 64 MB Konkatenation wie Font-GC);
 *   – /AcroForm/DR bleibt grundsätzlich stehen (Feld-DA-Strings nutzen
 *     die Map ohne Seitenevent);
 *   – Properties-Maps bleiben KOMPLETT stehen, wenn ein /StructTreeRoot
 *     oder /OCProperties existiert oder ein erreichbares XObject ein /OC
 *     trägt (MCID-/OC-Vertrag geht vor Bytegewinn);
 *   – benutzte Formen/SMask-Gruppen/tiling Patterns werden rekursiv
 *     gescannt, damit ihre Maps geschützt beräumt werden können.
 *
 * Verlustfrei: Es wird nur aus Maps getragen; verwaiste Objekte verwirft
 * der Writer. estimated_bytes_saved schätzt über die Rohbytes entfernter
 * Streams (inkl. Stream-Kinder entfernter Array-/Dict-Einträge).
 * Verschlüsselte Dokumente: Pass läuft leer. */
typedef struct pdfcore_resource_gc_stats {
    int xobjects_removed;
    int extgstates_removed;
    int colorspaces_removed;
    int patterns_removed;
    int shadings_removed;
    int properties_removed;
    long long estimated_bytes_saved;
} pdfcore_resource_gc_stats_t;

int pdfcore_remove_unused_resources(pdfcore_document_t *doc,
                                    pdfcore_resource_gc_stats_t *stats);

/* Phase V2-1 (Masterplan §7.5) – Native Byte-Attribution.
 *
 * Beantwortet „Wo liegen die Bytes?" auf Bridge-Ebene, deterministisch und
 * dokumentiert – Ersatz für die bisher nur skriptbasierte Attribution
 * (Scripts/byte-attribution.py bleibt als unabhängige Referenz bestehen).
 *
 * DEFINITIONEN (stabil vor/nach jedem Pass, das ist der Sinn der Messung):
 *   - Grundlage sind alle indirekten Objekte des Dokuments (getAllObjects).
 *   - Streambytes sind immer die KODIERTEN (rohen) Bytes – /Length-Ebene,
 *     nicht dekodiert. Nicht-Stream-Objekte tragen 0 Bytes; die Syntax-
 *     Reste (xref, Objektköpfe, Wörterbücher) sowie Streams, die keiner
 *     Kategorie entsprechen, landen in unattributed_bytes:
 *
 *       unattributed_bytes = document_bytes − Σ(Kategorien)   (auf 0 geklemmt)
 *
 *     document_bytes liefert der AUFRUFER (Dateigröße der Eingabe); die
 *     Bridge kennt keinen Pfad und liest keine Dateigrößen.
 *
 *   - Klassifikation je Stream, in dieser Reihenfolge (erste Treffer zählt,
 *     identisch zur Referenz-Skript-Logik):
 *       1. /Subtype /Image → Bildklasse anhand des LETZTEN bekannten
 *          Filters der /Filter-Kette (ASCII-Transportfilter übergangen):
 *          DCTDecode→jpeg, JPXDecode→jpx, CCITTFaxDecode→ccitt,
 *          JBIG2Decode→jbig2, FlateDecode→flate_image, sonst other_image.
 *       2. /Type FontFile|FontFile2|FontFile3 ODER Vorhandensein von
 *          /Length1 → font_program.
 *       3. /Type /Metadata oder /Subtype /XML → metadata.
 *       4. /Type /EmbeddedFile → embedded_file.
 *       5. /Type /ObjStm → object_stream.
 *       6. /Subtype /Form oder Seite-/Contents-Stream → content_stream
 *          (Content-Streams der Seiten werden über den Seitenbaum
 *          gesammelt, Formen über den Objekt-Walk).
 *       7. alles andere → unattributed (kein Byte-Konto, nur die Rest-
 *          bilanz oben).
 *
 * Bekannte legitime Abweichungen gegenüber byte-attribution.py: Das Skript
 * rechnet /ObjStm- und unklassifizierte Streams implizit in seine
 * structure_estimate; hier sind ObjStm eine eigene Kategorie und
 * unklassifizierte Streams Teil von unattributed_bytes. Daher gilt
 * unattributed(hier) = structure_estimate(Skript) − object_stream_bytes. */
typedef struct pdfcore_space_inventory {
    long long document_bytes;      /* vom Aufrufer geliefert (Dateigröße) */
    long long jpeg_bytes;
    long long jpx_bytes;
    long long ccitt_bytes;
    long long jbig2_bytes;
    long long flate_image_bytes;
    long long other_image_bytes;
    long long font_program_bytes;
    long long content_stream_bytes;
    long long metadata_bytes;
    long long embedded_file_bytes;
    long long object_stream_bytes;
    long long unattributed_bytes;  /* Rest inkl. Nicht-Stream-Syntax */
} pdfcore_space_inventory_t;

int pdfcore_space_inventory(pdfcore_document_t *doc,
                            long long document_bytes,
                            pdfcore_space_inventory_t *out);

int pdfcore_replace_image_object(pdfcore_document_t *doc,
                                 int obj_number, int generation,
                                 const unsigned char *jpeg, size_t jpeg_len,
                                 int new_width, int new_height,
                                 int grayscale, int decode_applied);

/* Phase 6C (Roadmap) – JPEG-Ersatz für VIERKANAL-Druckdaten (CMYK).
 *
 * Wie pdfcore_replace_image_object (dieselbe Verweigerungspolitik: /SMask,
 * /Mask, /Decode, /ImageMask), mit einem bewussten Unterschied: Ein
 * nicht-trivialer /ColorSpace wird ÜBERNOMMEN, wenn seine Komponentenzahl
 * zu den 4 Kanälen passt (ICCBased-4). Der Grund: Die übergebenen JPEG-Daten
 * tragen die Werte des ursprünglichen CMYK-Farbraums – der YCCK-Umlauf des
 * Kodierers ist farbtreu zur CMYK-Quelle, das Profil beschreibt sie
 * weiterhin richtig. Beim RGB-Ersatz gilt das nicht (dort liefert der
 * Kodierer sRGB, weil das Profil beim Dekodieren angewendet wurde) – deshalb
 * ist die Beibehaltung hier explizit und nicht generisch.
 * DeviceCMYK (einfacher Name) wird als /DeviceCMYK neu geschrieben. */
int pdfcore_replace_image_object_cmyk(pdfcore_document_t *doc,
                                      int obj_number, int generation,
                                      const unsigned char *jpeg, size_t jpeg_len,
                                      int new_width, int new_height,
                                      int decode_applied);

/* Verlustfreier Ersatz: FlateDecode-Stream mit Pixelbytes, optional mit
 * adaptivem PNG-Zeilenprädiktor (`png_predictor = 1`, PDF Predictor 15).
 * Für Grafiken/Screenshots, bei denen JPEG Kanten zerstören würde.
 * Dieselbe Verweigerungspolitik wie beim JPEG-Ersatz.
 *
 * components: 1 = DeviceGray, 3 = DeviceRGB, 4 = DeviceCMYK. Der Farbraum
 * folgt damit den übergebenen Bytes, statt auf grau/RGB beschränkt zu sein –
 * so lassen sich CMYK-Bilder verkleinern, ohne sie umzurechnen. */
int pdfcore_replace_image_object_flate(pdfcore_document_t *doc,
                                       int obj_number, int generation,
                                       const unsigned char *flate, size_t flate_len,
                                       int new_width, int new_height,
                                       int components, int png_predictor,
                                       int decode_applied);

/* OCR-Textebene (2026-10-01): hängt `content` als eigenen Content-Stream an
 * die Seite an. Der bestehende Inhalt wird in q … Q gekapselt, damit sein
 * Grafikzustand die Textebene nicht verschiebt; die Seite erhält die
 * Font-Ressource /PDFToolsOCR (Helvetica, WinAnsiEncoding) – bei geteilten
 * Ressourcen als Kopie nur für diese Seite. Rückgabe PDFCORE_OK oder Fehler. */
int pdfcore_append_ocr_layer(pdfcore_document_t *doc, int page_index,
                             const char *content, size_t content_len);

/* zlib-Kompression (echtes zlib, nicht Apples Compression-Framework):
 * level 0…9 bzw. -1 = Z_DEFAULT_COMPRESSION. Apples ZLIB-Variante fiel auf
 * glatten Bildern bis 4× größer aus – Planung und finaler Writer sprachen
 * sonst verschiedene Größen (2026-10-01). Ergebnis per malloc; der Aufrufer
 * gibt es mit free() frei. */
int pdfcore_flate_compress(const unsigned char *data, size_t data_len, int level,
                           unsigned char **out, size_t *out_len);

/* Stream-Bytes EINES Bildobjekts.
 * decoded = 0 → rohe Stream-Bytes (bei DCTDecode also JPEG-Daten)
 * decoded = 1 → von libqpdf dekodierte Bytes (Flate/LZW/RunLength aufgelöst,
 *               inkl. Predictor). Für Filter, die libqpdf nicht auflösen kann,
 *               wird PDFCORE_ERR_CHECK_FAILED gemeldet – NIE Ersatzdaten.
 * Gibt malloc'd Buffer zurück; Freigabe mit free(). */
int pdfcore_get_image_object_data(pdfcore_document_t *doc,
                                  int obj_number, int generation,
                                  int decoded,
                                  char **out, size_t *len);

/* Strukturprofil des Dokuments – Eingang in die Größenschätzung.
 * Bit 0: Dokument verwendet bereits Object Streams (/Type /ObjStm)
 * Bit 1: Dokument ist linearisiert
 * Bit 2: mindestens ein Content-Stream ist UNkomprimiert
 * Rückgabe < 0 = Fehler. */
int pdfcore_structure_profile(pdfcore_document_t *doc);

/* Masterplan Finding 12 – Metadaten-Policy im Produktionspfad.
 * Entfernt /Info-Felder und den XMP-Metadatenstrom des Katalogs.
 * `keep_producer` = 1 lässt /Producer stehen (deterministischer Stempel). */
int pdfcore_strip_metadata(pdfcore_document_t *doc, int keep_producer);

/* Phase 1b – JPEG-Backend (mozjpeg). Diese Funktionen stehen NICHT am
 * Dokument, sondern an den rohen JPEG-Bytes – die Bridge bleibt PDF-only.
 *
 * Verlustfreier Repack (jpegtran-Semantik): Die DCT-Koeffizienten werden
 * unverändert übernommen (jpeg_read_coefficients → jpeg_write_coefficients);
 * neu ist nur die Verpackung – optimierte Huffman-Tabellen und progressiver
 * Scan-Entwurf. Kein Qualitätsverlust.
 *
 * Status: OK   = *out trägt malloc'd Bytes (Freigabe mit free()),
 *         SKIP = Quelle ist bereits progressive (SOF2) – nichts zu tun,
 *         ERR  = kein lesbarer JPEG oder Kodierfehler.
 * In den Fällen SKIP/ERR behält der Aufrufer die Originalbytes (Never-Grow).
 * `progressive` = 0 verzichtet auf Progressive-Scans und kodiert nur die
 * Huffman-Tabellen neu (Baseline) – für den „Maximale Kompatibilität"-Preset. */
typedef enum {
    PDFCORE_JPEG_REPACK_OK = 0,
    PDFCORE_JPEG_REPACK_SKIP = 1,
    PDFCORE_JPEG_REPACK_ERR = 2
} pdfcore_jpeg_repack_status;

int pdfcore_jpeg_repack(const unsigned char *jpeg, size_t jpeg_len,
                        int progressive, unsigned char **out, size_t *out_len);

/* Verlustbehafteter Encode über mozjpeg (Trellis-Quantisierung, progressive
 * Scans, optimierte Huffman-Tabellen, 4:2:0-Chroma wie üblich; Graustufen
 * bleiben einkanalig). `pixels` ist ein unkomprimierter Pixelbuffer
 * (components: 1 = Grau, 3 = RGB – CMYK bewusst NICHT, siehe
 * CMYKJPEGRoundTripTests), `quality` 1...100.
 * 0 = ok (*out malloc'd, free()), sonst Fehler – der Aufrufer fällt dann auf
 * das ImageIO-Fallback-Backend zurück. */
int pdfcore_jpeg_encode(const unsigned char *pixels, size_t pixels_len,
                        int width, int height, int components,
                        int quality, unsigned char **out, size_t *out_len);

/* Phase 6C (Roadmap) – verlustbehafteter CMYK-Re-Encode über mozjpeg.
 *
 * `pixels` ist ein unkomprimierter, interleaved 8-bit-Puffer in
 * CMYK-Reihenfolge (4 Byte je Bildpunkt, Zeilen ohne Padding) – exakt das
 * Layout, das ImageResampler.rawBitmap(components: 4) liefert. Der Kodierer
 * schreibt JCS_YCCK mit Adobe-APP14 und Transform-Byte 2 – in der
 * Adobe-Konvention: Die Datei trägt YCC über den UNINVERTIERTEN CMY-Werten
 * und den K-Kanal invertiert. Da libjpegs cmyk_ycck_convert C/M/Y selbst
 * invertiert und K unangetastet lässt, invertiert der Shim ALLE VIER
 * Komponenten vor der Übergabe: Die C/M/Y-Doppelinversion hebt sich auf,
 * K landet invertiert in der Datei. Adobe-konforme Leser (ImageIO/
 * CoreGraphics, PDFKit, Acrobat, pdf.js) dekodieren farbgleich – verifiziert
 * am Re-Encode eines echten Adobe-CMYK-JPEG aus dem Korpus. Kein Subsampling
 * (4:4:4 über alle vier Komponenten): Die vier Druckfarbenplatten sind
 * gleichwertig, ein 2x2-Subsampling würde Pressdaten opfern – und CMYK-
 * JPEGs im Feld tragen üblicherweise ebenfalls keine Subsampling-Faktoren.
 * `quality` 1...100 wie bei pdfcore_jpeg_encode; Trellis, progressive
 * Scans und optimierte Huffman-Tabellen kommen über das mozjpeg-Profil
 * (JCP_MAX_COMPRESSION).
 * 0 = ok (*out malloc'd, free()), sonst Fehler – der Aufrufer verwirft den
 * Kandidaten; das Feld gehört dem verlustfreien 6b-Repack (Never-Grow). */
int pdfcore_jpeg_encode_cmyk(const unsigned char *pixels, size_t pixels_len,
                             int width, int height,
                             int quality, unsigned char **out, size_t *out_len);

/* Phase 4b (Roadmap) – JPX/JPEG2000-Eingabedekodierung über OpenJPEG.
 * Diese Funktion steht – wie das JPEG-Backend – NICHT am Dokument; sie
 * dekodiert rohe /JPXDecode-Stream-Bytes. Es gibt bewusst KEINE
 * JPX-Encode-Funktion: JPX wird ausschließlich als INPUT dekodiert und
 * niemals als Output geschrieben (PDFKit-Risiko, Roadmap Phase 4).
 *
 * PDF /JPXDecode trägt den JP2-Familien-Datenstrom: meist den nackten
 * Codestream (SOC…EOC), seltener mit vorangestellten Boxen. An der
 * 12-Byte-jP-Signatur wird der Codec-Typ erkannt (JP2), sonst
 * OPJ_CODEC_J2K. Der Farbraum ist im Codestream nicht verlässlich
 * (OPJ_CLRSPC_UNKNOWN) – die Farbwelt kennt der Aufrufer aus dem PDF-
 * /ColorSpace; hier zählt nur die Komponentenzahl.
 *
 * `reduce` (0 = volle Auflösung) entspricht opj cp_reduce: N dekodiert
 * direkt auf 1/2^N – der Downsampling-Zielpfad kann so ohne Full-Decode
 * arbeiten. Thread-Sicherheit: Je Aufruf entsteht eine eigene Codec-Instanz.
 *
 * AUSGABEFORM (durchgehend Little-Endian, dokumentierter Vertrag):
 *
 *   0..3    'J','P','X','D'
 *   4       u8  Version = 1
 *   5       u8  Komponentenzahl (1..4)
 *   6       u8  prec der Komponente 0
 *   7       u8  sgnd der Komponente 0 (0/1)
 *   8..11   u32 Flags (Bit 0 = einheitliches Raster: alle Komponenten
 *               liefern dieselben w/h wie Komponente 0)
 *   12..15  u32 Breite  des Referenzrasters (= w der Komponente 0,
 *               bereits um `reduce` verkleinert)
 *   16..19  u32 Höhe
 *   20..23  u32 Offset Komponententabelle (vom Pufferstart, = 32)
 *   24..27  u32 Offset Pixelpayload (= 32 + comps*24)
 *   28..31  u32 Länge Pixelpayload (Breite*Höhe*comps)
 *   ab 32   comps × { u32 w, u32 h, u32 dx, u32 dy, u32 prec, u32 sgnd }
 *           (Masse der QUELLE vor jeder Hochrechnung, nach cp_reduce)
 *   ab payloadOffset: interleaved 8-bit-Pixel, Zeilen ohne Padding,
 *           Komponenten in Codestream-Reihenfolge.
 *
 * Das Pixelziel ist bewusst 8-bit, denn der Kompressionspfad arbeitet
 * durchgehend auf 8-bit: prec ≤ 8 bleibt steht (Werte roh), 9..16 werden
 * um (prec-8) nach rechts geschoben. prec > 16 ist in PDF unrealistisch
 * und liefert einen Fehler. Mit Vorzeichen belegte Werte erhalten vor dem
 * Schieben den Offset 2^(prec-1). Subsampling (dx/dy > 1, kleinere w/h je
 * Komponente) wird auf das Referenzraster hochgerechnet (nächster
 * Nachbar) – in PDF-JPX selten; die Komponententabelle hält die
 * ursprünglichen Masse fest.
 *
 * Status: OK = *out trägt malloc'd Bytes (Freigabe mit free()), sonst
 * Fehlercode – der Aufrufer behält das Originalbild (KEEP). */
int pdfcore_jpx_decode(const unsigned char *data, size_t data_len,
                       int reduce, unsigned char **out, size_t *out_len);

/* Phase 2b – Bilevel-Kodierung (CCITT G4 via libtiff, lossless JBIG2 via
 * jbig2enc). Diese Funktionen stehen – wie das JPEG-Backend – NICHT am
 * Dokument, sondern arbeiten auf rohen 1-bit-Pixelpuffern.
 *
 * Pixelfolge, durchgehend für Eingabepuffer UND pdfcore_g4_decode-Ergebnis:
 *   Bit 1 = schwarz (Tinte), Bit 0 = weiss; MSB-first je Zeile;
 *   rowbytes = (width + 7) / 8, keine Zeilen über Wortgrenzen hinaus.
 *
 * G4: libtiff erzeugt einen NACKTEN T6-Strom (COMPRESSION_CCITTFAX4, ein
 * Strip, in-memory via TIFFClientOpen) – die Bytes sind direkt als
 * /CCITTFaxDecode-Payload verwendbar. Der Fax-Codec trägt intern
 * 0 = weiss / 1 = schwarz; encode kehrt die Reihen deshalb VOR dem
 * Schreiben um, decode NACH dem Lesen. Zusammen mit /BlackIs1 true im
 * DecodeParms rendert Bit 1 des Eingabepuffers als Tinte (im Render-Test
 * gegen die Originalpixel verifiziert). Der Decode liest den nackten
 * Strom über einen synthetischen TIFF-Wrapper (libtiff braucht Struktur);
 * width/height muss der Aufrufer mitliefern – ein nackter T6-Strom trägt
 * keine Masse.
 *
 * JBIG2, zwei Kodierer:
 *   - pdfcore_jbig2_encode: Symbolpfad jbig2_init → add_page →
 *     pages_complete → produce_page mit refine_level = -1 (Refinement HART
 *     aus – bekannter Acrobat-Crasher). Liefert Seitenstrom und, wenn ein
 *     Symbol-Dictionary entstand, den globalen Strom für
 *     /DecodeParms <</JBIG2Globals …>>. ABER: Der Symbolklassifizierer
 *     führt ähnliche (nicht identische) Glyphen zusammen (Schwellwert-
 *     Bereich 0.4–0.98, exakte Klassen nicht einstellbar) – die
 *     Rekonstruktion ist dadurch NICHT bitidentisch garantiert. Der
 *     Aufrufer muss den Kandidaten dekodieren und bitidentisch prüfen;
 *     scheitert er, ist er zu verwerfen.
 *   - pdfcore_jbig2_encode_generic: generische Region (jbig2_encode_generic,
 *     kein Symbol-Dict, keine Globals) – reine Entropiekodierung des
 *     exakten Bitmaps, damit konstruktiv verlustfrei. Das Render-Gate
 *     bestätigt das je Kandidat.
 * Alle Rückgabepuffer sind malloc'd (Freigabe mit free()). */
int pdfcore_g4_encode(const unsigned char *pixels, size_t pixels_len,
                      int width, int height,
                      unsigned char **out, size_t *out_len);

int pdfcore_g4_decode(const unsigned char *g4, size_t g4_len,
                      int width, int height,
                      unsigned char **out, size_t *out_len);

/* V2-3c (§9.10) – CCITT-EINGANGS-Decode. Decodiert vorhandene
 * CCITTFaxDecode-Streams (G4 UND G3) auf dieselbe Pixelfolge wie
 * pdfcore_g4_decode: Bit 1 = schwarz (Tinte), MSB-first, Zeilenende
 * ungefüllt.
 *
 * BlackIs1 IST hier wirksam (anders als in der pdfcore-internen
 * G4-Konvention): Der Fax-Dekodierer füllt weisse Läufe mit 0-Bits und
 * schwarze mit 1-Bits. Ohne BlackIs1 ist das bereits die sichtbare Tinte;
 * mit /BlackIs1 true erklärt der Schreiber den Strom für invertiert und
 * die Extraktion kehrt um – genau wie der Leser es anzeigt. Strom und
 * Flag zusammen bestimmen also das Ergebnis; ein passendes Paar liefert
 * dieselbe Tinten-1-Folge. (pdfcore_g4_decode komplementiert dagegen
 * UNBEDINGT, weil es ausschließlich die eigene, komplementierte
 * Output-Konvention zurückliest.)
 *
 * pdfcore_ccitt_parms_t trägt den DecodeParms-Katalog; die ANNAHME-
 * politik (welche Kombinationen dekodiert werden dürfen) liegt in Swift –
 * hier steht nur die defensive Abweisung unsinniger Werte. G3: ohne
 * /EndOfLine läuft der Dekodierer ohne EOL-Synchronisation (libtiff
 * FAXMODE_NOEOL|NORTC), mit /EndOfLine im T.4-Stil (EOL vor jeder Zeile,
 * FAXMODE_NORTC). /EncodedByteAlign und /DamagedRowsBeforeError > 0
 * werden vom Aufrufer verweigert (libtiff-Abdeckung nicht verifizierbar),
 * /EndOfBlock ist decodeseitig wirkungslos, weil zeilenzahlgesteuert
 * gelesen wird. */
typedef struct {
    int present;         /* 1, wenn /DecodeParms als Dictionary lesbar war */
    int k;               /* /K: -1 = G4 (T.6), 0 = G3 1D, 1..64 = G3 2D */
    int columns;         /* /Columns */
    int rows;            /* /Rows */
    int black_is_1;      /* /BlackIs1 – steuert die Extraktionsumkehr */
    int end_of_line;     /* /EndOfLine */
    int end_of_block;    /* /EndOfBlock */
    int byte_aligned;    /* /EncodedByteAlign */
    int damaged_rows;    /* /DamagedRowsBeforeError */
    int known_keys_only; /* 1, wenn das Dictionary nur bekannte Schlüssel trägt */
} pdfcore_ccitt_parms_t;

int pdfcore_ccitt_decode(const unsigned char *data, size_t data_len,
                         const pdfcore_ccitt_parms_t *parms,
                         unsigned char **out, size_t *out_len);

/* Liest /DecodeParms eines Bild-XObjects für CCITTFaxDecode. Die Filter-
 * kette selbst prüft der Aufrufer (Swift verlangt exakt [.ccitt]); hier
 * wird nur defensive geprüft, dass der terminale Filter CCITTFaxDecode
 * ist. /DecodeParms als Dictionary oder ein-elementiges Array wird
 * gelesen; fehlende optionale Schlüssel erhalten ihre PDF-Defaults.
 * Fehlertypen (falsche Typen, unbekannter terminaler Filter) liefern
 * PDFCORE_ERR_CHECK_FAILED – der Aufrufer behandelt das wie „nicht
 * rekonstruierbar“ (KEEP). */
int pdfcore_get_image_ccitt_parms(pdfcore_document_t *doc,
                                  int obj_number, int generation,
                                  pdfcore_ccitt_parms_t *out);

/* Fixture-/Test-Encoder (V2-3c): erzeugt G3-/G4-Ströme mit wählbarem
 * /EndOfLine-Verhalten, um echte Eingangs-Fixtures ohne externes Werkzeug
 * zu generieren. FAX-NATIV: Der Eingabepuffer trägt Bit 1 = Tinte und wird
 * OHNE Komplement geschrieben – der Strom entspricht einem realen
 * Standard-Stream mit PDF-Default (Abtastwert 1 = schwarz; anders als
 * pdfcore_g4_encode, dessen Output die komplementierte Konvention mit
 * /BlackIs1 true ist). k < 0 → G4 (end_of_line wirkungslos), k == 0 →
 * G3 1D, k > 0 → G3 2D (GROUP3OPT_2DENCODING). NICHT Teil der Produktion
 * – nur Fixtures. */
int pdfcore_ccitt_encode_fixture(const unsigned char *pixels, size_t pixels_len,
                                 int width, int height,
                                 int k, int end_of_line,
                                 unsigned char **out, size_t *out_len);

int pdfcore_jbig2_encode(const unsigned char *pixels, size_t pixels_len,
                         int width, int height,
                         unsigned char **page_out, size_t *page_len,
                         unsigned char **globals_out, size_t *globals_len);

int pdfcore_jbig2_encode_generic(const unsigned char *pixels, size_t pixels_len,
                                 int width, int height,
                                 unsigned char **out, size_t *out_len);

/* Ersetzt ein Bild-XObject durch CCITTFaxDecode bzw. JBIG2Decode (Phase 2b).
 * Das neue Wörterbuch trägt BitsPerComponent 1, /ColorSpace /DeviceGray und
 * die DecodeParms der Phase-2b-Konvention: G4 mit /K -1 /Columns /Rows
 * /BlackIs1 true; JBIG2 mit /JBIG2Globals als EIGENEM indirektem Stream-
 * Objekt, wenn Globals vorliegen (sonst ohne /DecodeParms). Dieselbe
 * Verweigerungspolitik wie beim JPEG-Ersatz (Farbschlüssel-/Schablonen-
 * Masken, ImageMask, unangewendetes /Decode). Die Masse bleiben unverändert,
 * /SMask und /Mask werden wie bisher mitgenommen. */
int pdfcore_replace_image_object_ccitt(pdfcore_document_t *doc,
                                       int obj_number, int generation,
                                       const unsigned char *g4, size_t g4_len,
                                       int width, int height);

int pdfcore_replace_image_object_jbig2(pdfcore_document_t *doc,
                                       int obj_number, int generation,
                                       const unsigned char *page_data, size_t page_len,
                                       const unsigned char *globals, size_t globals_len,
                                       int width, int height);

/* Masterplan §9.6 (V2-3b) – Ersetzt ein Bild-XObject durch einen
 * /Indexed-Farbraum mit FlateDecode + PNG-Prädiktor (Predictor 15).
 *
 * Neues Wörterbuch:
 *   /Type /XObject /Subtype /Image
 *   /Filter /FlateDecode
 *   /DecodeParms << /Predictor 15 /Colors 1
 *                  /BitsPerComponent bpc /Columns width >>
 *   /ColorSpace [/Indexed /DeviceGray|/DeviceRGB hival <Lookup>]
 *   /BitsPerComponent bpc /Width width /Height height
 *
 * Lookup-Form (dokumentierte Wahl): IMMER ein (in Hex geschriebener)
 * String, kein Stream – die Palette trägt höchstens 256 Einträge × 3 Byte
 * = 768 Byte, der String ist damit die kleinste und von allen Lesern
 * gedeckte Form (der Standard erlaubt String ODER Stream).
 * hival = Einträge − 1: die Palette wird exakt so groß geschrieben, wie
 * sie tatsächlich benutzt wird.
 *
 * Parameter:
 *   indices – FLATE-kodierte Indizes (gepackt MSB-first, mit PNG-
 *             Prädiktor). JEDE ZEILE der ENTPACKTEN Daten beginnt auf
 *             einer Bytegrenze (ISO 32000-1 §8.9.3: „each row of sample
 *             data shall begin on a byte boundary"; die Auffüllbits am
 *             Zeilenende müssen Leser ignorieren) – entpackte Länge ist
 *             also ceil(width*bpc/8) * height. Diese Länge kann hier ohne
 *             Inflate nicht geprüft werden; die Zeilenpackung ist Sache
 *             des Aufrufers (bitgenauer Nachweis im Swift-Gate).
 *   palette – Palette: palette_components Byte je Eintrag (RGB-Triplette
 *             bei 3, Grauwerte bei 1).
 *   bpc     – BitsPerComponent der Indizes: 1, 2, 4 oder 8. Die
 *             Einträgezahl darf 2^bpc nicht übersteigen (sonst könnten
 *             Indizes hinter hival liegen).
 *   palette_components – 1 = /DeviceGray-Basis, 3 = /DeviceRGB-Basis.
 *
 * Verweigerungspolitik wie pdfcore_replace_image_object_ccitt: /Mask als
 * Array (Farbschlüssel-Maskierung), /ImageMask true und ein nicht
 * erklärtes /Decode blockieren die Ersetzung; /SMask, /Mask (Stream) und
 * die Erklär-/Ansichts-Beziehungen (/Intent, /Interpolate, /Metadata,
 * /StructParent, /OC) werden übernommen. Die Never-Grow-Regel bleibt
 * Sache des Aufrufers – der C-Kern prüft nur die Struktur. */
int pdfcore_replace_image_object_indexed(pdfcore_document_t *doc,
                                         int obj_number, int generation,
                                         const unsigned char *indices, size_t indices_len,
                                         const unsigned char *palette, size_t palette_len,
                                         int width, int height,
                                         int bits_per_component,
                                         int palette_components,
                                         int decode_applied);

/* Ersetzt NUR die Stream-Bytes eines Bildobjekts – das Wörterbuch bleibt
 * unverändert. Für den verlustfreien JPEG-Repack: Gleiche Koeffizienten und
 * gleiche Dimensionen, also bleiben /Decode, /SMask, /Mask & Co. exakt
 * gültig. Verweigert die Ersetzung (PDFCORE_ERR_CHECK_FAILED), wenn der
 * Filter nicht ausschließlich DCTDecode ist – rohe Bytes ohne diesen Filter
 * sind keine JPEG-Daten. */
int pdfcore_replace_image_stream_bytes(pdfcore_document_t *doc,
                                       int obj_number, int generation,
                                       const unsigned char *bytes, size_t len);

/* Phase 3-Followup – Zopfli-Repack einzelner Flate-Streams (nur im
 * Max-Preset). Anders als beim JPEG-Repack liegt der Hebel in der
 * DEFLATE-Verpackung selbst: inflate + Zopfli-DEFLATE anstelle von
 * zlib -9. Der Predictor (/DecodeParms) bleibt unberührt – er wirkt auf
 * den INHALT, nicht auf die Verpackung. Thread-Sicherheit: Nur
 * pdfcore_zopfli_compress ist frei von Dokumentzugriff und darf parallel
 * laufen; alles andere am selben Handle bleibt seriell.
 *
 * pdfcore_zlib_inflate: roher zlib-Strom (RFC 1950) → Inhalt. Breakt ab,
 * wenn der Inhalt `max_content_bytes` übersteigt (Speicherschutz gegen
 * komprimierte Bomben) – PDFCORE_ERR_CHECK_FAILED.
 * pdfcore_zopfli_compress: Inhalt → zlib-Strom (ZOPFLI_FORMAT_ZLIB,
 * CLI-Voreinstellungen). *out malloc'd, free().
 * pdfcore_flate_stream_list: alle Streams mit EXAKT /FlateDecode (ohne
 * /ObjStm und /XRef, die der Writer ohnehin selbst schreibt) und
 * Rohgröße >= min_raw_bytes; Einträge "objNum|gen|rawLen", Freigabe mit
 * pdfcore_free_strings.
 * pdfcore_replace_stream_bytes: ersetzt NUR die rohen Stream-Bytes eines
 * Objekts; das Wörterbuch (inklusive /Filter und /DecodeParms) bleibt
 * unverändert. Verweigert (PDFCORE_ERR_CHECK_FAILED), wenn /Filter nicht
 * exakt /FlateDecode ist. Verlustfrei: Die dekodierten Bytes bleiben
 * bitidentisch. */
int pdfcore_zlib_inflate(const unsigned char *data, size_t data_len,
                         size_t max_content_bytes,
                         unsigned char **out, size_t *out_len);

int pdfcore_zopfli_compress(const unsigned char *data, size_t data_len,
                            unsigned char **out, size_t *out_len);

int pdfcore_flate_stream_list(pdfcore_document_t *doc, size_t min_raw_bytes,
                              char ***out, int *count);

/* Rohe (kodierte) Stream-Bytes eines BELIEBIGEN Stream-Objekts –
 * Gegenstück zu pdfcore_get_image_object_data(decoded: false).
 * *out malloc'd, free(). */
int pdfcore_get_stream_bytes(pdfcore_document_t *doc,
                             int obj_number, int generation,
                             unsigned char **out, size_t *len);

/* Phase 23c – Stream-Bytes eines BELIEBIGEN Stream-Objekts per Objekt-
 * identität. decoded=1: dekodierte Bytes (qpdf_dl_all) – scheitert die
 * Auflösung EINES Filters, kommt PDFCORE_ERR_CHECK_FAILED (niemals
 * Ersatzdaten). decoded=0: rohe (kodierte) Bytes, wie
 * pdfcore_get_stream_bytes. *out malloc'd, free(). */
int pdfcore_get_object_stream_bytes(pdfcore_document_t *doc,
                                    int obj_number, int generation,
                                    int decoded,
                                    char **out, size_t *len);

int pdfcore_replace_stream_bytes(pdfcore_document_t *doc,
                                 int obj_number, int generation,
                                 const unsigned char *bytes, size_t len);

/* ===========================================================================
 * Phase V2-7 (Masterplan §13.7) – MRC Scan Engine.
 *
 * Ersetzt den Full-Page-Raster-Draw einer Scan-Seite durch MRC-Layer:
 * Background (JPEG) → Photo-Regionen (JPEG, Sub-Rects) → Foreground-Maske
 * (ImageMask: JBIG2 oder CCITT G4, schwarze Tinte über dem Hintergrund).
 *
 * Die bestehende nicht-raster Semantik bleibt unberührt (Text-Operatoren
 * inkl. unsichtbarem OCR-Layer, Annotationen, Forms, Boxes, /Rotate) –
 * ersetzt wird ausschließlich die cm/Do-Sequenz um das Raster, unter
 * Wahrung der ursprünglichen cm-Transform.
 *
 * pdfcore_mrc_layer_t – EIN Layer in ZEICHNUNGSREIHENFOLGE (Hintergrund
 * zuerst, Maske zuletzt):
 *   kind        0 = JPEG (DCTDecode), 1 = JBIG2Decode, 2 = CCITT G4
 *   is_mask     1 = /ImageMask (nur kind 1/2, V1-Konvention: schwarze
 *               Tinte, /Decode [0 1]); 0 = 8-bit-Bild (nur kind 0)
 *   components  JPEG: 1 = /DeviceGray, 3 = /DeviceRGB
 *   globals     JBIG2: /JBIG2Globals (oder NULL/0)
 *   rect        Sub-Rect im BILDPIXELRAUM mit OBEN-LINKS-Ursprung
 *               (x0,y0,x1,y1); alle 0 = Vollbild. Die y-Spiegelung in den
 *               PDF-Bildraum nimmt der C-Kern vor.
 *
 * Transaktional: Alle Prüfungen (Seite, Name → Objektidentität, genau EIN
 * adjazenter cm/Do-Draw, Rect-Grenzen, Layer-Semantik, Concat-Budget)
 * laufen vor der ersten Mutation; eine Verweigerung lässt das Dokument
 * unangetastet (PDFCORE_ERR_CHECK_FAILED). Die Layer-Namen werden im
 * Copy-on-Write-/Resources-Dict eindeutig vergeben; der ersetzte Name
 * verschwindet aus der Map (das Original-Objekt selbst bleibt bestehen
 * und verwaist, falls keine weitere Referenz existiert). */
typedef struct pdfcore_mrc_layer {
    const unsigned char *bytes;
    size_t len;
    int width;
    int height;
    int kind;
    int components;
    int is_mask;
    const unsigned char *globals;
    size_t globals_len;
    double rect[4];   /* x0, y0, x1, y1 – Bildpixelraum, oben-links */
} pdfcore_mrc_layer_t;

int pdfcore_replace_page_image_draw_with_layers(
    pdfcore_document_t *doc,
    int page_index,
    int image_obj_number, int image_generation,
    const char *resource_name,
    const pdfcore_mrc_layer_t *layers, int layer_count);

/// Gibt ein von *_inspect/*_list-Funktionen geliefertes String-Array frei.
void pdfcore_free_strings(char **arr, int count);

/* Ink-Overlay (Freihand-Tinte): hängt rohe Content-Operatoren an Seiten an.
 *
 * `page_indices[i]` (0-basiert) erhält `contents[i]` (NUL-terminierter
 * Operator-String, z. B. "q … RG … w … m … l S Q") als ZUSÄTZLICHEN Stream
 * HINTER dem bestehenden Content (addPageContents, first=false). Alles
 * Bestehende – Text, Bilder, Annotationen, Formulare – bleibt unberührt;
 * die Tinte liegt darüber wie ein transparentes Deckblatt.
 *
 * Leere Strings sind erlaubt (kein Overlay für diese Seite). Der Writer
 * komprimiert die neuen Streams beim Schreiben selbst. 0=ok, -1=Fehler
 * (ungültiges Handle, Seitenindex oder Inhalt). */
int pdfcore_append_page_content(pdfcore_document_t *doc,
                                const int *page_indices,
                                const char *const *contents,
                                int count);

#ifdef __cplusplus
}
#endif
#endif /* PDFCORE_H */
