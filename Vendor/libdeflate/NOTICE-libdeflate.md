# NOTICE – libdeflate (vendored)

Dieses Verzeichnis enthält eine statische Build-Artefakt-Kopie (nur arm64)
von **libdeflate v1.25**.

- Quelle: https://github.com/ebiggers/libdeflate (Release `v1.25`,
  Tarball https://github.com/ebiggers/libdeflate/archive/refs/tags/v1.25.tar.gz,
  per SHA-256 geprüft)
- Lizenz: MIT, upstream `COPYING`.
- Verwendung: Schnelle, kompakte RFC-1950-zlib/DEFLATE-Kodierung für
  Flate-Bildströme (verlustfreier Resize, Paletten, Grafiken).
  Keine Änderungen am Quellcode.
- Build-Konfiguration: Release, LIBDEFLATE_BUILD_STATIC_LIB=ON,
  LIBDEFLATE_BUILD_SHARED_LIB=OFF, LIBDEFLATE_BUILD_GZIP=OFF,
  LIBDEFLATE_BUILD_TESTS=OFF. Deployment-Target macOS 11.0.

Original-Lizenztext:

Copyright 2016 Eric Biggers
Copyright 2024 Google LLC

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation files
(the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software,
and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
