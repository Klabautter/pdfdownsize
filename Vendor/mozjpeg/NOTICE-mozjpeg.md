# NOTICE – mozjpeg (vendored)

Dieses Verzeichnis enthält eine statische Build-Artefakt-Kopie (nur arm64)
von **mozjpeg v4.1.1**.

- Quelle: https://github.com/mozilla/mozjpeg (Tag `v4.1.1`), Tarball per
  SHA-256 geprüft (Scripts/vendor-common.sh)
- Lizenz: BSD-3-Clause (siehe `LICENSE-mozjpeg.md`, upstream `LICENSE.md`;
  umfasst die Hinweise der IJG-/libjpeg-turbo-Vorläufer)
- Verwendung: statisch gelinkte JPEG-Codec-Library für das JPEGBackend und
  den DCT-Pfad von qpdf. Keine Änderungen am Quellcode.
- Build-Konfiguration: Release, `ENABLE_SHARED=0`, `ENABLE_STATIC=1`,
  `WITH_JPEG8=0` (libjpeg-v6b-ABI), `WITH_MEM_SRCDST=1`, `WITH_SIMD=1`
  (NEON), `WITH_TURBOJPEG=0`, `PNG_SUPPORTED=0`. Deployment-Target macOS
  11.0.
