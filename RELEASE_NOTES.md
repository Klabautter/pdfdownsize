Stronger Smart compression for scans and photos, faithful colored ink and signatures, faster large-file handling, and a hardened sandboxed release.

## What's new in 1.1.0

### Compression & Visual Fidelity
- **Stronger Smart compression** – paper scans now use layered MRC with lossless JBIG2/CCITT masks and clean anti-aliasing edge handling (~83–87% typical savings), while photo-heavy and mixed documents search down to 150 DPI behind the viewing-resolution quality anchor.
- **Faithful colored ink & ICC profiles** – colored signatures, stamps, and annotations stay vivid instead of turning gray or black-speckled, and ICC color profiles are preserved across JPEG, Flate, and MRC rewrites.
- **Render verification & honest estimates** – every compression run validates rendered pages before saving, improves Custom-mode size estimates, and clearly explains when a PDF is already well compressed or mostly text.

### Speed, Stability & Security
- **Faster on large PDFs & lower memory** – parallel semantic validation, early compact-image probes, and bounded memory budgets roughly halve peak RAM on huge reports while cutting runtime on multi-hundred-page documents and large map sheets.
- **Crash-isolated validation & fuzz hardening** – PDFKit inspection runs in an isolated helper process with per-page hang protection; malformed streams, nested outlines, password-protected PDFs, and multi-page TIFF imports are handled cleanly.
- **App Sandbox & signed updates** – the app and bundled qpdf helper run inside the macOS App Sandbox, with signed Sparkle update feeds and preserved nested bookmarks on multi-file merges.

### Polish
- **UI & workflow refinements** – consistent focus rings, keyboard shortcuts, clear overwrite/save-as-copy behavior, proper cold-launch file opening from Finder, and complete German/English localization.

## Notes
- macOS 26, Apple silicon.
