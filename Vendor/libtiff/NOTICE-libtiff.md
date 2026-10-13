# NOTICE – libtiff (vendored)

Dieses Verzeichnis enthält eine statische, universelle Build-Artefakt-Kopie
(arm64 + x86_64) von **libtiff v4.7.2**.

- Quelle: https://gitlab.com/libtiff/libtiff (Release `v4.7.2`,
  Tarball https://download.osgeo.org/libtiff/tiff-4.7.2.tar.gz)
- Lizenz: BSD-artig (Sam Leffler / Silicon Graphics), upstream `LICENSE.md`.
- Verwendung: CCITT G3/G4-Encoding (Fax-Codec) für Bilevel-PDF-Bilder
  (COMPRESSION_ROADMAP.md, Phase 2). Keine Änderungen am Quellcode.
- Build-Konfiguration: Release, BUILD_SHARED_LIBS=OFF, tiff-cxx=OFF,
  alle optionalen Codecs OFF (zlib/zstd/lzma/jpeg/webp/jbig/lerc/
  libdeflate/pixarlog). CCITT-Fax-Codec default-ON. Deployment-Target
  macOS 11.0. Tools/Tests/Docs nicht enthalten (verbleiben unter
  /tmp/opencode).

Original-Lizenztext:

# LibTIFF license

Copyright © 1988-1997 Sam Leffler\
Copyright © 1991-1997 Silicon Graphics, Inc.

Permission to use, copy, modify, distribute, and sell this software and 
its documentation for any purpose is hereby granted without fee, provided
that (i) the above copyright notices and this permission notice appear in
all copies of the software and related documentation, and (ii) the names of
Sam Leffler and Silicon Graphics may not be used in any advertising or
publicity relating to the software without the specific, prior written
permission of Sam Leffler and Silicon Graphics.

THE SOFTWARE IS PROVIDED "AS-IS" AND WITHOUT WARRANTY OF ANY KIND, 
EXPRESS, IMPLIED OR OTHERWISE, INCLUDING WITHOUT LIMITATION, ANY 
WARRANTY OF MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE.  

IN NO EVENT SHALL SAM LEFFLER OR SILICON GRAPHICS BE LIABLE FOR
ANY SPECIAL, INCIDENTAL, INDIRECT OR CONSEQUENTIAL DAMAGES OF ANY KIND,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER OR NOT ADVISED OF THE POSSIBILITY OF DAMAGE, AND ON ANY THEORY OF 
LIABILITY, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE 
OF THIS SOFTWARE.

# Lempel-Ziv & Welch Compression (tif_lzw.c) license
The code of tif_lzw.c is derived from the compress program whose code is
derived from software contributed to Berkeley by James A. Woods,
derived from original work by Spencer Thomas and Joseph Orost.

The original Berkeley copyright notice appears below in its entirety:

Copyright (c) 1985, 1986 The Regents of the University of California.
All rights reserved.

This code is derived from software contributed to Berkeley by
James A. Woods, derived from original work by Spencer Thomas
and Joseph Orost.

Redistribution and use in source and binary forms are permitted
provided that the above copyright notice and this paragraph are
duplicated in all such forms and that any documentation,
advertising materials, and other materials related to such
distribution and use acknowledge that the software was developed
by the University of California, Berkeley.  The name of the
University may not be used to endorse or promote products derived
from this software without specific prior written permission.
THIS SOFTWARE IS PROVIDED ``AS IS'' AND WITHOUT ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED
WARRANTIES OF MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.
