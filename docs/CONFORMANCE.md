# Conformance ledger

Every requirement in [SPEC.md](SPEC.md), with what implements it and what proves it. `scripts/conformance.py` checks this
file on every `scripts/check.sh` run: each requirement must be listed, every name in backticks must exist, and a
release build (`--strict`) fails while any row is open.

Statuses: **built** (implemented and proved by a test or self-test), **person** (implemented; only a person can check
it), **amended** or **dropped** (by the decision named in the note), **partial** and **missing** (open).

First filled in for version 1.8 (2026-11-17) by reading every requirement against the code. Update the row in the same
change as the code.

| Requirement | Status | Implemented by | Proved by | Note |
|---|---|---|---|---|
| R-201 | person | `InstagramNotice.terms`, `WalkthroughView`, `InstagramForm` | `--selftest-browser` | Instagram terms and account risk on first run and in the sign-in banner (1.8); copy needs a person to read |
| R-202 | built | `configure_gallery_dl`, `EngineService.enqueueInstagram`, `Preferences.pacing` | `test_instagram_is_gentle_by_default_and_never_retried` | Gentle by default, no retries after a limit; one Instagram job at a time (queue) |
| R-301 | built | `MediaPull.xcodeproj/project.pbxproj`, `MediaPullKit/Package.swift` | `scripts/check.sh` | macOS 26 deployment target, ARCHS arm64; check.sh builds for arm64 |
| R-302 | built | `MediaPull.xcodeproj/project.pbxproj`, `MediaPullKit/Package.swift` | `scripts/check.sh` | Swift 6, approachable concurrency, MainActor default in the app; @concurrent used in the package |
| R-303 | built | `MediaPull/Platform/PaneSplit.swift`, `MediaPull/Platform/MediaGridView.swift` | `scripts/check.sh` | check.sh lint allows import AppKit only under MediaPull/ |
| R-304 | built | `MediaPullKit/Package.swift`, `scripts/fetch-engines.sh`, `scripts/build-ffmpeg.sh` | `scripts/fetch-engines.sh` | No package dependencies; engine wheels and ffmpeg source verified by SHA-256 when fetched |
| R-305 | amended | `Config/Info.plist`, `scripts/make-dmg.sh` | — | D-77: Apple Development signed for personal use; Developer ID and notarization for a public release only |
| R-306 | amended | `scripts/make-dmg.sh` | — | D-77: applies to a public release only |
| R-307 | built | `scripts/bundle-engines.sh`, `EngineSettings` | `scripts/check.sh` | Licences and SOURCES.txt with every bundled version are in the app (1.8) |
| R-308 | amended | `Config/Info.plist`, `RequestPolicy.evaluate` | `testOnlyReadsAreAllowed` | D-77: arbitrary loads allowed for http media from any host; the gate still allows only GET and HEAD |
| R-401 | built | `MediaPullKit/Package.swift`, `scripts/check.sh` | `scripts/check.sh` | Lint enforces SwiftData, WebKit, URLSession, Process, Vision and Core ML boundaries and D-59 bans |
| R-402 | built | `scripts/lint_invariants.py`, `LibraryModel.offMain`, `MediaListing.load` | `scripts/lint_invariants.py` | The main-io lint fails on file moves, copies, listings and reads in the app target unless justified (1.8) |
| R-403 | person | `BridgeClient.run`, `FFmpeg.run`, `CookieFile.cleanUpAll` | `testFinalEventsAreNeverLost` | Helpers run per job and stop with it; Activity Monitor check needs a person |
| R-501 | built | `GatedRequest`, `NetworkGate`, `RedirectGuard`, `RedirectPolicy.nextHeaders` | `testRedirectsKeepCookiesOnlyOnTheSameOriginAndRecomputeTheReferer`, `testCookiesStayBehindAndEveryHopIsLogged`, `testACutShortDownloadIsNotKept` | Per-hop Referer and same-origin cookies since 1.8; per-host limits follow redirects |
| R-502 | built | `RequestPolicy.urlRequest`, `RedirectGuard` | `testEngineUpdatesNeedHTTPS`, `testOnlyReadsAreAllowed` | Plain http is for media only (D-21); engine updates and their redirects are https only (1.8) |
| R-503 | built | `NetworkGate.entries`, `NetworkGate.logCapacity`, `AdvancedSettings` | `testCookiesStayBehindAndEveryHopIsLogged` | 2,000-entry in-memory log shown as Network activity; never written to disk |
| R-504 | amended | `WindowModel.previewFile`, `PlayerView` | `--selftest-video` | D-77: media is downloaded through the gate to a cache file before AVFoundation opens it |
| R-505 | built | `Engines/bridge/egress_guard.py`, `READ_POSTS`, `install_guard` | `test_write_operations_are_blocked`, `test_audited_site_reads_are_allowed`, `test_uploads_and_other_methods_are_blocked` | Read-only POST list per D-72 (amends D-40), already in the spec text |
| R-506 | built | `configure_gallery_dl`, `stream_options` | `test_engine_cache_stays_in_memory` | Config cleared per job, caches in memory, no cookies-from-browser, only the job's site cookies |
| R-507 | built | `scripts/build-ffmpeg.sh`, `FFmpeg.run` | `testFFmpegHasNoNetworkProtocols` | ffmpeg reaches only file and pipe (1.8 test) |
| R-508 | built | `ReadOnlyWebView`, `BrowserController.install`, `WebViewSetup.uploadBlockingRules`, `MediaPullKit/Sources/MediaPullBrowser/Resources/guard.js` | `--selftest-browser` | Rules compile first at launch; pages wait for them; a failure is reported (1.8) |
| R-509 | built | `WebViewSetup.uploadBlockingRules` | `testUploadBlockingRulesCompile` | The rules compile; they block upload hosts only, as D-17 keeps analytics |
| R-510 | built | `scripts/lint_invariants.py` | `scripts/lint_invariants.py` | Lint: only Apple frameworks and MediaPull modules, no package dependencies (1.8) |
| R-511 | person | `AppModel.exportDiagnostics`, `AppModel.diagnosticsReport`, `AdvancedSettings` | `--selftest-url` | Logs in the unified log (app.mediapull); Export Diagnostics writes a readable text file (1.8) |
| R-512 | built | `CookieFile.write`, `CookieFile.cleanUpAll`, `EngineCookies` | `testCookieFileRoundTrip` | 0600 file in a 0700 folder, deleted at job end and cleaned at launch |
| R-513 | built | `AnalysisService`, `SelfTestRunner.socketCount` | `--selftest-analyse` | Self-test records socket count while analysing |
| R-601 | built | `OperationJournal`, `AnalysisStore`, `FingerprintIndex` | `--selftest-analyse` | Journals, analysis and fingerprints in Application Support; self-test checks the tree is restored exactly |
| R-701 | built | `PaneArrangement.standard`, `PaneSplit`, `MainWindow` | `testMovesAndStacks`, `--selftest-layout` | Five panes, Downloads below Browser by repair, min widths and 1100 x 700 window |
| R-701a | built | `PaneArrangement`, `PaneMenu`, `PaneMoveCommands`, `LayoutPresetCommands`, `PaneSplitController.resetSavedSizes` | `testMovesAndStacks`, `testDecodingRepairsMissingAndDuplicatePanes`, `--selftest-layout` | Presets, per-arrangement divider autosave, hosts kept so the page never reloads |
| R-702 | person | `AppCommands`, `WindowModel.setShowing` | none | Checked: Opt-Cmd-1 to 3, Cmd-I, Ctrl-Cmd-1 and 2 wired in the View menu; keyboard needs a person |
| R-703 | person | `MediaPullApp`, `MainWindow`, `AppModel` | none | Checked: WindowGroup gives Cmd-N; each window has its own WindowModel, shared store, roots and jobs |
| R-704 | person | `MainWindow`, `SectionTabs`, `TopBarButton` | none | Compact toolbar with section tabs, Downloads, Activity and Undo; visual check only |
| R-705 | person | `ExtractedStatusBar`, `SaveFolderMenu` | none | Counts, selection size, save folder menu and Save button; visual check only |
| R-710 | built | `TourPage`, `WalkthroughView`, `GeneralSettings` | `--selftest-browser` | Eight tour pages; reopened from Settings and Help; self-test opens the tour sheet |
| R-801 | built | `ReadOnlyWebView`, `WebViewSetup.configuration` | `--selftest-browser` | Default persistent data store shared by every tab and window |
| R-802 | person | `BrowserBar`, `AddressField`, `TabStrip`, `PaneMenu` | none | Nav bar, fading address, star, panel button, Cmd-L, Cmd-[ and Cmd-]; UI check only |
| R-802a | person | `BrowserController.zoomIn`, `BrowserController.zoomSteps`, `AppCommands` | none | Steps 50 to 300 percent and pinch; shortcut bound to plus with no equals alternative, check by hand |
| R-803 | amended | `AddressInput.parse`, `WindowModel.showDownloads` | `--selftest-browser` | D-77: @name, story and highlight links open the Downloads pane, which offers the actions |
| R-804 | person | `CookieBridge.isSignedInToInstagram`, `InstagramSettings`, `AppCommands` | none | Sign In in Go menu and Settings (toolbar moved by D-48); needs a real sign-in |
| R-805a | built | `TabStrip`, `TabChip`, `WindowModel.newTab`, `WindowModel.reopenClosedTab`, `BrowserController` | `--selftest-browser` | Tabs, context menu, Cmd-click tabs and This Page chip; self-test opens, filters and closes tabs |
| R-805b | built | `BookmarkStar`, `BookmarksList`, `StartPage`, `BookmarkCollection` | `testBookmarksAndFolders`, `--selftest-browser` | Star editor, folders, Bookmarks menu and start page with four starting points |
| R-805c | built | `HistoryList`, `BrowsingStore.recordVisit`, `BrowsingHistory` | `testHistoryRecordsOncePerAddressAndClears` | 5,000-address cap, clear ranges, setting to stop recording, JSON in Application Support |
| R-805 | person | `CookieBridge.clearWebsiteData`, `InstagramSettings`, `AdvancedSettings` | none | Needs a signed-in session to check |
| R-806 | amended | `BrowserController.userAgent`, `configure_gallery_dl` | `test_browser_user_agent_goes_with_cookies` | D-24: engines keep their own UA; the browser UA goes only with cookies, never for Instagram |
| R-807 | person | `BrowserController`, `FolderPicker.chooseSaveLocation` | none | Pop-ups open as tabs; page downloads use the save dialog in the save folder (D-73) |
| R-808 | person | `Banner`, `EngineService.handleCheckpoint`, `EngineService.resumeAfterCheckpoint` | none | Checkpoint banner with Resume and Cancel Instagram Jobs; needs a real checkpoint |
| R-901 | built | `WebViewSetup.configuration`, `MediaPullKit/Sources/MediaPullBrowser/Resources/extract.js` | `--selftest-url` | Document start, all frames, isolated MediaPull world, handler only in that world |
| R-902 | amended | `MediaPullKit/Sources/MediaPullBrowser/Resources/extract.js` | `--selftest-url` | D-77: no inline SVG setting; manifests and media files reported, not stream segments |
| R-903 | built | `MediaPullKit/Sources/MediaPullBrowser/Resources/extract.js` | `--selftest-url` | MutationObserver with filtered attributes, idle chunks of 2,000, load events captured |
| R-904 | built | `MediaPullKit/Sources/MediaPullBrowser/Resources/extract.js` | `--selftest-url` | 50 ms first flush, 300 ms after, 500 candidates or 256 KB per message |
| R-905 | built | `ExtractionIngestor.ingest`, `ExtractionIngestor.sameOrigin` | `testBatchPageMustMatchTheFrameOrigin` | A batch page address is believed only within the frame origin from WebKit (1.8) |
| R-906 | built | `WindowModel.toggleAutoScroll`, `BrowserController.scrollStep` | `--selftest-url` | Stops after three quiet steps or when the person stops it |
| R-907 | built | `ExtractionMessageHandler`, `ExtractionIngestor` | `testSrcsetCandidatesMergeAndRank` | Raw JSON handed to the ingestor actor; snapshots every 250 ms at most |
| R-908 | built | `WindowModel.clear`, `MediaFilter`, `Preferences` | `--selftest-browser` | Accumulates until Cmd-K; grouped by page; This Page filter; Clear on navigation setting |
| R-909 | built | `URLNormalizer.normalize` | `testSrcsetCandidatesMergeAndRank`, `testRulesKeepOtherParametersAndPaths` | Resolved against the frame; queries kept unless a CDN rule applies |
| R-910 | built | `ExtractionIngestor.markDuplicate`, `CDNRules` | `testRenditionsInDifferentElementsMerge`, `testWordPressRenditionsShareOneAsset` | Same element and CDN asset key merge; identical checksums marked duplicate |
| R-911 | amended | `MediaProber.probe` | `testMalformedMP4BoxesDoNotCrash` | D-77: the tail read is the last 1 MB |
| R-912 | built | `MediaProber`, `WindowModel.ensureProbed`, `WindowModel.gridAppeared` | `--selftest-url` | Visible, selected or filter-needed items only; 6 at once; cached per session |
| R-913 | built | `CDNRules`, `WindowModel.ensureProbed` | `testNYTimesRendition`, `testTwitterWordPressAndSigned`, `testSmallerGuessedOriginalIsRejected` | Derived originals unverified until checked; signed URLs untouched |
| R-914 | built | `VariantRanker.best`, `VariantRanker.reason` | `testReasons` | The Preview says why a version was chosen (1.8) |
| R-915 | built | `URLNormalizer.referer`, `RequestContext`, `SavePipeline` | `--selftest-url` | Pane User-Agent, image Accept header, strict-origin-when-cross-origin Referer |
| R-916 | built | `URLNormalizer.mayCarryCookies`, `PublicSuffix` | `testCookiesNeedTheFrameToo`, `testRegistrableDomain` | Cookies only when the media is same-site with the page and the reporting frame (1.8) |
| R-917 | built | `MediaProber.bestHLSResolution`, `BridgeEngineFetcher`, `stream_options` | `test_stream_options_map_extras` | Stream items sized from the manifest; saved by yt-dlp with Referer and first-party cookies |
| R-918 | amended | `MediaPullKit/Sources/MediaPullBrowser/Resources/extract.js`, `VideoFormatInfo.drm` | `--selftest-url` | D-77: Protected from EME use in the page or DRM reported by yt-dlp |
| R-919 | amended | `MediaPullKit/Sources/MediaPullBrowser/Resources/extract.js`, `BrowserController.readBlob` | `--selftest-url` | D-77: blob videos listed as unavailable with a pointer to Save Video |
| R-1001 | person | `MediaGrid`, `WindowModel.gridInfo` | `--selftest-url` | Insecure (http) badge added in 1.8; badges need a person to look at |
| R-1001a | person | `MediaPullApp`, `WindowModel.cellSize` | `--selftest-zoom` | Thumbnail zoom keys work in Icon view, as R-1711 says; keys need a person |
| R-1002 | amended | `ThumbnailLoader` | `--selftest-url` | D-77: decoded at most 768 px on the longer side |
| R-1003 | person | `MediaCollectionView`, `WindowModel.gridSelectionChanged` | `--selftest-url` | Edit > Select All (Command-A) reaches the focused grid; Select All Media is Option-Command-A; keys need a person |
| R-1004 | person | `WindowModel.gridMenu` | `--selftest-url` | Copy Image and Copy Original URL added (1.8); menus need a person |
| R-1005 | amended | `ExtractedPane` | `--selftest-browser` | D-77: header buttons named as in the Downloads pane |
| R-1006 | amended | `FilterBar`, `MediaFilter` | `testFilterHidesTinyAndMatchesSize` | D-77: the filter bar offers the listed subset; the slider covers resolution presets |
| R-1006a | built | `QuickFilterBar`, `MediaFilter` | `testResolutionSliderUsesLongestSide`, `testLengthFilterKinds` | Type chips, longest-side slider with the listed stops, shown of found count |
| R-1007 | built | `SortOrder`, `MediaFilter.sorted` | `testEqualValuesKeepDiscoveryOrder` | All seven sort orders |
| R-1008 | partial | `MediaFilter`, `WindowModel.refilter` | none | Audit gap: filter state not persisted per window, no named presets, no 5,000-item timing test |
| R-1009 | built | `PreviewPane`, `ItemDetails`, `VariantRanker.reason` | `testReasons`, `--selftest-url` | The reason for the chosen variant is shown (1.8) |
| R-1009a | built | `WindowModel.showInPreview`, `WindowModel.openEditor`, `EditorModel` | `--selftest-edit` | Editor opens in the Preview pane; unsaved edits keep it from being replaced |
| R-1010 | person | `QuickLook`, `WindowModel.quickLook`, `WindowModel.previewFile` | none | Downloads through the gate to the cache, then previews the local file |
| R-1101 | person | `InstagramForm`, `EngineService.refreshSignIn` | `--selftest-pullsheet` | Sign-in state and Sign In shown in the Downloads pane; a signed-in pull needs a person (D-53) |
| R-1102 | person | `EngineService.describe`, `Engines/bridge/mediapull_bridge.py` | none | Private account error mapped to a fatal private event; only a signed-in pull can show it |
| R-1103 | amended | `EngineCookies`, `CookieFile.write`, `BridgeEngineFetcher.fetch` | `testCookieFileRoundTrip`, `test_browser_user_agent_goes_with_cookies` | D-24: engines keep their own User-Agent for Instagram; cookies exported, written back and deleted |
| R-1104 | built | `AddressInput.parse`, `AddressInput.bareUsername`, `InstagramIDs`, `DownloadsModel.use` | `testClassification` | A bare name in the Downloads pane is an account; a story link with an id gets that story, without one the account's stories; a highlight link gets the highlight (1.8) |
| R-1105 | built | `InstagramForm`, `PullDraft`, `AccountCard`, `PacingPreset.estimate`, `AccountFolders.resolveTarget` | `--selftest-pullsheet`, `testEstimateCountsPagesAtTheAverageDelay`, `testTargetIsTheExistingFolderAndNeverNested` | D-78: the destination line names the existing account folder or the new one; D-79: no Mode row (Find Missing replaces Verify); estimate since 1.8 |
| R-1105a | built | `InstagramContent`, `ArchivePlanner.folder`, `EngineService.startPull` | `testDefaultsAndGroups`, `testFoldersForEachKindOfContent`, `test_lists_hold_names_and_are_written_as_csv` | Content choices map to gallery-dl subcategories and folders (D-52, D-54) |
| R-1105b | built | `InstagramDateWindow.bounds`, `KnownTracker.outside_dates` | `testDateWindows`, `test_undated_items_are_kept_and_never_end_a_listing` | Date window applied in the bridge (D-38) |
| R-1106 | person | `EngineService.startPull`, `SavePipeline.saveStaged` | `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites` | Staged files go through the save pipeline; a signed-in Instagram pull needs a person |
| R-1107 | person | `EngineService.startPull`, `SavePipeline.acquire`, `BridgeEngineFetcher.fetch` | `--selftest-site` | Scan then save with re-resolve on 403 or 410; Instagram scans need a signed-in person |
| R-1108 | person | `EngineService.startPull`, `ArchivePlanner.folder` | none | Download This Post pulls one post into the owner's folder; needs a signed-in pull |
| R-1109 | person | `InstagramNotice.quality`, `ArchivePlanner.sidecar` | `testInstagramSidecarMatchesContract` | Size note in the Instagram options (1.8); original sizes recorded in sidecars |
| R-1110 | person | `MediaConverter.convertVideo`, `PullJob` | `testHEVCTaggedHev1IsRetaggedWithoutReencoding` | Codec policy as R-1607; Instagram videos need a signed-in pull to check |
| R-1111 | built | `ArchivePlanner.sidecar`, `NameTemplate.archiveEngine` | `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites` | Carousel items numbered from 1 with num and count in the sidecar |
| R-1112 | built | `KnownTracker`, `positional_key`, `EngineService.resolvePlace`, `AccountFolderStore` | `test_posts_are_known_by_post_and_number_but_stories_only_by_media_id`, `testStoreRemembersKeysAndCursorPerFolder`, `--selftest-update` | D-79: the known set and the cursor belong to the account folder; the known set goes with every pull into it |
| R-1113 | person | `PacingPreset.delay`, `EngineService.enqueueInstagram`, `HostLimiter` | none | Presets, one Instagram job at a time and 2 CDN downloads; only a signed-in pull shows them |
| R-1114 | person | `EngineService.handleCheckpoint`, `EngineService.canResume`, `EngineService.resumeAfterCheckpoint` | `test_write_operations_are_blocked` | Resume held until a session returns or the cooldown ends; 10, 20, 40 minutes within a day (1.8); needs a real checkpoint |
| R-1115 | built | `ArchivePlanner.folder`, `NameTemplate.archiveAvatar`, `FingerprintIndex`, `AccountFolders.sortsByType` | `testFoldersForEachKindOfContent`, `testFlatFoldersWhenSortingByTypeIsOff`, `testUpdateSavesIntoTheExistingFolderWithTheAccountsName` | Folders by type (D-54), avatar named at pull time and deduplicated, collab owner recorded (D-11); D-78: an existing account folder is used whatever its name |
| R-1111a | built | `DownloadsPane`, `DownloadsModel.use`, `WindowModel.showDownloads` | `--selftest-galleries`, `--selftest-video-download`, `--selftest-pullsheet` | Instagram, video and gallery options in one pane, saving into the window's save folder (D-69, D-70) |
| R-1111b | built | `SiteCatalogue`, `GalleryError`, `SiteKeychain`, `configure_gallery_dl` | `testBundledCatalogueNamesSitesAndSignIn`, `test_site_choices_reach_gallery_dl_and_unknown_switches_do_not`, `--selftest-galleries` | Per-site parts, switches, sign-in, keys and plain errors (D-71) |
| R-1111c | person | `AppDelegate.downloadWithMediaPull`, `Config/Info.plist`, `DownloadsPane` | — | D-82: Services entry and dropped links fill in the Downloads pane only; the Services menu needs a person |
| R-1201 | built | `WindowModel.siteExtractorCategory`, `EngineService.siteInfo`, `op_supports` | `--selftest-site`, `testFinalEventsAreNeverLost` | Debounced 1.5 s supports check, cached per URL, Instagram excluded |
| R-1202 | built | `EngineService.startSiteScan`, `EngineCookies` | `--selftest-site` | Scan with the site's own cookies; the button now reads Get Original Files |
| R-1203 | built | `site_request_interval`, `configure_gallery_dl` | `test_a_sites_own_request_interval_is_never_undercut` | Never faster than a site's own interval (1.8) |
| R-1204 | amended | `ArchivePlanner.sidecar` | `--selftest-site` | D-28: uploader recorded as author, username only for user pages, files under the site folder |
| R-1301 | built | `BridgeClient.run`, `EnginePaths.pythonPaths`, `configure_paths` | `testFinalEventsAreNeverLost`, `testSelfTestPassesAndGuardBlocksWrites` | Isolated interpreter, clean environment, staging working folder, request on standard input |
| R-1302 | built | `BridgeClient.run`, `BridgeEvent.decode`, `Emitter` | `testFinalEventsAreNeverLost`, `test_events_are_valid_json_even_with_nan_or_huge_numbers` | JSON Lines events; standard error logged privately |
| R-1303 | person | `BridgeClient.run`, `FFmpeg.run` | `testFinalEventsAreNeverLost` | Cancel escalates SIGINT, SIGTERM, SIGKILL and removes staging; timing needs a person (a 10-second test) |
| R-1304 | built | `EngineManager.install`, `EnginePaths.updates` | `testEngineUpdatesStayOutOfTheBundleAndCanBeUndone` | Updates under Application Support; the bundle is never written |
| R-1305 | built | `EngineManager.install`, `EnginePaths.pythonPaths` | `testCandidateEnginePathsComeFirstWithoutTouchingActiveFile`, `testVersionComparisonAndDependencies` | The candidate is self-tested from its folder; active.json is written only after it passes (1.8) |
| R-1306 | person | `ActivityView`, `EngineSettings`, `AppModel.checkForEngineUpdates` | `testUpdateCheckReadsPyPI` | Updates announced in Activity and listed in Settings; installing stays a choice (1.8) |
| R-1307 | built | `EngineManager.usePreviousVersions`, `EngineManager.resetToBuiltIn` | `testEngineUpdatesStayOutOfTheBundleAndCanBeUndone` | Use Previous Version and Reset to Built-In tested (1.8) |
| R-1308 | built | `EngineManager.updatable`, `EngineManager.unmetDependency` | `testVersionComparisonAndDependencies` | Only gallery-dl and yt-dlp update; dependency needs block the update |
| R-1401 | built | `SavePipeline.saveOne`, `SavePipeline.finalize`, `NetworkGate.download` | `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites`, `testACutShortDownloadIsNotKept` | Step 3 Content-Length check added in 1.8; identical concurrent saves re-checked after reserving |
| R-1402 | built | `SavePipeline.place` | `testParallelPlacementNeverOverwrites`, `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites` | Exclusive rename, never overwrites media or a left-behind metadata file |
| R-1403 | built | `AppModel.save`, `WindowModel.apply` | `--selftest-url` | One job with per-item results and Retry Failed; retry itself not exercised by the self-test |
| R-1404 | built | `WindowModel.saveFolder`, `WindowModel.useSaveFolder`, `SaveFolderMenu` | `--selftest-analyse` | One save folder per window, outside folders shown without joining the library (D-70) |
| R-1501 | built | `Sidecar.sidecarURL` | `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites` | Sidecar named after the full file name |
| R-1502 | built | `SaveLayout.allows`, `SavePipeline.finalize` | `testSVGIsSkippedInArchiveButKeptInPlain`, `--selftest-video-download` | Archive formats only; chosen WebM or M4A kept without metadata (D-56, D-13) |
| R-1503 | built | `ArchivePlanner.fileName`, `MediaConverter.convertVideo` | `testAudioOnlyMP4IsAudio`, `testArchiveNamesNeverMatchForbiddenPattern` | Audio-only MP4 is treated as audio, which Archive folders do not take (1.8) |
| R-1504 | built | `ArchivePlanner.fileName`, `FileNaming.isForbiddenArchiveName` | `testArchiveNamesNeverMatchForbiddenPattern`, `testCleanedNamesAreCheckedAndNeverHidden` | Checked on the cleaned name since 1.8 |
| R-1505 | built | `FileNaming.safeTopFolder`, `ArchivePlanner.folder` | `testReservedFoldersAndLengths`, `testReservedNamesGetAnUnderscore` | Reserved first-level names get a leading underscore |
| R-1506 | person | `AppModel.locationWarning`, `LibraryPane` | `--selftest-analyse` | The iCloud and network warning needs a folder in iCloud to see |
| R-1507 | built | `Sidecar`, `ArchivePlanner.sidecar` | `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites`, `testInstagramSidecarMatchesContract` | Closed struct; no location, engagement or identity keys (D-12) |
| R-1508 | built | `DateFormats.utc`, `DateFormats.sidecarString` | `testMetadataDatesUseAFixedCalendar`, `testDatesIgnoreUserCalendar` | POSIX locale, Gregorian calendar and UTC set explicitly, tested (1.8) |
| R-1509 | built | `ArchivePlanner.sidecar` | `testNumAndCountComeTogether` | Web sidecars carry no num or count (D-10) |
| R-1510 | built | `FileNaming.sanitize` | `testCleanedNamesAreCheckedAndNeverHidden`, `testReservedFoldersAndLengths` | Joiners kept (D-74); trimming repeats until stable so no hidden names (1.8) |
| R-1601 | built | `ImageConversion.analyze`, `ImageConversion.stillTarget`, `Sniffer.sniff` | `testLosslessWebPBehindALargeProfileIsFound`, `testAnimatedPNGAndWebPWithAlpha` | Lossless WebP is found behind a large colour profile (1.8) |
| R-1602 | built | `ImageConversion.convertStill` | `testDisplayP3SurvivesConversion`, `testPDFProfileIsAddedWithoutReencoding` | Display P3 kept through conversion (1.8 test) |
| R-1603 | built | `ImageConversion.plays`, `ImageConversion.forEachFrame`, `FFmpeg.gif`, `MediaConverter.convertAnimated` | `testPlayCountsSurviveConversion` | Play counts kept (ImageIO and ffmpeg), AVIF delays read, frames streamed with a 3,000-frame cap (1.8) |
| R-1604 | built | `MediaConverter.convert`, `ConversionPolicy` | `testModernFormatsAreKeptOnlyInPlainFolders` | Keep original applies to Plain only (1.8 test) |
| R-1605 | amended | `ConverterView`, `MediaConverter` | `testAnimatedPNGAndWebPWithAlpha` | D-77: no per-run options; follows section 16.1 and the Formats settings |
| R-1606 | person | `LibraryModel.gridMenu`, `AppModel.convertFiles` | `testModernFormatsAreKeptOnlyInPlainFolders` | The menu item is named by what it produces (1.8); menus need a person |
| R-1607 | built | `MediaConverter.convertVideo`, `FFmpeg.remuxToMP4`, `FFmpeg.transcodeToHEVC`, `higher_resolution` | `testHEVCTaggedHev1IsRetaggedWithoutReencoding`, `test_a_taller_video_in_another_codec_is_noted` | hvc1 always, Highest compatible never re-encodes, higher_res_available written, AV1 decoded by VideoToolbox (1.8) |
| R-1608 | built | `MediaConverter.convertVideo`, `FFmpeg.remuxToMP4` | `testNonAACSoundBecomesAAC` | Non-AAC sound becomes AAC, the picture is copied (1.8 test) |
| R-1701 | built | `LibraryPane`, `LibraryModel` | `--selftest-views`, `--selftest-url` | Folder tree over contents, sidecars hidden with a badge, columns replace both (D-76) |
| R-1702 | person | `AppModel.followRootLocations`, `AppModel.renameRoot`, `AppModel.locateRoot`, `LibraryRootInfo.resolvedURL` | `--selftest-analyse` | Roots follow Finder moves, show Not Found with Locate, and rename in the list (1.8); needs a person to move a folder |
| R-1703 | built | `LibraryModel.commitRename`, `LibraryModel.trash`, `LibraryModel.perform`, `OperationJournal.run` | `testRunMovesSidecarsAndUndoRestoresTheTree`, `testRedoDoesTheChangeAgainAndCanBeUndone` | Library rename, move and Trash go through the journal with sidecars and are undoable (1.8) |
| R-1704 | built | `AnalysisService.updateWatch`, `FolderWatcher`, `LibraryModel.invalidateTree` | `--selftest-analyse` | Every library folder is watched, analysed or not (1.8) |
| R-1707 | person | `WindowModel.find`, `QueryBar` | `--selftest-views` | Command-F focuses the search field of the pane being worked in (1.8) |
| R-1708 | person | `ViewModePicker`, `MediaList`, `MediaColumns` | `--selftest-views` | Stale rows and lost selection fixed in 1.8; drag, Quick Look and keys need a person |
| R-1709 | built | `MediaList`, `FolderChildren` | `--selftest-views` | Opened folders are rebuilt when the pane reloads and keep the pane filters (1.8) |
| R-1710 | built | `MediaColumns`, `LibraryModel.columnFolderChanged` | `--selftest-views` | Open columns refresh in place keeping the selection; clicks in other columns show the file (1.8) |
| R-1711 | person | `WindowModel.viewModeTarget`, `MediaGrid` | `--selftest-views` | Thumbnail size keys work in Icon view only, as specified; needs a person |
| R-1712 | built | `LibraryModel.findAccount`, `LibraryModel.accountMenuItems`, `FolderContents`, `AccountFolders.detect` | `--selftest-update`, `testDetectionFindsTheAccountFolderWhateverItsName` | Update, Find Missing and Update All Accounts (D-80) |
| R-1705 | person | `WindowModel.revealOrReload`, `QuickLook` | `--selftest-views` | Command-R reveals in Library and Organise panes, reloads in the browser (1.8); Quick Look needs a person |
| R-1706 | built | `WindowModel.saveFolder` | `--selftest-analyse`, `--selftest-views` | The Library pane's folder is Collect's save folder (D-70) |
| R-1801 | person | `LibraryModel.handleDrop`, `LibraryModel.importFiles`, `MediaPull/Platform/DragSupport.swift` | none | Drag and drop needs a person |
| R-1802 | person | `ItemDragPayload`, `MediaPull/Platform/DragSupport.swift` | none | Large drags and file promises need a person to check |
| R-1901 | built | `JobKind` | `--selftest-analyse`, `--selftest-galleries`, `--selftest-video-download` | All eight kinds exist; Convert and Engine Update not run by a self-test |
| R-1902 | person | `JobState`, `ActivityView` | `--selftest-url` | Waiting shows a countdown (1.8); needs a real wait to see |
| R-1903 | amended | `ActivityView`, `Job` | `--selftest-analyse` | D-77: Pause for Analyse jobs; Cancel and Retry Failed elsewhere; no speed column |
| R-1904 | built | `ActivityView`, `AccountFolderRecord`, `EngineService.startUpdate` | `--selftest-update` | D-80: the place is kept per account folder; Activity offers Resume, and any update continues it after pulling the newest posts |
| R-1905 | person | `JobCenter.finish`, `EngineService.handleCheckpoint` | `--selftest-url` | Both notices follow the setting (1.8) |
| R-2010 | built | `AppTheme`, `AppTheme.currentAccent` | `--selftest-theme`, `--selftest-idle` | Nine static themes; accent, chips, grid selection and title wash |
| R-2401 | person | `ReadOnlyWebView`, `ThemeSwatch`, `PeopleView`, `TabStrip` | `scripts/lint_invariants.py` | Icon-only buttons labelled (lint enforced), tap controls are buttons to VoiceOver, Reduce Motion honoured (1.8); VoiceOver pass needs a person |
| R-2402 | person | `MediaPull/Resources/Localizable.xcstrings` | `scripts/check.sh` | String Catalog added (1.8); Xcode fills it from the code when the project is opened |
| R-3101 | built | `WindowModel.extractPDF`, `WindowModel.extractAllDocuments`, `WindowModel.gridAcceptDrop` | `--selftest-pdf-links` | Pane PDFs, linked PDFs (gate, Referer, non-PDF rejected), Open PDF and drops on the grid |
| R-3102 | built | `PDFImageExtractor.extract` | `testEmbeddedImagesComeOutAtOriginalSize` | Inherited resources, nested forms, one copy per object, 24 px floor, masks skipped, locked PDFs reported |
| R-3103 | built | `ArchivePlanner.sidecar`, `ArchivePlanner.folder` | `--selftest-pdf-links` | PDF folder for local files, subcategory pdf, page_url never a local path |
| R-3201 | built | `EditorModel`, `CropAspect`, `CropCanvas` | `--selftest-edit`, `testRotateFlipAndCrop` | Crop box dragging itself is checked by a person |
| R-3202 | built | `EditorModel.saveFile`, `ImageEditing.writeReoriented`, `ImageEditing.Reorientation` | `testRotationAndFlipComposeAndStayLossless`, `--selftest-edit` | D-34 amended: rotate or flip of a JPEG is lossless; sidecar follows |
| R-3203 | person | `EditorModel.saveItem` | `--selftest-edit` | Saving an edited extracted item and Keep Name Only need a person |
| R-3301 | built | `DuplicateCommands`, `LibraryModel` | `--selftest-duplicates` | Frames, badges, bar with colour key, Only Duplicates, context menu and Preview list |
| R-3302 | built | `DuplicateFinder`, `PerceptualHash` | `testFingerprintsMatchResizedCopiesButNotOtherPictures`, `testGroupsIdenticalAndSimilarFilesAcrossFolders` | Size-gated SHA-256, pHash, dHash, colour grid, 8 bands |
| R-3303 | built | `DuplicateSensitivity`, `DuplicateCommands` | `testColourVersionsOfOnePhotoAreNotDuplicates` | Three sensitivities with the stated thresholds; highlight on by default |
| R-3304 | built | `DuplicateFinder` | `testGroupsIdenticalAndSimilarFilesAcrossFolders` | Cached in duplicates.json; four files at a time off the main actor |
| R-3401 | built | `VideoEditorModel`, `VideoEditorView` | `--selftest-video` | Video editor in the Preview pane with frame stepping, Save Frame, Trim, rename |
| R-3402 | built | `VideoEditorModel.saveFrame`, `VideoTools.frame` | `testFrameGrabIsFullSizeAndTrimKeepsTheSelection`, `--selftest-video` | Exact frame, full size, PNG named with _frame_ time |
| R-3403 | person | `VideoEditorModel.saveTrim`, `VideoTools.trim` | `testFrameGrabIsFullSizeAndTrimKeepsTheSelection`, `--selftest-video` | Passthrough trim is tested; choosing the range in the player's trim bar needs a person |
| R-3404 | built | `VideoEditorModel.writeSidecar` | `--selftest-video` | frame_time and trimmed_from written; num, count and duration dropped for frames |
| R-3501 | amended | `op_video_info`, `VideoForm`, `VideoPage.isLikely` | `--selftest-video-download`, `testVideoPagesAndDates` | D-69: the sheet became the Downloads pane video form |
| R-3502 | built | `VideoDownloadFormat`, `VideoForm` | `testResolutionsPerFormat`, `testSelectorsSizesAndConversion` | Five formats, real heights, 4K and 2K and high fps marked, DRM hidden, size estimate |
| R-3505 | built | `stream_options`, `VideoForm` | `test_stream_options_map_extras` | Playlist range, count, dates, subtitles, thumbnail, description, speed limit |
| R-3503 | built | `EngineService.saveVideo` | `--selftest-video-download` | site/uploader folders, upload date names, MP4 sidecar; WebM and M4A without one (D-56) |
| R-3504 | amended | `YOUTUBE_PATHS` | `test_youtube_video_reads_are_allowed_and_nothing_else`, `test_youtube_channel_pages_are_read` | D-72 adds /youtubei/v1/browse beside player and next |
| R-3601 | built | `Analyzer.analyse`, `Thumbnailer.videoFrame` | `--selftest-analyse` | Videos are analysed a tenth of the way in (1.8) |
| R-3602 | built | `Analyzer`, `scripts/models.lock` | `--selftest-analyse` | Bundled pinned models on Neural Engine and CPU; duplicates stay model-free |
| R-3603 | built | `AnalysisService.openStore`, `Analyzer.recogniseText` | `--selftest-analyse` | A damaged store is set aside and analysis starts again; Settings says so (1.8) |
| R-3604 | built | `ScreenshotRule` | `testScreenshotRule` | Marker, file name and screen-size rules only |
| R-3605 | built | `OfflineGeocoder` | `testGeocoderFindsTheNearestPlaceWithinFiftyKilometres` | Bundled GeoNames index, nearest place within 50 km |
| R-3606 | built | `ColourName.dominant` | `testDominantColour` | Saturation-weighted 8x8 grid, fixed palette of twelve names |
| R-3607 | built | `AnalysisService.deleteAllAnalysis`, `AnalysisService.removeVectorFiles`, `AnalysisSettings` | `testVectorStoreRemovesRowsAndKeepsTheRest`, `--selftest-analyse` | Every vector file removed; the button is named Analyse Again in the spec too (D-77 table) |
| R-3701 | amended | `QueryBar`, `WindowModel.find`, `Preferences.libraryQuery` | `--selftest-analyse` | D-77: sort and filters kept between launches for the Library as a whole; Command-F focuses the search (1.8) |
| R-3702 | built | `LibrarySort`, `MediaDates.effective`, `LibraryQuery.events` | `testDateFallsBackFromCaptureToMetadataToFile`, `testEventsSplitAtTheGap`, `testSortsBySizeAndSource` | All sorts, both directions, events at the gap |
| R-3703 | built | `FilterMenu`, `LibraryQuery.apply`, `AnalysisService.queryContext`, `AnalysisService.forgetUnknownPeople` | `testFiltersCombine`, `--selftest-analyse` | Format filter added; unknown people dropped from filters; opened list folders use the same context (1.8) |
| R-3704 | built | `LibraryQuery.apply`, `MediaListing.load`, `AnalysisService.meaningScores` | `testSearchMatchesTextTagsAndSimilarity`, `--selftest-analyse` | Only media files count toward the 50,000 listing limit, which the header and Organise now state (1.8) |
| R-3705 | built | `SimilarSets`, `LibraryFilter.similarOnly` | `testCloseVectorsFormSets`, `--selftest-analyse` | Filter and Group Similar sort; not marked in the grid |
| R-3706 | built | `SubjectClassifier`, `OrganiseModel.autoSort` | `--selftest-analyse` | Fixed list plus added words, threshold, Unsorted; Library menu opens Organise generally |
| R-3801 | built | `WindowSection`, `OrganiseModel.open` | `--selftest-analyse` | Collect and Organise tabs, Cmd-Ctrl-1 and 2, Open Folder, drops, panes stay mounted |
| R-3802 | built | `OrganiseModel`, `OrganisePane` | `--selftest-analyse`, `--selftest-views`, `testOrganiseArrangementsHoldOnlyOrganisePanes` | Source, Organise, Target panes; in place, copy or move to an opt-in target (D-68, D-76) |
| R-3803 | person | `FolderOperations`, `OrganisePane.gridMenu` | `testRunMovesSidecarsAndUndoRestoresTheTree`, `testMergeCombinesSameNamedFolders` | Move To... added (1.8); the panel needs a person |
| R-3804 | built | `FolderOperations.sort`, `FolderOperations.samePlace`, `OperationJournal.run` | `testCaseOnlyFolderDifferenceRenamesTheFolderOnce`, `testFlattenNumbersCollisionsAndKeepsDatePrefix` | Case-only folder differences rename the folder once (1.8) |
| R-3805 | built | `OrganiseModel.autoSort`, `OrganisePlan` | `--selftest-analyse` | Sorts only what the Source shows; no matches means no plan and a message (1.8) |
| R-3806 | built | `OperationJournal.undo`, `OperationJournal.redo`, `WindowModel.registerUndo`, `AppModel.applyChange` | `testRedoDoesTheChangeAgainAndCanBeUndone`, `testUndoOfACopyKeepsCopiesEditedSince`, `testUndoLeavesChangedFilesInPlace` | Every Library and Organise change undoable with ⌘Z and redoable with Shift-⌘Z (1.8) |
| R-3807 | built | `OperationJournal.run`, `OrganiseModel.execute` | `testACancelledOperationCanBeUndone` | A cancelled operation stops and can be undone (1.8 test) |
| R-3901 | built | `FaceOptIn`, `FaceSettings`, `AnalysisService.deleteAllFaceData`, `AnalysisService.removeVectorFiles` | `--selftest-analyse`, `testFaceVectorsStayExcludedFromBackups` | Opt-in, off switch that keeps data, and Delete All removing every face file (1.8) |
| R-3902 | built | `FaceDetector`, `FaceEncoder`, `FaceRules.minimumPixels` | `--selftest-analyse` | SCRFD with five landmarks, Vision fallback, 32 px floor, mirrored-crop fusion |
| R-3903 | built | `FaceGrouping.group`, `AnalysisStore.pruneOrphans` | `testFaceGroupingRespectsCorrections`, `testOrphanedResultsFacesAndPeopleArePruned` | Faces of files that are gone are pruned after each scan (1.8) |
| R-3904 | built | `PeopleView`, `AnalysisService.split`, `AnalysisService.notThisPerson`, `AnalysisStore.pruneOrphans` | `testNotThisPersonSurvivesRegrouping`, `testOrphanedResultsFacesAndPeopleArePruned` | Corrections persist; people of deleted files no longer linger (1.8) |
| R-3905 | built | `NameSuggestion.suggest`, `NameSuggestion.looksLikeName` | `testNameSuggestion` | Suggested only; applied after one click on Use Name |
| R-3906 | amended | `FolderOperations.sort`, `OrganiseModel.autoSort` | `testSortClonesGroupPhotosAndUsesUnsorted` | D-77: photos without a recognised person stay where they are |
| R-3907 | built | `FaceOptIn.limits` | `--selftest-analyse` | Full limits text (1.8) |

## Settings and shortcuts (sections 20 and 21)

These tables have no requirement numbers; differences found in the 1.8 pass:

- §20: Conversion tab — named "Formats"; SVG rasterising in Archive has no setting to turn it off (`rasterizeSVGInArchive` is never exposed)
- §20: Conversion, include inline SVG (off) — no such setting
- §20: Browser pane — there is no Browser settings pane; Clear All Website Data is under Advanced
- §20: Browser, allow pop-ups in new windows — no setting; pop-ups always open as tabs
- §20: Analysis, Rebuild Analysis — labelled "Analyse Again"
- §20: Faces, on or off — once opted in there is no off switch; turning off only happens through Delete All Face Data
- §20: Organise, keep undo history — there is no Organise pane; the picker sits in the Analysis tab
- §20: Advanced, download concurrency limits — missing (only "Save N files at a time" in General)
- §20: Advanced, allow insecure http media (on, D-21) — no setting; always allowed
- §20: Advanced, Export Diagnostics — missing; "Show Logs Folder" opens ~/Library/Logs instead
- §20: Advanced, verbose engine logging (off) — missing
- §21: ⌘. — not bound in Collect; it does not stop loading or auto-scroll (it is only Discard in Organise)
- §21: ⌘F — only toggles the Extracted filter bar; never focuses the Library or Organise search field
- §21: ⇧⌘Z in Organise — Redo is missing; undo actions register no redo
- §21: ⌘A — the menu's Select All Media is ⌥⌘A; ⌘A selects all only through the grid's own Select All when it has focus
- §21: ⌘R in Library — Reveal in Finder is not bound; ⌘R always reloads the page
