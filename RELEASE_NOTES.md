More accurate size estimates for text documents.

## What's new in 1.0.7

- **Fonts are now part of the estimate** – when a document embeds a complete font, compression keeps only the characters it uses. The preview now counts this: a one-page document was shown as 1 % and really saved 64 %; the preview now says 68 %.
- **No more false promises on large documents** – a single tiny uncompressed stream could make a large file look like it had much to gain. A 32 MB document was shown as 65 % and really saved 7 %; the preview now says 7 %.
- Compression results do not change in this version, only the preview before the run.

## Notes

- The estimate is still a prediction. Some unusual files, such as 16-bit images or very small documents, can differ noticeably from the final size.
- macOS 26, Apple silicon.
- Not signed with an Apple Developer ID: on first launch, click “Open Anyway” in System Settings → Privacy & Security.
- Installed versions from 1.0.2 on offer this update themselves.
