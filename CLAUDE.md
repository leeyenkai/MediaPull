# MediaPull, working notes for Claude

## What this project is

A lightweight native macOS app that collects media from the web into local folders. It extracts images, videos and streams from pages shown in an embedded browser pane (including lazy-loaded media) and pulls posts, Reels, stories, highlights and profile pictures from Instagram accounts, all at the highest quality available and saved only in normal formats (JPEG, PNG, GIF, MP4).

The full product specification is the source of truth:

- [docs/SPEC.md](docs/SPEC.md)

Read the relevant section of the spec before writing or refactoring code. If a request conflicts with the spec, surface the conflict rather than silently deviating, and update the spec (with a D-nn decision entry where needed) before the code.

Status: version 1.8 implemented, plus the Devices section (section 41, D-115 to D-118: phones and cameras over USB, read-only)
and Organise parity (D-114: duplicates, analysis progress and a Details tab in Organise); version 1.8 itself (account folder updates, conformance ledger, invariant lints and audit protocol; then FileOps,
Save As, notes, file details with a map, post details kept and Profile views, D-107 to D-113; on top of 1.7: on-device analysis, Library search and filters, the Organise section, people, Icon, List and Column views). Personal tool, not a public release. See "Implementation status" at the top of the spec for what is verified and what still needs a person (drag and drop, Quick Look, a signed-in Instagram pull and update).

## Stack

- Swift 6 (approachable concurrency), SwiftUI
- macOS 26 or later, Apple silicon only; the shared package also builds for iOS 26 so an iPad port stays cheap
- SwiftData for app state
- WebKit (`WKWebView`) for the browser pane
- ImageIO, AVFoundation, VideoToolbox for media
- Bundled engines (not Swift packages): standalone CPython with gallery-dl and yt-dlp as pure-Python wheels, plus a minimal LGPL ffmpeg and ffprobe, each pinned with a SHA-256 by the build scripts
- Bundled analysis models (Core ML, converted at build time, pinned in `scripts/models.lock`): MobileCLIP2-S3 (image–text), AdaFace IR-101 (faces), SCRFD-10G (face detection), plus GeoNames places; Apple Vision for labels and text
- Direct distribution: Developer ID, hardened runtime, notarized DMG, not sandboxed
- XCTest; Python tests for the bridge run with the bundled interpreter

## Repository layout

```
MediaPull/                        (project root, inside an iCloud-synced Desktop)
  CLAUDE.md, README.md
  docs/SPEC.md                    source of truth
  Config/Info.plist               merged into the generated Info.plist (ATS, exported drag type)
  MediaPull.xcodeproj/            hand-maintained project file; app sources are a synchronized folder
  MediaPull/                      app target (MainActor by default)
    App/                          MediaPullApp (scenes, commands), AppModel, WindowModel (tabs), BrowsingStore (bookmarks, history),
                                  Preferences, Theme, PaneMenu, Jobs, SelfTest
    Features/                     Browser (pane, TabStrip, BrowsingPanel), Extracted, Preview (pane, details, inline editor host), Library, Instagram (EngineService, PullSheet),
                                  Editor (image and video editors), Video (Save Video sheet), Jobs, Converter, Settings, Onboarding (WalkthroughView),
                                  Analysis (AnalysisService, MediaListing, QueryBar, ViewModePicker, PaneMediaView, FolderChildren), Organise (OrganiseModel, OrganiseView: Source, Organise, Target panes),
                                  People, Downloads (DownloadsPane: Instagram, video and gallery forms), Notes (NotesView),
                                  Profile (ProfilePane, ProfileLayouts, ProfileOverlays: Profile, Channel, Timeline, Board),
                                  Devices (DeviceCenter, DevicesModel, DevicesView: Devices, Media, Import panes)
    Platform/                     AppKit: ReadOnlyWebView, MediaGridView (NSCollectionView), MediaListView (NSOutlineView),
                                  MediaColumnsView (NSBrowser), PaneSplit (nested split views per arrangement), LocationMap (MapKit),
                                  MediaPreviewViews (player, animated image), VideoStage (editor player, trim bar), DragSupport, QuickLook, SVGRasterizer
    Resources/                    Assets.xcassets (accent colour) and AppIcon.icon (Liquid Glass icon: icon.json + SVG layers)
  MediaPullKit/                   local Swift package (macOS 26, iOS 26)
    Sources/MediaPullCore/        types, sniffing, URL rules, CDN rules, ranking, filters, naming, sidecar, ExtractionIngestor, PaneArrangement, PaneViewMode, BrowsingData, VideoDownload
    Sources/MediaPullNet/         NetworkGate (GET and HEAD only), cookies, host limiter, hashing
    Sources/MediaPullMedia/       ImageIO conversion, thumbnails, image and MP4 probes, PDFImageExtractor, ImageEditing, PerceptualHash, VideoTools
    Sources/MediaPullEngines/     bridge protocol and client, cookie files, ffmpeg runner, engine manager
    Sources/MediaPullLibrary/     MediaConverter, SavePipeline, ArchivePlanner, FingerprintIndex, DuplicateFinder, prober, thumbnails, engine fetcher
    Sources/MediaPullStore/       SwiftData models and the AppStore actor
    Sources/MediaPullBrowser/     web view setup, extract.js, guard.js, cookie bridge
    Sources/MediaPullAnalysis/    Vision and Core ML: Analyzer, image–text and face encoders, SCRFD detector, CLIP tokenizer, vector store,
                                  face grouping, similar sets, subjects, offline geocoder
    Sources/MediaPullDevices/     read-only MTP codec and allow-list, MTPSession, device sources (ImageCaptureCore, MTP through its
                                  PTP pass-through), routing, ImportPlan, ImportedIndex, DeviceImporter, stand-ins for tests
    Tests/MediaPullKitTests/
  Engines/bridge/                 mediapull_bridge.py, egress_guard.py, test_egress_guard.py
  scripts/                        fetch-engines.sh, build-ffmpeg.sh, bundle-engines.sh, check.sh, install-app.sh,
                                  fetch-models.sh, convert-models.sh (+ convert_models.py), build_places.py, bundle-models.sh, models.lock
```

## Build and test

- Engines: `scripts/fetch-engines.sh` (Python, gallery-dl, yt-dlp, verified by SHA-256) and `scripts/build-ffmpeg.sh` (minimal LGPL ffmpeg, no network). Both write to `~/Library/Caches/MediaPullBuild/engines`; the Xcode build phase copies them into the app.
- Models: `scripts/fetch-models.sh` downloads, converts (throwaway venv with pinned torch and coremltools), compiles and checks them against `scripts/models.lock`, staging `~/Library/Caches/MediaPullBuild/models/bundle`; `bundle-models.sh` (called by the build phase) copies it into `Contents/Resources/Models`. macOS can purge `~/Library/Caches` when the disk is nearly full; rerun the fetch scripts if the cache is gone.
- Everything: `scripts/check.sh`. Install: `scripts/install-app.sh`. Disk image: `scripts/make-dmg.sh` (Apple Development signing only; not notarized).
- Always build outside the iCloud folder: `swift test --scratch-path ~/Library/Caches/MediaPullBuild/spm` and `xcodebuild ... -derivedDataPath ~/Library/Caches/MediaPullBuild/DerivedData`. Building inside the project folder fails code signing ("resource fork, Finder information, or similar detritus").
- End to end without touching the UI: `MediaPull --selftest-url <url> --selftest-out <folder>` (SPEC section 25). Extra flags:
  `--selftest-edit`, `--selftest-site`, `--selftest-pdf-links`, `--selftest-theme <name>`, `--selftest-layout <preset index>`,
  `--selftest-browser <second url>` (tabs, bookmarks, history, panel, walkthrough), `--selftest-idle <seconds>` (idle CPU),
  `--selftest-duplicates`, `--selftest-video`, `--selftest-zoom <points>`, `--selftest-pullsheet <account>`,
  `--selftest-video-download <page url>` (downloads a 360p H.264 copy and the audio), `--selftest-views` (Icon, List and Column views),
  `--selftest-galleries <file>` (downloads the first 3 items from each address in the file through the whole app),
  `--selftest-update` (offline: a stand-in bridge replays an account update into an existing folder), `--selftest-downloads-list <a|b|c>`,
  `--selftest-analyse <folder>` (copies the folder into the test library, analyses it with faces on, checks no sockets open, searches,
  filters, sorts it in Organise and undoes the sort, comparing checksums), `--selftest-save-as` (offline: Save As of Instagram,
  video and gallery downloads, never redirected), `--selftest-details` (a photo's camera, date and place, maps off; add
  `--selftest-map` to load the map; also Organise's duplicates and Details tab), `--selftest-profile` (offline: Profile, Channel,
  Timeline and Board views), `--selftest-devices` (offline: a stand-in iPhone and a simulated Android phone, browse and import),
  `--selftest-formats` (offline: RAW+JPEG and Live Photo units, .hif, tagged audio, a post kept together),
  `--selftest-edits` (offline: a rating written into a HEIC losslessly with its analysis kept, a RAW pair's `.xmp`, a
  date shift, the Rating filter and Undo), `--selftest-drives <mount>` (an exFAT image check.sh attaches: a camera card imported, a pair moved and undone, Eject))
  (theme and layout are restored afterwards).

## Rules

- **Read-only contract (SPEC section 5) is non-negotiable.** MediaPull never uploads files from the Mac (the library or anything else) and never performs write actions on any account. The browser pane is the exception for what pages themselves send (sign-in forms, searches), never files. All Swift network traffic goes through `NetworkGate` (GET and HEAD only). Engine traffic goes through the bridge's egress guard. The browser pane has no file upload path. Every change that touches networking keeps the egress tests passing.
- **Module boundaries (SPEC 4.2):** SwiftData only in `MediaPullStore`, WebKit only in `MediaPullBrowser` and the browser pane (`Features/Browser`, `Platform/ReadOnlyWebView`), `URLSession`/`URLRequest` only in `MediaPullNet`, `Process` only in `MediaPullEngines`, Vision and Core ML only in `MediaPullAnalysis`, AppKit only in the app target (views built on it in `Platform/`),
  MapKit only in `Platform/LocationMap.swift` and only to draw a map, after the person allows maps (D-110), ImageCaptureCore only in
  `MediaPullDevices` (D-115). `scripts/check.sh` enforces these. Dependencies point one way. No online geocoding, map search, model or Vision asset downloads anywhere (D-59).
- **No third-party Swift packages.** Third-party code is limited to the pinned bundled engines and their runtime. Adding anything else needs explicit approval and a spec decision.
- **Never name or reference other applications** in code, comments, docs, UI copy, identifiers or test fixtures. The Archive layout is described only as a gallery-dl-compatible metadata archive (SPEC section 15).
- **Archive layout is a contract.** Do not change sidecar keys, date format, naming rules, the forbidden name pattern (R-1504) or reserved folder names (R-1505) without a decision entry and updated golden tests.
- **Quality:** never re-encode when a lossless path exists; follow the conversion tables in SPEC section 16.
- **Concurrency:** no image decoding, hashing, JSON parsing of page or engine output, or conversion on the main actor.
- **Performance budgets** live in `scripts/perf-budgets.json` and are enforced in CI (SPEC section 22).
- **Formatting:** swiftformat and swiftlint with the repository's `.swiftformat` and `.swiftlint.yml` (`scripts/check.sh` runs both), 140-column lines. swiftformat's wrapping is off: wrap long lines by hand. Few comments; explain why, not what.
- **User-facing copy:** plain and short, no exclamation marks, no emoji.
- **Tests:** XCTest for Swift, table-driven where possible; never hit live sites in automated tests (use recorded fixtures and the `mediapull-test://` scheme handler).

## Gotchas

- The save layout type is `SaveLayout` (SwiftUI already has `Layout`).
- AppKit subclasses that must be called off the main actor (file promise providers, menu items) are marked `nonisolated`.
- The bundled Python has no `unittest`, no sources (sourceless bytecode) and no embedding library; bridge tests use plain asserts.
- Bridge events must only end after stdout reaches EOF and the process exits (see BridgeClient); a fast exit must never drop the last events.
- WebKit content-rule regexes do not support `|`.
- Panes keep one hosting controller each for the window's life (PaneSplit); never recreate the Browser pane's view, or the page reloads.
- The app icon is `AppIcon.icon`, not an asset-catalog icon set; do not add an `AppIcon.appiconset` back. Preview a change with
  `xcrun actool AppIcon.icon --compile <out> --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist <out>/p.plist`
  and `sips -s format png <out>/AppIcon.icns --out preview.png`.
- Duplicate detection must stay deterministic (checksums, pHash, dHash, colour grid); no learned models (D-50). Learned models are for analysis only (D-57).
- Analysis results, face data and Organise journals live in Application Support, never in library folders (R-601, D-60). Face embeddings need the opt-in; face boxes do not (R-3901).
- Profile views (D-113, `Features/Profile`, `ProfileDetector`/`ProfileBuilder`) read saved files only: never load a picture, link
  or page from the network there; their keys are `.onKeyPress` on a focused overlay, never window shortcuts.
- Organise operations go through `FolderOperations` plans and `OperationJournal`, so every change is undoable and sidecars move with their media.
- Every other move, copy or trash of the person's files goes through `FileOps` (D-107): off the main actor, metadata file with its
  media, exclusive renames, never over an orphaned metadata file. Editor Replace is `OperationJournal.replace`. The lint's
  `file-write` rule allows `FileManager` moves only for MediaPull's own app data (`lint:allow app-data`); stale markers fail.
- The Collect panes stay mounted while Organise is shown (opacity, not `if`), so the Browser never reloads. Both sections use `PaneSplit` with their own `PaneArrangement` (`PaneGroup` collect/organise); a pane's group decides which arrangement it joins.
- No sheets for everyday work (D-69): downloads live in the Downloads pane, Organise previews and People are in the Organise pane, folder renames are inline. Pop-ups only for errors and confirmations of destructive actions.
- ⌘+/⌘-/⌘0 zoom the web page; ⌥⌘+/⌥⌘- change thumbnail size.
- `LibraryItem` is taken by the SDK; the analysis file type is `MediaEntry`.
- Vision's accurate text recognition fails on macOS 27.0.x; the Analyzer falls back to fast mode for the session.
- The bundled Python runs with `-I`, so the bridge finds its modules only through the `paths` list in each request.
- Video trimming must stay passthrough (no re-encode); frame grabs use zero time tolerance.
- Collect has one save folder per window: `WindowModel.saveFolder` (the Library pane's selected folder, else the default root). Save, Downloads
  and the editors use it; downloads take a `SaveDestination` (any folder plus its layout), not a library root (D-70).
- The Organise target is opt-in: `target.root == nil` means in place, and opening a new source never changes the target (D-68).
- When gallery-dl is updated: rerun `scripts/build_site_catalogue.py <gallery-dl source>` (SiteCatalogue.json) and re-audit its POST
  requests against `READ_POSTS` in the egress guard (docs/spikes/gallery-dl-post-audit.md, D-72).
- `model.browser` is the selected tab; per-page callbacks must use the tab they came from, not `model.browser`.
- The inline editor must not use Return, Escape or bare-key shortcuts: they would fire while typing in the web page.
- AppKit grids read the theme accent from `AppTheme.currentAccent`; bump the grid revision when the theme changes.

- Devices are only read (R-4107): MTP requests are built only through `MTPOperation`'s allow-list and carry no data; the
  framework's delete, upload, clock and capture requests are barred by `check.sh`, and `requestSendPTPCommand` lives only in
  `ImageCaptureDevices.swift`. The camera framework starts only when the Devices section is first shown.
- A RAW+JPEG pair or a Live Photo is a unit (D-120, `MediaUnits`, `UnitFiles`): listings show the lead only, and every
  move, copy, trash and Undo carries its members, `.xmp`, `.aae` and metadata files. Plan new file operations through
  `FolderOperations` so `freeDestination(alsoFree:)` keeps one shared name for the whole unit.
- Facts read from files have their own version (`AnalysisRecord.currentFactsVersion`): bump it, not `currentVersion`, when only
  reading facts changes, so no model runs again. Local files never change format on the way into a folder (D-121).
- Drives (D-123, `DriveCenter`, `Volumes`): volumes are told apart by UUID, never by name; analysis of a drive that is not
  connected is pruned only when the one drive ever seen at that mount point is back (`Volumes.isGone`). Drives are ordinary
  folders; only phones and cameras that connect as devices are read-only.
- How real Android phones in File transfer mode are handed over is settled by `docs/spikes/device-access.md` (run
  `swift docs/spikes/device-probe.swift usb|icc` with a phone plugged in); record the results there and in D-116.

- Metadata edits (section 45, D-125, D-126) write JPEG and HEIC in place only through `MetadataWriter.writeCopy`, which
  proves the same picture and the values read back; everything else, and any file with a `.xmp`, uses the `.xmp`. A
  file is replaced only by `OperationJournal.putInPlace`. An in-place edit changes the checksum, so analysis must follow
  it (`AnalysisService.beginEdit` / `followEdit`); never let a scan read a file mid-edit.

## Environment notes

- This folder lives under an iCloud-synced Desktop. iCloud can leave duplicate files named like `File 2.swift`; `scripts/check.sh` fails on them. Compare each with its original (and git) before removing it, and never commit one.
- The default library root for testing is `~/Pictures/MediaPull`, which is outside iCloud.
