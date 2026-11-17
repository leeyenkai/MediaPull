# MediaPull Specification

Version 1.7 (1.6 implemented; 1.7 adds Icon, List and Column views), 2026-11-17

This document is the source of truth for MediaPull. Code follows the spec; when a request or an implementation detail conflicts with it, the conflict is raised and the spec is updated first.

Conventions:

- **R-nnn** is a requirement. "Must" is mandatory for the milestone that owns it; "should" is expected unless a recorded decision says otherwise. The first digit(s) follow the section number (R-501 lives in section 5).
- **D-nn** is a recorded decision (section 27). Decisions can be changed, but only by editing this spec.
- "Verify in M0" marks a detail that depends on third-party behaviour and must be confirmed by the engine spike before it is built on.

## Implementation status (version 1.7)

MediaPull is a personal tool for archiving and collecting media, not a public release. The app, its engines and the read-only contract are implemented. Some supporting pieces described here were deliberately not built for personal use: the `mediapull-test://` fixture pages and the extraction tests that would use them (section 25), `scripts/perf-budgets.json` and CI enforcement (section 22, budgets were measured by hand instead), `docs/PRIVACY.md`, `scripts/sign-helpers.sh`, Developer ID signing and notarization (section 26; the app is signed for this Mac only).

Verification so far:

- **Automated** (`scripts/check.sh`): module-boundary and read-only lint, Swift tests (sidecar contract, forbidden names, CDN rules and image proxies, sniffing, request policy, ingestor, filters, conversion, save pipeline, pane arrangement, bookmarks and history, hostile inputs, duplicate detection, video frames and trimming, the real bundled engine and its event stream), 8 Python tests of the egress guard, an iOS Simulator build of the package and an app build.
- **End to end** (`MediaPull --selftest-url <url> --selftest-out <folder>`, section 25): on the New York Times international front page, 204 items were found (135 of them only while scrolling) and all 190 shown items were saved (185 saved, 5 recognised as duplicates), with images at the newspaper's largest rendition (2048 px), WebP converted to JPEG or PNG, SVG converted to PNG, and videos saved as H.264 MP4. A Wikipedia page was also scanned with the site extractor (48 originals).
- **Version 1.6, verified end to end** (`--selftest-analyse`): media analysis (section 36), Library sort, filter and search (section 37), the Organise section (section 38) and faces and people (section 39), decisions D-57 to D-70. On 96 test files (60 photos, 36 faces of three people): all analysed in 5.8 s with no network sockets opened, the three people found with 12 photos each and two named from their folders, a second scan analysing nothing, Sort by Subject previewed and run into 13 folders, and undo restoring every file exactly (checksums). The save folder (D-70) and the opt-in Organise target (D-68) are checked by the same run: a folder outside the library becomes the save folder without joining the library, Organise opens in place, and a new source keeps the chosen target. The app is 696 MB with the models.
- **gallery-dl sites** (R-1111b, D-71, D-72): every bundled site was run on gallery-dl's own test address through the bridge; 196 of 372 listed items with no sign-in and none was blocked by the egress guard (`docs/spikes/gallery-dl-sites.md`). `--selftest-galleries` downloaded through the whole app from 21 sites (Bluesky, Imgur, ArtStation, Mastodon, Behance, VSCO, Pinterest, Patreon, VK, Civitai and others). Twitter needs the browser signed in; Reddit needs the person's own API key; Pixiv's app sign-in is not built.
- **Views (R-1708 to R-1711, D-76), verified end to end** (`--selftest-views`): the Library as a list (a subfolder row that opens in place to show its 20 files, a header click changing the sort) and as columns (opening at the selected folder; choosing a file keeps its folder as the pane's folder, choosing a library folder opens it), Extracted Media as a list (68 rows for 68 items, Column view refused), and the Organise Source as a list and as columns. Dragging between views and Quick Look in them still need a person.
- **Version 1.5 additions, verified end to end**: the Instagram content choices (section 11.5), date windows and folders by type; saving videos from video sites (section 35; `--selftest-video-download`: a YouTube video's 47 formats listed, saved as 360p H.264 MP4 with metadata in 7 s and as 128 kbps AAC M4A without metadata in 2 s).
- **Version 1.4 additions, verified end to end**: duplicate detection in the Library (section 33; `--selftest-duplicates` found an identical copy in a subfolder and a resized, re-compressed copy, and kept colour versions of one product photo apart) and video frame grabs and trimming (section 34; `--selftest-video`: a 640×360 frame at 2.5 s saved as PNG, a 1–3 s selection saved as a 2.00 s copy without re-encoding, metadata files updated).
- **Version 1.3 additions, verified end to end**: browser tabs, bookmarks in renamable folders, history with clearing, the walkthrough, the reworked icon and the narrow-pane fixes (`--selftest-browser`: two tabs, This Page 2 / 47 / 49 items, folder rename, history cleared, ⌘W bound to Close Tab). Measured: window ready 0.9 s after launch, idle CPU 0.17 % over 30 s, app memory peak 138–183 MB on the hard pages.
- **Version 1.2 additions, verified end to end**: the Preview pane and movable panes (R-701a, section 10.3), themes (R-2010), the Liquid Glass app icon (section 26.1), image-proxy and lightbox originals (Appendix D), and fixes from a code review (D-39 to D-44). Hard pages tested: a product catalogue with script-resized thumbnails (55 items; colour-variant photos now saved at full size instead of 400 px thumbnails) and a large news front page (598 items, 495 of them only while scrolling, 519 saved in 12 s, app memory peak about 150 MB).
- **Version 1.1 additions, verified end to end**: images inside a hosted PDF (the arXiv paper 2010.11929: 298 embedded images extracted in about 2 seconds and saved), the image editor, and the quick filter row with the resolution slider.
- **Not yet exercised by a person**: drag and drop, Quick Look, the trim bar and frame stepping in the video editor, and Instagram pulls with a signed-in account.

Decisions that changed during implementation are D-13 and D-24 to D-56 (and D-68, D-72 in 1.6) in section 27. Sections 31 (PDFs) and 32 (editing) and R-1006a (resolution slider) were added in version 1.1; the Preview pane, pane arrangement and themes in version 1.2.

---

## Contents

1. Overview and principles
2. Scope
3. Platform, toolchain and distribution
4. Architecture
5. Read-only and privacy contract
6. Data model and persistence
7. Window and layout
8. Browser pane
9. Web extraction
10. Extracted media pane
11. Instagram
12. Site extractor scans
13. Engines (bundled helpers)
14. Save pipeline
15. Output layouts
16. Format conversion
17. Library pane
18. Drag and drop
19. Jobs and activity
20. Settings
21. Menus and keyboard shortcuts
22. Performance budgets
23. Errors and edge cases
24. Accessibility and localisation
25. Testing
26. Build and release
27. Decisions
28. Milestones
29. Risks
30. Open questions
31. Images inside PDFs
32. Editing
33. Duplicates in the Library
34. Video frames and trimming
35. Saving videos from video sites
36. Media analysis
37. Library sort, filter and search
38. Organise
39. Faces and people

Appendices: A. Bridge protocol, B. Extraction message schema, C. Sidecar schema and examples, D. CDN original-size rules, E. Engine configuration template

---

## 1. Overview and principles

### 1.1 What MediaPull is

MediaPull is a lightweight native macOS app for collecting media from the web into local folders.

- **Web pages.** The user browses any public page in an embedded browser pane. MediaPull finds every image, video and media stream on the page, including media that only loads as the user scrolls or interacts, and lists it live in an Extracted Media pane. The user filters by type, format, resolution, file size and more, then drags or saves the chosen items into folders.
- **Instagram.** The user enters a public account (or a post or Reel link) and MediaPull pulls posts, carousels, videos, Reels, the HD profile picture, highlights and current stories at the highest quality Instagram serves, into a folder per account.
- **Supported sites.** On pages from roughly 300 sites with a dedicated extractor (Pinterest, X, Reddit, Tumblr, Flickr and others), a site extractor scan returns original-resolution files.
- **Normal formats.** Everything is saved as JPEG, PNG, GIF or MP4 (MOV kept when served as MOV). WebP, AVIF and HEIC are converted at maximum quality. A standalone converter does the same for files already on disk.
- **Metadata archive layout.** One save layout writes a gallery-dl-compatible metadata archive: each media file has a JSON sidecar describing where it came from. Media-library and archiving tools that understand gallery-dl folders can import these folders directly, with captions, dates and carousel grouping intact.

### 1.2 Principles

- **P1 Read-only.** MediaPull reads from the web and writes only to the local disk. No file or media bytes ever leave the Mac, and MediaPull never performs any action on any account (no posting, liking, following, commenting, marking stories as seen). This is enforced in code and proved by tests (section 5).
- **P2 Highest quality.** For every item MediaPull chooses the largest variant actually available and never re-compresses when it does not have to.
- **P3 Normal formats.** Saved files open everywhere on a Mac without extra software.
- **P4 Local-first and private.** No accounts, no servers, no analytics, no crash upload. The only background network activity MediaPull initiates by itself is the optional weekly engine update check (section 13.6).
- **P5 Lightweight.** Small resident footprint, near-zero idle CPU, no helper processes running when no job is running.
- **P6 Honest.** The UI says plainly when something is lower quality than requested, protected, private, rate-limited or blocked, and why.

### 1.3 Glossary

| Term | Meaning |
|---|---|
| Page session | The extraction state for one window's browser pane: every media item found since the session was last cleared. |
| Media item | One logical piece of media (one photo, one video, one stream), possibly available as several variants. |
| Variant | One concrete URL for a media item (a srcset candidate, a CDN size, an Instagram candidate, a DASH representation). |
| Best variant | The variant MediaPull would save, chosen by the ranking in section 9.6. |
| Library root | A folder on disk the user registered as a save destination. The Library pane shows its tree. |
| Layout | How files are written into a folder: **Plain** (media only) or **Archive** (media plus JSON sidecar). |
| Sidecar | `<file>.<ext>.json` next to a media file, in the format defined in section 15 and Appendix C. |
| Engine | A bundled third-party extractor: gallery-dl (Instagram, site extractors) or yt-dlp (streams, DASH video). |
| Bridge | MediaPull's own small Python program that drives the engines and talks to the app over a JSON Lines protocol (Appendix A). |
| Scan | Listing media without saving it. |
| Pull | Scanning and saving an Instagram account into a library folder in one job. |
| Job | A unit of background work shown in the Activity panel (save, pull, scan, stream download, convert, engine update). |
| Checkpoint | Any response from a site that requires the user to act in the browser (Instagram challenge, login redirect, rate-limit block). |
| NetworkGate | The single component through which all of MediaPull's own Swift network requests pass (section 5). |

---

## 2. Scope

### 2.1 In version 1

- Embedded browser pane with persistent sign-in (for Instagram and any other site the user chooses to sign in to).
- Live extraction of images, animated images, videos, audio and streams from any page, including lazy-loaded and dynamically inserted media, iframes and open shadow roots.
- Extracted Media pane with filters, sorting and multi-select, and a Preview pane with details and editing.
- Instagram: posts, carousels, videos, Reels, HD profile picture, highlights, current stories; single post and Reel links; incremental sync.
- Site extractor scans for pages that gallery-dl supports.
- HLS and DASH stream download (non-DRM).
- Save pipeline with Plain and Archive layouts, deduplication, naming templates.
- Format conversion on save and a standalone converter for local files.
- Library pane with folder management and drag and drop to and from Finder.
- Activity panel with pause, resume, cancel and retry.
- Engine update mechanism for gallery-dl and yt-dlp.

### 2.2 Later (not version 1)

- Several signed-in Instagram identities at once (D-08).
- Scheduled background syncs.
- yt-dlp page scans for video sites (open question Q-03).
- iPad and iPhone versions (section 4.6).

### 2.3 Non-goals

- Downloading DRM-protected or encrypted media of any kind (D-19).
- Uploading, posting, liking, following, commenting, messaging or any other write action on any service.
- Mac App Store distribution (D-02).
- Bypassing logins, paywalls, private accounts or CAPTCHAs. Private accounts are only accessible when the signed-in user already follows them, exactly as in a browser.
- A general-purpose web browser. The browser pane exists to find media.

### 2.4 Terms of service and account risk

**R-201** The first-run screen and the Instagram sign-in banner must state plainly that automated collection from Instagram may breach Instagram's terms, that the signed-in account bears any rate limits, checkpoints or restrictions Instagram applies, and that the user is responsible for respecting the rights of the people whose media they save.

**R-202** Defaults must be conservative: Gentle pacing (section 11.8), one Instagram job at a time, no automatic retries after a checkpoint.

---

## 3. Platform, toolchain and distribution

**R-301** macOS 26 or later, Apple silicon only (arm64). No Intel slice.

**R-302** Swift 6 language mode with approachable concurrency. The app target uses MainActor default isolation; package targets are nonisolated by default and mark CPU-heavy functions `@concurrent`.

**R-303** SwiftUI for all UI. AppKit only in the app target, never in the MediaPullKit modules; views and controllers built on it live in the app's `Platform/` folder (section 4.3), and other app files use it only for small things such as the pasteboard, menus and windows.

**R-304** No third-party Swift packages. Third-party code is limited to the bundled engines and their runtime (section 13), each pinned to an exact version with a recorded SHA-256 by the build scripts.

**R-305** *(Amended by D-77: For this personal tool the disk image is signed with an Apple Development identity; Developer ID signing and notarization apply only to a public release.)* Distribution is direct: Developer ID signed, hardened runtime, notarized, shipped as a DMG (D-02). The app is not sandboxed (D-03) so that it can run its bundled helper processes and write to any folder the user chooses. File access is still modelled through bookmarks (section 17) so that sandboxing remains possible later.

**R-306** *(Amended by D-77: Applies to a public release only (see R-305).)* Every Mach-O file in the bundle (app, Python interpreter, Python extension modules, ffmpeg, ffprobe, dylibs) is signed individually, inside out, with the hardened runtime and a secure timestamp. Helpers get only the entitlements M0 proves they need (expected: none).

**R-307** The bundle contains the licence texts of every bundled component and a plain-language notice of where to obtain their source code (section 26).

**R-308** *(Amended by D-77: App Transport Security allows arbitrary loads, because http media (D-21) can come from any host; every request still passes the gate (GET and HEAD only).)* App Transport Security stays on for the app's own requests except for plain-http media downloads (D-21). The browser pane follows WebKit's normal rules.

---

## 4. Architecture

### 4.1 Targets and modules

The repository contains one Xcode project with a macOS app target `MediaPull` (synchronized folder groups) and a local Swift package `MediaPullKit` that builds for macOS 26 and iOS 26.

| Module | Depends on | Responsibility | Frameworks allowed |
|---|---|---|---|
| `MediaPullCore` | none | Value types, URL normalization, CDN rules, variant ranking, filter predicates, name templates, sidecar schema and encoder, reserved-name rules, Instagram shortcode helpers, storage protocols | Foundation |
| `MediaPullNet` | Core | `NetworkGate`, request policy, cookie snapshots, host limiter, download queue, prober, egress log | Foundation, CryptoKit |
| `MediaPullMedia` | Core | Magic-byte sniffing, ImageIO conversion, animated image conversion, local media probing, thumbnail decoding, AVFoundation helpers | ImageIO, AVFoundation, UniformTypeIdentifiers, CoreGraphics |
| `MediaPullEngines` | Core, Net, Media | `MediaSourceEngine` protocol, bridge client (process launch, JSON Lines decoding), engine manager (versions, updates, smoke tests), cookie file export | Foundation |
| `MediaPullLibrary` | Core, Net, Media, Engines | Save pipeline, layouts, deduplication index, atomic writer, location checks, converter jobs | Foundation |
| `MediaPullStore` | Core | SwiftData models and `@ModelActor` repositories implementing Core's storage protocols | SwiftData |
| `MediaPullBrowser` | Core, Net | WKWebView configuration factory, injected scripts (package resources), message ingestion, cookie bridge, checkpoint detection, content rules | WebKit |
| `MediaPullAnalysis` | Core, Media | On-device analysis (section 36): content labels, recognised text, image and text embeddings, faces and face embeddings, technical facts, dominant colour, offline place names, similarity search | Vision, CoreML, Accelerate, ImageIO, CoreGraphics |

The app target holds `App/` (entry point, window scenes, commands), `Features/` (Browser, Extracted, Library, Organise, People, Instagram, Jobs, Converter, Settings, Onboarding), `Platform/` (macOS-only views and bridges) and `Resources/`.

### 4.2 Dependency rule

**R-401** Dependencies point only in the direction of the table. SwiftData appears only in `MediaPullStore`, WebKit only in `MediaPullBrowser` and the browser pane's own files in the app (`Features/Browser`, `Platform/ReadOnlyWebView`), with the rest of the app reaching cookies and website data through `MediaPullBrowser`, `URLSession` and `URLRequest` only in `MediaPullNet`, `Process` only in `MediaPullEngines`, Vision and Core ML only in `MediaPullAnalysis`. No module uses Apple's geocoder (`CLGeocoder`), MapKit search, Vision asset downloads (`downloadAssets`) or Core ML model collections (`MLModelCollection`), all of which reach the network (D-59). A lint script enforces this (section 25).

### 4.3 Platform layer

macOS-only code lives in the app's `Platform/` folder:

- `ReadOnlyWebView`: a `WKWebView` subclass that refuses file drags, plus its `NSViewRepresentable`.
- `ThreePaneSplit`: the collapsible three-pane split.
- `FilePromiseDragSource`: `NSFilePromiseProvider` support for dragging unsaved items to Finder.
- `QuickLookPanel`: `QLPreviewPanel` bridge.
- `FolderPicker`: `NSOpenPanel` plus bookmark creation.
- `FinderReveal`: reveal and open in Finder.
- `GridCollectionView`: an `NSCollectionView` fallback for the media grid, used only if the SwiftUI grid misses the budgets in section 22.

### 4.4 Concurrency

| Component | Kind | Role |
|---|---|---|
| `NetworkGate` | actor | Owns the app's URLSessions; checks every request against the policy; records the egress log. |
| `HostLimiter` | actor | Per-host concurrency (default 6 per host, as browsers use, 2 for Instagram's CDN, 16 total). |
| `DownloadQueue` | actor | Priorities save > preview > probe; pause and resume with resume data; retries 5xx and timeouts with backoff; never retries 4xx except to refresh an expired signed URL. Progress as `AsyncStream`. |
| `ExtractionIngestor` | actor, one per page session | Decodes script messages off the main thread, normalizes, merges, ranks, filters; publishes snapshots at most 4 times per second. |
| `Prober` | actor | Range-GET probing of dimensions, byte size and duration for items that are visible or that an active filter needs. |
| `ThumbnailService` | actor | Coalesces requests, at most 4 decodes at once, downsampled decoding, `NSCache` with a byte budget. |
| `EngineRunner` | actor | Launches bridge processes, streams their events, enforces one Instagram job at a time, handles cancellation. |
| `InstagramGate` | actor | Shared state for all Instagram work: ready, paused, cooldown(until), blocked(checkpoint URL). |
| Repositories | `@ModelActor` | SwiftData access. Engines and the pipeline see only Core protocols, so package tests never need a model container. |

**R-402** The main actor never decodes images, parses JSON from the page or the bridge, hashes files or converts media.

### 4.5 Process model

- The app process (UI, Swift networking, save pipeline).
- WebKit's own WebContent and networking processes for the browser pane.
- Bridge processes (bundled Python), started per engine job and exited when the job ends. At most one Instagram job and two other engine jobs run at once.
- ffmpeg and ffprobe, started by the engines or by the converter for single operations.

**R-403** When no job is running, no bridge, ffmpeg or ffprobe process exists.

### 4.6 Future iPad and iPhone port

The package builds for iOS from the first milestone so the port stays cheap. The bundled Python engines cannot run on iOS, so the `MediaSourceEngine` protocol is the seam where a native Instagram engine would be added. Web extraction, the save pipeline, layouts and conversion are already platform-neutral.

---

## 5. Read-only and privacy contract

### 5.1 The contract

1. No file or media bytes from the Mac are ever sent anywhere. This protects the library and every other file on the Mac.
2. Neither MediaPull's own code nor the engines perform any write action on any account or service.
3. MediaPull sends no telemetry, analytics or crash reports.
4. The browser pane is the one honest exception to "MediaPull sends nothing": pages loaded in it run their own code and send what any browser sends (sign-in details typed into a login form, a search, cookies, a page's own requests). The pane still cannot upload files from the Mac (5.4).

### 5.2 Swift network gate

**R-501** All network requests made by MediaPull's Swift code go through `NetworkGate`. The request type (`GatedRequest`) has exactly two factories, `.get(url, purpose, context)` and `.head(url, purpose, context)`. There is no way to construct a request with another method or with a body.

**R-502** The request policy is a pure function, tested exhaustively:

- Methods: GET and HEAD only.
- Schemes: https; http only for GET and HEAD of media (D-21). `file:`, `data:` and custom schemes are never sent through the gate.
- No request body, no body stream, no upload task, no multipart or octet-stream content type.
- Header allowlist: `Accept`, `Accept-Language`, `Range`, `Referer`, `Cookie`, `User-Agent`, `If-None-Match`, `If-Modified-Since`. Never `Authorization`.
- Purposes: thumbnail, preview, probe, rewrite-check, save, engine-update. The purpose is recorded with every request.

**R-503** Every request is appended to an in-memory egress log (ring buffer of 2,000 entries: time, method, host, path, purpose, status, bytes received). Settings > Advanced shows it as "Network activity". It is never written anywhere unless the user exports diagnostics.

**R-504** *(Amended by D-77: There is no custom resource loader: media is downloaded through the gate to a cache file before AVFoundation opens it.)* Remote media is never handed directly to a framework that would fetch it outside the gate. `AsyncImage`, `AVURLAsset(url:)` with a remote URL, `Data(contentsOf:)` with a remote URL, `NSImage(contentsOf:)` with a remote URL and Quick Look on remote URLs are forbidden. Video preview uses an `AVAssetResourceLoaderDelegate` with a custom scheme that fetches ranges through the gate. Quick Look previews a file downloaded to the cache first.

### 5.3 Engine egress guard

**R-505** The bridge installs an egress guard before importing any engine code. It wraps the HTTP entry points used by gallery-dl (its `requests` sessions) and yt-dlp (its `urlopen`) and enforces:

- GET and HEAD to any http or https URL, without a request body.
- POST only to Instagram's GraphQL read endpoints (`/graphql/query`, `/api/graphql`) and to the read-only Instagram endpoints the pinned gallery-dl version is shown to need in M0. The request's operation name (`fb_api_req_friendly_name`) or query must end in `Query` (optionally followed by a lower-case suffix, as in `…Query_connection`) and must not contain any of: Mutation, Like, Follow, Comment, Seen, Upload, Create, Delete, Edit, Save, Mark, Share, Send, Report, Block.
- POST to the read-only endpoints other sites need (D-72): listings, searches, file links and anonymous or public-client tokens, each listed by host and path in `READ_POSTS` from an audit of every POST the bundled gallery-dl can make (`docs/spikes/gallery-dl-post-audit.md`). Bodies are checked per endpoint: GraphQL must be a query, token requests must be the public or guest kind, and nothing carrying a password or refresh token is sent. Sign-ins, favourites, watching, likes, rating settings and quota resets stay blocked, as does the one GET that thanks a post.
- No multipart or octet-stream bodies, no bodies over 16 KB, no PUT, PATCH or DELETE.

Any blocked request raises inside the engine and is reported as a `policy_violation` event (Appendix A). The job stops.

**R-506** Engines run with a configuration generated by MediaPull for each job (Appendix E). User and global configuration files for gallery-dl and yt-dlp are never read. The bridge never enables `exec`-type post-processors, never uses cookies read from the user's other browsers (`cookies-from-browser` is never set), and passes only cookies exported from MediaPull's own browser pane for the domains the job targets (section 11.3). gallery-dl's cache (which holds Instagram tokens) and yt-dlp's cache are kept in memory, so nothing about a session outlives the job.

**R-507** The bundled ffmpeg is built with networking disabled. It only reads and writes local files.

### 5.4 Browser pane

**R-508** The browser pane cannot upload files:

- The web view's UI delegate does not implement the file open panel method, so `<input type="file">` does nothing.
- `ReadOnlyWebView` rejects drags that carry files or file promises; text and URLs are still accepted.
- A capture-phase script injected at document start drops paste events that carry files.
- A content rule list blocks well-known upload hosts and endpoints (for example Instagram's `rupload` hosts).

**R-509** MediaPull does not block a site's own analytics or telemetry inside the pane (D-17), because doing so can break sign-in.

### 5.5 Privacy

**R-510** No third-party SDKs, analytics, crash reporters or update frameworks.

**R-511** Logs go to the unified log (`os.Logger`, subsystem `app.mediapull`, privacy-redacted by default) and to a rolling local file in `~/Library/Logs/MediaPull/` capped at 10 MB. Cookie values, session identifiers and full signed URLs are always redacted. "Export diagnostics" writes a zip to a location the user picks; nothing is ever sent.

**R-512** Cookie files written for engines live in a private temporary folder (mode 0700), are created with mode 0600, and are deleted when the job ends, including after a crash (cleaned at next launch).

**R-513** Media analysis (section 36) runs entirely on the Mac. Models are bundled (D-58); no request ever carries media, analysis results or face data; the `--selftest-analyse` run checks that the process opens no network sockets while it analyses.

---

## 6. Data model and persistence

### 6.1 Core value types (sketch)

```swift
struct MediaItem: Identifiable, Sendable {
    let id: AssetKey                       // identity shared by all variants of one asset
    var kind: MediaKind                    // image, animatedImage, video, audio, stream, vector
    var variants: [MediaVariant]
    var best: VariantID?
    var source: MediaSource
    var firstSeen: Date
    var discoveryIndex: Int
    var alt: String?
    var poster: URL?
    var flags: Set<MediaFlag>              // tiny, icon, duplicate, protected, blobOnly, insecure, saved
}

struct MediaVariant: Identifiable, Hashable, Sendable {
    let id: VariantID                      // hash of the normalized URL
    var url: URL
    var format: MediaFormat?               // sniffed > Content-Type > extension
    var pixelSize: PixelSize?
    var byteCount: Int64?
    var duration: Double?
    var codecs: [String]
    var origin: VariantOrigin              // img, srcset, picture, cssBackground, video, audio, poster,
                                           // meta, link, lazyAttribute, network, cdnRewrite(rule),
                                           // engine(category), instagramCandidate, instagramProgressive,
                                           // instagramDash, dataURI
    var expiresAt: Date?                   // signed URL expiry where known
    var check: VerifyState                 // unverified, verified, failed(status)
}

enum MediaSource: Sendable {
    case web(WebContext)                   // page URL, frame origin, page title, discovered at
    case instagram(InstagramContext)       // username, owner username, shortcode, post id, media id,
                                           // num, count, taken at, caption, subcategory, product type,
                                           // highlight title
    case siteExtractor(EngineContext)      // engine category, subcategory, username, post id, title, date
}

struct SaveRequest: Sendable {
    var items: [MediaItem.ID]
    var destination: FolderRef             // bookmark-backed folder
    var layout: Layout                     // plain, archive
    var naming: NameTemplate
    var conflict: ConflictPolicy           // suffix, skip
    var conversion: ConversionPolicy
}
```

Instagram identifiers are always stored as strings (they exceed 2^53).

### 6.2 Persistence matrix

| Where | What |
|---|---|
| SwiftData (versioned schema from the first release) | `LibraryRoot` (bookmark, display name, default layout, created). `InstagramAccount` (user id, username, last options, newest saved post date, resume cursor, last pull result). `ArchiveEntry` (unique key such as `ig:<media id>` or `web:<sha256>`, library root, relative path, sha256, saved at). `FileFingerprint` (library root, relative path, size, modification date, sha256). `JobRecord` (summary of finished jobs, capped at 500). |
| In memory | Page sessions and their items, probe results (LRU), thumbnails, current filter state. |
| `UserDefaults` / `@AppStorage` | Preferences (section 20), last-used filters and presets, pane widths. |
| Application Support `~/Library/Application Support/MediaPull/` | `Engines/` (updated engine versions and `active.json`), `EngineHome/` (empty home folder for engine processes), `Staging/` (per-job download staging, cleaned at launch). |
| Application Support `Analysis/` and `Organise/` | `Analysis.store` (SwiftData, separate from the main store) and memory-mapped vector files (section 36; face data in its own files, excluded from backups, D-61); Organise journals for undo (R-3806). |
| Caches `~/Library/Caches/MediaPull/` | URL cache (256 MB disk), `Partial/` downloads (cleared at launch), preview files. |
| Library roots | Media files and sidecars only. **R-601** MediaPull never writes hidden state files, databases or folders inside a library root, including analysis results, face data and journals (D-60, D-63). |

---

## 7. Window and layout

**R-701** The main window has five resizable, collapsible panes: **Browser**, **Extracted Media**, **Preview**, **Library** and **Downloads** (below the Browser by default, section 11.11). By default the Browser is on the left, Extracted Media in the middle with the Preview below it, and the Library on the right, at roughly 42 / 36 / 22 of the width and 58 / 42 of the middle column's height. Minimum widths 360, 280, 240 and 200 points. Minimum window size 1100 × 700. These panes form the **Collect** section; the **Organise** section (section 38) shares the window (D-62).

**R-701a** Panes can be arranged freely as columns, each holding one pane or a stack of panes. Each pane's title bar has an arrange menu (also under View > Arrange Panes, which covers the Browser) with Move Left and Move Right (a stacked pane moves out into its own column), Stack in Column on the Left or Right, Move Up and Move Down within a stack, and Hide. Presets: Standard, Preview in Its Own Column, Preview Below Browser, Preview Below Library, Mirrored. The arrangement is shared by all windows and kept between launches; divider positions are kept per arrangement, and Reset Pane Sizes restores the defaults. Moving panes never reloads the page in the Browser.

**R-702** ⌥⌘1, ⌥⌘2 and ⌥⌘3 toggle the Browser, Extracted and Library panes and ⌘I toggles the Preview. At least one pane stays visible. ⌃⌘1 and ⌃⌘2 switch to the Collect and Organise sections.

**R-703** ⌘N opens a new window with its own browser pane and page session. All windows share the website data store, the library roots and the job queue.

**R-704** The window uses the compact unified toolbar: the section tabs Collect · Organise (D-62), then the window title, then at the right edge, in Collect, Downloads (shows or hides the Downloads pane) and Activity (a popover listing every job, with a badge for running ones); in Organise, Undo and Activity. Pausing extraction is a button in the Extracted Media header. The Downloads pane appears when asked for and stays until closed. Both sections use the same pane headers, arrange menus and title bar (D-69). The title bar has no capsule backgrounds: tabs and buttons are drawn like the browser's tab chips, with the same 6-point corners as the address and search fields, and the Organise pane's Sort / People / History switch uses the same tabs. Everything that belongs to browsing lives in the Browser pane itself (R-802), so it moves with the pane.

**R-705** A bottom status bar in the Extracted pane shows item counts (found, shown after filters, selected), the total size of the selection where known, the save folder (a menu of library folders, recent folders and "Other Folder…"; D-70) and the Save button.

### 7.1 First run

A sheet in one window:

1. What MediaPull does, the read-only contract in one paragraph, and the terms-of-service note (R-201), with "Take the Tour" and "Skip Tour".
2. The optional tour (section 7.2).
3. Choose the default library root (default `~/Pictures/MediaPull`, created on confirmation) and the default layout (Archive, explained as "keeps captions, dates and post grouping in small JSON files next to each item").
4. Optional: sign in to Instagram now (opens the sign-in page in the browser pane).

### 7.2 Walkthrough

**R-710** The tour has eight pages, each with a drawing of the window that picks out the pane it describes: browsing (tabs, bookmarks, history, handles), Extracted Media (lazy loading, Scroll to End, chips and the resolution slider), the Preview pane and editing, saving into Library folders, Instagram pulls, arranging panes and themes, searching and organising (sections 37 and 38), and the read-only contract. It can be skipped at any page and reopened at any time from Settings > General > Show Walkthrough or Help > MediaPull Walkthrough (the tour alone, without the setup steps).

---

## 8. Browser pane

**R-801** The browser pane is a `WKWebView` (`ReadOnlyWebView`) using one persistent `WKWebsiteDataStore` shared by all windows. Cookies, local storage and sign-ins persist across launches.

**R-802** The Browser pane has, from the top: a navigation bar with back, forward, reload or stop, the address field (security or Instagram icon, load progress, bookmark star), the Bookmarks and History button and the pane's arrange menu; then the tab strip (R-805a). A long address fades out before the star instead of running into it, and shows in full while it is edited. ⌘L focuses the address field (showing the Browser pane if it was hidden). ⌘[ and ⌘] go back and forward.

**R-802a** Pages can be zoomed: ⌘+ and ⌘- step through 50 % to 300 %, ⌘0 returns to actual size, and a trackpad pinch magnifies.

**R-803** *(Amended by D-77: An @name, story or highlight link typed in the address field opens the Downloads pane (D-69), which offers the actions; the field itself offers none.)* The address field accepts:

| Input | Behaviour |
|---|---|
| A URL, or text that parses as a host (`example.com/path`) | Navigate; `https://` is assumed. |
| `@name` | Offers "Pull @name…" and "Scan @name"; Return opens the profile in the pane. |
| `instagram.com/<name>` or `/<name>/reels` | Navigate; the Extracted pane header offers "Pull @name…". |
| `instagram.com/p/<code>`, `/reel/<code>`, `/reels/<code>`, `/tv/<code>` | Navigate; offers "Save This Post". |
| `instagram.com/stories/<name>/…`, `/stories/highlights/<id>/` | Navigate; offers "Save Stories" or "Save Highlight". |
| Any other text | Shows "Not a web address" (D-18: no search engine). |

Tracking parameters such as `igsh`, `utm_*` and `fbclid` are removed from Instagram links before use.

**R-804** "Sign in to Instagram" (toolbar menu and Settings) opens `https://www.instagram.com/accounts/login/` in the pane. The app is considered signed in when the store holds `sessionid` and `ds_user_id` cookies for `instagram.com`. MediaPull never sees or stores the password.

**R-805a** Tabs: each window has one or more browser tabs, shown in a strip at the top of the Browser pane with a new-tab button (⌘T), a close button on the selected or hovered tab (⌘W; closing the last tab closes the window), Reopen Closed Tab (⇧⌘T), Show Next and Previous Tab (⌃Tab, ⌃⇧Tab) and a context menu (New Tab, Duplicate, Bookmark, Close, Close Other Tabs). Links that ask for a new window open in a new tab; ⌘-click opens a link in a background tab and ⇧⌘-click in a selected one. All tabs share the website data store. Extracted Media collects from every tab in the window; the "This Page" chip shows only media from the selected tab's page. Switching tabs never reloads a page.

**R-805b** Bookmarks: the star in the address field bookmarks the page into the first folder ("Favourites") and opens a small editor (name, folder, Remove); ⌘D does the same. The Bookmarks and History panel (toolbar button, ⌥⌘B) lists folders with their bookmarks. Folders can be added, renamed (double-click or context menu), reordered and deleted; bookmarks can be opened, opened in a new tab, renamed, moved to another folder and deleted. A Bookmarks menu lists every folder. The start page of a new tab shows bookmarks and recently visited pages, then four starting points: open a web page, download from one of the supported sites (opens the Downloads pane), organise a folder, and convert WebP, AVIF or HEIC files. It is not tied to any one site.

**R-805c** History: every page that finishes loading in any tab is recorded once per address (title, last visit, visit count; at most 5,000 addresses). The panel's History tab (⌘Y) groups visits by day with search; entries can be opened, bookmarked or removed. Clear History removes the last hour, today, today and yesterday, or everything (panel, History menu, Settings). Settings > General > "Remember browsing history" turns recording off. Bookmarks and history are stored as JSON files in `~/Library/Application Support/MediaPull/Browser/` and never leave the Mac; they are separate from website data (cookies), which "Clear All Website Data" removes.

**R-805** "Clear Instagram Session" removes all website data for `instagram.com` and related Meta domains from the store. "Clear All Website Data" removes everything.

**R-806** The pane uses WebKit's default User-Agent for the platform. The same User-Agent string is used for the app's own downloads and passed to the engines so that all requests look consistent.

**R-807** Pop-ups (which WebKit allows only after a click) open in a new tab (R-805a). A download the page itself offers (a download link, `Content-Disposition: attachment`, or a file the pane cannot show) opens the standard save dialog, starting in the Collect save folder (D-70) with the site's file name; the file is fetched by WebKit with the page's own session, and the address bar reports where it went. Nothing is saved without the dialog (D-73).

**R-808** When a checkpoint occurs (section 11.9), the pane shows a banner above the page: what happened, "Resume" (enabled when the condition is cleared) and "Cancel Jobs".

---

## 9. Web extraction

### 9.1 Injected script

**R-901** `extract.js` is injected as a `WKUserScript` at document start, into all frames, in an isolated `WKContentWorld`, so that page scripts cannot see or tamper with it and page Content Security Policy does not block it. It reports through a script message handler registered only in that world.

**R-902** *(Amended by D-77: There is no "Include inline SVG" setting (inline SVG is not collected), and the network observer reports manifests and media files, not individual stream segments.)* The script collects candidates from:

- `img` (`currentSrc`, `src`, every `srcset` candidate with its descriptor, `naturalWidth` and `naturalHeight` once loaded).
- `picture > source` (`srcset`, `type`, `media`).
- `video` and `audio` (`currentSrc`, `src`, `source` children with `type`, `poster`).
- Computed `background-image` and `background` (all `url()` values, including `image-set()` candidates).
- `meta` tags: `og:image`, `og:image:secure_url`, `og:video`, `og:video:secure_url`, `twitter:image`, `twitter:player:stream`; `link rel="image_src"`, `link rel="preload" as="image"`.
- Anchors whose `href` points to a media file (common for "click for full size" thumbnails).
- Lazy-load attributes: `data-src`, `data-srcset`, `data-lazy`, `data-lazy-src`, `data-original`, `data-full`, `data-full-src`, `data-zoom-image`, `data-large_image`, `data-hires`, `data-bg`.
- Open shadow roots (walked recursively).
- `svg` images referenced by URL; inline `svg` elements only when "Include inline SVG" is on.
- `data:` images of at least 4 KB (saved without any network request).
- Network: a `PerformanceObserver` on `resource` entries (buffered) reports every loaded URL whose extension or initiator suggests media, including `.m3u8`, `.mpd` and media segments.

**R-903** Media that appears later must be found. A `MutationObserver` watches `childList`, `subtree` and `attributes` (filtered to `src`, `srcset`, `style`, `class`, `poster` and the lazy attributes above). Changed nodes are collected in a set and processed during idle time (`requestIdleCallback` with a fallback timer). `load` events on images are captured so natural dimensions arrive once known. The initial pass walks the document in chunks of 2,000 elements per idle slice, and computed styles are read only for elements in a chunk or a mutation.

**R-904** Messages are batched: the first flush 50 ms after the first candidate, then at most every 300 ms, with at most 500 candidates or 256 KB per message. Each candidate is reported once per element and URL; attribute changes report again. The schema is in Appendix B.

**R-905** Frame origin and page URL are taken from `WKScriptMessage.frameInfo`, never from the script's own claims. Media from cross-origin iframes is shown and tagged with the frame's origin.

**R-906** "Auto-scroll" (Extracted pane menu) scrolls the page in steps with a pause between steps until no new candidates arrive for three steps or the user stops it, to trigger lazy loading on long pages.

### 9.2 Ingestion

**R-907** The message handler on the main actor only hands the raw message to the session's `ExtractionIngestor`. The ingestor decodes, normalizes, merges and ranks, then publishes a snapshot (ordered IDs plus changed items) to the UI at most 4 times per second.

**R-908** Page sessions accumulate across navigations within a window until the user clears them (⌘K, "Clear Extracted Media") (D-16). Items are grouped by page in the grid, and a "Current page only" filter is available. A setting can switch to "Clear on navigation".

### 9.3 Normalization and deduplication

**R-909** URLs are resolved against the frame URL. Scheme and host are lowercased, fragments and default ports are removed. Query strings are never reordered or stripped, except by an explicit CDN rule (section 9.5), because many CDN URLs are signed.

**R-910** Variants are merged into one item when they come from the same element (all `srcset` candidates of one image, all `source` children of one video) or share a CDN asset key (the URL with size parameters removed by a CDN rule). After download, items with identical SHA-256 are merged as duplicates.

### 9.4 Probing

**R-911** *(Amended by D-77: The tail read for a `moov` box at the end is the last 1 MB.)* The Prober fills in unknown byte size, pixel size, format and duration with a single `Range: bytes=0-65535` GET: the size comes from `Content-Range`, the format from magic bytes, image dimensions from an incremental ImageIO source, and video dimensions and duration from the MP4 `moov` box (fetching the last 512 KB when `moov` is at the end). HEAD is used only as a fallback because many CDNs answer HEAD poorly.

**R-912** Only items that are visible in the grid, selected, or needed by an active filter are probed. At most 6 probes run at once. Results are cached per session.

### 9.5 Original-size rules

**R-913** For known CDNs, MediaPull derives a larger "original" variant from the URL found on the page (Appendix D). A derived variant is marked unverified and is checked with a Range GET when the Preview pane asks for it or when it is about to be saved; if the check fails (non-2xx, not media, or smaller than the found variant) the found variant is used. Rules never apply to URLs that carry a signature parameter.

### 9.6 Ranking

**R-914** The best variant is chosen by, in order:

1. Most pixels (verified or reported).
2. If equal pixels: a variant already in a normal format (JPEG, PNG, GIF, MP4) over one that needs conversion, to avoid generational loss.
3. If still equal: a lossless format over a lossy one.
4. If still equal: most bytes.

The Preview pane shows the full variant table and the reason for the choice.

### 9.7 Downloads from pages

**R-915** Downloads for a web item send the pane's User-Agent, an `Accept` header that prefers normal formats (`image/jpeg,image/png,image/gif;q=0.9,image/*;q=0.5,*/*;q=0.1` for images), and a `Referer` computed with the browser's default policy (strict-origin-when-cross-origin) from the page or frame URL.

**R-916** Cookies from the pane's store are attached only when the media URL's registrable domain equals the page's registrable domain (first-party), matching Safari's tracking-prevention behaviour. Registrable domains use a bundled copy of the Public Suffix List, refreshed with each app release.

### 9.8 Streams and special cases

**R-917** HLS (`.m3u8`) and DASH (`.mpd`) manifests found on a page appear as **Stream** items with the best rendition's resolution once the manifest is parsed. Saving a stream runs a yt-dlp job through the bridge with the page's Referer and first-party cookies, which downloads the best rendition and merges it with ffmpeg into MP4, applying the video codec policy (section 16.3).

**R-918** *(Amended by D-77: An item is Protected when the page uses Encrypted Media Extensions for it, or when yt-dlp reports its formats as DRM; MediaPull does not parse manifests for key systems itself.)* Streams with DRM (FairPlay, Widevine, PlayReady, `SAMPLE-AES`, MPD `ContentProtection`) or AES-128 key encryption are marked **Protected**, shown greyed with the reason, and never downloaded (D-19).

**R-919** *(Amended by D-77: `blob:` videos are listed as unavailable with a pointer to Save Video… (which reads the page with yt-dlp); they are not linked to a recorded manifest.)* `blob:` video sources (Media Source Extensions) cannot be downloaded directly. They are shown as "Stream (find manifest)" and linked to any manifest the PerformanceObserver recorded for the same frame. `blob:` images are read inside the page context at save time (up to 25 MB) and saved without a network request.

---

## 10. Extracted media pane

### 10.1 Grid

**R-1001** A virtualized thumbnail grid. Each cell shows the thumbnail and badges: type (image, animated, video, stream, audio, vector), format, pixel size (W×H), byte size, and state (saved, protected, failed, insecure). Video cells show duration.

**R-1001a** Zoom: a slider in the Extracted pane's status bar (with zoom-out and zoom-in buttons either side), a trackpad pinch on the grid, ⌥⌘+ and ⌥⌘- (⌘+ and ⌘- zoom the web page, R-802a), and Zoom In and Zoom Out in the sort menu set the thumbnail size from 80 to 360 points, so the pane shows more or fewer items at once. The size is kept between launches. Thumbnails are decoded in 128-pixel steps, so dragging the slider does not decode on every step.

**R-1002** *(Amended by D-77: Thumbnails are decoded at most 768 px on the longer side (twice the largest cell).)* Thumbnails load lazily through the gate using the smallest variant at least as large as the cell, are decoded downsampled to at most twice the cell size (512 px maximum), and are cached within the budget in section 22.

**R-1003** Selection: click, ⇧-click range, ⌘-click toggle, ⌘A select all shown, ⌘⇧A deselect, drag-rectangle select. Arrow keys move focus; Space opens Quick Look; double-click shows the item in the Preview pane.

**R-1004** Context menu: Save to the save folder, Save to…, Copy Image (images only, after download), Copy URL, Copy Original URL, Open Page in Pane, Show in Preview, Hide Items from This Domain.

**R-1005** *(Amended by D-77: The header buttons are named as in the Downloads pane (D-69): "Download…" and "List in Extracted Media".)* The pane header shows the page session title. When the pane shows an Instagram profile or post, or a page that gallery-dl supports, the header shows the matching action buttons ("Pull @name…", "Scan @name", "Save This Post", "Scan with Site Extractor").

### 10.2 Filters

**R-1006** *(Amended by D-77: The filter bar offers search text, minimum width and height, file size range, shape, format, source, Instagram items, state, domains and the toggles below; the quick row's resolution slider covers the resolution presets. Maximum width and height, shorter side, megapixels, duration, a custom ratio and an Instagram date range are not offered.)* The filter bar (⌘F) offers:

| Filter | Values |
|---|---|
| Type | Image, Animated, Video, Stream, Audio, Vector |
| Format | JPEG, PNG, GIF, WebP, AVIF, HEIC, JXL, SVG, BMP/TIFF/ICO, MP4, MOV, WebM, HLS, DASH, audio formats |
| Resolution | Minimum and maximum width, height and shorter side; presets ≥ 500, ≥ 1000, ≥ 2000 px |
| Megapixels | Minimum |
| File size | Minimum and maximum with units |
| Aspect | Portrait, landscape, square, panorama, or a custom ratio range |
| Duration | Minimum and maximum (video and audio) |
| Source | Image tag, srcset, picture, CSS background, video/audio tag, meta tag, link, network, iframe, site extractor, Instagram |
| Domain | Include and exclude tokens; "Same site only" |
| Instagram | Post, carousel item, Reel, story, highlight, profile picture; date range |
| State | Not saved, saved, failed |
| Text | Search over URL, file name, alt text and caption |

Toggles, on by default: **Hide tiny** (either side under 64 px), **Hide icons** (favicons, sprites, tracking pixels, images under 32 px, `rel=icon`), **Hide duplicates** (show one item per asset). Off by default: **Exclude unknown sizes** (otherwise an item with an unknown value passes a minimum filter until probing fills it in).

**R-1006a** A quick filter row is always visible under the pane header: type chips (All, Images, Animated, Videos, Audio, SVG), a **resolution slider** and a live "shown of found" count. The slider sets the minimum length of an item's longer side, snapping to 0 (any size), 100, 200, 300, 400, 500, 640, 800, 1000, 1200, 1500, 1920, 2400, 3000 and 4000 px; items smaller than the chosen point are hidden at once, and items whose size is still unknown are probed and hidden when they turn out smaller. "More Filters" (⌘F) opens the full filter bar.

**R-1007** Sorting: discovery order (default), resolution, file size, duration, type, domain, Instagram date.

**R-1008** Filtering 5,000 items completes within the budget in section 22. Filter state persists per window; named presets can be saved.

### 10.3 Preview pane

**R-1009** The Preview pane (⌘I) is a pane of its own, not a popup. It shows the item or library file selected on its own most recently: media beside its details when the pane is wide, above them when it is tall. For an extracted item it shows:

- A preview: the grid thumbnail at once, then the full image (downloaded through the gate to the preview cache); animated GIFs animate; videos play after "Play" downloads them through the gate (AVFoundation never receives a remote URL); streams show their poster and play once saved.
- The variant table: URL, origin, pixel size, bytes, format, verified state, and which one was chosen and why.
- Source: page and frame, Instagram post details or site extractor details.
- The planned file name and destination for the current layout.
- Actions: Save (to the save folder), Save to…, Edit, Copy URL, Open, Quick Look, Check Original Sizes.

For a library file it shows the image, animated GIF or video player, format, dimensions, size, date, folder and the sidecar's account, section, source and caption, with Show in Finder, Open and Quick Look.

**R-1009a** The editor (section 32) opens inside the Preview pane. While an edit has unsaved changes, selecting another item does not replace it.

**R-1010** Quick Look (Space) downloads the best variant to the cache through the gate and previews the local file.

**R-1011** Items already in the library (D-84): every save remembers the item under its engine key, or a hash of a web item's address, with the file it became. As items are extracted they are looked up in one batch off the main thread; those whose file still exists show the saved badge and, in the details, "In your library:" with the file name, which shows it in the Finder. The State filter's Not Saved hides them. Nothing is downloaded to check.

---

## 11. Instagram

### 11.1 Engine

Instagram access runs through the bundled gallery-dl engine (D-04), driven by the bridge. gallery-dl is the most actively maintained open-source Instagram extractor; Instagram changes its internal APIs every few weeks, and engine updates (section 13.6) are how MediaPull keeps up without an app release. yt-dlp (as a module inside the same Python runtime) and ffmpeg handle DASH video merging.

### 11.2 Sign-in

**R-1101** Sign-in happens only in the browser pane, and pulls need a signed-in session (D-53). Checked in November 2026 with the bundled gallery-dl 1.32.19 against a large public account, signed out: the profile page loads, but the GraphQL route fails because Instagram does not serve the profile query to signed-out visitors, the REST route reports the account as not found, and a single post redirects to the login page. The browser pane itself, signed out, shows about 12 recent posts at 640 px or less, profile pictures at 150 px and no stories; those can be collected like any web page, but that is preview quality, not an archive. The Pull sheet shows the sign-in state and offers "Sign In" when signed out.

**R-1102** Private accounts are only pulled when the signed-in user already follows them. Otherwise the job stops with "This account is private".

### 11.3 Cookies and identity

**R-1103** For each Instagram job, MediaPull exports the cookies for `instagram.com` (including HttpOnly cookies) from `WKHTTPCookieStore` into a Netscape-format `cookies.txt` (R-512) and passes its path and the pane's User-Agent to the bridge. When the job ends, cookies the engine updated (Instagram rotates some) are written back into the pane's store, then the file is deleted.

### 11.4 Inputs

**R-1104** Accepted inputs: `@name`, `name`, profile URLs, post and Reel URLs (`/p/`, `/reel/`, `/reels/`, `/tv/`), story URLs, highlight URLs. Shortcode and media-id conversions are pure functions in Core.

### 11.5 Pull sheet

**R-1105** "Pull Account…" (⇧⌘P), the toolbar's Downloads button, or typing an @account or #hashtag in the Downloads pane shows the Instagram options in that pane (section 11.11):

- **Account card**: avatar, name, username, post count, private or public, followed state (from a quick `account` bridge call).
- **Input**: a username, @handle or profile link, or a `#hashtag` (or a hashtag page link), which pulls the hashtag's posts instead of an account.
- **Content** (R-1105a), in three groups, each choice remembered per account and with defaults in Settings > Instagram.
- **Dates** (R-1105b): All Time (default), Past Month, Past Year or Custom, plus "Only new posts (stop at the posts the folder already has)" (on when a previous pull exists).
- **Destination** *(Amended by D-78)*: the save folder (D-70). When it is, is inside, or contains the account's folder, that folder is updated; otherwise a new folder named after the account is made. A line under the save folder says which: "Adds only what "<folder>" doesn't have yet (N files there)" or "Saves into a new folder "<name>" in "<parent>"".
- **Layout**: Archive (default) or Plain.
- **Mode** *(Amended by D-79: there is no Mode row. Every pull skips what the folder has; Find Missing in the Library replaces Verify.)*: Incremental (default) or Verify (walk everything, download only what is missing on disk).
- **Pacing**: Gentle (default) or Standard.
- **Estimate**: approximate requests and time, computed from the post count and pacing.
- Buttons: **Scan Only** and **Pull**.

**R-1105a** Content choices, mapped to the bundled gallery-dl's Instagram extractors:

| Group | Choice | Default | Engine | Saved in |
|---|---|---|---|---|
| From the account | Posts and carousels | on | `posts` | `<account>/posts/` |
| | Reels | on | `reels` | `<account>/reels/` |
| | Current stories | on | `stories` | `<account>/stories/` |
| | Highlights | on | `highlights` | `<account>/highlights/<title>/` |
| | Profile picture | on | `avatar` | `<account>/profile pictures/` |
| | Posts the account is tagged in | off | `tagged` | `<account>/tagged/` |
| | Reposts | off | `reposts` | `<account>/reposts/` |
| | Highlight covers | off | `highlights-covers` | `<account>/highlights/<title>/` |
| Account details | Profile information | off | `info` | `<account>/Account details/<date>_profile.json` (the whole profile record) |
| | Followers list, Following list | off | `followers`, `following` | `<account>/Account details/<date>_followers.csv` (username, full name, id, private, verified, profile link) |
| From your own account (signed in) | Saved posts and collections | off | `saved` | `Saved posts/` |
| | Stories from accounts you follow | off | `stories-tray` | `<owner>/stories/` |
| Hashtag (input) | Posts with the hashtag | — | `tag` | `Hashtags/<tag>/` |

Media is sorted into a folder per type by default (D-54); Settings > Instagram > "Sort into folders by type" off puts posts, Reels and profile pictures directly in `<account>/` (stories, highlights, tagged posts and reposts keep their folders). The "From the account" choices are listed through the profile in one listing; the others are pages of their own, run one after another in the same job. Follower and following lists record names only: the bridge never opens the accounts in them. The Instagram "user profile" page is the listing itself, and single post, Reel, story and collection links are pulled with the same sheet. Guides are not offered: Instagram retired them and the pinned gallery-dl has no extractor for them.

**R-1105b** Dates: All Time, Past Month and Past Year count back from the moment the pull starts; Custom covers whole days from the start of the first to the end of the last (a reversed range is put in order). The bridge applies the window (D-38): pinned posts outside it are skipped rather than ending the listing, profile pictures are always included, and stories (at most a day old) and highlights keep their own dates.

### 11.6 Modes of operation

**R-1106 Pull.** The bridge runs a gallery-dl download job for the selected content into a per-job staging folder. Each downloaded file arrives as a `file` event with its metadata and goes through the save pipeline (section 14), which converts if needed, deduplicates, names, writes the sidecar and moves the file into place. Items also appear live in the Extracted pane (as saved).

**R-1107 Scan Only.** The bridge lists items without downloading (`scan` operation). Items appear in the Extracted pane with their thumbnails, grouped by post, so the user can filter and select. Saving selected items:

- Images and progressive videos are downloaded by the Swift download queue straight from the URLs in the scan (Instagram CDN URLs need no cookies). If a URL's signature has expired, the item is re-resolved first.
- Videos whose best version is a DASH stream are fetched by the bridge (`fetch` operation), which downloads and merges them.

Which `fetch` method the bridge uses (reusing the engine's downloaders on scanned items, or re-resolving each post by its URL) is decided by the M0 spike and recorded in `docs/spikes/M0.md`.

**R-1108 Single post or Reel.** "Save This Post" runs a pull limited to that post (all carousel items) into `<root>/<owner username>/`.

### 11.7 Quality

**R-1109 Images.** The largest candidate Instagram provides (by width × height) is used, and its URL is never edited (CDN URLs are signed). `original_width` and `original_height` are recorded in the sidecar when present. The UI says, where relevant, that Instagram's largest version is usually 1080 or 1440 px wide and is not the original upload.

**R-1110 Videos.** The engine compares the progressive versions with the DASH manifest and takes the highest resolution, applying the video codec policy (section 16.3):

- Best H.264 or HEVC stream plus the best AAC audio, merged with `ffmpeg -c copy` into MP4, without re-encoding.
- If a strictly higher resolution exists only as VP9 or AV1, by default it is re-encoded to HEVC MP4 with the hardware encoder at high quality (D-05). Other policies are available in Settings.

**R-1111** Carousels are saved as separate files numbered from 1 in carousel order, with `num` and `count` in the sidecar so that downstream tools can regroup them.

### 11.8 Incremental sync and pacing

**R-1112** *(Amended by D-79: the known set and the resume cursor belong to the account folder, not the account; the known set is sent on every pull into an account folder, and "Only new posts" decides only the early stop.)* For incremental pulls, the bridge receives the set of already-archived media ids for the account and stops after 12 consecutive already-archived posts that are not pinned (Instagram shows up to 3 pinned posts first, out of date order). The resume cursor is saved after every page so an interrupted pull continues where it stopped, including after the app quits.

**R-1113** Pacing presets set the engine's delay between Instagram API requests: **Gentle** 8–15 s (default) and **Standard** 6–12 s, both with random jitter. CDN downloads run at most 2 at a time. Only one Instagram job runs at a time across all windows; others wait in the queue.

### 11.9 Checkpoints and rate limits

**R-1114** The bridge classifies these as checkpoints: `checkpoint_required`, `challenge_required`, `feedback_required`, HTTP 429, HTTP 401 with a "please wait" message, and redirects to `/accounts/login/` or `/challenge/`. On a checkpoint:

1. `InstagramGate` moves to **blocked** and every Instagram job pauses.
2. The challenge or login page opens in the browser pane with the banner from R-808.
3. "Resume" stays disabled until a valid `sessionid` cookie is present again (for login and challenge) or the cooldown ends (for rate limits).
4. Rate-limit cooldowns grow 10, 20, then 40 minutes for repeated hits within a day.
5. Nothing retries automatically after a checkpoint.

### 11.10 Folders and naming

**R-1115** *(Amended by D-78: `<root>/<username>/` is the folder of a new pull; an existing account folder is used whatever its name, and keeps its own choice of type folders, read from what it holds.)* Default destination layout for an account:

```
<root>/<username>/
    2023-01-06_022210_CnAbCdEfGh_01.jpg
    2023-01-06_022210_CnAbCdEfGh_01.jpg.json
    2023-01-06_022210_CnAbCdEfGh_02.mp4
    2023-01-06_022210_CnAbCdEfGh_02.mp4.json
    2024-05-02_181500_avatar.jpg
    2024-05-02_181500_avatar.jpg.json
    stories/
        2026-11-13_210455_3512345678901234567_01.jpg
    highlights/
        Travel/
            2025-07-20_101010_3412345678901234567_01.mp4
```

- By default each type has its own folder: `posts/`, `reels/`, `stories/`, `highlights/<highlight title>/`, `profile pictures/`, `tagged/` and `reposts/` (D-54). With "Sort into folders by type" off, posts, Reels and the profile picture share the account folder and `subcategory` in the sidecar tells them apart.
- The profile picture is named with the time of the pull and deduplicated by content, so it is only saved again when it changes.
- Collab posts are saved in the folder of the account being pulled; the sidecar records `owner_username` (D-11).

---

### 11.11 Downloads pane

**R-1111a** The Downloads pane (D-69) replaces the pull and video sheets. It follows the page in the browser (or an address, @account or #hashtag typed into it) and shows the options for what is there:

- **Instagram** accounts, posts and hashtags: the options of R-1105, with "Sort into folders by type" on by default (D-54).
- **Videos** (YouTube, Vimeo and the other sites yt-dlp supports): the format and resolution of R-3502, plus the choices of R-3505.
- **Galleries** on any site gallery-dl supports (section 12): everything at the address, or a range of items, between dates, only what is new since the last download; or "Show in Extracted Media" to pick by hand.

Below the options it lists the downloads in progress and just finished. Downloads go into the window's save folder (R-1404), which the pane shows and can change; accounts, sites and channels get their own subfolders inside it.

**R-1111b** Every gallery-dl site gets the same care as Instagram (D-71):

- **What is there.** The pane names the site ("DeviantArt", "Bluesky") and the kind of page (profile, one post, tag, search), from `SiteCatalogue.json`, which `scripts/build_site_catalogue.py` builds from the bundled gallery-dl's own site list and documentation.
- **Parts of a profile.** Where gallery-dl splits a profile into parts (gallery, scraps, favourites; posts, media, likes), they are offered as chips with gallery-dl's defaults, read from the extractor without a network request. Parts that are lists of other accounts are not offered.
- **The site's switches.** Its own media switches (videos, retweets, reblogs, quoted posts, replies, Live Photo videos and the like) with gallery-dl's defaults. Only switches that choose media are offered or passed on; nothing that changes an account (such as watching a user) is.
- **Sign-in.** For sites that show more when signed in, or need it, the pane says whether the browser has a session for the site and offers Sign In, which opens the site in the browser. The browser's cookies and user agent go to gallery-dl together. Sites that need the site's own app token or an API key say so.
- **Your own API key.** Sites that accept one (Tumblr, DeviantArt, Flickr, Reddit, Wallhaven, Gelbooru and others; `SiteKeys`) offer an optional key field with a link to get one. Keys live in the Keychain, go to the bridge on standard input with known option names only, and lift the limits of the shared keys gallery-dl ships with.
- **Errors in plain words** (`GalleryError`): a browser check, a sign-in, an API key, a refusal, a limit, nothing found, or a changed site, each with what to do next.
- **Dates, items, only new, folders.** As for Instagram: a date window, an item range, only what is new since the last download, and folders by part when several are chosen. Choices are remembered per site.
- **Animations stored as frames** (pixiv, Danbooru) are turned into MP4 with the hardware encoder.

**R-1111c** Other apps (D-82): **Download with MediaPull** in the Services menu, for selected text or a link in any app, brings MediaPull forward with the address in the front window's Downloads pane. A link dropped on the Downloads pane does the same. Nothing starts until the person clicks Download.

**R-1111d** Several addresses at once: two to 200 addresses, @accounts or #hashtags typed or pasted into the Downloads field, separated by spaces or new lines, become a list. Each line says what it is (Instagram, a gallery on a named site, a video, or "Not recognised: skipped"), worked out locally. **Download All (N)** runs them one after another into the save folder, each with the options last chosen for its kind (the account's remembered choices, the site's parts and switches with only new items, the best MP4 video), waiting for each to finish; Instagram keeps its pace and one-at-a-time rule (R-1113). **Stop After This One** lets the current download finish and starts no more.

## 12. Site extractor scans

**R-1201** After each committed navigation (debounced 1.5 s), MediaPull asks the bridge whether gallery-dl has an extractor for the URL (`supports` operation, local only, no network). Results are cached per URL. Instagram URLs are handled by section 11 instead.

**R-1202** When supported, the Extracted pane header shows "Scan with Site Extractor". The scan runs a `scan` operation with cookies exported for that site's registrable domain only (as in R-1103). Results appear as items with source "Site extractor (<category>)", with the engine's metadata (category, subcategory, user, post id, title, date).

**R-1203** Saving site extractor items follows R-1107: direct URLs through the Swift download queue (with any HTTP headers the engine reports as required), otherwise a bridge `fetch`. Pacing uses gallery-dl's per-site defaults, never faster.

**R-1204** In the Archive layout, sidecars for these items use the engine's own `category`, `subcategory` and user name where present, falling back to the host (section 15.3).

---

## 13. Engines (bundled helpers)

### 13.1 Contents

| Component | Purpose | Licence | Baseline at time of writing |
|---|---|---|---|
| CPython (python-build-standalone, `install_only_stripped`, aarch64) | Runtime for the bridge and engines | PSF | 3.13.x, pinned |
| gallery-dl | Instagram and site extractors | GPL-2.0 | 1.32.19 (2026-10-31) |
| yt-dlp | DASH and HLS download, used as a module by gallery-dl and directly for streams | Unlicense | 2026.10.26 |
| requests, urllib3, idna, charset-normalizer (pure-Python wheel), certifi | Engine dependencies | Apache-2.0, MIT, BSD, MPL-2.0 | pinned |
| ffmpeg and ffprobe (minimal LGPL build) | Merging, remuxing, re-encoding with VideoToolbox, animated GIF palettes | LGPL-2.1 | pinned stable release |
| `bridge.py` | MediaPull's own driver and egress guard | MediaPull | n/a |

Only pure-Python wheels are bundled for the engines and their dependencies, so engine updates never introduce unsigned native code.

### 13.2 Bundle placement

The Python runtime, trimmed standard library (no `tkinter`, `idlelib`, `ensurepip`, `test`, `turtledemo`, `lib2to3`), baseline site-packages and `bridge.py` live under `Contents/Resources/Engines/`. ffmpeg and ffprobe live in `Contents/Helpers/`. Standard library and packages are precompiled to `.pyc` at build time. Exact placement is verified against notarization in M0 (verify in M0).

### 13.3 Launching

**R-1301** A bridge process is started with:

- The bundled interpreter in isolated mode (`-I`), with `sys.path` set by the bridge to the active engine versions followed by the baseline.
- A clean environment: `HOME` and `XDG_CONFIG_HOME` pointing to the empty `EngineHome/` folder, `PATH` containing only `Contents/Helpers`, `TMPDIR` inside the job's staging folder, `PYTHONDONTWRITEBYTECODE=1`.
- Working directory set to the job's staging folder.
- The job request as one JSON object on standard input (Appendix A).

**R-1302** Events arrive as JSON Lines on standard output. Standard error is captured into the log (redacted). The app never parses the engines' human-readable output.

**R-1303** Cancelling a job sends SIGINT, then SIGTERM after 5 s, then SIGKILL after a further 5 s. Staging files of a cancelled job are deleted, except completed files already handed to the save pipeline.

### 13.4 Bridge operations

| Operation | Purpose |
|---|---|
| `hello` | Versions of Python, gallery-dl, yt-dlp, ffmpeg; protocol version. |
| `selftest` | Imports engines, runs the egress guard self-check, checks ffmpeg. Used after installs and updates. |
| `supports` | Whether gallery-dl has an extractor for a URL (no network). |
| `account` | Instagram profile summary for the Pull sheet. |
| `scan` | List items for an account, post, story, highlight or supported page, without downloading. |
| `pull` | Download items for an account or post into staging, streaming `file` events. |
| `fetch` | Download specific items from an earlier scan (DASH videos, items needing engine downloaders). |
| `stream` | Download an HLS or DASH stream with yt-dlp and merge to MP4. |
| `install_wheel` | Unpack a verified pure-Python wheel into an engine version folder. |

### 13.5 Error mapping

The bridge maps engine exceptions and messages to typed `error` and `checkpoint` events: `not_found`, `private`, `login_required`, `checkpoint`, `rate_limited`, `network`, `engine_outdated` (an extractor error that typically means Instagram changed something), `unsupported`, `policy_violation`, `internal`. `engine_outdated` suggests checking for engine updates.

### 13.6 Engine updates

**R-1304** The baseline engines in the app bundle are always available and never modified.

**R-1305** "Check for Engine Updates" (Settings > Engines) fetches PyPI's JSON metadata for gallery-dl and yt-dlp through the gate. When a newer release has a pure-Python wheel, MediaPull downloads it, verifies its SHA-256 against PyPI's metadata, checks that its declared dependencies are satisfied by the bundled ones (otherwise: "Needs an MediaPull update"), installs it with `install_wheel` into `Application Support/MediaPull/Engines/<name>/<version>/`, runs `selftest` with it, and only then marks it active in `active.json`. A failed self-test or install leaves the previous version active.

**R-1306** A weekly automatic check is on by default (D-20). It only notifies (a badge in Settings and the Activity panel); installing is one click. Updates never install while a job runs.

**R-1307** The previous active version is kept for rollback ("Use Previous Version"); at most two versions per engine are kept. "Reset to Built-In Engines" removes all updates.

**R-1308** The Python runtime, the engines' dependencies and ffmpeg update only with the app.

---

## 14. Save pipeline

**R-1401** Every saved file goes through the same steps:

1. **Resolve** the best variant. Re-resolve if a signed URL has expired. Verify a derived original-size variant (R-913).
2. **Download** to `Caches/MediaPull/Partial/` (Swift queue) or receive a completed file from the bridge's staging folder.
3. **Validate** by magic bytes. Reject HTML or JSON served in place of media (a login page served with status 200), empty files and length mismatches against `Content-Length`.
4. **Convert** if the format or layout requires it (section 16), writing into a temporary folder on the destination volume.
5. **Hash** the final bytes with SHA-256 (streamed in 1 MB blocks).
6. **Deduplicate**: in the Archive layout, skip if an identical file already exists in the account or site folder; in the Plain layout, skip if it exists in the destination folder. If the media is skipped but its sidecar is missing, write the sidecar. The `FileFingerprint` index makes this cheap; it hashes unknown files lazily and caches by path, size and modification date.
7. **Name** the file from the template (section 15.4). On a name collision with different content, add ` 2`, ` 3`, … before the extension (or skip, per the conflict policy).
8. **Move** into place atomically (rename within the volume; fails rather than overwriting).
9. **Set dates**: creation and modification dates set to the post's date (Instagram, site extractor) or the server's `Last-Modified` (web), when known and the setting is on (default on).
10. **Write the sidecar** atomically after the media (Archive layout only).
11. **Record** the `ArchiveEntry` and `FileFingerprint`. Optionally set the "Where from" attribute (`kMDItemWhereFroms`) to the page and media URLs (default on).

**R-1402** Saving never overwrites or deletes an existing file.

**R-1403** A save of many items runs as one job with per-item results. Items that fail stay in the Extracted pane marked failed, with "Retry Failed" on the job.

**R-1404** Collect has one save folder per window (D-70): the folder selected in the Library pane, the default library folder (`Pictures/MediaPull`) until another is chosen. Save (⌘S) saves there; its name is shown beside the Save button, whose menu changes it to a library folder, a recent folder or any other folder on the Mac. "Save to…" (⇧⌘S) picks any folder, makes it the save folder and saves. A folder outside the library is shown in the Library pane under the library folders until it is replaced or removed; it is not added to the library.

---

## 15. Output layouts

### 15.1 Plain

Media files only, named by the Plain template (default `{orig_name}.{ext}`, falling back to `{host}_{index:04}.{ext}` when the URL has no usable name). Any format allowed by the conversion settings may be written, including SVG, audio and kept originals.

### 15.2 Archive (default)

The Archive layout is a **gallery-dl-compatible metadata archive**. It is designed so that tools which import gallery-dl download folders can import an MediaPull folder directly, with captions, dates, post grouping and content type preserved. The rules below are a contract; changing them requires a decision entry.

**R-1501** Each media file has a sidecar named `<full file name>.json` in the same folder (for `photo.jpg` the sidecar is `photo.jpg.json`).

**R-1502** Only these media types are written: `.jpg`, `.png`, `.gif`, `.mp4`, `.mov`. Anything else is converted (section 16) or skipped with a reason (SVG, audio and protected streams are skipped, D-13). The one exception is a WebM or M4A file the person chooses in the Save Video sheet, which is saved without a metadata file (D-56).

**R-1503** File names begin with a sortable timestamp (`YYYY-MM-DD_HHMMSS_…`) so that name order equals chronological order.

**R-1504** File names must never match the pattern `^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_UTC`. Some tools detect that pattern as a different downloader's layout and then ignore the sidecars. Template validation rejects any template that could produce it, and a property test checks generated names over random dates.

**R-1505** Folders named `media` or `your_instagram_activity` (compared case-insensitively) are never created at the first level below the folder being saved into or below a library root, because some tools treat such folders as a different kind of export. An account or host with one of these names gets a leading underscore (`_media`).

**R-1506** Files are written fully to local disk. When a library root is inside iCloud Drive or on a volume that is not local, MediaPull warns once per root that files may become cloud-only placeholders, which some importing tools cannot read.

### 15.3 Sidecar schema

The sidecar is encoded from a closed Swift struct, never by passing through engine or Instagram JSON, so that unwanted fields cannot leak. Keys are sorted, the encoding is UTF-8, and slashes are not escaped. Full schema and examples are in Appendix C.

| Key | Type | Instagram | Site extractor | Web page |
|---|---|---|---|---|
| `category` | string | `"instagram"` | engine category (`"pinterest"`) | page host (`"example.com"`) |
| `subcategory` | string | `"posts"`, `"reels"`, `"stories"`, `"highlights"`, `"avatar"` | engine subcategory | `"page"` |
| `username` | string | account being pulled | engine user name, else host | page host |
| `author` | string, optional | display name | engine author | omitted |
| `post_shortcode` | string, optional | shortcode | omitted | omitted |
| `post_id` | string | post id | engine post id, else a short hash of the file URL | 12-hex-digit hash of the page URL (D-29) |
| `num` | integer, optional | 1-based index in the post | engine `num` | omitted |
| `count` | integer, optional | number of items in the post | engine `count` | omitted |
| `date` | string `"YYYY-MM-DD HH:MM:SS"`, UTC | post date | engine date | `Last-Modified` if known, else omitted |
| `description` | string | caption with hashtags | engine description or title | alt text or figure caption, else omitted |

Additional keys (ignored by tools that do not know them): `post_url`, `page_url`, `source_url`, `width`, `height`, `original_width`, `original_height`, `duration`, `owner_username`, `highlight_title`, `product_type`, `sha256`, `extractor`, `mediapull_version`.

**R-1507** Sidecars never contain location data, comments, likes, view counts, tagged-user lists or the signed-in user's identity (D-12).

**R-1508** Dates are formatted with a fixed `en_US_POSIX` locale, the Gregorian calendar and UTC, regardless of the user's settings. A test runs the encoder under a non-Gregorian calendar and a 12-hour locale.

**R-1509** Web pages are never grouped: `num` and `count` are omitted so each image is its own item (D-10).

### 15.4 Name templates

Tokens: `{yyyy}`, `{MM}`, `{dd}`, `{HH}`, `{mm}`, `{ss}`, `{date:<format>}`, `{shortcode}`, `{post_id}`, `{media_id}`, `{num}` / `{num:02}`, `{count}`, `{username}`, `{host}`, `{title}`, `{orig_name}`, `{index:04}` (discovery order), `{hash8}`, `{w}`, `{h}`, `{ext}`.

| Use | Default template |
|---|---|
| Archive, Instagram post, Reel, story, highlight item | `{yyyy}-{MM}-{dd}_{HH}{mm}{ss}_{shortcode or media_id}_{num:02}.{ext}` |
| Archive, Instagram profile picture | `{yyyy}-{MM}-{dd}_{HH}{mm}{ss}_avatar.{ext}` (time of the pull) |
| Archive, web page or site extractor | `{yyyy}-{MM}-{dd}_{HH}{mm}{ss}_{index:04}_{orig_name}.{ext}` (date of the post if known, else the time the save started) |
| Plain | `{orig_name}.{ext}` |

**R-1510** Names are NFC-normalized; `/`, `:`, control codes and text-direction overrides are replaced, zero-width spaces are removed, and joiners (U+200C, U+200D) are kept (D-74); names never start with a dot; the full name plus `.json` fits in 255 bytes (the name is shortened before the extension if needed).

---

## 16. Format conversion

### 16.1 Images

**R-1601** Conversion uses ImageIO. Output rules:

| Input | Output |
|---|---|
| JPEG, PNG, GIF | Unchanged bytes |
| WebP lossy (VP8), no alpha | JPEG, quality 1.0 (4:4:4 chroma) |
| WebP lossless (VP8L), or any WebP with alpha | PNG |
| AVIF, HEIC, JPEG XL, 8-bit, no alpha | JPEG, quality 1.0 |
| AVIF, HEIC, JPEG XL with alpha or more than 8 bits per channel | PNG (16 bits per channel when the source has more than 8) |
| Animated WebP, animated AVIF, APNG | GIF by default (D-06); MP4 or APNG as options |
| BMP, TIFF, ICO | PNG |
| SVG | Plain: kept as `.svg`. Archive: skipped, or rasterized to PNG when "Rasterize SVG" is on (D-13) |

**R-1602** EXIF, orientation and the ICC colour profile are carried over (`CGImageDestinationAddImageFromSource` with the source's properties). A test with a Display P3 fixture checks that the profile survives. HDR gain maps are not carried over in version 1 (D-14).

**R-1603** Animated GIF output decodes frames with ImageIO and builds an optimized palette with ffmpeg (`palettegen` and `paletteuse`) for quality far better than a single global palette; frame delays and loop count are preserved.

**R-1604** "Keep original WebP/AVIF/HEIC" (off by default) applies only to the Plain layout. The Archive layout always converts.

### 16.2 Converter

**R-1605** *(Amended by D-77: The Converter has no per-run options: it follows section 16.1 and the Formats settings.)* The Converter window (⇧⌘K) accepts files and folders dragged from Finder or the Library pane. Options: output policy (Automatic per the table, Always JPEG, Always PNG), keep metadata (on), include subfolders (on), destination (next to originals, or a chosen folder), skip files already in a normal format (on). It shows per-file results. It never modifies or deletes originals; an existing output name gets a numbered suffix.

**R-1606** The Library pane's context menu offers "Convert to JPEG/PNG" for convertible files, using the same rules.

### 16.3 Video

**R-1607** Video codec policy (Settings > Video), applied to Instagram videos, streams and WebM files:

| Policy | Behaviour |
|---|---|
| **Highest resolution, re-encode only if needed** (default, D-05) | Take the highest resolution available. If it is H.264 or HEVC, merge or remux with no re-encoding. If it exists only as VP9 or AV1, re-encode it to HEVC MP4 with the hardware encoder (VideoToolbox) in constant-quality mode tuned for visually lossless output (tuned in M0), tagged `hvc1` so it plays in QuickTime and Photos. |
| Highest compatible, never re-encode | Take the best H.264 or HEVC version untouched, even if a higher resolution existed in VP9 or AV1. The sidecar records `higher_res_available`. |
| Keep original codec | Highest resolution with no re-encode; VP9 or AV1 in MP4. May not play in QuickTime or Photos. |

**R-1608** Audio that is not AAC (Opus, Vorbis) is converted to AAC at 256 kbit/s with the system AAC encoder when the output is MP4. MOV and M4V inputs are kept as they are (M4V renamed `.mp4`). WebM inputs are converted to MP4 following the codec policy.

---

## 17. Library pane

**R-1701** The Library pane shows the library roots as a folder tree (top) and the contents of the selected folder (bottom) in the view chosen for the pane (R-1708; a thumbnail grid at first), separated by a resizable divider; in Column view a column browser replaces both. Sidecar files are hidden from the grid; items with a sidecar show a small metadata badge.

**R-1702** Library roots are added with "Add Folder…" (an open panel) and stored as bookmarks (`LibraryRoot`). Each root has a default layout. Roots can be renamed (display name only), removed from the list (files untouched) and revealed in Finder.

**R-1703** Folder operations: New Folder (⇧⌘N), Rename (Return), Move to Trash (⌘⌫). MediaPull never deletes permanently. Renaming or moving a media file renames or moves its sidecar with it. Moving to Trash moves the sidecar too.

**R-1704** The pane updates live when files change on disk (FSEvents, recursive per library root), including changes made in Finder. Up to version 1.5 only the selected folder was watched; version 1.6 builds the FSEvents watch that analysis needs (R-3603).

**R-1707** Sort, filter and search: section 37. Return renames and ⌘⌫ moves to the Trash in the grid as well as the tree (R-1703).

**R-1708** Views, as in the Finder (D-76): the Library, Organise Source and Target, and Extracted Media panes show their media as Icons (the thumbnail grid), as a List, or (folder panes only) as Columns. A small segmented control in each pane's header switches the view, and View > as Icons ⌘1, as List ⌘2 and as Columns ⌘3 switch the pane last clicked or focused. Each pane keeps its own view between launches. Space (Quick Look), Return, ⌘⌫, double-click, the context menu, multiple selection, and dragging out (with metadata files) and dropping in work the same in every view.

**R-1709** List view: one row per item with a small thumbnail and the name, then Date, Size, Dimensions, Kind and Duration (Extracted Media: Dimensions, Size, Kind, Duration, Source and Found). Clicking a column header sorts by it, through the pane's own sort (section 37, R-1006), and clicking it again reverses the order; columns without a matching sort do not sort. In a folder pane, the folder's subfolders come first as rows with a disclosure triangle that shows their contents in place; with search text or Include Subfolders on, the list is flat. Sorts that make groups (Events, Group Similar) show each group as a heading row.

**R-1710** Column view (folder panes): a column browser starting at the library folders (Organise: the pane's folder) replaces the folder tree and the search and filter row. Each column lists a folder's subfolders and then its media files by name; the last column previews the selected file with its name, kind, size, dimensions, length and dates. Columns share the pane's width (up to three, each at least 160 points wide), so every visible column is shown whole. The deepest selected folder is the pane's folder (the Collect save folder for the Library, D-70).

**R-1711** Thumbnail size (R-1001a) applies to Icon view; ⌥⌘+ and ⌥⌘- are disabled in the other views.

**R-1712** Account folders (D-78 to D-80): when the selected folder holds an Instagram account (or is inside its folder), the Library's title row shows **Update @name** and the subtitle adds "@name updated <when>" or "@name: an earlier update stopped part way". The folder's context menu (tree, List and Column views) has **Update @name** and **Find Missing from @name**, and a folder containing two or more remembered account folders has **Update All Accounts (N)**. Updates run as ordinary Instagram jobs in Activity, one at a time (R-1113). The button is disabled while that folder's update is queued or running.

**R-1713** Check Folder (folder context menu in every view, D-83): reads every file in the folder and its subfolders once, off the main thread, and reports under the folder's title how many files it checked and what no longer matches what was saved: files whose checksum differs from the one in their metadata file (edited since, or damaged), media files without a metadata file (Archive folders only), metadata files whose media file is gone, and files kept only in iCloud. It changes nothing by itself; **Trash Orphaned Metadata** moves the metadata files without media to the Trash as one undoable operation, and **Show in Finder** selects the files it found. The `Account details` folder is not checked.

**R-1714** Folder sizes: in List view, a folder row's Kind says how many media files it holds (with its subfolders, metadata files not counted) and its Size column their total. Folders are measured in the background, one at a time, the first time their row is shown, and again after MediaPull changes files; until then the row shows "Folder" and "--". The folder tree is unchanged.

**R-1705** Quick Look (Space), Reveal in Finder (⌘R), Open With default app, Copy (file URLs).

**R-1706** The selected folder is the save folder of Collect: Save, the Downloads pane and the editors all save there (D-70).

---

## 18. Drag and drop

**R-1801**

| From | To | Result |
|---|---|---|
| Extracted items | Library folder (tree row or grid) | Save job into that folder using its root's layout |
| Extracted items | Finder or another app | File promises: files are downloaded and converted on drop, Plain layout; holding ⌥ adds sidecars |
| Finder files | Library folder | Copy into the folder; converted when the root's layout is Archive |
| Finder files or folders | Converter window | Convert |
| Library items | Finder | Copy (sidecars included) |
| Library items | Another Library folder | Move (sidecars included); ⌥ copies |
| Anything | Browser pane | Files are rejected (R-508); a URL or text navigates |

**R-1802** Multi-item drags of up to 5,000 items stay responsive: the drag starts within 100 ms and file promises resolve asynchronously.

---

## 19. Jobs and activity

**R-1901** Job kinds: Save, Pull, Scan, Stream Download, Convert, Engine Update, Analyse, Organise.

**R-1902** Job states: queued, running, paused, waiting (pacing or cooldown, with a countdown), blocked (checkpoint), completed, failed, cancelled.

**R-1903** *(Amended by D-77: Pause and Resume are offered for Analyse jobs; other jobs offer Cancel and Retry Failed (Instagram pulls continue from their cursor). Speed is not shown, and checkpoints are handled by the browser banner (R-808).)* The Activity panel (⇧⌘J) lists jobs with progress (items and bytes), current item, speed, and actions: Pause, Resume, Cancel, Retry Failed, Show Page (for checkpoints), Reveal Folder.

**R-1904** *(Amended by D-80: the cursor is kept per account folder; the Activity window shows "An update of @name into "<folder>" stopped part way" with Resume, and the folder's Library subtitle says so. Any update of that folder also continues it.)* Interrupted Pull jobs (app quit, crash, cancelled) keep their cursor; on next launch the panel offers "Resume Pull".

**R-1905** A local notification is posted when a job longer than 1 minute finishes or becomes blocked (setting, default on).

---

## 20. Settings

| Pane | Settings |
|---|---|
| General | Library roots and default root; default layout; name templates (with live preview and validation); conflict policy (number, skip); set file dates (on); set "Where from" (on); "Clear extracted media on navigation" (off) |
| Formats | WebP/AVIF/HEIC handling for Plain (convert, keep original); animated images (GIF, MP4, APNG); SVG (kept in Plain, rasterized in Archive); video codec policy (section 16.3) |
| Instagram | Sign in, sign-in state, Clear Instagram Session; default content; pacing (Gentle, Standard); sort into folders by type (on, D-54); incremental stop count (12) |
| Engines | Installed and active versions; Check for Updates; weekly check (on); Use Previous Version; Reset to Built-In Engines; licences and source links |
| Analysis | On (default) or off; which library roots; pause on battery (on); event gap (3 hours); subject list and confidence threshold for Sort by Subject; Analyse Again; Delete All Analysis Data (section 36); keep Organise undo history for (30 days) |
| Faces | Off until opted in (R-3901); match threshold; group photos when sorting by person; Delete All Face Data |
| Appearance | Theme (R-2010); pane arrangement presets with a diagram; Reset Pane Sizes |
| Advanced | Network activity log; Clear All Website Data; Export Diagnostics (D-77) |

**R-2010** Themes: System (the accent colour from System Settings), Ocean, Sunset, Forest, Lavender, Graphite, Rose Gold, Aurora and Spectrum (a full colour spectrum). A theme sets the accent for controls, chips and grid selection, and a soft gradient wash behind pane titles that keeps text legible in light and dark appearances. Themes are static: no animation, so idle CPU is unaffected.

---

## 21. Menus and keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New window |
| ⌘T / ⌘W / ⇧⌘T | New tab / close tab / reopen closed tab |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘D | Bookmark this page |
| ⌥⌘B / ⌘Y | Bookmarks / History |
| ⌘L | Focus address field |
| ⌘[ / ⌘] | Back / Forward |
| ⌘R in browser | Reload |
| ⌘. | Stop loading or stop auto-scroll |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Toggle Browser / Extracted / Library pane |
| ⌘F | Filter bar (Extracted) or search field (Library, Organise) |
| ⌃⌘1 / ⌃⌘2 | Collect / Organise section |
| ⇧⌘Y | Save Video from This Page… |
| ⌘O in Organise | Open Folder… |
| ⌘Z / ⇧⌘Z | Undo / Redo the window's last file change, in the Library or Organise (rename, move, copy in, new folder, Move to Trash, sorts); text fields keep their own typing undo |
| ⌘Return / ⌘. in Organise | Apply / Discard the previewed change (only while Organise is shown; never Return or Escape, D-47) |
| ⌘I | Show or hide the Preview pane |
| ⌘K | Clear extracted media |
| ⌘A / ⇧⌘A | Select all shown / deselect |
| Space | Quick Look |
| ⌘S | Save to the save folder |
| ⇧⌘S | Save to… |
| ⇧⌘P | Pull Account… (Downloads pane) |
| ⌘O | Open PDF… (extract its images) |
| ⌘E | Edit the selected item (crop, rotate, rename) |
| ⇧⌘J | Activity |
| ⇧⌘K | Converter |
| ⇧⌘N | New Folder (Library) |
| ⌘⌫ | Move to Trash (Library) |
| ⌘R in Library | Reveal in Finder |
| ⌘+ / ⌘- / ⌘0 | Zoom the page in, out, actual size |
| ⌥⌘+ / ⌥⌘- | Larger or smaller thumbnails |
| ⌥⌘4 | Show or hide Downloads |

Menus: MediaPull, File (New Window, New Tab, Close Tab, Reopen Closed Tab, Pull Account, Save, Save to…, Add Library Folder), Edit, View (panes, Arrange Panes, filter bar, grid size), Go (back, forward, address), Bookmarks, History, Window (tabs, Activity, Converter), Help (MediaPull Walkthrough).

---

## 22. Performance budgets

Budgets are recorded in `scripts/perf-budgets.json` and measured by hand for this personal tool (see Implementation status); the XCTest `measure` blocks and CI enforcement are not built.

| Area | Budget |
|---|---|
| App bundle size | ≤ 800 MB, engines and models included (D-58; 90 MB up to version 1.5) |
| Launch to interactive window | ≤ 1 s on Apple silicon |
| Idle CPU (static page, no jobs) | ≤ 1 % averaged over 60 s; no timers when nothing is pending |
| Helper processes when idle | none (R-403) |
| App process memory, 5,000 items, scrolling | ≤ 250 MB (WebKit processes excluded) |
| Bridge process memory | ≤ 150 MB typical, only while a job runs |
| Ingesting 5,000 candidates | ≤ 200 ms of ingestor time |
| Re-filtering 5,000 items | ≤ 10 ms |
| Grid scrolling | no dropped frames at 120 Hz with 5,000 items |
| Thumbnail cache | ≤ 150 MB; decode at ≤ 2 × cell size rounded up to 128 px, max 768 px; ≤ 4 decodes at once |
| Converting a 12 MP lossy WebP to JPEG | ≤ 400 ms |
| Remuxing a 60 s Reel (copy) | ≤ 1 s |
| Instagram API requests | ≤ 10 per minute (Gentle), enforced by pacing |
| Analysis, first pass | ≥ 15 photos per second, two at a time (measured 26.5 on 640 px photos, 16.7 in the app including checksums) |
| Analysis memory | ≤ 250 MB above idle (measured peak 180 MB) |
| Search, 50,000 images | ≤ 20 ms including the text query (measured 4 ms query + 4 ms scan) |
| Analysis when idle | no analysis CPU when nothing is new or changed |

---

## 23. Errors and edge cases

| Case | Behaviour |
|---|---|
| Signed URL expired | Re-resolve the item (Instagram: re-scan the post; web: re-read from the page if still open), then retry once. |
| Login or error page served with status 200 | Rejected by magic-byte validation; item marked failed with "The site returned a web page instead of media". |
| Private account not followed | Job stops: "This account is private." |
| Account not found or renamed | Job stops: "No account named @name." Stored accounts keep their user id and detect renames. |
| Instagram changed something | `engine_outdated`: "Instagram may have changed. Check for engine updates." |
| Checkpoint or rate limit | Section 11.9. |
| Protected stream | Shown greyed as Protected with the reason; not saveable. |
| `blob:` video only | "Stream (find manifest)", linked to any recorded manifest; otherwise not saveable with an explanation. |
| Cross-origin iframe media | Shown with the frame origin tag. |
| Disk full | Job pauses with "Not enough space on <volume>"; resumes after space is freed. |
| Library root missing or moved | Bookmark resolved; if unresolvable, the root is shown as missing with "Locate…". |
| Destination in iCloud with placeholders | Warning per R-1506. |
| Engine crash | Job fails with the last event and a log reference; the next job starts a fresh process. |
| Engine update fails self-test | Previous version stays active; Settings shows the failure. |
| Very large page (over 20,000 candidates) | Ingestion continues; the grid shows a banner suggesting filters; probing is limited to visible items. |
| Network offline | Jobs wait and resume automatically when the network returns (not for checkpoints). |

---

## 24. Accessibility and localisation

**R-2401** All controls have accessibility labels; grid cells announce type, size and state; the grid, tree and filter bar are fully keyboard-navigable; Reduce Motion disables animated transitions; text respects the system text size where SwiftUI allows.

**R-2402** Version 1 is English only. All user-facing strings live in a String Catalog. Copy is plain and short, without exclamation marks or emoji.

---

## 25. Testing

`scripts/check.sh` runs every automated check:

- **Lint**: networking (`URLSession`, `URLRequest`) only in MediaPullNet, SwiftData only in MediaPullStore, `Process` only in MediaPullEngines, WebKit only in MediaPullBrowser and the browser pane, AppKit only in the app target, no remote loading that bypasses the gate, no file open panel in the browser pane, and no reference to other applications (R-401, R-504, R-508).
- **Swift tests** (`swift test` in `MediaPullKit`, built outside the iCloud-synced folder): sidecar contract and key order, date formatting independent of the user's calendar, forbidden Instaloader-style names over many dates, reserved folder names and name lengths, CDN rules (NYT, X, WordPress, Wikimedia, signed URLs), magic-byte sniffing, the request policy, address parsing and registrable domains, the ingestor merging srcset candidates, filters, image conversion (PNG kept, HEIC to JPEG), SVG handling per layout, the save pipeline (sidecar contents, duplicates, never overwriting), Netscape cookie files with 0600 permissions, engine version and dependency checks, and the real bundled engine (self-test, and the final events of repeated runs are never lost).
- **Network tests** (opt in with `MEDIAPULL_NETWORK_TESTS=1`): the engine update check against PyPI.
- **Bridge tests** (`Engines/bridge/test_egress_guard.py`, run with the bundled interpreter): reads allowed, Instagram GraphQL queries allowed, mutations, uploads, file bodies and other methods blocked, `requests` wrapped.
- **iOS build**: the package builds for the iOS Simulator.
- **End-to-end self-test**: `MediaPull --selftest-url <url> --selftest-out <folder> [--selftest-limit <n>] [--selftest-site] [--selftest-edit] [--selftest-pdf-links] [--selftest-theme <name>] [--selftest-layout <preset>] [--selftest-browser <second url>] [--selftest-idle <seconds>] [--selftest-views]` loads the page in a real window, scrolls it to the end, probes sizes, optionally runs a site-extractor scan, saves every item that passes the default filters into `<folder>/library` (Archive layout, in-memory database, no change to the user's library), and writes `report.json`, `window-extracted.png` (with the largest image in the Preview pane) and `window-saved.png` (plus `window-editor.png` and `window-preview-file.png` with `--selftest-edit`, and `view-library-list.png`, `view-library-columns.png`, `view-extracted-list.png`, `view-organise-list.png` and `view-organise-columns.png` with `--selftest-views`, which also checks row counts, header sorting and that the deepest folder chosen in the columns becomes the pane's folder), then quits. Theme and pane arrangement are restored afterwards. It prints `SELFTEST-CAPTURE <window number> <path>` lines so a script can take real window screenshots with `screencapture -l`.

Planned additions: fixture pages served through an `mediapull-test://` scheme handler, recorded Instagram responses for the bridge, and an egress audit with a recording `URLProtocol`.

**Manual checklist** (needs a person): the drag-and-drop matrix (section 18), Quick Look, an Instagram pull with a signed-in account including a resumed incremental pull, and checkpoint handling.

---

## 26. Build and release

- `scripts/fetch-engines.sh`: downloads the pinned python-build-standalone archive and wheels, verifies each SHA-256 against values committed in the script, trims the standard library, precompiles bytecode, and lays out `Contents/Resources/Engines/`.
- `scripts/build-ffmpeg.sh`: builds the pinned ffmpeg release as a minimal LGPL build (`--disable-network`, `--disable-everything`, then only the needed demuxers, muxers, parsers, bitstream filters, the native VP9 decoder, dav1d for AV1, VideoToolbox encoders, AudioToolbox AAC, and the palette filters).
- `scripts/sign-helpers.sh`: signs every Mach-O inside out with the hardened runtime and timestamp.
- `scripts/check.sh`: lint, `swift test`, bridge tests, iOS Simulator package build, app build.
- `scripts/bundle-engines.sh`: the Xcode build phase that copies the engines into the app and removes extended attributes before signing.
- `scripts/install-app.sh`: builds the Release app and installs it in `~/Applications`.
- Notarized distribution needs a Developer ID certificate: build an archive in Xcode with that identity (the build phase then re-signs every nested Mach-O with the hardened runtime), notarize with `notarytool`, and staple.
- `Resources/Licenses/`: licence texts for every bundled component and a `SOURCES.txt` with exact versions and source URLs (GPL and LGPL obligations).
- `docs/PRIVACY.md`: the read-only contract in plain language.

### 26.1 App icon

The icon is a Liquid Glass icon in Icon Composer's format: `MediaPull/Resources/AppIcon.icon` (an `icon.json` plus SVG layers in `Assets/`), compiled by `actool` into `AppIcon.icns` and the asset catalog, so the system renders its light, dark, clear and tinted appearances. It is meant to sit quietly among system and professional tools in the Dock: a deep ink gradient background (darker in dark appearance) and a stack of three glass photo cards, the back two fainter, with a flowing waveform line in a cyan-to-violet gradient across the front card that reads both as a horizon and as media, and a small warm sun. No arrows or download marks. Edit it in Icon Composer (Xcode > Open Developer Tool) and keep the layers as SVG. Apple's guidance: Human Interface Guidelines, App icons; "Creating your app icon using Icon Composer".

---

## 27. Decisions

| ID | Decision | Reason |
|---|---|---|
| D-01 | Native Swift and SwiftUI, macOS 26, Apple silicon only | Lightweight, same toolchain as the developer's other projects, reusable for iPad |
| D-02 | Direct distribution (Developer ID, notarized DMG), no Mac App Store | App Review guideline 5.2.3 rules out downloaders of third-party media |
| D-03 | Not sandboxed | The bundled helper processes and arbitrary destinations; bookmarks keep sandboxing possible later |
| D-04 | Instagram and site extraction through bundled gallery-dl (with yt-dlp and ffmpeg), not a native reimplementation | gallery-dl is maintained against Instagram changes almost weekly; engine updates keep pace without app releases |
| D-05 | Video default: highest resolution; re-encode to HEVC only when the higher resolution is VP9 or AV1 only | Keeps resolution and playability; one generation of loss only when unavoidable |
| D-06 | Animated images become GIF by default | Most compatible normal format; ffmpeg palettes keep quality acceptable |
| D-07 | Site extractor scans in version 1 | Nearly free once gallery-dl is bundled; gives originals on many popular sites |
| D-08 | One Instagram identity in version 1 | Simplicity; one website data store |
| D-09 | Archive layout is the default | It keeps metadata that downstream tools can use and loses nothing |
| D-10 | Web pages are never grouped as posts in sidecars | A page can have hundreds of images; grouping would be meaningless |
| D-11 | Collab posts go in the pulled account's folder, owner recorded as `owner_username` | The user asked for that account's media |
| D-12 | Sidecars exclude location, comments, engagement counts and tagged users | Privacy and size; not needed by importing tools |
| D-13 | Audio is Plain-only. SVG is kept as SVG in Plain folders and converted to PNG in Archive folders (4 times its own size, 1024 to 4096 px on the long side; a setting turns this off) | Archive is limited to formats importing tools accept; skipping SVGs lost too many diagrams and maps |
| D-14 | HDR gain maps are not preserved in version 1 | ImageIO support varies; revisit later |
| D-15 | Instagram identifiers are strings everywhere | They exceed the range of JSON numbers in many readers |
| D-16 | Page sessions accumulate across navigations until cleared | Users browse several pages of a gallery and collect as they go |
| D-17 | No blocking of a site's own analytics in the pane | It can break sign-in |
| D-18 | The address field has no search engine | Avoids sending typed text to a third party |
| D-19 | No DRM or AES-128 encrypted streams | Out of scope and protected content |
| D-20 | Weekly engine update check on by default, notify only | Instagram breaks often; installing stays the user's choice |
| D-21 | Plain-http media downloads allowed, marked insecure | Older sites still serve media over http; requests are GET-only |
| D-22 | WKWebView rather than SwiftUI's WebView | Needs a subclass to refuse drops, full UI delegate control and per-frame script messages |
| D-23 | Engines run from pure-Python wheels on one bundled interpreter | Updates never add unsigned native code |
| D-24 | Engines keep their own User-Agent instead of the browser pane's (overrides R-806 for engines) | gallery-dl's Instagram extractor receives lower-quality video with a non-Chrome User-Agent |
| D-25 | The egress guard allows POST for GraphQL read queries on any host (no files, small body, path containing `graphql`, operation names that are queries and name no write action) | Several site extractors read through GraphQL; the write-action rule still blocks every mutation |
| D-26 | File fingerprints for duplicate detection are cached in `Application Support/MediaPull/fingerprints.json`, and only files of the same byte size are ever hashed | Fast and simple; SwiftData keeps roots, accounts, the archive and job history |
| D-27 | The bundled Python ships as sourceless bytecode without the embedding library, `unittest` or the interactive shell; updated engines keep their sources | The app is 70 MB instead of 112 MB |
| D-28 | Site-extractor items are saved under `<root>/<site host>/`; the uploader is recorded as `author` (or as `username` when the scan was of a user page) | One folder per site instead of one per uploader |
| D-29 | Web-page `post_id` is a 12-hex-digit FNV-1a hash of the page URL | Core stays Foundation-only; the value only needs to be stable |
| D-30 | Both media grids use NSCollectionView in the platform layer | Multi-item drags with file promises, rubber-band selection and smooth scrolling at thousands of items |
| D-31 | Known advertising and tracking hosts are flagged as icons (hidden by default), and URLs with non-media extensions (html, js, css, json, pdf and similar) are ignored | Pages otherwise list tracking pixels and ad frames |
| D-33 | Images inside PDFs are taken from the file as stored, never rendered from pages: JPEG data is copied byte for byte; everything else (Flate, JPEG 2000, CMYK, indexed, with soft masks) is decoded once and written as PNG | The original resolution and quality of each embedded image |
| D-34 | Editing a library file replaces it and moves the original to the Trash; "Save as Copy" keeps both. A rename alone never re-encodes. Edited images are written as JPEG at quality 1.0 or PNG, keeping EXIF except orientation. (Amended in 1.8: a JPEG that is only rotated or flipped keeps its image data exactly and gets a new orientation tag; only a crop re-encodes) | Simple, undoable through the Trash, no quality loss beyond the edit itself |
| D-35 | A custom name for an extracted item is used when it is saved; in Archive folders the date prefix is added in front of it if missing, so the naming contract holds | Rename without breaking the archive format |
| D-36 | Instagram requests are never retried automatically (no retries, no 429 back-off); error bodies are read for challenge, login, feedback and rate-limit signals; only the person's Resume reopens Instagram after a checkpoint | R-1114, after review |
| D-37 | A resumed pull continues from the saved cursor (reported after every page) with the known-item list but without the early stop; a new pull never starts from a stale cursor (amended by D-80: an update of a folder with a stored cursor first pulls the newest posts with the early stop, then continues from the cursor) | Interrupted pulls continue without re-fetching or skipping new posts |
| D-38 | The date window is applied by the bridge: old pinned posts are skipped instead of ending the listing | One old pinned post must not end a pull |
| D-39 | The inspector and the editor sheet become one Preview pane, and panes can be arranged in columns and stacks | Requested: a separate preview pane and free pane positions |
| D-40 | POST from the engines is allowed only to `instagram.com` and its subdomains at `/graphql/query` and `/api/graphql`; GET and HEAD may not carry a body; GraphQL documents containing `mutation` or `subscription` anywhere, denied words in any letter case, and multipart, binary or media bodies are refused | Code review found bypasses of R-505 |
| D-41 | A pull keeps its resume cursor and is not marked as pulled unless the engine finished cleanly; otherwise the job fails with "Pull again to continue" | An incremental pull would otherwise never fill a gap left by a failed page |
| D-42 | File paths reported by the engines are used only if they resolve inside the job's staging folder (checked in the bridge and in Swift) | Site metadata can put `..` into engine paths |
| D-43 | Probe follow-up ranges are sent only when the server honours ranges, and read at most the requested bytes; untrusted sizes (MP4 boxes, srcset widths, PDF dimensions, engine numbers) are clamped | Code review: crashes and full downloads from hostile or odd servers |
| D-45 | Extracted Media collects from every tab of a window, with a "This Page" chip for the selected tab, instead of a separate collection per tab | Matches the existing collection across navigations; one grid and one selection per window |
| D-46 | Bookmarks and history are JSON files in Application Support rather than SwiftData | Small, user-readable, easy to back up or delete; never part of the media library |
| D-47 | The inline editor has no Return, Escape or bare-key shortcuts; rotation is ⌥⌘[ and ⌥⌘] | Keys typed into a web page or the address field must never save, cancel or rotate an edit |
| D-48 | Browser controls (navigation, address field, bookmarks, history) live in the Browser pane; the window toolbar is compact and holds only app-wide actions | More room for content; browsing controls stay with the pane wherever it is placed |
| D-49 | The app is renamed MediaPull (bundle id `com.yenkai.MediaPull`, modules `MediaPull*`, drag type `com.yenkai.mediapull.items`, test scheme `mediapull-test://`); the sidecar's informational key `instapull_version` becomes `mediapull_version`. No other sidecar key, the date format, naming rules or reserved names change, and importers ignore this key | The product name is MediaPull; the key names the app that wrote the file |
| D-50 | Duplicates are found with checksums, two perceptual hashes and a colour grid, never with learned models, and are only marked, never removed automatically | Deterministic results that can be explained; the person decides what to delete |
| D-51 | Frames and trimmed videos add the informational sidecar keys `frame_time` and `trimmed_from`; frames drop `num`, `count` and `duration`. No existing key, the date format or the naming rules change | Derived files keep their source's details without joining its carousel |
| D-52 | New folders: `tagged/` and `reposts/` inside an account folder; `Saved posts/` and `Hashtags/<tag>/` at library level; `<account>/Account details/` for the profile JSON and follower CSVs (not media). Instagram usernames cannot contain spaces, so these names never clash with an account folder. Sidecar keys and subcategories are unchanged: tagged, reposted, saved and hashtag posts are `posts`; stories from followed accounts are `stories`; highlight covers are `highlights` | Every gallery-dl Instagram source has a predictable place in the archive |
| D-53 | Instagram pulls require a signed-in session; no signed-out engine route | Tested signed out (R-1101): every engine route failed, and the browser shows only preview-size media |
| D-54 | Instagram media is sorted into a folder per type by default (`posts/`, `reels/`, `profile pictures/`, alongside `stories/`, `highlights/`, `tagged/`, `reposts/`), with a setting for the old flat layout; this replaces the "Reels in a subfolder" setting | Requested: several content types in one account folder stay organised; sidecars and names are unchanged |
| D-55 | The egress guard allows POST to YouTube's `/youtubei/v1/player` and `/youtubei/v1/next`, which read one video's details; writing actions live at other paths and stay blocked | Without it yt-dlp cannot read any YouTube video inside MediaPull |
| D-56 | A video format chosen by hand in the Save Video sheet is kept exactly as downloaded; WebM and M4A are saved without a metadata file in Archive folders (an exception to R-1502 the person asks for) | Requested: choose the format of a saved video |
| D-57 | Learned models are allowed for content labels, recognised text, image–text search, visually similar sets and faces (section 36). Duplicate detection is the exception and stays deterministic under D-50 | Requested: find and sort media by what it shows; duplicates stay explainable |
| D-58 | Models are bundled in the app, never downloaded. Each is pinned by SHA-256 in `scripts/models.lock` like the engines, its licence goes in `Contents/Resources/Licenses/`, and its licence is checked for use in a personal, non-commercial tool. The bundle budget is 800 MB, models included | Offline by design; reproducible builds; licences on record |
| D-59 | Analysis runs only on the Mac and never uses the network. Place names come from bundled GeoNames data (cities of 1,000 people or more, regions and countries; CC BY 4.0, credited in About), never from Apple's online geocoder or MapKit; Vision requests that download assets and Core ML model collections are not used | Privacy contract unchanged: nothing leaves the Mac for analysis |
| D-60 | Analysis results (labels, text, embeddings, places, faces) live in `~/Library/Application Support/MediaPull/Analysis/`, never in library folders. They are keyed by the file's SHA-256 and the model version, so moved or renamed files keep their results and only new or changed files are analysed after the first pass | R-601 holds; analysis is incremental |
| D-61 | Face data is biometric: face analysis is off until the person accepts an opt-in sheet; "Delete All Face Data" removes faces, people, names, corrections and face vectors in one step; face files are excluded from Time Machine; face data never goes into metadata files or exports | Requested: clear opt-in and one-step deletion |
| D-62 | Organise is a second section of the window, chosen with tabs after the window title (Collect · Organise). It works on any local folder and fetches nothing. (Its two layouts became the Source, Organise and Target panes in 1.6, D-69, with the target optional, D-68) | Requested; both ways of organising are common, so both are modes of one section |
| D-63 | Every Organise operation is recorded in a journal in Application Support and can be undone, a whole automatic sort as one step, including after relaunch. Deleting always means moving to the Trash | Requested: every operation reversible |
| D-64 | Sort into Folders by Person puts a photo of several people into each person's folder as an APFS clone (a full copy where the volume cannot clone, shown before the sort), each copy with its own metadata file. In Archive-layout folders group photos go into one shared `Group photos/` folder instead. Settings also offers the shared folder everywhere and "first person only" | Requested; in Archive folders the archive's reader would count each copy as a separate post |
| D-65 | Sort into Folders by Subject files an item under a subject only when the model's confidence is above a threshold (adjustable in Settings); everything else goes to `Unsorted/` | Requested: no guessing |
| D-66 | A folder named like a person that holds most photos of an unnamed face group is offered as that group's name; the name is applied only after one click | Chosen by the person: suggest, never name silently |
| D-67 | Models (chosen for accuracy; licences set aside for this private tool at the person's request): **MobileCLIP2-S3** for image–text search, subjects and similar sets (768-d; 79.0 % of COCO captions find their photo in the top 5 of 3,000; top tag right for 92.7 %); **AdaFace IR-101 (WebFace12M)** for faces (99.80 % on LFW; grouping 158 people at 0.34 gives 99.9 % pure groups with 99.9 % of each person's photos together); **SCRFD-10G** for faces and landmarks; Apple Vision for labels and text; GeoNames for places. About 620 MB in all; the whole pipeline analyses 26.5 photos a second, peak 180 MB (`docs/spikes/analysis-models.md`) | Requested: the most accurate current models that fit |
| D-68 | Organise works on any folder in three ways: in place, copying to a target (the source untouched; how media is imported into the library) and moving to a target. Copies are APFS clones. The source defaults to the MediaPull library; a target is opt-in, so every source starts in place, and changing the source keeps the chosen target. (Amended in 1.6: opening a folder outside the library no longer picks the library as the target by itself) | Requested: in-place and non-in-place organising, importing, no fixed rules for the library, and a target only when the person wants one |
| D-69 | One pane system for the whole window: Organise's Source, Organise and Target panes and Collect's new Downloads pane are arranged, stacked and hidden like the others, with the same headers. Sheets are replaced by panes and inline previews; pop-ups only for what needs attention now | Requested: a cohesive interface with few pop-ups |
| D-70 | Collect has one save folder per window, the folder selected in the Library pane (the default library folder at first), named beside the Save button. Save, the Downloads pane and the editors use it; any folder on the Mac can be chosen without becoming a library folder. "Save to Last Folder" is removed | Requested: the library by default, an easy change to any folder; three separate destinations (Save, Save Here, last folder) were confusing |
| D-71 | Every gallery-dl site gets per-site options: its name, the parts of a profile, its media switches, sign-in state and remembered choices, from a catalogue generated from the bundled gallery-dl and from the extractor itself. Checked against gallery-dl's own test addresses for every site | Requested: every source with as much attention to detail as Instagram and YouTube |
| D-72 | The egress guard allows the read-only POSTs gallery-dl's sites need, listed by host and path from an audit of every POST in the bundled gallery-dl (49 reads, 8 tokens; logins and the 7 account actions stay blocked), with a body check per endpoint. Re-audit when gallery-dl is updated. YouTube's `/youtubei/v1/browse` is allowed beside player and next, since yt-dlp reads every page of a channel or playlist after the first through it (R-3505). This amends D-40 | About 40 sites, DeviantArt among them, could not download at all because a public token or a search is a POST |
| D-73 | A download a web page offers is saved where the person chooses in the standard save dialog (starting in the save folder), instead of being listed in Extracted Media. It is a read, like any download | Requested: clicking a download link in the browser should download the file |
| D-74 | File names keep the zero-width joiner and non-joiner (U+200C, U+200D); control codes and text-direction overrides are still replaced and zero-width spaces removed. Names already saved are not changed. This amends R-1510 | Persian and Hindi words and joined emoji (a family, a flag) were broken by an underscore |
| D-75 | A file from an engine is keyed by its post and its number in the post (`category:id:num`) whenever the post numbers its files, for `id` as well as `post_id`. Keys already recorded for such sites change once: their next incremental pull may fetch those files again, and they are recognised as duplicates, not saved twice | On sites that give every file of a post the post's id (Pixiv, Kemono), all files of a post had one key, so scans kept one and incremental pulls skipped the rest |
| D-76 | The folder panes (Library, Organise Source and Target) and Extracted Media can be shown as Icons, a List or Columns, like the Finder (Extracted Media: Icons and List, since it is not a folder). Each pane keeps its own view; ⌘1 to ⌘3 switch the focused pane. Column view replaces the folder tree and the search and filter row, and sorts each column by name with folders first. Amends R-1701 and R-3802 | Requested: the same view choices as the Finder |
| D-77 | Version 1.8 aligns the spec with the app where the app's behaviour is simpler and sound, instead of adding options that add little: R-305, R-306, R-308, R-504, R-803, R-902, R-911, R-918, R-919, R-1002, R-1005, R-1006, R-1605, R-1903, R-3701 and R-3906 are amended in place; Settings > Advanced keeps the network log and Export Diagnostics and drops download concurrency limits, the insecure-http switch and verbose engine logging; there is no separate Browser or Organise settings pane, no pop-up setting (pop-ups always open as tabs) and no inline-SVG setting | A requirement-by-requirement pass (docs/CONFORMANCE.md) found these written but never built; the person asked for a simple app without a pile of options |
| D-78 | A folder holds an Instagram account when four in five of a sample of its metadata files name that account; the account folder is the highest such folder, so a folder renamed, moved in the Finder or made before 1.8 is still recognised. A pull of an account goes into its existing folder when the save folder is that folder, is inside it, or contains it (whatever it is called); otherwise a new folder is made beside any other account's folder, never inside it. The metadata always names the account, never the folder | Requested: fetch an account again into the folder that already has it, adding only what is missing, without ` 2` copies or a nested folder |
| D-79 | Every pull into an account folder skips the items that folder already has, recognised from file names (`<date>_<code>_<NN>`, whose code is the media id) or, for renamed files, their metadata (`media_id`, or `post_id` and `num` for posts and Reels). MediaPull also remembers per folder (Application Support, found again through a bookmark) the items it ever saved there and where an interrupted update stopped. **Update** skips both, so files deleted from the folder on purpose stay deleted, and stops after 12 known posts. **Find Missing** walks the whole account and adds everything the folder lacks, including deleted files; it replaces the Verify mode. A different folder is independent: a pull into a new folder makes a complete copy | Chosen by the person: Update must never bring back deletions, and a second folder is a complete copy |
| D-80 | An account folder selected in the Library shows **Update @name** in the pane's title row: one click starts an update with the account's remembered media choices and pace, without the form. The folder's context menu adds **Find Missing from @name**, and a folder that contains several remembered account folders has **Update All Accounts (N)**, run one after another. An update that stopped part way first pulls from the top with the early stop, then continues from where it stopped (amends D-37) | Requested: a one-click "fetch updated data" for folders that already hold an account |
| D-81 | Instagram metadata files gain `media_id`, the id of the one file (a string, like `post_id`), so files can be matched exactly even after they are renamed. Informational, like `extractor`; older files without it are matched by name or by `post_id` and `num` | Exact matching for renamed files |
| D-82 | MediaPull offers a Services menu entry and accepts dropped links, both of which only fill in the Downloads pane. There is no URL scheme or other way for another app to start a download | Requested: send a link from another app without copying and pasting; nothing outside MediaPull may start network work on its own |
| D-83 | Two explicit tidying actions, both through the operation journal so ⌘Z undoes them: Trash Extra Copies (one file of each duplicate group stays) and Check Folder (reports; trashes orphaned metadata files only when asked). Nothing is still ever removed automatically (D-50 holds) | Requested features that keep the library tidy without new panes or settings |
| D-84 | Web saves are remembered like engine saves, under `web:` and the SHA-256 of the item's address, in the same table (Application Support), so items already saved are marked when they are extracted again. A record whose file is gone is ignored | Requested: see at a glance what is already in the library, without a new control |
| D-44 | Concurrency is 6 requests per host and 16 in total (Instagram's CDN stays at 2); identical content saved concurrently is reserved by checksum so only one copy is written; cancelling a job stops a running ffmpeg | Faster probing of large pages; correct duplicates; cancel means stop |
| D-32 | When a version of an item cannot be converted (for example AV1 on a Mac without an AV1 decoder), the next version is tried; only if none works is the original codec kept, with a note | Prefers a playable H.264 or HEVC copy whenever the page offers one |

---

## 28. Milestones

Riskiest work first. Each milestone ends with a check that can be demonstrated.

| Milestone | Scope | Exit criterion |
|---|---|---|
| **M0 Engine spike** | Signed bundled Python with gallery-dl, yt-dlp and ffmpeg inside a hardened-runtime test app; bridge with egress guard; cookie export from a pane sign-in; scan and download of an account; DASH merge; VP9 to HEVC re-encode; notarization of the layout | A public account with 150+ posts is scanned and downloaded with no failures, at resolutions matching the browser; a DASH Reel merges to MP4; a notarized test build runs the helpers; `docs/spikes/M0.md` records the bridge `fetch` method, the exact gallery-dl options, and measured rate limits |
| **M1 Scaffold and shell** | Project, package, modules, lint and format, git hooks, `scripts/check.sh`, the three-pane window, the browser pane with persistent store and read-only protections | `check.sh` passes, including the iOS Simulator package build; file inputs and file drags are inert in the pane |
| **M2 Gate and save pipeline** | `NetworkGate`, egress log, download queue, save pipeline, both layouts, sidecars, name templates, image conversion, Converter window | Golden sidecar, forbidden-name property, reserved-name, converter fixture and egress audit tests pass |
| **M3 Instagram** | Pull sheet, Pull and Scan Only, single posts, stories, highlights, profile picture, incremental sync, resume, checkpoints, engine updates | A second pull of the same account downloads nothing and makes at most 2 API requests; a recorded checkpoint pauses jobs and opens the page; an engine update installs, self-tests and rolls back |
| **M4 Web extraction** | `extract.js`, ingestor, grid, filters, inspector, probing, CDN rules, streams, site extractor scans | All fixture pages produce their expected items; the 5,000-item budgets pass; an HLS fixture saves as playable MP4 |
| **M5 Library and drag and drop** | Library pane, folder operations, FSEvents, the drag and drop matrix, Quick Look | The drag and drop checklist passes |
| **M6 Release** | Budgets, accessibility pass, PRIVACY.md, licences, notarized DMG | The notarized DMG passes the egress audit and all budgets |

---

## 29. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Instagram terms and account restrictions | The signed-in account may be challenged or restricted | Clear warnings (R-201), Gentle pacing, one job at a time, no automatic retries, manual resume |
| Instagram API changes | Pulls break | Bundled gallery-dl, one-click engine updates, `engine_outdated` detection, recorded fixtures |
| Signing and notarizing an embedded Python | Release blocked | Retired first in M0 |
| VP9 or AV1 only at the highest resolution | Lower resolution or one generation of loss | Codec policy with a clear default and alternatives |
| WebP to JPEG generational loss | Slight quality loss | Prefer normal-format variants, `Accept` header negotiation, quality 1.0 with 4:4:4, PNG for lossless sources |
| Grid performance at 5,000 items | Jank | Snapshot throttling, downsampled thumbnails, `NSCollectionView` fallback |
| Signed URLs expiring during long jobs | Failed items | Expiry tracking and re-resolution |
| Library roots inside iCloud | Placeholders unreadable by other tools | Default root in `~/Pictures`, warning per root |
| Instagram's largest image is not the original upload | User expectation | Stated in the UI and recorded dimensions in sidecars |
| GPL and LGPL obligations of bundled engines | Licence compliance | Licences, `SOURCES.txt`, unmodified engines, LGPL ffmpeg |
| App size (about 75 MB without models, up to 800 MB with them) | Heavier than a pure Swift app | Trimmed runtime, minimal ffmpeg, arm64 only, models chosen for size (D-67) |
| Model licences change (MobileCLIP's weights moved to a research-only licence in 2025) | Unclear right to use a model | Pin the reviewed revision with its licence text; prefer MIT or Apache models (D-67) |
| Wrong faces grouped together | A photo in the wrong person's folder | Thresholds, corrections that persist, preview before sorting, undo |
| Analysis load | Battery and heat | Background priority, two files at a time, pause on battery and heat |

---

## 30. Open questions

- **Q-01** Should a second Instagram identity (a separate data store) come soon after version 1?
- **Q-02** Should EXIF `DateTimeOriginal` be written into converted JPEGs from Instagram, or are file dates and sidecars enough? (Current answer: not written; converted files keep only the source's metadata.)
- **Q-03** Should yt-dlp also be offered as a page scanner for video sites (embedded players), alongside gallery-dl site extractors?
- **Q-04** Should scheduled background syncs of chosen accounts be added after version 1 (useful for stories)?
- **Q-05** iPad and iPhone: is a native Instagram engine worth building, or should the mobile versions cover web extraction only?

---

## 31. Images inside PDFs

**R-3101** MediaPull lists the images embedded in PDFs, at their original resolution (D-33):

- **PDFs in the browser pane**: when the pane shows a PDF, its images are extracted automatically and appear in Extracted Media, grouped under the document.
- **PDFs linked from a page**: links to PDFs (`.pdf` links, `/pdf/` paths, links labelled "PDF", and PDFs in iframes, embeds and objects) are collected. The header shows "PDFs on This Page (N)" with "Extract Images from All PDFs" and the individual documents. Downloads go through the gate with the page's Referer and first-party cookies, and anything that is not a PDF is rejected.
- **PDFs on this Mac**: File > Open PDF… (⌘O), the PDF menu in the Extracted pane header, or dropping PDF files on the Extracted grid.

**R-3102** Extraction walks every page's resources (including inherited resources and nested form objects), takes each image object once (the same object reused on several pages, or identical data, appears once), and skips images smaller than 24 px on either side and stencil masks. Password-protected PDFs are reported as such.

**R-3103** Extracted images behave like any other item: filters, the Preview pane (which shows the PDF page), editing and saving. In the Archive layout they go to `<root>/<site host>/` (or `<root>/PDF/` for local files) named `<date>_<index>_<document> p<page> <n>.<ext>`, with `subcategory` `pdf`, `description` "Page N of <document>" and `page_url` set to the PDF's web address (never a local path).

## 32. Editing

**R-3201** The editor (⌘E, the edit button in the Preview pane's title bar, "Edit" in the item details and in both grids' context menus) opens inside the Preview pane and offers: rotate left and right, flip horizontally, crop with a draggable box (corner handles, drag inside to move, rule-of-thirds guides) and aspect presets (Free, Original, Square, 4:5, 3:4, 16:9, 9:16), reset, and rename. The output size is shown live. Images are edited at full resolution with their camera orientation applied.

**R-3202** For a **library file**: Save replaces the file and moves the original to the Trash; Save as Copy writes a new file next to it. The sidecar follows the file and records the new width, height, checksum and `"edited": true`. A rename without edits only renames (file and sidecar). Videos and animated images can be renamed only.

**R-3203** For an **extracted item** (not saved yet): Save to Library or Save to… writes the edited image through the normal save pipeline with its source metadata; "Keep Name Only" stores a custom name that every later save uses (D-35).

## 33. Duplicates in the Library

**R-3301** The Library pane marks files under the same library folder that are copies of each other: an orange frame and badge for a file with a byte-for-byte identical twin, a purple frame and badge for one that only looks the same. A bar under the folder title shows progress while checking, how many shown files have matches, a colour key and an "Only Duplicates" toggle, which lists just the matched files with copies side by side. Each matched file's context menu has "Copies and Look-alikes", and the Preview pane lists the other copies with their paths; choosing one opens its folder and selects it.

**R-3302** Detection is deterministic, with no learned models:

- Identical: SHA-256 checksums, computed only for files that share a size.
- Same or similar picture: two 64-bit perceptual hashes of a small greyscale copy (pHash, the signs of the 63 lowest-frequency DCT coefficients of a 32×32 copy against their median; dHash, brightness differences across a 9×8 copy), plus the average colour of each cell of an 8×8 grid, because the hashes see only brightness. Two pictures match when both hashes are within the threshold and the colours agree.
- Nearly flat pictures (a blank frame, a solid colour) get no perceptual hash and are only ever matched as identical files.
- Candidate pairs come from eight 8-bit bands of the pHash (two hashes within 7 bits of each other share at least one band), so large libraries are not compared pair by pair; matches are joined into groups.

**R-3303** Settings (Library menu and Settings > General > Duplicates): "Highlight Duplicates" (on by default) and what counts as a duplicate: Identical Files Only; Same Picture (resized or re-saved: hashes within 4 bits, every colour cell within 14 of 255; the default); Similar Pictures (light edits such as a small crop or a watermark: hashes within 7 bits, three quarters of the colour cells within 20). The same product photographed in another colour is not a duplicate at any setting.

**R-3304** Checksums and fingerprints are cached in `~/Library/Application Support/MediaPull/duplicates.json` by path, size and modification date, so only new or changed files are read again; the folder is re-checked whenever its contents change. Hashing runs off the main actor, four files at a time. Nothing is deleted or moved automatically.

**R-3305** **Trash Extra Copies…** in the duplicates bar (shown only when the folder has duplicates, D-83) keeps one file of each group that has a file in the folder: the one with the most pixels, then one with a metadata file, then the oldest, then the shortest path. A confirmation says how many files go, how much space that frees and how many groups only look alike; the files then go to the Trash as one operation, with their metadata files, and Undo puts them all back.

## 34. Video frames and trimming

**R-3401** Editing a video (⌘E, the edit button in the Preview pane's title bar, "Edit Video" in the item details and context menus) opens the video editor in the Preview pane: the system player with frame stepping, Save Frame, Trim, the rename field and the length. Extracted videos are downloaded through the gate first; streams must be saved before they can be edited.

**R-3402** Save Frame writes the frame being shown, exactly (no time tolerance), at the video's full resolution with its rotation applied, as a lossless PNG named `<video name>_frame_<MM>m<SS-mmm>s.png`. Library videos get the frame next to them; extracted videos send it to the library through the save pipeline.

**R-3403** Trim uses the player's trim bar to choose the part to keep. Trimming never re-encodes: the samples are copied (passthrough) and the cut points are kept exact with an edit list. A library video can be saved as a copy (`<name>_trimmed.mp4`) or replace the original, which goes to the Trash; an extracted video is saved trimmed to the library.

**R-3404** A frame or trimmed copy of a library video gets a copy of the video's metadata file with updated fields: for frames `width`, `height`, `sha256`, `edited` and `frame_time` (seconds), without `num`, `count` and `duration` so the frame is not grouped into the post's carousel; for trimmed videos `duration`, `sha256`, `edited` and `trimmed_from` (start and end in seconds of the original). Names keep the date prefix of the video they came from, so the archive naming rules hold.

## 35. Saving videos from video sites

**R-3501** On a page holding a video, "Save Video…" (a button in the Browser pane's navigation bar on YouTube, Vimeo, Dailymotion, Twitch and TikTok video pages; File > Save Video from This Page, ⇧⌘Y, and the Extracted pane's actions menu on any page) opens a sheet. The bridge's `video_info` operation asks yt-dlp for the page's formats without downloading anything; the sheet shows the title, uploader, length, date and thumbnail.

**R-3502** The person chooses:

| Format | yt-dlp selection | Saved as |
|---|---|---|
| MP4, best quality (default) | best video and audio at or under the resolution | MP4; VP9 or AV1 converted to HEVC per the codec setting (section 16.3) |
| MP4, H.264 (plays everywhere) | H.264 video and AAC audio only | MP4, never converted |
| MP4, original codec | best video and audio, any codec | MP4 exactly as merged (often AV1 or VP9) |
| WebM, original | WebM video and Opus audio | WebM exactly as sent |
| Audio only, M4A | the best AAC track | M4A |

and a resolution from the heights that format actually offers for this video (with 4K and 2K and frame rates over 30 marked), or "Best available". Protected (DRM) formats are never offered. The sheet estimates the size (reported size, or bitrate times length) and says when best quality will have to convert, which is slow at 4K.

**R-3505** More Options (yt-dlp): the whole playlist or channel the page belongs to, with an item range, a maximum count and an upload date range; subtitles as uploaded or automatic, in chosen languages, saved beside the video as `<name>.<language>.vtt`; the thumbnail (as JPEG) and description (`<name>.description.txt`) beside the video; and a download speed limit. Members-only and age-checked videos use the browser's sign-in for that site.

**R-3503** The download runs as a job with progress through the bridge's `stream` operation and the save pipeline. Files go to `<library>/<site>/<uploader>/`, named `<upload date>_<title>`. MP4 files get a metadata file (`category` the site, `subcategory` `video`, `username` the uploader, `post_id` the video id, `date` the upload date, `description` the title, `post_url` the page). WebM and M4A are kept exactly as chosen and saved without a metadata file, because the archive's metadata files describe only its formats (D-56).

**R-3504** YouTube reads a video's details with a POST to its player API; the egress guard allows exactly `/youtubei/v1/player` and `/youtubei/v1/next` on YouTube's hosts and nothing else there (D-55). Checked in November 2026: the bundled yt-dlp lists YouTube formats from 144p to 2160p and downloads them, although without a JavaScript challenge solver it warns that some formats may be missing. If YouTube starts enforcing that challenge, the fix is to bundle yt-dlp's solver scripts and let it use a JavaScript runtime.

## 36. Media analysis

**R-3601** MediaPull analyses the images and videos in library roots and in folders opened in Organise (section 38). Videos are analysed from a frame a tenth of the way in. For each file it records:

- content labels with confidence (Apple's built-in image classifier);
- recognised text (Apple's text recognition);
- an image embedding for free-text search and visually similar sets (a bundled image–text model, D-67);
- technical facts: pixel size, orientation, aspect ratio, format, still or animated, video length, camera make and model;
- the capture date and GPS position from EXIF, and a place name (R-3605);
- whether it looks like a screenshot (R-3604) and its dominant colour (R-3606);
- where the faces are, for the face filters (a bundled face detector, D-67); recognising who they are only after the opt-in (section 39).

**R-3602** Learned models are used for labels, text, embeddings and faces (D-57); duplicate detection (section 33) never uses them (D-50). Every model is bundled and pinned (D-58); none is downloaded at run time. Core ML runs on the Neural Engine and CPU, leaving the GPU to the window.

**R-3603** Text recognition uses Apple's accurate mode once a background probe shows it works, and fast mode otherwise. On macOS 27.0 accurate mode stalls Vision for up to a minute and then fails (a known system problem), so it is not tried there. Analysis never runs on the main actor. It runs at utility priority (background priority was throttled about tenfold in the benchmark), two files at a time, and pauses on battery (setting, on by default), in Low Power Mode and when the Mac is hot; Activity shows an Analyse job with Pause and Resume. The first pass covers every file; after that only new or changed files are analysed (path, size and modification date; the content checksum decides whether earlier results still apply, so a moved or renamed file is not analysed again). Library roots and open Organise folders are watched with FSEvents. Results carry the model version; after a model changes, files are re-analysed in the background.

**R-3604** Screenshots are recognised by deterministic signs only: the system's screen-capture marker on the file (or its EXIF comment), a file name starting with "Screenshot", or a PNG or HEIC whose pixel size is a common screen size with no camera EXIF. The image classifier's "utility image" score was tested and rejected: it flagged 13 % of ordinary photos and missed most text images.

**R-3605** Place names come from bundled GeoNames data compiled at build time into a compact index (D-59): the nearest place within 50 km of the GPS position, shown as "City, Region, Country". Nothing is looked up online. Location stays in MediaPull's own data; metadata files still never contain it (R-1507).

**R-3606** The dominant colour comes from the 8×8 colour grid that duplicate detection already computes (R-3302), weighted by saturation and named from a fixed palette: red, orange, yellow, green, teal, blue, purple, pink, brown, black, grey, white.

**R-3607** Results live in `~/Library/Application Support/MediaPull/Analysis/` (`Analysis.store` and memory-mapped vector files), never in library folders (R-601, D-60). Settings > Analysis: on or off, which library roots, pause on battery, Rebuild Analysis, Delete All Analysis Data.

## 37. Library sort, filter and search

**R-3701** *(Amended by D-77: sort and filter choices are kept between launches for the Library as a whole, not per window.)* The Library pane's header has a Sort menu, a Filter popover, "Include Subfolders" and a search field (⌘F when the Library has focus). Sort and filter choices are kept per window between launches.

**R-3702** Sorts, each ascending or descending: Date (the EXIF capture date, then the metadata file's date, then the file's creation date), Name, File Size, Pixel Size, Video Length, Source (account or site, then post, from metadata files), Camera, and Events (grid sections that start wherever the gap between neighbouring dates is longer than the event gap, 3 hours by default).

**R-3703** Filters combine with AND, and the values chosen within one filter with OR: kind (still, animated, video), format, orientation (landscape, portrait, square), aspect ratio, pixel size, video length, camera, source (account, site), screenshots or photos, duplicates (section 33), visually similar sets (R-3705), dominant colour, place, content tags, faces (with faces, without faces, portraits: one face covering at least a tenth of the picture; group photos: three or more faces) and people (section 39). Filters that need analysis show its progress and include only analysed files.

**R-3704** Search finds files by name, by the metadata file's description and username, by recognised text, by content tags, and by free text through the image–text model ("dog on a beach"). Text matching ignores case and accents. Exact text and tag matches come first, then images by similarity to the query above a minimum. Search covers the selected folder, or everything below it with Include Subfolders.

**R-3705** Visually similar sets are images whose embeddings are close (threshold from the benchmark, D-67), joined into groups. They are looser than duplicates and are not marked in the grid; they appear as a filter and as the "Group Similar" sort.

**R-3706** Sort into Folders by Subject (in Organise, and from a Library folder's context menu, which opens Organise) uses a fixed subject list (people, dogs, cats, birds, other animals, food, nature, beach, mountains, city, buildings, vehicles, documents, screenshots, art) plus subjects the person adds as words. Each file goes to the subject with the highest confidence if it is above the threshold (Settings > Analysis); everything else goes to `Unsorted/` (D-65).

## 38. Organise

**R-3801** Organise is the second section of the window, chosen with the tabs before the window title (Collect · Organise; ⌃⌘1 and ⌃⌘2) (D-62). It works on any local folder the person opens (Open Folder… ⌘O, dropping a folder from Finder, or a library root), only rearranges local files and never fetches anything. Switching sections never reloads the Browser pane.

**R-3802** Organise has three panes, arranged like Collect's (movable, stackable, hidable; D-69):

- **Source** (left): any folder, the default library folder by default. Folder tree on top, the media below with search, sort and filters (section 37), as Icons, a List or Columns (R-1708); in Column view a column browser replaces both.
- **Organise** (middle): where to put results, the automatic sorts, the preview of the pending change with Apply and Discard, People (section 39) and History.
- **Target** (right): optional. Until a target folder is chosen it shows "Organising in place" with Choose Target Folder… and, for a source outside the library, Use MediaPull Library; once chosen, its own tree and grid.

Where results go (D-68): **In Place** (no target; folders inside the source folder, files move into them) is the default for every source; **Copy to Target** (the source stays exactly as it was; organised copies go into the target, as APFS clones) and **Move to Target** apply once a target folder is chosen. Changing the source never changes the target; choosing the source itself, or None, as the target returns to in place. Copying into a library folder is how media is imported. Dropping a folder from Finder on a pane's header opens it in that pane. The MediaPull library has no fixed rules of its own; it is organised however the person likes.

**R-3803** Operations: New Folder, Rename, Move (drag and drop, or Move To…), Flatten (every media file from all subfolders moved up into the folder; the emptied subfolders go to the Trash), Remove Subfolders (each chosen subfolder's contents moved up one level; the emptied subfolder goes to the Trash), Merge Folders (one folder's contents moved into another; the emptied folder goes to the Trash), Move to Trash, and the automatic sorts: by Date (year, then month), by Event, by Source, by Subject (R-3706), by Person (R-3906), screenshots apart from photos, and by Place.

**R-3804** Every operation follows these rules:

- Metadata files (`<file>.json`) always move, rename and go to the Trash with their media.
- Name collisions get a number (`name 2.jpg`); in Archive folders the number goes after the name so the date prefix stays first (R-1503, R-1504).
- Reserved folder names (R-1505) get a leading underscore, including folder names made from a person's name or a subject.
- Nothing is ever deleted permanently.
- A folder's layout is its library root's. A folder outside every root counts as Archive when it holds metadata files, otherwise as Plain.
- Moves inside a library root keep MediaPull's records (archive entries, checksums, analysis) pointing at the new paths.

**R-3805** Before an automatic sort, flattening, removing a folder or merging runs, the Organise pane shows the folders it will create with their counts and sample thumbnails, how many files go to `Unsorted/`, collisions, and for Sort by Person how many copies are clones and how much space any full copies take. Nothing moves until the person applies it. Moving, copying, renaming (in place in the tree), new folders and moving to the Trash apply at once and can be undone. Pop-up windows are kept for what needs attention now, such as errors.

**R-3806** Every operation is recorded in a journal in `~/Library/Application Support/MediaPull/Organise/` (D-63). ⌘Z undoes the last operation, a whole automatic sort as one step; journals survive relaunch and are listed in the Organise pane's History, each with Undo. Undoing moves files back, removes clones and folders it created, and puts trashed items back from the Trash. A file that was changed or moved since is left where it is and reported.

**R-3807** Long operations run as Organise jobs in Activity with progress and Cancel; a cancelled operation can be undone as far as it got.

## 39. Faces and people

**R-3901** Faces are always located (boxes only, for the With Faces, Portraits and Group Photos filters); a box says nothing about who someone is. Recognising people is off until the person turns it on in a sheet that explains that face data is biometric, stays on this Mac, is never written into library folders, metadata files or exports, and can be deleted in one step (D-61). Settings > Faces: on or off, Delete All Face Data (faces, people, names, corrections and face vectors, with one confirmation), the match threshold, and where group photos go when sorting by person.

**R-3902** The bundled face detector finds faces with five landmarks (eyes, nose tip, mouth corners); Apple's face detection is the fallback when it is missing. Faces narrower than 32 px count for the face filters (R-3703) but are not used to recognise people. The rest are aligned to the standard five-point template and turned into a face embedding by the bundled face model, with the mirrored crop added as the model's own evaluation does (D-67), because Apple's frameworks detect faces but do not recognise people.

**R-3903** A face joins the closest person when it is similar enough (the match threshold), otherwise it starts a new person; groups are re-checked as photos are added. Unnamed people are called "Person 1", "Person 2" and so on, largest first.

**R-3904** The People list (in the Organise sidebar and the Library's People filter) lets the person name someone, merge two people, split a person (the chosen photos become a new person) and choose "Not This Person" on a photo. Corrections are stored as constraints (same person, not the same person) tied to the file's checksum and the face's position, so they survive rescans, moves, renames and regrouping.

**R-3905** When at least 5 photos and at least 60 % of an unnamed person's photos sit in one folder whose name looks like a person's name (not a date, an account folder, a reserved, type or generic name such as `Unsorted`, `posts` or `Saved posts`), and that folder mostly holds this person, the person shows "Alice? (from folder Alice)". One click accepts the name; it is never applied without that click (D-66).

**R-3906** *(Amended by D-77: Photos without a recognised person stay where they are; there is no Unsorted option for this sort.)* Sort into Folders by Person makes one folder per named person (unnamed people optional, off by default); photos without a recognised person stay where they are, or go to `Unsorted/` (option). A photo of several people goes into each person's folder as an APFS clone, each copy with its own metadata file. In Archive-layout folders group photos go into one shared `Group photos/` folder instead (D-64). Settings > Faces offers: every person's folder, a shared `Group photos/` folder, or the first person's folder only.

**R-3907** Accuracy limits, stated in Settings > Faces and the People list: faces turned well away from the camera (side profiles) are matched much less reliably; children's faces change with age and are confused more often; faces narrower than 32 px are not used; JPEG compression matters only at very small sizes, while blur, poor light and partial covering matter more. The accuracy measured on this Mac is recorded in D-67.

## Appendix A. Bridge protocol (version 1)

### A.1 Request (one JSON object on standard input)

```json
{
  "v": 1,
  "op": "pull",
  "job": "6E1C2B0A-3F4D-4C55-9A10-2B7E3E1D9C11",
  "url": "https://www.instagram.com/example.account/",
  "include": ["posts", "reels", "avatar"],
  "cookies": "/private/var/folders/.../MediaPull-cookies/6E1C.../cookies.txt",
  "user_agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
  "staging": "/Users/me/Library/Application Support/MediaPull/Staging/6E1C...",
  "known_ids": "/Users/me/Library/Application Support/MediaPull/Staging/6E1C.../known.json",
  "stop_after_known": 12,
  "date_from": "2025-01-01T00:00:00Z",
  "date_to": null,
  "pacing": { "request_delay": [8.0, 15.0] },
  "video": { "codec_policy": "highest_reencode_if_needed" },
  "cursor": null
}
```

`known_ids` lists item keys (`ig:<media_id>` for Instagram) and, for files of posts and Reels, `igp:<post_id>:<num>`; an item is known when either matches (D-79). Stories and highlights have no positional key, since their numbers change as the tray changes.

`fetch` adds `"items": [...]` with item keys and the data returned by `scan`. `stream` takes `url`, `referer` and `cookies`. `supports` takes only `url`.

### A.2 Events (JSON Lines on standard output)

Every event has `v`, `seq` (increasing integer) and `type`.

| Type | Fields |
|---|---|
| `hello` | `python`, `gallery_dl`, `yt_dlp`, `ffmpeg`, `protocol` |
| `account` | `username`, `full_name`, `user_id`, `is_private`, `followed_by_viewer`, `post_count`, `avatar_url` |
| `item` | `key`, `kind` (`image`, `video`), `subcategory`, `url`, `thumb_url`, `width`, `height`, `video` (`variant`: `progressive` or `dash`; `codec`; `duration`), `expires_at`, `meta` (the closed set of fields used for sidecars) |
| `file` | `key`, `path` (inside staging), `bytes`, `meta` |
| `skip` | `key`, `reason` (`known`, `filtered`, `duplicate`) |
| `progress` | `key`, `received`, `total` |
| `wait` | `seconds`, `reason` (`pacing`, `rate_limit`) |
| `cursor` | `value` (opaque; saved for resume) |
| `checkpoint` | `kind` (`challenge`, `login`, `feedback`, `rate_limit`), `url`, `message` |
| `error` | `code` (section 13.5), `message`, `key` (optional), `fatal` |
| `policy_violation` | `method`, `host`, `path`, `reason` |
| `log` | `level`, `logger`, `message` (warnings and errors from the engines, with cookies and tokens redacted) |
| `supports` | `url`, `supported`, `category`, `subcategory` (answer to the `supports` operation) |
| `done` | `status` (`completed`, `cancelled`, `failed`), `counts` (`found`, `downloaded`, `skipped`, `failed`) |

Unknown fields are ignored; an unknown `type` is logged and ignored; a different major `v` stops the job with `engine_outdated` or "Needs an MediaPull update".

---

## Appendix B. Extraction message schema (version 1)

```json
{
  "v": 1,
  "seq": 17,
  "page": "https://example.com/gallery/",
  "items": [
    { "u": "https://cdn.example.com/a/photo-1200.jpg", "k": "srcset", "d": "1200w",
      "w": 1200, "h": 800, "dw": 600, "dh": 400, "alt": "A lake at dawn", "g": 42, "t": "image/jpeg" },
    { "u": "https://cdn.example.com/v/clip.m3u8", "k": "network" }
  ]
}
```

| Field | Meaning |
|---|---|
| `u` | Absolute URL as seen by the page |
| `k` | Kind: `img`, `srcset`, `picture`, `css`, `video`, `audio`, `poster`, `meta`, `link`, `lazy`, `network`, `icon` (`data:` and `blob:` URLs are recognised from the URL) |
| `d` | srcset descriptor (`2x`, `1200w`), if any |
| `w`, `h` | Natural size, if known |
| `dw`, `dh` | Displayed size, if rendered |
| `alt` | Alt text, title or figure caption (trimmed to 500 characters) |
| `g` | Element group id (same element, same id); 0 for none |
| `t` | Declared MIME type, if any |

Frame origin and frame URL are added by the native side from `frameInfo`.

---

## Appendix C. Sidecar schema and examples

### C.1 Instagram carousel item

File `2023-01-06_022210_CnAbCdEfGh_02.jpg`, sidecar `2023-01-06_022210_CnAbCdEfGh_02.jpg.json`:

```json
{
  "author": "Example Account",
  "category": "instagram",
  "count": 3,
  "date": "2023-01-06 02:22:10",
  "description": "Morning walk by the river #autumn #walk",
  "extractor": "gallery-dl 1.32.19",
  "height": 1350,
  "media_id": "3008811223344556678",
  "mediapull_version": "1.0",
  "num": 2,
  "post_id": "3008811223344556677",
  "post_shortcode": "CnAbCdEfGh",
  "post_url": "https://www.instagram.com/p/CnAbCdEfGh/",
  "sha256": "9f2c4e0b7a1d3c5e8f60718293a4b5c6d7e8f90112233445566778899aabbccd",
  "subcategory": "posts",
  "username": "example.account",
  "width": 1080
}
```

### C.2 Instagram Reel

```json
{
  "category": "instagram",
  "count": 1,
  "date": "2025-07-20 10:10:10",
  "description": "Sunset timelapse",
  "duration": 14.6,
  "height": 1920,
  "num": 1,
  "post_id": "3412345678901234567",
  "post_shortcode": "DLxYzAbCdEf",
  "product_type": "clips",
  "subcategory": "reels",
  "username": "example.account",
  "width": 1080
}
```

### C.3 Web page image

File `2026-11-14_093000_0007_lake-at-dawn.jpg`:

```json
{
  "category": "example.com",
  "description": "A lake at dawn",
  "height": 2400,
  "page_url": "https://example.com/gallery/",
  "post_id": "5d41402abc4b",
  "source_url": "https://cdn.example.com/a/photo-original.jpg",
  "subcategory": "page",
  "username": "example.com",
  "width": 3600
}
```

### C.4 Rules

- Keys are sorted; values are strings or numbers as shown; no `null` values (absent means unknown).
- `date` is always `YYYY-MM-DD HH:MM:SS` in UTC.
- `num` and `count` appear together or not at all; `count` greater than 1 together with `post_shortcode` or `post_id` means the files form one post.
- `username` and `author` are always strings when present.
- `media_id` (Instagram, from 1.8) is the id of the one file, as a string (D-81); files saved earlier do not have it.

---

## Appendix D. CDN original-size rules

Each rule produces an unverified candidate that is checked before use (R-913). Rules are data in Core and covered by table tests.

| CDN or site | Recognised by | Rule |
|---|---|---|
| X / Twitter images | `pbs.twimg.com/media/` | Set `name=orig`; keep or set `format` to the served format, trying `jpg` then `png` |
| WordPress | `/wp-content/uploads/` | Remove a trailing `-<W>x<H>` before the extension; remove `-scaled`; for `i0.wp.com` (and i1, i2) remove resize query parameters |
| Pinterest | `i.pinimg.com/<size>/` | Replace the size segment with `originals`, falling back to `1200x` |
| Shopify | `cdn.shopify.com`, `/cdn/shop/` | Remove a `_<W>x<H>` or `_<W>x` suffix before the extension; remove `width`, `height` and `crop` parameters |
| Cloudinary | `res.cloudinary.com/<cloud>/image/upload/` | Remove transformation segments between `upload/` and the version or public id, unless the URL is signed (`s--…--`) |
| imgix | `*.imgix.net` | Remove `w`, `h`, `q`, `fit`, `auto`, `fm`, `dpr`, `crop` parameters, unless an `s` signature parameter is present |
| Wikimedia | `upload.wikimedia.org/…/thumb/` | Remove `/thumb` and the final `<N>px-…` segment |
| Reddit | `preview.redd.it` | Rewrite to `i.redd.it/<id>.<ext>` without query parameters |
| Image proxies and resizing scripts | a query parameter `src`, `img`, `image`, `file`, `url`, `path`, `u`, `f`, `source`, `photo` or `pic` whose value is an image path (`thumb.php?src=photos/a.jpg`, `/_next/image?url=…`) | The value, resolved against the proxy's URL; the file is named after it. URLs served by a script from an `<img>` are accepted even without an image extension |
| Lightbox links | a quoted image or video path in a link's `onclick` (`show('photos/large.jpg')`) | Added as a link variant; an unsized link to a media file ranks above the thumbnail until a probe shows otherwise |
| Generic | sizing query parameters on image URLs: `w`, `width`, `h`, `height`, `resize`, `size`, and the quality, fit, crop and format parameters CDNs pair with them (`q`, `quality`, `fit`, `crop`, `dpr`, `auto`, `fm`, `format`, `max-w`, `max-h`, `maxwidth`, `maxheight`, `im`, `rect`, `ar`, `c`, `imwidth`, `impolicy`, `downsize`, `disable`, `output-quality`, `output-format`) | All of these are removed and other parameters kept as they are. Offered as a candidate only when no specific rule matched, the URL is unsigned and it has at least one of them; like every candidate it is probed before use |

---

## Appendix E. Engine configuration template

Illustrative. Exact option names are verified against the pinned gallery-dl and yt-dlp versions in M0 and recorded in `docs/spikes/M0.md`. The bridge builds this configuration in memory for each job; nothing is read from user configuration files.

```json
{
  "extractor": {
    "base-directory": "<staging>",
    "cookies": "<cookies.txt>",
    "cookies-update": true,
    "user-agent": "<pane User-Agent>",
    "sleep-request": [8.0, 15.0],
    "retries": 2,
    "postprocessors": [],
    "instagram": {
      "include": ["posts", "reels", "avatar"],
      "videos": "merged",
      "previews": false
    }
  },
  "downloader": {
    "part": true,
    "mtime": false,
    "ytdl": {
      "module": "yt_dlp",
      "raw-options": {
        "format": "<selector from the video codec policy>",
        "merge_output_format": "mp4"
      }
    }
  },
  "output": {
    "mode": "null",
    "log": "<json lines handler installed by the bridge>"
  }
}
```

Format selectors by codec policy (yt-dlp syntax, refined in M0):

| Policy | Selector |
|---|---|
| Highest compatible | `bv*[vcodec~='^(avc1|avc3|hvc1|hev1)']+ba[acodec^=mp4a]/b[vcodec~='^(avc|hvc|hev)']/b` |
| Highest resolution, re-encode if needed | `bv*+ba/b`, then the bridge re-encodes VP9 or AV1 video to HEVC (`hevc_videotoolbox`, constant quality, `-tag:v hvc1`) and non-AAC audio to AAC |
| Keep original codec | `bv*+ba/b` with `merge_output_format` `mp4` |
