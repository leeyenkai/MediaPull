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
| R-201 | partial | `WalkthroughView`, `InstagramSettings` | none | First-run note is generic (no Instagram or account-risk wording); no sign-in banner, full note only in Settings |
| R-202 | partial | `PacingPreset`, `EngineService.enqueueInstagram`, `EngineService.resumeAfterCheckpoint`, `configure_gallery_dl` | none | Gentle default, one Instagram job at a time and no retries are in code; no test |
| R-301 | built | `MediaPull.xcodeproj/project.pbxproj`, `MediaPullKit/Package.swift` | `scripts/check.sh` | macOS 26 deployment target, ARCHS arm64; check.sh builds for arm64 |
| R-302 | built | `MediaPull.xcodeproj/project.pbxproj`, `MediaPullKit/Package.swift` | `scripts/check.sh` | Swift 6, approachable concurrency, MainActor default in the app; @concurrent used in the package |
| R-303 | built | `MediaPull/Platform/PaneSplit.swift`, `MediaPull/Platform/MediaGridView.swift` | `scripts/check.sh` | check.sh lint allows import AppKit only under MediaPull/ |
| R-304 | built | `MediaPullKit/Package.swift`, `scripts/fetch-engines.sh`, `scripts/build-ffmpeg.sh` | `scripts/fetch-engines.sh` | No package dependencies; engine wheels and ffmpeg source verified by SHA-256 when fetched |
| R-305 | partial | `scripts/make-dmg.sh`, `MediaPullKit/Sources/MediaPullStore/Store.swift` | none | Not sandboxed and bookmarks kept; DMG is Apple Development signed, not Developer ID or notarized |
| R-306 | partial | `scripts/bundle-engines.sh` | `scripts/install-app.sh` | Nested Mach-O re-signed only for Release with an identity; nothing checks runtime flag or timestamp |
| R-307 | partial | `scripts/bundle-engines.sh`, `EngineSettings` | none | Licence texts are bundled; no notice of where to obtain source code; no test |
| R-308 | partial | `Config/Info.plist`, `RequestPolicy.evaluate` | none | Info.plist sets NSAllowsArbitraryLoads, so ATS is off for all app requests, not only http media |
| R-401 | built | `MediaPullKit/Package.swift`, `scripts/check.sh` | `scripts/check.sh` | Lint enforces SwiftData, WebKit, URLSession, Process, Vision and Core ML boundaries and D-59 bans |
| R-402 | partial | `ExtractionIngestor`, `MediaProber`, `ThumbnailLoader` | none | Decoding, parsing and hashing run off the main actor by design; no test or lint checks it |
| R-403 | partial | `BridgeClient.run`, `stop_children` | none | Bridge and ffmpeg run per job and are stopped with it; no test checks no process remains |
| R-501 | built | `GatedRequest`, `NetworkGate`, `RedirectGuard`, `RedirectPolicy.nextHeaders` | `testRedirectsKeepCookiesOnlyOnTheSameOriginAndRecomputeTheReferer`, `testCookiesStayBehindAndEveryHopIsLogged`, `testACutShortDownloadIsNotKept` | Per-hop Referer and same-origin cookies since 1.8; per-host limits follow redirects |
| R-502 | partial | `RequestPolicy.evaluate`, `RedirectPolicy.nextHeaders` | `testOnlyReadsAreAllowed`, `testRedirectsAreCheckedAgainstThePolicy` | Plain http is allowed for every purpose, not only media; spec or code to decide |
| R-503 | built | `NetworkGate.entries`, `NetworkGate.logCapacity`, `AdvancedSettings` | `testCookiesStayBehindAndEveryHopIsLogged` | 2,000-entry in-memory log shown as Network activity; never written to disk |
| R-504 | partial | `ItemMediaPreview`, `WindowModel.previewFile`, `QuickLook` | `scripts/check.sh` | No resource-loader scheme: video plays from a gate download; lint covers only AsyncImage and remote Data |
| R-505 | built | `Engines/bridge/egress_guard.py`, `READ_POSTS`, `install_guard` | `test_write_operations_are_blocked`, `test_audited_site_reads_are_allowed`, `test_uploads_and_other_methods_are_blocked` | Read-only POST list per D-72 (amends D-40), already in the spec text |
| R-506 | built | `configure_gallery_dl`, `stream_options` | `test_engine_cache_stays_in_memory` | Config cleared per job, caches in memory, no cookies-from-browser, only the job's site cookies |
| R-507 | partial | `scripts/build-ffmpeg.sh` | none | Built with --disable-network and only file and pipe protocols; no test |
| R-508 | built | `ReadOnlyWebView`, `BrowserController.install`, `WebViewSetup.uploadBlockingRules`, `MediaPullKit/Sources/MediaPullBrowser/Resources/guard.js` | `--selftest-browser` | Rules compile first at launch; pages wait for them; a failure is reported (1.8) |
| R-509 | partial | `WebViewSetup.uploadBlockingRules` | none | Rules block only upload hosts, not analytics; no test |
| R-510 | partial | `MediaPullKit/Package.swift`, `MediaPull.xcodeproj/project.pbxproj` | none | No SDKs or update frameworks present; nothing checks for them |
| R-511 | partial | `MediaPullKit/Sources/MediaPullEngines/BridgeClient.swift` | none | os.Logger app.mediapull used for the engine only; no rolling file in Logs/MediaPull, no Export diagnostics |
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
| R-803 | partial | `AddressInput.parse`, `WindowModel.submitAddress` | `testClassification` | No Pull or Scan offers for @name in the field; no Save Stories or Save Highlight actions |
| R-804 | person | `CookieBridge.isSignedInToInstagram`, `InstagramSettings`, `AppCommands` | none | Sign In in Go menu and Settings (toolbar moved by D-48); needs a real sign-in |
| R-805a | built | `TabStrip`, `TabChip`, `WindowModel.newTab`, `WindowModel.reopenClosedTab`, `BrowserController` | `--selftest-browser` | Tabs, context menu, Cmd-click tabs and This Page chip; self-test opens, filters and closes tabs |
| R-805b | built | `BookmarkStar`, `BookmarksList`, `StartPage`, `BookmarkCollection` | `testBookmarksAndFolders`, `--selftest-browser` | Star editor, folders, Bookmarks menu and start page with four starting points |
| R-805c | built | `HistoryList`, `BrowsingStore.recordVisit`, `BrowsingHistory` | `testHistoryRecordsOncePerAddressAndClears` | 5,000-address cap, clear ranges, setting to stop recording, JSON in Application Support |
| R-805 | person | `CookieBridge.clearWebsiteData`, `InstagramSettings`, `AdvancedSettings` | none | Needs a signed-in session to check |
| R-806 | amended | `BrowserController.userAgent`, `configure_gallery_dl` | `test_browser_user_agent_goes_with_cookies` | D-24: engines keep their own UA; the browser UA goes only with cookies, never for Instagram |
| R-807 | person | `BrowserController`, `FolderPicker.chooseSaveLocation` | none | Pop-ups open as tabs; page downloads use the save dialog in the save folder (D-73) |
| R-808 | person | `Banner`, `EngineService.handleCheckpoint`, `EngineService.resumeAfterCheckpoint` | none | Checkpoint banner with Resume and Cancel Instagram Jobs; needs a real checkpoint |
| R-901 | built | `WebViewSetup.configuration`, `MediaPullKit/Sources/MediaPullBrowser/Resources/extract.js` | `--selftest-url` | Document start, all frames, isolated MediaPull world, handler only in that world |
| R-902 | partial | `MediaPullKit/Sources/MediaPullBrowser/Resources/extract.js` | `testSrcsetCandidatesMergeAndRank`, `--selftest-url` | No Include inline SVG option; PerformanceObserver skips media segments |
| R-903 | built | `MediaPullKit/Sources/MediaPullBrowser/Resources/extract.js` | `--selftest-url` | MutationObserver with filtered attributes, idle chunks of 2,000, load events captured |
| R-904 | built | `MediaPullKit/Sources/MediaPullBrowser/Resources/extract.js` | `--selftest-url` | 50 ms first flush, 300 ms after, 500 candidates or 256 KB per message |
| R-905 | partial | `ExtractionMessageHandler`, `ExtractionIngestor.ingest` | `testLateBatchKeepsItsOwnPage` | Frame origin from frameInfo, but the main-frame page URL is taken from the batch's own page field |
| R-906 | built | `WindowModel.toggleAutoScroll`, `BrowserController.scrollStep` | `--selftest-url` | Stops after three quiet steps or when the person stops it |
| R-907 | built | `ExtractionMessageHandler`, `ExtractionIngestor` | `testSrcsetCandidatesMergeAndRank` | Raw JSON handed to the ingestor actor; snapshots every 250 ms at most |
| R-908 | built | `WindowModel.clear`, `MediaFilter`, `Preferences` | `--selftest-browser` | Accumulates until Cmd-K; grouped by page; This Page filter; Clear on navigation setting |
| R-909 | built | `URLNormalizer.normalize` | `testSrcsetCandidatesMergeAndRank`, `testRulesKeepOtherParametersAndPaths` | Resolved against the frame; queries kept unless a CDN rule applies |
| R-910 | built | `ExtractionIngestor.markDuplicate`, `CDNRules` | `testRenditionsInDifferentElementsMerge`, `testWordPressRenditionsShareOneAsset` | Same element and CDN asset key merge; identical checksums marked duplicate |
| R-911 | partial | `MediaProber`, `NetworkGate.head`, `MP4Probe` | `testMalformedMP4BoxesDoNotCrash`, `--selftest-url` | Range 0-65535 GET as written, but the moov tail read is the last 1 MB, not 512 KB |
| R-912 | built | `MediaProber`, `WindowModel.ensureProbed`, `WindowModel.gridAppeared` | `--selftest-url` | Visible, selected or filter-needed items only; 6 at once; cached per session |
| R-913 | built | `CDNRules`, `WindowModel.ensureProbed` | `testNYTimesRendition`, `testTwitterWordPressAndSigned`, `testSmallerGuessedOriginalIsRejected` | Derived originals unverified until checked; signed URLs untouched |
| R-914 | partial | `VariantRanker.best`, `VariantRow` | `testSrcsetCandidatesMergeAndRank`, `testEqualValuesKeepDiscoveryOrder` | Ranking as written; Preview marks the chosen variant but never says why |
| R-915 | built | `URLNormalizer.referer`, `RequestContext`, `SavePipeline` | `--selftest-url` | Pane User-Agent, image Accept header, strict-origin-when-cross-origin Referer |
| R-916 | built | `URLNormalizer.mayCarryCookies`, `PublicSuffix` | `testCookiesNeedTheFrameToo`, `testRegistrableDomain` | Cookies only when the media is same-site with the page and the reporting frame (1.8) |
| R-917 | built | `MediaProber.bestHLSResolution`, `BridgeEngineFetcher`, `stream_options` | `test_stream_options_map_extras` | Stream items sized from the manifest; saved by yt-dlp with Referer and first-party cookies |
| R-918 | partial | `ExtractionIngestor`, `SaveFailure` | none | Only EME mediaKeys marks Protected; manifests not checked for SAMPLE-AES, AES-128 or ContentProtection |
| R-919 | partial | `BrowserController.readBlob`, `ExtractionIngestor` | none | blob: images read in the page at save; blob: videos not shown as Stream or linked to a manifest |
| R-1001 | partial | `MediaGrid`, `WindowModel.gridInfo` | `--selftest-url` | Virtualized grid with type, format, size, bytes, duration and state badges; no insecure badge |
| R-1001a | partial | `ZoomSlider`, `WindowModel.gridMagnify`, `WindowModel.zoomRange`, `AppCommands` | `--selftest-zoom` | Audit: shortcuts unverified; Opt-Cmd-plus bound to plus only and disabled outside Icons view |
| R-1002 | partial | `ThumbnailLoader`, `WindowModel.gridThumbnail` | `--selftest-views` | Smallest adequate variant through the gate, but decodes up to 768 px, not 512 |
| R-1003 | partial | `MediaCollectionView`, `GridKeyRouter`, `WindowModel.selectAll`, `WindowModel.deselectAll` | none | Audit: Select All Media is Opt-Cmd-A, not Cmd-A; other selection keys need a person |
| R-1004 | partial | `WindowModel.gridMenu` | none | No Copy Image or Copy Original URL items |
| R-1005 | partial | `ExtractedHeader` | none | Header shows no page session title; buttons are named Download and List, not Pull, Scan, Save This Post |
| R-1006 | partial | `FilterBar`, `QuickFilterBar`, `MediaFilter` | `testFilterHidesTinyAndMatchesSize`, `testLengthFilterKinds` | UI lacks max width and height, shorter side, presets, megapixels, duration, custom ratio, IG dates |
| R-1006a | built | `QuickFilterBar`, `MediaFilter` | `testResolutionSliderUsesLongestSide`, `testLengthFilterKinds` | Type chips, longest-side slider with the listed stops, shown of found count |
| R-1007 | built | `SortOrder`, `MediaFilter.sorted` | `testEqualValuesKeepDiscoveryOrder` | All seven sort orders |
| R-1008 | partial | `MediaFilter`, `WindowModel.refilter` | none | Audit gap: filter state not persisted per window, no named presets, no 5,000-item timing test |
| R-1009 | partial | `PreviewPane`, `ItemMediaPreview`, `ItemDetails`, `FileDetails` | `--selftest-edit` | Preview, variants, source, name and actions present; the reason for the chosen variant is missing |
| R-1009a | built | `WindowModel.showInPreview`, `WindowModel.openEditor`, `EditorModel` | `--selftest-edit` | Editor opens in the Preview pane; unsaved edits keep it from being replaced |
| R-1010 | person | `QuickLook`, `WindowModel.quickLook`, `WindowModel.previewFile` | none | Downloads through the gate to the cache, then previews the local file |
| R-1101 | person | `InstagramForm`, `EngineService.refreshSignIn` | `--selftest-pullsheet` | Sign-in state and Sign In shown in the Downloads pane; a signed-in pull needs a person (D-53) |
| R-1102 | person | `EngineService.describe`, `Engines/bridge/mediapull_bridge.py` | none | Private account error mapped to a fatal private event; only a signed-in pull can show it |
| R-1103 | amended | `EngineCookies`, `CookieFile.write`, `BridgeEngineFetcher.fetch` | `testCookieFileRoundTrip`, `test_browser_user_agent_goes_with_cookies` | D-24: engines keep their own User-Agent for Instagram; cookies exported, written back and deleted |
| R-1104 | partial | `AddressInput.parse`, `InstagramIDs`, `DownloadsModel.use` | `testClassification` | A bare name is refused, highlight URLs get no download, a story URL pulls the whole account |
| R-1105 | partial | `InstagramForm`, `PullDraft`, `AccountCard` | `--selftest-pullsheet` | Verify mode and the request and time estimate were never built |
| R-1105a | built | `InstagramContent`, `ArchivePlanner.folder`, `EngineService.startPull` | `testDefaultsAndGroups`, `testFoldersForEachKindOfContent`, `test_lists_hold_names_and_are_written_as_csv` | Content choices map to gallery-dl subcategories and folders (D-52, D-54) |
| R-1105b | built | `InstagramDateWindow.bounds`, `KnownTracker.outside_dates` | `testDateWindows`, `test_undated_items_are_kept_and_never_end_a_listing` | Date window applied in the bridge (D-38) |
| R-1106 | person | `EngineService.startPull`, `SavePipeline.saveStaged` | `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites` | Staged files go through the save pipeline; a signed-in Instagram pull needs a person |
| R-1107 | person | `EngineService.startPull`, `SavePipeline.acquire`, `BridgeEngineFetcher.fetch` | `--selftest-site` | Scan then save with re-resolve on 403 or 410; Instagram scans need a signed-in person |
| R-1108 | person | `EngineService.startPull`, `ArchivePlanner.folder` | none | Download This Post pulls one post into the owner's folder; needs a signed-in pull |
| R-1109 | partial | `ArchivePlanner.sidecar`, `ItemDetails` | none | original_width and height recorded, but the 1080 or 1440 px note is not in the UI; no test |
| R-1110 | partial | `VideoCodecPolicy.selector`, `MediaConverter.convertVideo` | none | Inherits R-1607 gaps (hev1 not retagged, AV1 fails without hardware decode); no test |
| R-1111 | built | `ArchivePlanner.sidecar`, `NameTemplate.archiveEngine` | `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites` | Carousel items numbered from 1 with num and count in the sidecar |
| R-1112 | partial | `KnownTracker`, `EngineService.startPull` | none | Cursor saved per page but used only by the in-memory Resume; a new pull after quitting starts over |
| R-1113 | person | `PacingPreset.delay`, `EngineService.enqueueInstagram`, `HostLimiter` | none | Presets, one Instagram job at a time and 2 CDN downloads; only a signed-in pull shows them |
| R-1114 | partial | `classify_instagram_error`, `EngineService.handleCheckpoint`, `EngineService.resumeAfterCheckpoint` | `test_checkpoints_belong_to_instagram_only` | Resume after a challenge is not held until a sessionid returns; cooldown steps reset per pull, not per day |
| R-1115 | built | `ArchivePlanner.folder`, `NameTemplate.archiveAvatar`, `FingerprintIndex` | `testFoldersForEachKindOfContent`, `testFlatFoldersWhenSortingByTypeIsOff` | Folders by type (D-54), avatar named at pull time and deduplicated, collab owner recorded (D-11) |
| R-1111a | built | `DownloadsPane`, `DownloadsModel.use`, `WindowModel.showDownloads` | `--selftest-galleries`, `--selftest-video-download`, `--selftest-pullsheet` | Instagram, video and gallery options in one pane, saving into the window's save folder (D-69, D-70) |
| R-1111b | built | `SiteCatalogue`, `GalleryError`, `SiteKeychain`, `configure_gallery_dl` | `testBundledCatalogueNamesSitesAndSignIn`, `test_site_choices_reach_gallery_dl_and_unknown_switches_do_not`, `--selftest-galleries` | Per-site parts, switches, sign-in, keys and plain errors (D-71) |
| R-1201 | built | `WindowModel.siteExtractorCategory`, `EngineService.siteInfo`, `op_supports` | `--selftest-site`, `testFinalEventsAreNeverLost` | Debounced 1.5 s supports check, cached per URL, Instagram excluded |
| R-1202 | built | `EngineService.startSiteScan`, `EngineCookies` | `--selftest-site` | Scan with the site's own cookies; the button now reads Get Original Files |
| R-1203 | partial | `SavePipeline.request`, `BridgeEngineFetcher.fetch`, `EngineService.startSiteScan` | `--selftest-site` | A fixed 1 to 3 s sleep-request replaces gallery-dl per-site intervals, so pacing can be faster |
| R-1204 | amended | `ArchivePlanner.sidecar` | `--selftest-site` | D-28: uploader recorded as author, username only for user pages, files under the site folder |
| R-1301 | built | `BridgeClient.run`, `EnginePaths.pythonPaths`, `configure_paths` | `testFinalEventsAreNeverLost`, `testSelfTestPassesAndGuardBlocksWrites` | Isolated interpreter, clean environment, staging working folder, request on standard input |
| R-1302 | built | `BridgeClient.run`, `BridgeEvent.decode`, `Emitter` | `testFinalEventsAreNeverLost`, `test_events_are_valid_json_even_with_nan_or_huge_numbers` | JSON Lines events; standard error logged privately |
| R-1303 | partial | `BridgeClient.run`, `EngineService.startPull` | `test_signal_path_writes_a_parsable_line_without_the_lock` | Escalation and staging cleanup built; no test of SIGINT, SIGTERM, SIGKILL timing |
| R-1304 | partial | `EnginePaths.pythonPaths`, `EngineManager.install` | none | Updates go to Application Support and the bundle is untouched; no test |
| R-1305 | built | `EngineManager.install`, `EnginePaths.pythonPaths` | `testCandidateEnginePathsComeFirstWithoutTouchingActiveFile`, `testVersionComparisonAndDependencies` | The candidate is self-tested from its folder; active.json is written only after it passes (1.8) |
| R-1306 | partial | `AppModel.checkForEngineUpdates`, `AppModel.installEngineUpdates` | none | Weekly check on and installs wait for jobs, but no badge in Settings or Activity; no test |
| R-1307 | partial | `EngineManager.usePreviousVersions`, `EngineManager.resetToBuiltIn` | none | Previous version kept, two per engine, reset built; no test |
| R-1308 | built | `EngineManager.updatable`, `EngineManager.unmetDependency` | `testVersionComparisonAndDependencies` | Only gallery-dl and yt-dlp update; dependency needs block the update |
| R-1401 | built | `SavePipeline.saveOne`, `SavePipeline.finalize`, `NetworkGate.download` | `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites`, `testACutShortDownloadIsNotKept` | Step 3 Content-Length check added in 1.8; identical concurrent saves re-checked after reserving |
| R-1402 | built | `SavePipeline.place` | `testParallelPlacementNeverOverwrites`, `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites` | Exclusive rename, never overwrites media or a left-behind metadata file |
| R-1403 | built | `AppModel.save`, `WindowModel.apply` | `--selftest-url` | One job with per-item results and Retry Failed; retry itself not exercised by the self-test |
| R-1404 | built | `WindowModel.saveFolder`, `WindowModel.useSaveFolder`, `SaveFolderMenu` | `--selftest-analyse` | One save folder per window, outside folders shown without joining the library (D-70) |
| R-1501 | built | `Sidecar.sidecarURL` | `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites` | Sidecar named after the full file name |
| R-1502 | built | `SaveLayout.allows`, `SavePipeline.finalize` | `testSVGIsSkippedInArchiveButKeptInPlain`, `--selftest-video-download` | Archive formats only; chosen WebM or M4A kept without metadata (D-56, D-13) |
| R-1503 | partial | `ArchivePlanner.fileName` | `testArchiveNamesNeverMatchForbiddenPattern` | Names start with the timestamp, but an audio-only MP4 is saved as a video in Archive folders |
| R-1504 | partial | `FileNaming.isForbiddenArchiveName`, `NameTemplate.archiveProblems`, `ArchivePlanner.fileName` | `testArchiveNamesNeverMatchForbiddenPattern` | Pattern check runs before sanitising, so a cleaned name can still match |
| R-1505 | built | `FileNaming.safeTopFolder`, `ArchivePlanner.folder` | `testReservedFoldersAndLengths`, `testReservedNamesGetAnUnderscore` | Reserved first-level names get a leading underscore |
| R-1506 | partial | `AppModel.locationWarning`, `LibraryPane` | none | iCloud and network warning shown under the folder; no test |
| R-1507 | built | `Sidecar`, `ArchivePlanner.sidecar` | `testArchiveSaveWritesSidecarDedupesAndNeverOverwrites`, `testInstagramSidecarMatchesContract` | Closed struct; no location, engagement or identity keys (D-12) |
| R-1508 | partial | `DateFormats.utc`, `DateFormats.sidecarString` | `testDatesIgnoreUserCalendar` | Formatter fixed, but the test never switches to a non-Gregorian calendar or 12-hour locale |
| R-1509 | built | `ArchivePlanner.sidecar` | `testNumAndCountComeTogether` | Web sidecars carry no num or count (D-10) |
| R-1510 | partial | `FileNaming.sanitize`, `FileNaming.fileName` | `testNamesKeepJoinersButNotControls`, `testReservedFoldersAndLengths` | Joiners kept (D-74); archive name checks run before sanitising, so cleaned names are not rechecked |
| R-1601 | partial | `ImageConversion.stillTarget`, `ImageConversion.analyze`, `MediaConverter.convertImage` | `testPNGStaysUntouchedAndHEICBecomesJPEG`, `testAnimatedPNGAndWebPWithAlpha` | WebP lossless re-sniff past a large profile chunk is a no-op |
| R-1602 | partial | `ImageConversion.convertStill` | `testPDFProfileIsAddedWithoutReencoding` | Properties carried by ImageIO; the Display P3 test covers PDF extraction, not conversion |
| R-1603 | partial | `MediaConverter.convertAnimated`, `FFmpeg.gif`, `ImageConversion.frames` | none | GIF loop count forced to infinite and AVIF frame delays ignored; no test |
| R-1604 | partial | `MediaConverter.convertImage`, `ConversionPolicy` | none | Keep original WebP, AVIF, HEIC applies only to Plain; no test |
| R-1605 | partial | `ConverterView`, `AppModel.convertFiles` | none | No output policy, keep-metadata, subfolder or skip options; no test |
| R-1606 | partial | `LibraryModel.gridMenu`, `AppModel.convertFiles` | none | Convert to JPEG or PNG in the Library menu; no test |
| R-1607 | partial | `MediaConverter.convertVideo`, `FFmpeg.transcodeToHEVC`, `VideoCodecPolicy.selector` | none | hev1 not retagged, Highest compatible re-encodes, higher_res_available never written, AV1 needs hardware |
| R-1608 | partial | `FFmpeg.remuxToMP4`, `VideoStreamInfo.audioNeedsConversion` | none | Opus and Vorbis to AAC 256 kbit/s with aac_at, MOV kept; no test |
| R-1701 | built | `LibraryPane`, `LibraryModel` | `--selftest-views`, `--selftest-url` | Folder tree over contents, sidecars hidden with a badge, columns replace both (D-76) |
| R-1702 | partial | `LibraryModel.promptForRoot`, `LibraryRootInfo`, `AppModel.addRoot` | none | Roots not followed when moved and no root rename UI; no test |
| R-1703 | partial | `LibraryModel.newFolder`, `LibraryModel.commitRename`, `LibraryModel.trash`, `MediaFiles.move` | `testMetadataFilesTravelWithTheirMedia` | Sidecars follow renames, moves and Trash in code; no test of Library rename or trash |
| R-1704 | partial | `FolderWatcher`, `AnalysisService.updateWatch` | none | Recursive FSEvents per root, but roots excluded from analysis are not watched; no test |
| R-1707 | partial | `QueryBar`, `LibraryModel` | none | Command-F toggles Extracted filters and does not focus Library search |
| R-1708 | partial | `PaneViewMode`, `WindowModel.setViewMode`, `MediaOutlineView`, `MediaColumns` | `--selftest-views`, `testAllowedViewsPerPane` | List and Column views have stale-row and selection bugs |
| R-1709 | partial | `MediaOutlineView`, `LibraryModel.listSortChanged` | `--selftest-views`, `testHeaderClicks`, `testColumnsMapToSortsBothWays` | List view rows go stale and selection is lost after changes |
| R-1710 | partial | `MediaColumns` | `--selftest-views` | Column view has stale-row and selection bugs |
| R-1711 | partial | `WindowModel.cellSize`, `PaneViewMode` | `--selftest-views` | Size keys follow only the Extracted pane's view; List and Column bugs as in R-1708 |
| R-1705 | partial | `LibraryModel.gridQuickLook`, `LibraryModel.reveal`, `QuickLook` | none | Command-R goes to the browser reload, not Reveal in Finder; Quick Look needs a person |
| R-1706 | built | `WindowModel.saveFolder` | `--selftest-analyse`, `--selftest-views` | The Library pane's folder is Collect's save folder (D-70) |
| R-1801 | person | `LibraryModel.handleDrop`, `LibraryModel.importFiles`, `MediaPull/Platform/DragSupport.swift` | none | Drag and drop needs a person |
| R-1802 | person | `ItemDragPayload`, `MediaPull/Platform/DragSupport.swift` | none | Large drags and file promises need a person to check |
| R-1901 | built | `JobKind` | `--selftest-analyse`, `--selftest-galleries`, `--selftest-video-download` | All eight kinds exist; Convert and Engine Update not run by a self-test |
| R-1902 | partial | `JobState` | none | All states exist, but waiting shows an end time, not a countdown; no test |
| R-1903 | partial | `ActivityView`, `JobRow` | none | No speed and no Show Page for checkpoints; Pause only for Analyse jobs |
| R-1904 | partial | `EngineService.startPull`, `AppStore.updateAccount` | none | Cursor kept, but no Resume Pull offer at launch |
| R-1905 | partial | `JobCenter.finish`, `JobCenter.post`, `EngineService.handleCheckpoint` | none | Finish notice after 1 minute; blocked notice ignores the setting; no test |
| R-2010 | built | `AppTheme`, `AppTheme.currentAccent` | `--selftest-theme`, `--selftest-idle` | Nine static themes; accent, chips, grid selection and title wash |
| R-2401 | partial | `TopBarButton`, `GridKeyRouter` | | Many icon-only buttons have no accessibility label; Reduce Motion not honoured (tab strip, walkthrough animate) |
| R-2402 | partial | `MediaPull/App/MediaPullApp.swift` | | English only, but there is no String Catalog: user-facing strings are inline literals |
| R-3101 | built | `WindowModel.extractPDF`, `WindowModel.extractAllDocuments`, `WindowModel.gridAcceptDrop` | `--selftest-pdf-links` | Pane PDFs, linked PDFs (gate, Referer, non-PDF rejected), Open PDF and drops on the grid |
| R-3102 | built | `PDFImageExtractor.extract` | `testEmbeddedImagesComeOutAtOriginalSize` | Inherited resources, nested forms, one copy per object, 24 px floor, masks skipped, locked PDFs reported |
| R-3103 | built | `ArchivePlanner.sidecar`, `ArchivePlanner.folder` | `--selftest-pdf-links` | PDF folder for local files, subcategory pdf, page_url never a local path |
| R-3201 | built | `EditorModel`, `CropAspect`, `CropCanvas` | `--selftest-edit`, `testRotateFlipAndCrop` | Crop box dragging itself is checked by a person |
| R-3202 | partial | `EditorModel.saveFile` | `--selftest-edit` | A rotate-only edit re-encodes JPEG at quality 1.0 (D-34 wording) although a lossless rotation exists |
| R-3203 | partial | `EditorModel.saveItem`, `EditorModel.keepNameOnly` | | no test: saving an edited extracted item and Keep Name Only are not exercised |
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
| R-3601 | partial | `Analyzer.analyse`, `Thumbnailer.videoFrame` | `--selftest-analyse` | Videos are analysed at min(1 s, 10 %) of their length, not a tenth of the way in |
| R-3602 | built | `Analyzer`, `scripts/models.lock` | `--selftest-analyse` | Bundled pinned models on Neural Engine and CPU; duplicates stay model-free |
| R-3603 | partial | `AnalysisService`, `Analyzer.recogniseText` | `--selftest-analyse` | A failure to open the analysis store is silent (try?), so analysis quietly does nothing |
| R-3604 | built | `ScreenshotRule` | `testScreenshotRule` | Marker, file name and screen-size rules only |
| R-3605 | built | `OfflineGeocoder` | `testGeocoderFindsTheNearestPlaceWithinFiftyKilometres` | Bundled GeoNames index, nearest place within 50 km |
| R-3606 | built | `ColourName.dominant` | `testDominantColour` | Saturation-weighted 8x8 grid, fixed palette of twelve names |
| R-3607 | partial | `AnalysisService.deleteAllAnalysis`, `AnalysisService.removeVectorFiles`, `AnalysisSettings` | `testVectorStoreRemovesRowsAndKeepsTheRest` | Vector files now removed by name (1.8); the button is labelled Analyse Again, not Rebuild |
| R-3701 | partial | `QueryBar`, `LibraryModel` | | Cmd-F never focuses the Library search field; sort and filters are kept app-wide, not per window |
| R-3702 | built | `LibrarySort`, `MediaDates.effective`, `LibraryQuery.events` | `testDateFallsBackFromCaptureToMetadataToFile`, `testEventsSplitAtTheGap`, `testSortsBySizeAndSource` | All sorts, both directions, events at the gap |
| R-3703 | partial | `LibraryFilter`, `LibraryQuery.matches`, `FolderChildren` | `testFiltersCombine` | People filter keeps unknown ids; List folders ignore People and Similar; no format or aspect filter in the menu |
| R-3704 | partial | `LibraryQuery.textScore`, `MediaListing.load` | `testSearchMatchesTextTagsAndSimilarity` | Listing is capped at 50,000 entries without telling the person |
| R-3705 | built | `SimilarSets`, `LibraryFilter.similarOnly` | `testCloseVectorsFormSets`, `--selftest-analyse` | Filter and Group Similar sort; not marked in the grid |
| R-3706 | built | `SubjectClassifier`, `OrganiseModel.autoSort` | `--selftest-analyse` | Fixed list plus added words, threshold, Unsorted; Library menu opens Organise generally |
| R-3801 | built | `WindowSection`, `OrganiseModel.open` | `--selftest-analyse` | Collect and Organise tabs, Cmd-Ctrl-1 and 2, Open Folder, drops, panes stay mounted |
| R-3802 | built | `OrganiseModel`, `OrganisePane` | `--selftest-analyse`, `--selftest-views`, `testOrganiseArrangementsHoldOnlyOrganisePanes` | Source, Organise, Target panes; in place, copy or move to an opt-in target (D-68, D-76) |
| R-3803 | partial | `FolderOperations`, `SortRules` | `testFlattenNumbersCollisionsAndKeepsDatePrefix`, `testMergeCombinesSameNamedFolders` | No Move To... folder chooser: moves only by drag or to the chosen target |
| R-3804 | partial | `FolderOperations.rename`, `FolderNames.safe`, `AppModel.noteMoved` | `testReservedNamesGetAnUnderscore`, `testCaseOnlyRenameKeepsTheName` | A case-only folder rename renames every file inside it |
| R-3805 | built | `OrganiseModel.autoSort`, `OrganisePlan` | `--selftest-analyse` | Sorts only what the Source shows; no matches means no plan and a message (1.8) |
| R-3806 | partial | `OperationJournal`, `WindowModel.registerUndo` | `testUndoOfACopyKeepsCopiesEditedSince`, `testUndoLeavesChangedFilesInPlace` | Copies edited since are kept (1.8); shared undo manager and missing Redo still open |
| R-3807 | partial | `OrganiseModel.execute`, `OperationJournal` | `--selftest-analyse` | no test: Cancel of an Organise job and undoing a cancelled operation are not exercised |
| R-3901 | partial | `FaceOptIn`, `FaceSettings`, `AnalysisService.deleteAllFaceData`, `AnalysisService.removeVectorFiles` | `--selftest-analyse`, `testFaceVectorsStayExcludedFromBackups` | Every face vector file removed (1.8); still no off switch apart from deleting all face data |
| R-3902 | built | `FaceDetector`, `FaceEncoder`, `FaceRules.minimumPixels` | `--selftest-analyse` | SCRFD with five landmarks, Vision fallback, 32 px floor, mirrored-crop fusion |
| R-3903 | built | `FaceGrouping.group`, `AnalysisStore.pruneOrphans` | `testFaceGroupingRespectsCorrections`, `testOrphanedResultsFacesAndPeopleArePruned` | Faces of files that are gone are pruned after each scan (1.8) |
| R-3904 | built | `PeopleView`, `AnalysisService.split`, `AnalysisService.notThisPerson`, `AnalysisStore.pruneOrphans` | `testNotThisPersonSurvivesRegrouping`, `testOrphanedResultsFacesAndPeopleArePruned` | Corrections persist; people of deleted files no longer linger (1.8) |
| R-3905 | built | `NameSuggestion.suggest`, `NameSuggestion.looksLikeName` | `testNameSuggestion` | Suggested only; applied after one click on Use Name |
| R-3906 | partial | `SortRules.personFolders`, `GroupPhotoPlacement` | `testSortClonesGroupPhotosAndUsesUnsorted`, `testGroupPhotoPlacement` | The option to leave photos without a person in place is missing: they always go to Unsorted |
| R-3907 | partial | `FaceOptIn.limits` | | Limits text omits JPEG, blur, light and covering, and the 32 px figure |

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
