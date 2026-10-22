# mozjpeg-Integration (Phase 1a → 1b) – Kurznotiz

## Artefakt

- `lib/libmozjpeg.a`: statisch, Universal arm64 + x86_64, Deployment-Target
  macOS 11.0, built mit `WITH_JPEG8=0` (JPEG_LIB_VERSION 62, libjpeg-v6b-API).
- `include/`: jpeglib.h, jerror.h, jmorecfg.h, jconfig.h, jconfigint.h
  (jversion.h falls generiert) – kompilierfähiger Satz gegen die Static-Lib.
- Benennung: mozjpegs CMake-Target `jpeg-static` erzeugt intern `libjpeg.a`;
  dokumentierte Umbenennung nach `libmozjpeg.a`, damit im App-Link-Setup klar
  ist, welche JPEG-Implementierung gelinkt wird.
- ABI-Abgleich: vendor-qpdf.sh baut libjpeg-turbo 3.1.0 ohne WITH_JPEG8-Flag
  → Default 62; verifiziert in /tmp/opencode/pdftools-vendor/jpeg-arm64/jconfig.h
  (`#define JPEG_LIB_VERSION 62`). mozjpeg wurde mit demselben Modus gebaut
  → späterer Austausch API-kompatibel. `jpeg_mem_src/jpeg_mem_dest` sind im
  6b-Modus verfügbar (WITH_MEM_SRCDST=1). mozjpeg-Erweiterungen zusätzlich:
  `jpeg_c_set_int_param` / `jpeg_c_set_bool_param` / `JINT_COMPRESS_PROFILE`.
- Build: `WITH_SIMD=1` auf arm64 (NEON), `WITH_SIMD=0` auf x86_64 (keine NASM-Abhängigkeit),
  `WITH_TURBOJPEG=0`, `PNG_SUPPORTED=0`, ENABLE_SHARED=0/ENABLE_STATIC=1.
  cjpeg/djpeg/jpegtran landen nur unter /tmp/opencode (nicht in Vendor).

## Kollisions-Analyse (libjpeg-turbo in pdfcore vs. libmozjpeg)

- `libqpdf.a` referenziert jpeg_* ausschließlich undefiniert (kein Einbetten);
  die App linkt `Vendor/pdfcore/lib/libjpeg_universal.a` separat.
- Turbo-Lib exportiert 91 `jpeg_*`-Symbole, mozjpeg 102;
  davon identisch (Name + Definition): 89.
- Turbo-Symbole, die mozjpeg NICHT exportiert:
  - jpeg_aritab
  - jpeg_enable_lossless
  Bewertung: unkritisch – keine dieser Referenzen wird vom
  pdfcore-Binary (pdfcore.o + libqpdf.a) gezogen. Betroffen sind
  turbo-3.x-Lossless (`jpeg_enable_lossless`) und die interne
  Arith-Tabelle (`jpeg_aritab`, mozjpeg 6b-Mode baut Arith-CODEC
  nicht mit; bei Bedarf WITH_ARITH_DEC/WITH_ARITH_ENC=1).

## MÖGLICHE Symbolkollision

Beide Archive definieren dieselben Symbolnamen (u. a. `jpeg_CreateCompress`,
`jpeg_mem_src`, `jpeg_mem_dest`). Werden `libpdfcore_universal.a` +
`libjpeg_universal.a` UND `libmozjpeg.a` gleichzeitig ins App-Binary gelinkt,
führen beide gezogene jpeg-Objekte zu Duplicate-Symbol-Fehlern des Linkers
(first-wins ist bei Static-Archives nicht verlässlich deterministisch – nicht
darauf anlegen).

## Empfehlung für Phase 1b (Swift-Integration)

1. **Bevorzugt:** mozjpeg ERSETZT libjpeg-turbo in pdfcore – in
   `vendor-qpdf.sh` `LIBJPEG_H_PATH`/`LIBJPEG_LIB_PATH` auf
   `Vendor/mozjpeg/include` bzw. `libmozjpeg.a` zeigen lassen und
   `libjpeg_universal.a` aus dem Link-Setup entfernen. Gleiche ABI (62) +
   Superset-Symbole → genau eine JPEG-Implementierung im App-Binary, keine
   Kollision, JPEGBackend und qpdf-DCT-Pfad teilen sich eine Lib.
2. **Alternativ (Übergang):** turbo in pdfcore behalten, mozjpeg nur ins
   App-Target linken – dafür mozjpeg-Symbole beim Vendor-Bau mit Präfix
   umbenennen (llvm-objcopy --redefine-syms, z. B. `mozjpeg_`) plus
   Header-Makro-Mapping. Aufwändig und fehleranfällig.
3. **Nicht tun:** beide Archive unumbenannt parallel linken.

## Anhang: Phase 1b – Integrationsergebnis (2026-08-30)

Umgesetzt nach Empfehlung 1, mit null Projektedits:

- **Link-Weg:** `Vendor/pdfcore/lib/libjpeg_universal.a` trägt jetzt
  INHALTLICH `lib/libmozjpeg.a` (Dateiname stabil → Xcode-Link
  `-ljpeg_universal` unverändert; `project.pbxproj` nicht angefasst).
  `Scripts/build-pdfcore.sh` kompiliert die Bridge gegen
  `Vendor/mozjpeg/include` und legt bei jedem Lauf das mozjpeg-Artefakt
  unter dem bekannten Namen ab; `Scripts/vendor-qpdf.sh` baut qpdf nun
  direkt gegen mozjpeg (kein turbo-Bau mehr im Skript).
- **ABI:** pdfcore.cc kompiliert unverändert gegen die mozjpeg-Header
  (arm64 + x86_64). Im Release-App-Binary sind 98 `jpeg_*`-Symbole intern
  definiert, `jpeg_c_set_int_param` ist da, turbo-only-Symbole
  (`jpeg_enable_lossless`, `jpeg_aritab`) fehlen – genau eine
  JPEG-Implementierung, keine Kollision.
- **Neue pdfcore-C-API** (pdfcore.h/.cc, alles hinter setjmp-Fehlerhülle):
  `pdfcore_jpeg_repack` (Koeffizienten bitidentisch via
  jpeg_read/write_coefficients, optimierte Huffman-Tabellen, progressiver
  Scan-Entwurf; SOF2 → `PDFCORE_JPEG_REPACK_SKIP`; `progressive=0` =
  Baseline/optimize-only) · `pdfcore_jpeg_encode` (Grau/RGB-Pixelbuffer,
  Trellis + progressive + optimierte Huffman, 4:2:0; CMYK bewusst
  abgelehnt) · `pdfcore_replace_image_stream_bytes` (ersetzt NUR
  Stream-Bytes, Wörterbuch bleibt; gibt den bisherigen /Filter zurück –
  ein leeres Handle hätte /Filter durch null ersetzt).
- **Swift:** `JPEGEncoder` (PageTools/JPEGEncoder.swift) kapselt Shim +
  ImageIO-Fallback; `JPEGBackend { mozjpeg, imageIO }` in
  CompressionOptions (Default mozjpeg). ImageResampler/ImageEngine kodieren
  darüber, Dekodieren bleibt AppKit/ImageIO. Executor: verlustfreier
  Repack-Pass für behaltene DCT-Streams (Skip + Never-Grow im Repack
  selbst), `Result.repackedImages`. Qualitätsleiter/SSIM-Gate unverändert;
  Bracketed Search als TODO vermerkt (Drei-Stufen-Leitern ergeben durch
  die lineare Suche dasselbe Ergebnis).
- **Tests:** Suite `MozjpegBackendTests` (8 Tests): lossless Repack
  (bitidentische Pixel, kleiner, SOF2), Skip-Signal, optimize-only bleibt
  Baseline, progressiv optimierter Stream bleibt byteidentisch im
  Dokument, Pipeline-Repack am Dokument, mozjpeg-Encode → DCTDecode-
  Ersetzung, Grau einkanalig, CMYK-Fallback. Vollsuite 441/441 grün
  (Debug, vorher 433 bestehende); Scripts/memory-check.sh 10/10 grün;
  Release-Build grün ohne Compilerwarnungen.
  Kontrollprobe: Im Schnellvergleich liegen auf dem Rausch-Fixture
  (2000×1500) mozjpeg-Encode bei q0,85 bei 17 % der ImageIO-Größe; der
  verlustfreie Repack spart 25–29 % gegenüber der ImageIO-Baseline.
  Einzige Randnotiz: Der Last-sensible Speicher-Slopetest
  (MemoryRegressionTests) ist in der VOLLsuite bekannt flatterhaft
  (Parallelkontamination, die Suite selbst schreibt: sie gehört in
  Scripts/memory-check.sh) – isoliert mit mozjpeg-Slope 0,016 MB gegen
  0,0 MB imageIO je vier Kompressionen, also kein Leck.
