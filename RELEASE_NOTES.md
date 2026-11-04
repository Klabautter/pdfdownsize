Much better compression for scans and unusual PDF formats, and clearer differences between Small, Smart and Quality.

## What's new in 1.0.5

- **Black-and-white scans** – Small now reduces 300 DPI scans to about 200 DPI. A 47-page scan went from 2.9 MB to 1.5 MB in Small, and to 2.2 MB in Smart and Quality, where it previously stayed almost unchanged.
- **Oversized scans** – pages that are physically larger than A4, such as phone or paper scans stored at 72 ppi, are now judged like normal documents and shrink properly.
- **More image formats** – CMYK JPEGs, indexed images, 16-bit images, JPEG 2000 without a declared color space, Lab, Separation and DeviceN colors are now compressed per mode.
- **Images in more places** – images inside tiling patterns, annotations and mask groups are now included. Soft masks are resized together with their image.
- **Very large images** – images above 36 megapixels now shrink according to the selected mode.
- **Modes that really differ** – Small and Smart now also work on images that are already within their resolution target, so many files that came out the same size in every mode no longer do.

## Fixes

- Fax-compressed (CCITT) images without a declared row count can now be read.
- Content stream cleanup no longer splits malformed numbers, which could make a file fail validation.
- Strongly noisy images, which could stay very large in Small, now shrink as well.
- In Quality, JPEG scans within the resolution target keep their original pixels and are only repacked losslessly, unless you set a target size.

## Notes

- Files with very little to remove, such as plain text documents, may still come out the same size in every mode. In rare cases of strong image noise, Small can end up slightly larger than Smart.
- macOS 26, Apple silicon.
- Not signed with an Apple Developer ID: on first launch, click “Open Anyway” in System Settings → Privacy & Security.
- Installed versions from 1.0.2 on offer this update themselves.
