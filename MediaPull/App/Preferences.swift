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
    var reelsSubfolder: Bool { didSet { set(reelsSubfolder, "reelsSubfolder") } }
    var stopAfterKnown: Int { didSet { set(stopAfterKnown, "stopAfterKnown") } }
    var weeklyEngineCheck: Bool { didSet { set(weeklyEngineCheck, "weeklyEngineCheck") } }
    var lastEngineCheck: Date? { didSet { set(lastEngineCheck, "lastEngineCheck") } }
    var notifyWhenDone: Bool { didSet { set(notifyWhenDone, "notifyWhenDone") } }
    var archiveEngineTemplate: String { didSet { set(archiveEngineTemplate, "archiveEngineTemplate") } }
    var archiveWebTemplate: String { didSet { set(archiveWebTemplate, "archiveWebTemplate") } }
    var plainTemplate: String { didSet { set(plainTemplate, "plainTemplate") } }
    var onboardingDone: Bool { didSet { set(onboardingDone, "onboardingDone") } }
    var lastSaveFolder: String? { didSet { set(lastSaveFolder, "lastSaveFolder") } }
    var defaultContent: Set<InstagramContent> { didSet { set(defaultContent.map(\.rawValue).sorted(), "defaultContent") } }
    var autoProbe: Bool { didSet { set(autoProbe, "autoProbe") } }
    var verboseEngineLog: Bool { didSet { set(verboseEngineLog, "verboseEngineLog") } }
    var saveConcurrency: Int { didSet { set(saveConcurrency, "saveConcurrency") } }
    var paneArrangement: PaneArrangement { didSet { set(try? JSONEncoder().encode(paneArrangement), "paneArrangement") } }
    var rememberHistory: Bool { didSet { set(rememberHistory, "rememberHistory") } }
    var thumbnailSize: CGFloat { didSet { set(Double(thumbnailSize), "thumbnailSize") } }
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
        reelsSubfolder = d.bool(forKey: "reelsSubfolder")
        stopAfterKnown = d.object(forKey: "stopAfterKnown") as? Int ?? 12
        weeklyEngineCheck = d.object(forKey: "weeklyEngineCheck") as? Bool ?? true
        lastEngineCheck = d.object(forKey: "lastEngineCheck") as? Date
        notifyWhenDone = d.object(forKey: "notifyWhenDone") as? Bool ?? true
        archiveEngineTemplate = d.string(forKey: "archiveEngineTemplate") ?? NameTemplate.archiveEngine.pattern
        archiveWebTemplate = d.string(forKey: "archiveWebTemplate") ?? NameTemplate.archiveWeb.pattern
        plainTemplate = d.string(forKey: "plainTemplate") ?? NameTemplate.plain.pattern
        onboardingDone = d.bool(forKey: "onboardingDone")
        lastSaveFolder = d.string(forKey: "lastSaveFolder")
        let content = (d.array(forKey: "defaultContent") as? [String])?.compactMap(InstagramContent.init(rawValue:))
        defaultContent = Set(content ?? [.posts, .reels, .avatar])
        autoProbe = d.object(forKey: "autoProbe") as? Bool ?? true
        verboseEngineLog = d.bool(forKey: "verboseEngineLog")
        saveConcurrency = d.object(forKey: "saveConcurrency") as? Int ?? 4
        paneArrangement = d.data(forKey: "paneArrangement").flatMap { try? JSONDecoder().decode(PaneArrangement.self, from: $0) } ?? .standard
        rememberHistory = d.object(forKey: "rememberHistory") as? Bool ?? true
        thumbnailSize = CGFloat(d.object(forKey: "thumbnailSize") as? Double ?? 150)
        theme = AppTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        AppTheme.currentAccent = theme.nsAccent
    }

    private func set(_ value: Any?, _ key: String) {
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
        settings.reelsSubfolder = reelsSubfolder
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
