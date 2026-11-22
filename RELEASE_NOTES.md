Faster scan, photo, and MRC compression via Accelerate/SIMD and libdeflate, plus seamless document handoff across Compress, Organize, OCR, and Convert.

## What's new in 1.2.0

### Speed & Engine Optimizations
- **Faster quality gates & MRC segmentation** – SSIM, Sobel edge maps, PSNR, color-reference caching, and Sauvola scan segmentation now run on Apple Accelerate/SIMD and pointer fast paths, cutting CPU work by up to 1.6× on scans and photo-heavy PDFs.
- **libdeflate 1.25 (arm64 NEON)** – Flate stream compression in the native core now uses `libdeflate` for faster stream encoding with identical lossless fidelity.
- **1-page MRC QA & two-stage MozJPEG search** – MRC quality verification writes single-page scratch PDFs instead of re-serializing full documents per page, and large images (≥ 0.5 MP) bisect with fast Robidoux scans before finalizing the winning rung with full Trellis + progressive MozJPEG.

### Cross-Tool Workflow UX
- **Active result flows forward** – after compressing, running OCR, organizing pages, or converting images to PDF, switching tools in the sidebar now carries the **latest processed version** forward instead of silently reverting to the old original.
- **Direct follow-up actions** – jump straight from a compression result to **Organize** or **OCR**, from **OCR** to **Organize** or **Compress**, and from **Organize** to **OCR** (even before saving, while preserving password protection).
- **Session-aware status & no double-compression nag** – tools show a quiet status badge (e.g. *Compressed version*, *Searchable (OCR)*), and Organize recognizes already-compressed documents instead of pushing you to compress them a second time.

## Notes
- macOS 26, Apple silicon.
