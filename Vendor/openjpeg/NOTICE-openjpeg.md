# NOTICE – OpenJPEG (vendored)

Dieses Verzeichnis enthält eine statische, universelle Build-Artefakt-Kopie
(arm64 + x86_64) von **OpenJPEG v2.5.4**.

- Quelle: https://github.com/uclouvain/openjpeg (Tag `v2.5.4`,
  Tarball https://github.com/uclouvain/openjpeg/archive/refs/tags/v2.5.4.tar.gz)
- Lizenz: BSD-2-Klausel (upstream `LICENSE`, Volltext unten).
- Verwendung: Dekodierung von `/JPXDecode`-Streams (JPEG 2000 rohe
  Codestreams + JP2-Container) für die Neukompression oversized JPX-
  Bilder (COMPRESSION_ROADMAP.md, Phase 4). Ausdrücklich NUR Dekodier-
  pfad: kein JPX-Output (PDFKit-Risiko). Keine Änderungen am Quellcode.
- Build-Konfiguration: Release, BUILD_SHARED_LIBS=OFF,
  BUILD_STATIC_LIBS=ON, BUILD_CODEC=ON (Tools verbleiben unter
  /tmp/opencode), BUILD_TESTING=OFF, BUILD_DOC=OFF. Alle optionalen
  Drittanbieter-Bibliotheken deaktiviert (zlib/png/tiff/lcms/lcms2) –
  der Kern braucht nur libm; Konsequenz: Farbmanagement (lcms) der
  JP2-Tools ist aus, rohe Codestream-Dekodierung unberührt.
  Deployment-Target macOS 11.0.

Original-Lizenztext:

```
/*
 * The copyright in this software is being made available under the 2-clauses 
 * BSD License, included below. This software may be subject to other third 
 * party and contributor rights, including patent rights, and no such rights
 * are granted under this license.
 *
 * Copyright (c) 2002-2014, Universite catholique de Louvain (UCL), Belgium
 * Copyright (c) 2002-2014, Professor Benoit Macq
 * Copyright (c) 2003-2014, Antonin Descampe
 * Copyright (c) 2003-2009, Francois-Olivier Devaux
 * Copyright (c) 2005, Herve Drolon, FreeImage Team
 * Copyright (c) 2002-2003, Yannick Verschueren
 * Copyright (c) 2001-2003, David Janssens
 * Copyright (c) 2011-2012, Centre National d'Etudes Spatiales (CNES), France 
 * Copyright (c) 2012, CS Systemes d'Information, France
 *
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS `AS IS'
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */
```
