# NOTICE – mozjpeg (vendored)

Dieses Verzeichnis enthält eine statische, universelle Build-Artefakt-Kopie
(arm64 + x86_64) von **mozjpeg v4.1.1**.

- Quelle: https://github.com/mozilla/mozjpeg (Tag `v4.1.1`)
- Lizenz: BSD-3-Clause (siehe `LICENSE-mozjpeg.md`, upstream `LICENSE.md`;
  umfasst die Hinweise der IJG-/libjpeg-turbo-Vorläufer)
- Verwendung: statisch gelinkte JPEG-Codec-Library für das JPEGBackend
  (COMPRESSION_ROADMAP.md, Phase 1). Keine Änderungen am Quellcode.
- Build-Konfiguration: Release, `ENABLE_SHARED=0`, `ENABLE_STATIC=1`,
  `WITH_JPEG8=0` (libjpeg-v6b-ABI, identisch zur libjpeg-turbo 3.1.0 in
  `Vendor/pdfcore`), `WITH_MEM_SRCDST=1`, `WITH_SIMD=0`, `WITH_TURBOJPEG=0`,
  `PNG_SUPPORTED=0`. Deployment-Target macOS 11.0.
- Die Tools cjpeg/djpeg/jpegtran sind nicht Teil dieses Verzeichnisses
  (verbleiben im Build-Arbeitsverzeichnis unter /tmp/opencode).
