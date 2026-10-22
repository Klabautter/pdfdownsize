New app icon, about 9 % faster compression, a more precise quality check in Small, and a fix for images with pre-blended transparency.

## What's new in 1.0.4

- **Liquid Glass app icon** – rebuilt with Icon Composer, with variants for the dark, clear and tinted appearances of macOS 26.
- **Faster** – JPEG encoding now uses the NEON instructions of Apple silicon: about 9 % shorter run times with byte-identical results.
- **More precise check in Small** – large images are checked on a finer grid, so visible blur is no longer accepted. Files stay practically the same size.
- **Fix** – images with pre-blended transparency (a soft mask with “Matte”) are now resized together with their mask; before, viewers could show fringes or errors.

## Notes

- macOS 26, Apple silicon.
- Not signed with an Apple Developer ID: on first launch, click “Open Anyway” in System Settings → Privacy & Security.
- Installed versions from 1.0.2 on offer this update themselves.
