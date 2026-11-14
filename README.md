# MediaPull

A native macOS app that collects images and videos from the web into your own folders, at the highest quality available, in normal formats (JPEG, PNG, GIF, MP4).

- **Any web page.** Browse in the built-in browser, with tabs, bookmarks in folders and a history you can clear. Every image, video and stream on the page appears in Extracted Media, including media that only loads as you scroll. Filter by type, format, size, resolution, shape, source or domain, then drag items onto a folder or press ⌘S.
- **PDFs.** Images inside PDFs come out at their original resolution: PDFs you open in the browser, PDFs linked from a page, or PDF files you drop in (⌘O).
- **Filters.** Type chips and a resolution slider are always at hand; More Filters adds format, file size, shape, source and domain.
- **Preview pane.** Select any item or saved file to see it full size, play videos and GIFs, and read its details, including every version found and the name it will be saved under.
- **Quick edits.** Crop (free or fixed ratios), rotate, flip and rename right in the Preview pane, for saved files and for items before you save them (⌘E).
- **Your layout.** Resize every pane, and move or stack them however you like from each pane's arrange button or View > Arrange Panes. By default the browser is on the left, Extracted Media in the middle with the Preview below it, and the Library on the right.
- **Walkthrough.** A short optional tour on first launch; open it again from Settings or Help.
- **Themes.** Settings > Appearance offers Ocean, Sunset, Forest, Lavender, Graphite, Rose Gold, Aurora and a full-spectrum theme, or your system accent colour.
- **Original sizes.** For many sites (The New York Times, WordPress, X, Pinterest, Shopify, Cloudinary, imgix, Wikimedia, Reddit) and for thumbnail scripts, image proxies and lightbox links on any site, MediaPull finds the largest rendition instead of the size shown on the page. On around 300 sites, Scan with Site Extractor returns the original files.
- **Instagram.** Sign in once in the browser pane, then Pull Account (⇧⌘P) to save posts, carousels, Reels, the profile picture, highlights and current stories. Later pulls only fetch new posts.
- **Normal formats.** WebP, AVIF, HEIC and JPEG XL become maximum-quality JPEG or lossless PNG; SVG becomes PNG; VP9 and AV1 video become HEVC MP4 when needed. The Converter (⇧⌘K) does the same for files you already have.
- **Archive layout.** By default each saved file gets a small JSON file next to it with its caption, date, source and post grouping, in the format gallery-dl uses, so media-library and archiving tools can import the folders with their details.
- **Read-only.** MediaPull never uploads files and never likes, follows or posts. Every request it makes is listed in Settings > Advanced.

The full specification is in [docs/SPEC.md](docs/SPEC.md).

## Install

Requirements: macOS 26 or later on Apple silicon, Xcode 27.

```bash
./scripts/install-app.sh
```

This downloads and verifies the bundled engines (a standalone Python with gallery-dl and yt-dlp, about 47 MB), builds a minimal ffmpeg the first time (a few minutes), builds the app and installs it in `~/Applications/MediaPull.app`.

To work on it in Xcode, run `./scripts/fetch-engines.sh` and `./scripts/build-ffmpeg.sh` once, then open `MediaPull.xcodeproj`.

## Check

```bash
./scripts/check.sh
```

Runs the lint, the Swift and engine tests, the bridge tests, an iOS Simulator build of the shared package and an app build.

An end-to-end run on a real page (saves into a folder you choose and writes a report):

```bash
~/Applications/MediaPull.app/Contents/MacOS/MediaPull --selftest-url https://www.nytimes.com/international/ --selftest-out /tmp/mediapull-test
```

## Notes

- Instagram requires a signed-in session to list an account's posts. Automated collection may breach Instagram's terms; MediaPull paces its requests and pauses when Instagram asks for a check.
- Build products and the engine cache live in `~/Library/Caches/MediaPullBuild`, outside this iCloud-synced folder.
- Bundled components keep their licences (gallery-dl GPL-2.0, yt-dlp Unlicense, Python PSF, ffmpeg LGPL-2.1); see Settings > Engines > Show Licences and Sources.
