# MediaPull, working notes for Claude

## What this project is

A lightweight native macOS app that collects media from the web into local folders. It extracts images, videos and streams from pages shown in an embedded browser pane (including lazy-loaded media) and pulls posts, Reels, stories, highlights and profile pictures from Instagram accounts, all at the highest quality available and saved only in normal formats (JPEG, PNG, GIF, MP4).

The full product specification is the source of truth:

- [docs/SPEC.md](docs/SPEC.md)

Read the relevant section of the spec before writing or refactoring code. If a request conflicts with the spec, surface the conflict rather than silently deviating, and update the spec (with a D-nn decision entry where needed) before the code.

Status: version 1.3 implemented. See "Implementation status" at the top of the spec for what is verified and what still needs a person (drag and drop, Quick Look, a signed-in Instagram pull).

## Stack

- Swift 6 (approachable concurrency), SwiftUI
- macOS 26 or later, Apple silicon only; the shared package also builds for iOS 26 so an iPad port stays cheap
- SwiftData for app state
- WebKit (`WKWebView`) for the browser pane
- ImageIO, AVFoundation, VideoToolbox for media
- Bundled engines (not Swift packages): standalone CPython with gallery-dl and yt-dlp as pure-Python wheels, plus a minimal LGPL ffmpeg and ffprobe, each pinned with a SHA-256 by the build scripts
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
                                  Editor, Jobs, Converter, Settings, Onboarding (WalkthroughView)
    Platform/                     AppKit: ReadOnlyWebView, MediaGridView (NSCollectionView), PaneSplit (nested split views per arrangement),
                                  MediaPreviewViews (player, animated image), DragSupport, QuickLook, SVGRasterizer
    Resources/                    Assets.xcassets (accent colour) and AppIcon.icon (Liquid Glass icon: icon.json + SVG layers)
  MediaPullKit/                   local Swift package (macOS 26, iOS 26)
    Sources/MediaPullCore/        types, sniffing, URL rules, CDN rules, ranking, filters, naming, sidecar, ExtractionIngestor, PaneArrangement, BrowsingData
    Sources/MediaPullNet/         NetworkGate (GET and HEAD only), cookies, host limiter, hashing
    Sources/MediaPullMedia/       ImageIO conversion, thumbnails, image and MP4 probes, PDFImageExtractor, ImageEditing
    Sources/MediaPullEngines/     bridge protocol and client, cookie files, ffmpeg runner, engine manager
    Sources/MediaPullLibrary/     MediaConverter, SavePipeline, ArchivePlanner, FingerprintIndex, prober, thumbnails, engine fetcher
    Sources/MediaPullStore/       SwiftData models and the AppStore actor
    Sources/MediaPullBrowser/     web view setup, extract.js, guard.js, cookie bridge
    Tests/MediaPullKitTests/
  Engines/bridge/                 mediapull_bridge.py, egress_guard.py, test_egress_guard.py
  scripts/                        fetch-engines.sh, build-ffmpeg.sh, bundle-engines.sh, check.sh, install-app.sh
```

## Build and test

- Engines: `scripts/fetch-engines.sh` (Python, gallery-dl, yt-dlp, verified by SHA-256) and `scripts/build-ffmpeg.sh` (minimal LGPL ffmpeg, no network). Both write to `~/Library/Caches/MediaPullBuild/engines`; the Xcode build phase copies them into the app.
- Everything: `scripts/check.sh`. Install: `scripts/install-app.sh`.
- Always build outside the iCloud folder: `swift test --scratch-path ~/Library/Caches/MediaPullBuild/spm` and `xcodebuild ... -derivedDataPath ~/Library/Caches/MediaPullBuild/DerivedData`. Building inside the project folder fails code signing ("resource fork, Finder information, or similar detritus").
- End to end without touching the UI: `MediaPull --selftest-url <url> --selftest-out <folder>` (SPEC section 25). Extra flags:
  `--selftest-edit`, `--selftest-site`, `--selftest-pdf-links`, `--selftest-theme <name>`, `--selftest-layout <preset index>`,
  `--selftest-browser <second url>` (tabs, bookmarks, history, panel, walkthrough), `--selftest-idle <seconds>` (idle CPU)
  (theme and layout are restored afterwards).

## Rules

- **Read-only contract (SPEC section 5) is non-negotiable.** MediaPull never uploads files and never performs write actions on any account. All Swift network traffic goes through `NetworkGate` (GET and HEAD only). Engine traffic goes through the bridge's egress guard. The browser pane has no file upload path. Every change that touches networking keeps the egress tests passing.
- **Module boundaries (SPEC 4.2):** SwiftData only in `MediaPullStore`, WebKit only in `MediaPullBrowser`, `URLSession`/`URLRequest` only in `MediaPullNet`, `Process` only in `MediaPullEngines`, AppKit only in the app's `Platform/` folder. Dependencies point one way.
- **No third-party Swift packages.** Third-party code is limited to the pinned bundled engines and their runtime. Adding anything else needs explicit approval and a spec decision.
- **Never name or reference other applications** in code, comments, docs, UI copy, identifiers or test fixtures. The Archive layout is described only as a gallery-dl-compatible metadata archive (SPEC section 15).
- **Archive layout is a contract.** Do not change sidecar keys, date format, naming rules, the forbidden name pattern (R-1504) or reserved folder names (R-1505) without a decision entry and updated golden tests.
- **Quality:** never re-encode when a lossless path exists; follow the conversion tables in SPEC section 16.
- **Concurrency:** no image decoding, hashing, JSON parsing of page or engine output, or conversion on the main actor.
- **Performance budgets** live in `scripts/perf-budgets.json` and are enforced in CI (SPEC section 22).
- **Formatting:** swiftformat and swiftlint, 140-column lines. Few comments; explain why, not what.
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
- `model.browser` is the selected tab; per-page callbacks must use the tab they came from, not `model.browser`.
- The inline editor must not use Return, Escape or bare-key shortcuts: they would fire while typing in the web page.
- AppKit grids read the theme accent from `AppTheme.currentAccent`; bump the grid revision when the theme changes.

## Environment notes

- This folder lives under an iCloud-synced Desktop. Watch for iCloud duplicate files named like `File 2.swift` and never commit them; a pre-commit check for them should be added in M1.
- The default library root for testing is `~/Pictures/MediaPull`, which is outside iCloud.
