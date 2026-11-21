import CoreText
import Foundation

/// The fonts text layers can use (R-4607, D-129): every family installed on the Mac, and Apple's fonts that macOS fetches
/// on request. Listing reads only what is on the Mac (spike `docs/spikes/fonts.md`); a download happens only through
/// `download`, which the app calls only after the person allowed it.
public enum FontCatalog {
    public struct Family: Sendable, Hashable, Identifiable {
        public var name: String
        public var installed: Bool
        public var id: String { name }
    }

    /// Installed families first come with `installed`; downloadable ones not yet on the Mac follow. Sorted by name, with
    /// hidden system families (names starting with ".") left out.
    public static func families() -> [Family] {
        let installed = Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).filter { !$0.hasPrefix(".") })
        let downloadable = Set(downloadableDescriptors().compactMap { familyName($0) }).subtracting(installed)
        return (installed.map { Family(name: $0, installed: true) } + downloadable.map { Family(name: $0, installed: false) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The faces of an installed family ("Regular", "Bold", "Light Italic"), as the family orders them.
    public static func faces(of family: String) -> [String] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, Set([kCTFontFamilyNameAttribute as String]) as CFSet)
            as? [CTFontDescriptor] ?? []
        var seen = Set<String>()
        return matches.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String }
            .filter { seen.insert($0).inserted }
    }

    public static func isInstalled(_ family: String) -> Bool {
        (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).contains(family)
    }

    static func downloadableDescriptors() -> [CTFontDescriptor] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontDownloadableAttribute: true] as CFDictionary)
        return CTFontDescriptorCreateMatchingFontDescriptors(descriptor, Set([kCTFontDownloadableAttribute as String]) as CFSet)
            as? [CTFontDescriptor] ?? []
    }

    static func familyName(_ descriptor: CTFontDescriptor) -> String? {
        (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String).flatMap { $0.hasPrefix(".") ? nil : $0 }
    }

    /// Asks macOS to fetch a downloadable family from Apple (D-129). Only call once the person allowed font downloads.
    /// True when the family is installed afterwards.
    public static func download(_ family: String) async -> Bool {
        let wanted = downloadableDescriptors().filter { familyName($0) == family }
        guard !wanted.isEmpty else { return isInstalled(family) }
        let finished: Bool = await withCheckedContinuation { continuation in
            let resumed = Resumed()
            let started = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(wanted as CFArray, nil) { state, _ in
                switch state {
                case .didFinish:
                    if resumed.claim() { continuation.resume(returning: true) }
                    return false
                case .didFailWithError:
                    if resumed.claim() { continuation.resume(returning: false) }
                    return false
                default:
                    return true
                }
            }
            if !started, resumed.claim() { continuation.resume(returning: false) }
        }
        return finished && isInstalled(family)
    }

    /// The continuation is resumed once, whichever callback comes first.
    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }
    }
}
