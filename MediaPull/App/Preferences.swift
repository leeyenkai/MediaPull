import Foundation
import MediaPullCore
import MediaPullLibrary
import Observation

/// User settings (SPEC section 20), stored in UserDefaults.
@Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var defaultLayout: SaveLayout { didSet { set(defaultLayout.rawValue, "defaultLayout") } }
    var conflict: ConflictPolicy { didSet { set(conflict.rawValue, "conflict") } }
    var setFileDates: Bool { didSet { set(setFileDates, "setFileDates") } }
    var setWhereFroms: Bool { didSet { set(setWhereFroms, "setWhereFroms") } }
    var clearOnNavigation: Bool { didSet { set(clearOnNavigation, "clearOnNavigation") } }
    var keepOriginalModernImages: Bool { didSet { set(keepOriginalModernImages, "keepOriginalModernImages") } }
    var animated: AnimatedPolicy { didSet { set(animated.rawValue, "animated") } }
    var video: VideoCodecPolicy { didSet { set(video.rawValue, "video") } }
    var pacing: PacingPreset { didSet { set(pacing.rawValue, "pacing") } }
    var typeSubfolders: Bool { didSet { set(typeSubfolders, "instagramTypeSubfolders") } }
    var stopAfterKnown: Int { didSet { set(stopAfterKnown, "stopAfterKnown") } }
    /// Saved posts deleted from Saved posts are not fetched again (D-106); off gives earlier versions' behaviour.
    var savedPostsRemember: Bool { didSet { set(savedPostsRemember, "savedPostsRemember") } }
    var weeklyEngineCheck: Bool { didSet { set(weeklyEngineCheck, "weeklyEngineCheck") } }
    var lastEngineCheck: Date? { didSet { set(lastEngineCheck, "lastEngineCheck") } }
    var notifyWhenDone: Bool { didSet { set(notifyWhenDone, "notifyWhenDone") } }
    var archiveEngineTemplate: String { didSet { set(archiveEngineTemplate, "archiveEngineTemplate") } }
    var archiveWebTemplate: String { didSet { set(archiveWebTemplate, "archiveWebTemplate") } }
    var plainTemplate: String { didSet { set(plainTemplate, "plainTemplate") } }
    var onboardingDone: Bool { didSet { set(onboardingDone, "onboardingDone") } }
    /// Folders saved to recently, newest first, for the save folder menu (D-70).
    var recentSaveFolders: [String] { didSet { set(recentSaveFolders, "recentSaveFolders") } }
    var defaultContent: Set<InstagramContent> { didSet { set(defaultContent.map(\.rawValue).sorted(), "defaultContent") } }
    var autoProbe: Bool { didSet { set(autoProbe, "autoProbe") } }
    var saveConcurrency: Int { didSet { set(saveConcurrency, "saveConcurrency") } }
    var paneArrangement: PaneArrangement { didSet { set(try? JSONEncoder().encode(paneArrangement), "paneArrangement") } }
    var organiseArrangement: PaneArrangement { didSet { set(try? JSONEncoder().encode(organiseArrangement), "organiseArrangement") } }
    var devicesArrangement: PaneArrangement { didSet { set(try? JSONEncoder().encode(devicesArrangement), "devicesArrangement") } }
    var editArrangement: PaneArrangement { didSet { set(try? JSONEncoder().encode(editArrangement), "editArrangement") } }
    /// Where imports from devices go; nil for the default library folder (R-4104).
    var deviceImportFolder: String? { didSet { set(deviceImportFolder, "deviceImportFolder") } }
    /// The folder last shown in Edit/Frame's Media pane.
    var editFolder: String? { didSet { set(editFolder, "editFolder") } }
    /// Apple's downloadable fonts may be fetched (R-4607, D-129); off until the person allows it.
    var allowFontDownloads: Bool { didSet { set(allowFontDownloads, "allowFontDownloads") } }
    /// Edit/Frame's canvas guides (R-4613, D-133): snapping (on by default), rulers (shown by default) and the grid.
    var editSnap: Bool { didSet { set(editSnap, "editSnap") } }
    var editRulers: Bool { didSet { set(editRulers, "editRulers") } }
    var editGrid: CanvasGrid { didSet { set(editGrid.rawValue, "editGrid") } }
    /// Inspector sections the person folded (D-132), by name.
    var foldedSections: Set<String> { didSet { set(foldedSections.sorted(), "foldedSections") } }
    /// What Paste Settings carries (R-4611), by `SettingGroup` raw value.
    var pasteGroups: Set<String> { didSet { set(pasteGroups.sorted(), "pasteGroups") } }
    var includeLivePhotoClips: Bool { didSet { set(includeLivePhotoClips, "includeLivePhotoClips") } }
    /// Automatic sorts put a whole post in one folder unless this is on (R-4208).
    var sortPostImagesIndividually: Bool { didSet { set(sortPostImagesIndividually, "sortPostImagesIndividually") } }

    func arrangement(for group: PaneGroup) -> PaneArrangement {
        switch group {
        case .collect: paneArrangement
        case .organise: organiseArrangement
        case .devices: devicesArrangement
        case .edit: editArrangement
        }
    }

    func setArrangement(_ arrangement: PaneArrangement) {
        switch arrangement.group {
        case .collect: paneArrangement = arrangement
        case .organise: organiseArrangement = arrangement
        case .devices: devicesArrangement = arrangement
        case .edit: editArrangement = arrangement
        }
    }
    var rememberHistory: Bool { didSet { set(rememberHistory, "rememberHistory") } }
    /// Maps of where photos were taken load map images from Apple, so they are off until the person asks (D-110, R-514).
    var showMaps: Bool { didSet { set(showMaps, "showMaps") } }
    var highlightDuplicates: Bool { didSet { set(highlightDuplicates, "highlightDuplicates") } }
    var duplicateSensitivity: DuplicateSensitivity { didSet { set(duplicateSensitivity.rawValue, "duplicateSensitivity") } }
    var thumbnailSize: CGFloat { didSet { set(Double(thumbnailSize), "thumbnailSize") } }
    // Analysis, Organise and faces (SPEC sections 36 to 39).
    var analysisEnabled: Bool { didSet { set(analysisEnabled, "analysisEnabled") } }
    var analysisPauseOnBattery: Bool { didSet { set(analysisPauseOnBattery, "analysisPauseOnBattery") } }
    var analysisExcludedRoots: Set<String> { didSet { set(analysisExcludedRoots.sorted(), "analysisExcludedRoots") } }
    var eventGapHours: Double { didSet { set(eventGapHours, "eventGapHours") } }
    var subjectThreshold: Double { didSet { set(subjectThreshold, "subjectThreshold") } }
    var customSubjects: [String] { didSet { set(customSubjects, "customSubjects") } }
    var facesEnabled: Bool { didSet { set(facesEnabled, "facesEnabled") } }
    /// Offset from the model's own match threshold; positive is stricter.
    var faceMatchAdjustment: Double { didSet { set(faceMatchAdjustment, "faceMatchAdjustment") } }
    var groupPhotoPlacement: GroupPhotoPlacement { didSet { set(groupPhotoPlacement.rawValue, "groupPhotoPlacement") } }
    var sortUnnamedPeople: Bool { didSet { set(sortUnnamedPeople, "sortUnnamedPeople") } }
    var undoHistoryDays: Int { didSet { set(undoHistoryDays, "undoHistoryDays") } }
    var recentOrganiseFolders: [String] { didSet { set(recentOrganiseFolders, "recentOrganiseFolders") } }
    /// The parts of a profile and the site switches last chosen per gallery-dl site (SPEC R-1111b).
    var galleryChoices: [String: [String]] { didSet { set(galleryChoices, "galleryChoices") } }
    var gallerySwitches: [String: [String: Bool]] { didSet { set(gallerySwitches, "gallerySwitches") } }
    var libraryQuery: LibraryQuery { didSet { set(try? JSONEncoder().encode(libraryQuery), "libraryQuery") } }
    var libraryIncludeSubfolders: Bool { didSet { set(libraryIncludeSubfolders, "libraryIncludeSubfolders") } }
    /// The Extracted Media filters last used, which new windows start with, and the person's named presets (R-1008).
    var extractedFilter: MediaFilter { didSet { set(try? JSONEncoder().encode(extractedFilter), "extractedFilter") } }
    var filterPresets: [FilterPreset] { didSet { set(try? JSONEncoder().encode(filterPresets), "filterPresets") } }
    /// Each pane's view: icons, a list or columns (R-1708).
    var paneViewModes: PaneViewModes { didSet { set(try? JSONEncoder().encode(paneViewModes), "paneViewModes") } }
    var theme: AppTheme {
        didSet {
            set(theme.rawValue, "theme")
            AppTheme.currentAccent = theme.nsAccent
        }
    }

    init() {
        let d = UserDefaults.standard
        defaultLayout = SaveLayout(rawValue: d.string(forKey: "defaultLayout") ?? "") ?? .archive
        conflict = ConflictPolicy(rawValue: d.string(forKey: "conflict") ?? "") ?? .number
        setFileDates = d.object(forKey: "setFileDates") as? Bool ?? true
        setWhereFroms = d.object(forKey: "setWhereFroms") as? Bool ?? true
        clearOnNavigation = d.bool(forKey: "clearOnNavigation")
        keepOriginalModernImages = d.bool(forKey: "keepOriginalModernImages")
        animated = AnimatedPolicy(rawValue: d.string(forKey: "animated") ?? "") ?? .gif
        video = VideoCodecPolicy(rawValue: d.string(forKey: "video") ?? "") ?? .highestReencodeIfNeeded
        pacing = PacingPreset(rawValue: d.string(forKey: "pacing") ?? "") ?? .gentle
        typeSubfolders = d.object(forKey: "instagramTypeSubfolders") as? Bool ?? true
        stopAfterKnown = d.object(forKey: "stopAfterKnown") as? Int ?? 12
        savedPostsRemember = d.object(forKey: "savedPostsRemember") as? Bool ?? true
        weeklyEngineCheck = d.object(forKey: "weeklyEngineCheck") as? Bool ?? true
        lastEngineCheck = d.object(forKey: "lastEngineCheck") as? Date
        notifyWhenDone = d.object(forKey: "notifyWhenDone") as? Bool ?? true
        archiveEngineTemplate = d.string(forKey: "archiveEngineTemplate") ?? NameTemplate.archiveEngine.pattern
        archiveWebTemplate = d.string(forKey: "archiveWebTemplate") ?? NameTemplate.archiveWeb.pattern
        plainTemplate = d.string(forKey: "plainTemplate") ?? NameTemplate.plain.pattern
        onboardingDone = d.bool(forKey: "onboardingDone")
        recentSaveFolders = d.array(forKey: "recentSaveFolders") as? [String] ?? []
        let content = (d.array(forKey: "defaultContent") as? [String])?.compactMap(InstagramContent.init(rawValue:))
        defaultContent = Set(content ?? Array(InstagramContent.defaults))
        autoProbe = d.object(forKey: "autoProbe") as? Bool ?? true
        saveConcurrency = d.object(forKey: "saveConcurrency") as? Int ?? 4
        paneArrangement = d.data(forKey: "paneArrangement")
            .flatMap { try? JSONDecoder().decode(PaneArrangement.self, from: $0) } ?? .standard
        organiseArrangement = d.data(forKey: "organiseArrangement").flatMap { try? JSONDecoder().decode(PaneArrangement.self, from: $0) }
            .flatMap { $0.group == .organise ? $0 : nil } ?? .organiseStandard
        devicesArrangement = d.data(forKey: "devicesArrangement").flatMap { try? JSONDecoder().decode(PaneArrangement.self, from: $0) }
            .flatMap { $0.group == .devices ? $0 : nil } ?? .devicesStandard
        editArrangement = d.data(forKey: "editArrangement").flatMap { try? JSONDecoder().decode(PaneArrangement.self, from: $0) }
            .flatMap { $0.group == .edit ? $0 : nil } ?? .editStandard
        deviceImportFolder = d.string(forKey: "deviceImportFolder")
        editFolder = d.string(forKey: "editFolder")
        allowFontDownloads = d.bool(forKey: "allowFontDownloads")
        editSnap = d.object(forKey: "editSnap") as? Bool ?? true
        editRulers = d.object(forKey: "editRulers") as? Bool ?? true
        editGrid = d.string(forKey: "editGrid").flatMap(CanvasGrid.init(rawValue:)) ?? .none
        foldedSections = Set(d.stringArray(forKey: "foldedSections") ?? [])
        pasteGroups = Set(d.stringArray(forKey: "pasteGroups") ?? ["look", "adjustments", "frame", "layers"])
        includeLivePhotoClips = d.bool(forKey: "includeLivePhotoClips")
        sortPostImagesIndividually = d.bool(forKey: "sortPostImagesIndividually")
        rememberHistory = d.object(forKey: "rememberHistory") as? Bool ?? true
        showMaps = d.object(forKey: "showMaps") as? Bool ?? false
        highlightDuplicates = d.object(forKey: "highlightDuplicates") as? Bool ?? true
        duplicateSensitivity = DuplicateSensitivity(rawValue: d.string(forKey: "duplicateSensitivity") ?? "") ?? .nearIdentical
        thumbnailSize = CGFloat(d.object(forKey: "thumbnailSize") as? Double ?? 150)
        analysisEnabled = d.object(forKey: "analysisEnabled") as? Bool ?? true
        analysisPauseOnBattery = d.object(forKey: "analysisPauseOnBattery") as? Bool ?? true
        analysisExcludedRoots = Set(d.array(forKey: "analysisExcludedRoots") as? [String] ?? [])
        eventGapHours = d.object(forKey: "eventGapHours") as? Double ?? 3
        subjectThreshold = d.object(forKey: "subjectThreshold") as? Double ?? 0.5
        customSubjects = d.array(forKey: "customSubjects") as? [String] ?? []
        facesEnabled = d.bool(forKey: "facesEnabled")
        faceMatchAdjustment = d.object(forKey: "faceMatchAdjustment") as? Double ?? 0
        groupPhotoPlacement = GroupPhotoPlacement(rawValue: d.string(forKey: "groupPhotoPlacement") ?? "") ?? .everyPerson
        sortUnnamedPeople = d.bool(forKey: "sortUnnamedPeople")
        undoHistoryDays = d.object(forKey: "undoHistoryDays") as? Int ?? 30
        recentOrganiseFolders = d.array(forKey: "recentOrganiseFolders") as? [String] ?? []
        galleryChoices = d.dictionary(forKey: "galleryChoices") as? [String: [String]] ?? [:]
        gallerySwitches = d.dictionary(forKey: "gallerySwitches") as? [String: [String: Bool]] ?? [:]
        // Settings written by an earlier version keep what they hold when a field was added since.
        libraryQuery = d.data(forKey: "libraryQuery").map { LenientJSON.decode(LibraryQuery.self, from: $0, over: LibraryQuery()) }
            ?? LibraryQuery()
        libraryIncludeSubfolders = d.bool(forKey: "libraryIncludeSubfolders")
        extractedFilter = d.data(forKey: "extractedFilter").map { LenientJSON.decode(MediaFilter.self, from: $0, over: MediaFilter()) }
            ?? MediaFilter()
        filterPresets = d.data(forKey: "filterPresets").flatMap { data in
            (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.compactMap { preset -> FilterPreset? in
                guard let name = preset["name"] as? String, let filter = preset["filter"],
                      let filterData = try? JSONSerialization.data(withJSONObject: filter) else { return nil }
                return FilterPreset(name: name, filter: LenientJSON.decode(MediaFilter.self, from: filterData, over: MediaFilter()))
            }
        } ?? []
        paneViewModes = d.data(forKey: "paneViewModes").flatMap { try? JSONDecoder().decode(PaneViewModes.self, from: $0) }
            ?? PaneViewModes()
        theme = AppTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        AppTheme.currentAccent = theme.nsAccent
    }

    private func set(_ value: Any?, _ key: String) {
        // A self-test reads the person's settings but never writes them: a run that is stopped part way leaves nothing
        // changed for the installed app (audit 7, C7-m1).
        guard !SelfTestRunner.isActive else { return }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    var conversion: ConversionPolicy {
        var policy = ConversionPolicy()
        policy.keepOriginalModernImages = keepOriginalModernImages
        policy.animated = animated
        policy.video = video
        return policy
    }

    func saveSettings(extractorVersion: String?) -> SaveSettings {
        var settings = SaveSettings()
        settings.conversion = conversion
        settings.conflict = conflict
        settings.setFileDates = setFileDates
        settings.setWhereFroms = setWhereFroms
        settings.typeSubfolders = typeSubfolders
        let engine = NameTemplate(archiveEngineTemplate)
        settings.archiveEngineTemplate = engine.archiveProblems().isEmpty ? engine : .archiveEngine
        let web = NameTemplate(archiveWebTemplate)
        settings.archiveWebTemplate = web.archiveProblems().isEmpty ? web : .archiveWeb
        settings.plainTemplate = NameTemplate(plainTemplate)
        settings.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        settings.extractorVersion = extractorVersion
        return settings
    }
}

/// A named set of Extracted Media filters (R-1008).
struct FilterPreset: Codable, Equatable, Identifiable {
    var name: String
    var filter: MediaFilter
    var id: String { name }
}
