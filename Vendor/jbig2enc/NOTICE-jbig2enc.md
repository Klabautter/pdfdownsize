# NOTICE – jbig2enc + Leptonica (vendored)

Dieses Verzeichnis enthält statische, universelle Build-Artefakt-Kopien
(arm64 + x86_64) von:

1. **jbig2enc**, Commit `23f992c92b10048064602b4d8ea29bb434752634` (Master-Stand Aug 2026, kein
   Release-Tag – Commit gepinnt)
   Quelle: https://github.com/agl/jbig2enc
   Lizenz: Apache-2.0 (upstream `COPYING`, siehe unten)

2. **Leptonica v1.87.0**
   Quelle: https://github.com/DanBloomberg/leptonica (Tag `1.87.0`)
   Lizenz: BSD-artig (upstream `leptonica-license.txt`, siehe unten)

Verwendung: lossless JBIG2-Encoding für Bilevel-PDF-Bilder
(COMPRESSION_ROADMAP.md, Phase 2). Keine Änderungen am Quellcode.
Regeln: NUR lossless, KEIN Refinement (CLI `-r` unbenutzt; bekannter
Acrobat-Crasher). Das CLI `jbig2` ist NICHT Teil dieses Verzeichnisses
(verbleibt unter /tmp/opencode).

Build-Konfiguration: Release, BUILD_SHARED_LIBS=OFF. Leptonica mit ALLEN
optionalen Codecs OFF (zlib/png/gif/jpeg/tiff/webp/openjpeg) – BMP/PNM
sind eingebaut; jbig2enc benötigt nur die Pix-Kern-API. Deployment-Target
macOS 11.0. Nur System-Abhängigkeiten (libm).

---

## Lizenz jbig2enc (upstream `COPYING`)

```
See also doc/PATENTS.

Copyright 2006 Google Inc. All Rights Reserved.
Author: agl@imperialviolet.org (Adam Langley)

Copyright (C) 2006 Google Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.```

## Lizenz Leptonica (upstream `leptonica-license.txt`)

```
/*====================================================================*
 -  Copyright (C) 2001-2020 Leptonica.  All rights reserved.
 -
 -  Redistribution and use in source and binary forms, with or without
 -  modification, are permitted provided that the following conditions
 -  are met:
 -  1. Redistributions of source code must retain the above copyright
 -     notice, this list of conditions and the following disclaimer.
 -  2. Redistributions in binary form must reproduce the above
 -     copyright notice, this list of conditions and the following
 -     disclaimer in the documentation and/or other materials
 -     provided with the distribution.
 -
 -  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 -  ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 -  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 -  A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL ANY
 -  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 -  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 -  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 -  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 -  OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 -  NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 -  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *====================================================================*/

```
