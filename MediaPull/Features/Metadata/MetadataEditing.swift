import AppKit
import MediaPullCore
import MediaPullLibrary
import SwiftUI

/// Metadata edits from a window (section 45): the Rating and Edit Details menu items, and running an edit as a change
/// ⌘Z takes back.
extension WindowModel {
    /// Photos among `files` whose details can be changed now (R-4501): videos and audio wait for spike S1.
    static func editablePhotos(_ files: [URL]) -> [URL] {
        files.filter { url in
            guard MediaFormat.fromExtension(url.pathExtension)?.kind == .image, !MediaFormat.isSequenceExtension(url.pathExtension) else {
                return false
            }
            // A locked card is only read (R-4304).
            return AppModel.shared.driveCenter.drive(containing: url)?.isReadOnly != true
        }
    }

    /// Rating ▸ and Edit Details for a grid's menu (R-4508); none when no photo is chosen.
    func metadataMenuItems(for files: [URL], showDetails: @escaping @MainActor ([URL]) -> Void) -> [NSMenuItem] {
        let photos = Self.editablePhotos(files)
        guard !photos.isEmpty else { return [] }
        let rating = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        let stars = NSMenu(title: "Rating")
        stars.addItem(ActionMenuItem("No Rating") { [weak self] in self?.editMetadata(photos, .rating(nil)) })
        for count in 1 ... 5 {
            let item = ActionMenuItem(String(repeating: "★", count: count)) { [weak self] in self?.editMetadata(photos, .rating(count)) }
            item.setAccessibilityLabel("\(count) star\(count == 1 ? "" : "s")")
            stars.addItem(item)
        }
        rating.submenu = stars
        return [rating, ActionMenuItem("Edit Details") { [weak self] in
            self?.editTargets = photos
            showDetails(photos)
        }]
    }

    /// Runs `edit` on `files` as one change ⌘Z takes back, and says what was done where the person is working.
    func editMetadata(_ files: [URL], _ edit: MetadataEdit) {
        let photos = Self.editablePhotos(files)
        guard !photos.isEmpty else { return }
        let title = Self.title(of: edit, count: photos.count)
        let job = Job(kind: .organise, title: title)
        job.state = .running
        app.jobs.add(job)
        job.task = Task { [weak self] in
            let result = await AppModel.shared.editMetadata(photos, edit, title: title) { done, total in
                Task { @MainActor in
                    job.fraction = Double(done) / Double(max(total, 1))
                    job.summaryOverride = "\(done) of \(total) photos"
                }
            }
            let problems = result.skipped
            let state: JobState = result.stopped ? .cancelled : problems.isEmpty ? .completed : .failed(problems[0])
            AppModel.shared.jobs.finish(job, state, notify: false)
            // A short edit leaves Activity once done; a long or stopped one stays, so what happened can be seen.
            if problems.isEmpty, !result.stopped, photos.count <= 20 { AppModel.shared.jobs.jobs.removeAll { $0 === job } }
            guard let self else { return }
            if let entry = result.entry { self.registerUndo(entry) }
            let photosChanged = "\(result.changed) photo\(result.changed == 1 ? "" : "s") changed"
            var text = result.changed == 0
                ? (result.stopped ? "Stopped before anything was changed."
                    : problems.isEmpty ? "Nothing needed changing." : "Nothing could be changed.")
                : "\(title): \(photosChanged)\(result.stopped ? " before it was stopped" : ""). ⌘Z undoes it."
            if let first = problems.first {
                text += problems.count == 1 ? " \(first)" : " \(problems.count) were left as they were, such as: \(first)"
            }
            self.say(text)
            await self.organise.refreshHistory()
        }
    }

    /// A short note where the person is working: Organise or the Library.
    func say(_ text: String) {
        if section == .organise { organise.message = text } else { library.message = text }
    }

    static func title(of edit: MetadataEdit, count: Int) -> String {
        let what = count == 1 ? "1 Photo" : "\(count) Photos"
        return switch edit {
        case let .rating(stars): (stars ?? 0) > 0 ? "Rate \(what)" : "Clear Rating of \(what)"
        case let .keywords(add, _): add.isEmpty ? "Remove Keyword from \(what)" : "Add Keyword to \(what)"
        case .shiftDate: "Shift Date of \(what)"
        case .timeZone: "Set Time Zone of \(what)"
        case .location: "Set Location of \(what)"
        case .removeLocation: "Remove Location of \(what)"
        }
    }
}

/// The Edit section of a file's details (R-4508): stars, keywords, the date taken and the location, for the file shown
/// or the photos Edit Details was chosen for. No sheet opens (D-69).
struct MetadataEditSection: View {
    @Bindable var model: WindowModel
    var file: URL
    @State private var loaded: Loaded?
    @State private var newKeyword = ""
    @State private var shiftDays = 0
    @State private var shiftHours = 0
    @State private var shiftMinutes = 0
    @State private var zone = MetadataEdit.offsetText(seconds: TimeZone.current.secondsFromGMT())
    @State private var placeQuery = ""
    @State private var placeResults: [(place: PlaceName, latitude: Double, longitude: Double)] = []
    @State private var pickingOnMap = false
    private var app: AppModel { .shared }

    struct Loaded {
        var values: MetadataValues
        var hasMetadataFile: Bool
        var xmpName: String?
    }

    /// The photos the edit applies to: those Edit Details was chosen for when this file is among them, else this one.
    private var targets: [URL] {
        if let chosen = model.editTargets, chosen.contains(where: { $0.standardizedFileURL == file.standardizedFileURL }) {
            return chosen
        }
        return [file]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let reason = Self.reason(file) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if let loaded {
                if targets.count > 1 {
                    Text("Changes apply to the \(targets.count) chosen photos.").font(.caption).foregroundStyle(.secondary)
                }
                ratingRow(loaded)
                keywordRows(loaded)
                dateRows(loaded)
                locationRows(loaded)
                Text(loaded.xmpName.map { "Written in “\($0)” beside the photo; the photo itself is not changed." }
                    ?? "Written in the photo itself; its picture is not changed.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(file.path)|\(app.fileChangeRevision)") { await load() }
    }

    /// Why this file's details cannot be changed, or nil when they can (R-4508).
    static func reason(_ file: URL) -> String? {
        guard let kind = MediaFormat.fromExtension(file.pathExtension)?.kind else { return "This file's details cannot be changed." }
        if kind == .video || kind == .audio { return "The details of videos and audio cannot be changed yet." }
        if kind != .image || MediaFormat.isSequenceExtension(file.pathExtension) {
            return "The details of animations and image sequences cannot be changed."
        }
        if AppModel.shared.driveCenter.drive(containing: file)?.isReadOnly == true {
            return "This card is locked, so its photos are only read."
        }
        if OperationJournal.isLocked(file) { return "This photo is locked in the Finder; unlock it to change its details." }
        return nil
    }

    private func load() async {
        let url = file
        let read = await Task.detached(priority: .userInitiated) { () -> Loaded in
            // lint:allow main-io inside a detached task
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
            let place = OperationJournal.place(of: url, names: names)
            return Loaded(values: OperationJournal.currentValues(of: url, place: place), hasMetadataFile: place.hasMetadataFile,
                          xmpName: place.xmp?.lastPathComponent)
        }.value
        guard !Task.isCancelled, url == file else { return }
        loaded = read
    }

    private func edit(_ edit: MetadataEdit) {
        model.editMetadata(targets, edit)
    }

    private func ratingRow(_ loaded: Loaded) -> some View {
        HStack(spacing: 2) {
            Text("Rating").font(.callout).frame(width: 74, alignment: .leading)
            ForEach(1 ... 5, id: \.self) { star in
                let on = targets.count == 1 && star <= (loaded.values.rating ?? 0)
                Button {
                    // Choosing the stars it has again clears them.
                    edit(.rating(targets.count == 1 && loaded.values.rating == star ? nil : star))
                } label: {
                    Image(systemName: on ? "star.fill" : "star").foregroundStyle(on ? Color.orange : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .help("\(star) star\(star == 1 ? "" : "s")")
            }
            Spacer()
            Button("Clear") { edit(.rating(nil)) }.controlSize(.small)
                .disabled(targets.count == 1 && loaded.values.rating == nil)
        }
    }

    private func keywordRows(_ loaded: Loaded) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Keywords").font(.callout).frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if targets.count == 1, let words = loaded.values.keywords, !words.isEmpty {
                    ForEach(words, id: \.self) { word in
                        HStack(spacing: 4) {
                            Text(word).font(.callout)
                            Button { edit(.keywords(add: [], remove: [word])) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(word)")
                            .help("Remove this keyword")
                        }
                    }
                }
                HStack {
                    TextField("Add a keyword", text: $newKeyword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addKeyword)
                    Button("Add", action: addKeyword).controlSize(.small).disabled(newKeyword.trimmedNonEmpty == nil)
                    if targets.count > 1 {
                        Button("Remove") {
                            if let word = newKeyword.trimmedNonEmpty { edit(.keywords(add: [], remove: [word])) }
                            newKeyword = ""
                        }
                        .controlSize(.small).disabled(newKeyword.trimmedNonEmpty == nil)
                    }
                }
            }
        }
    }

    private func addKeyword() {
        guard let word = newKeyword.trimmedNonEmpty else { return }
        edit(.keywords(add: [word], remove: []))
        newKeyword = ""
    }

    @ViewBuilder
    private func dateRows(_ loaded: Loaded) -> some View {
        let taken = loaded.values.taken
        HStack(alignment: .firstTextBaseline) {
            Text("Taken").font(.callout).frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.describe(taken)).font(.callout)
                if loaded.hasMetadataFile {
                    Text("Keeps the date of its post.").font(.caption).foregroundStyle(.secondary)
                } else if taken == nil, targets.count == 1 {
                    Text("The photo records no date to change.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Stepper("\(shiftDays) d", value: $shiftDays, in: -3650 ... 3650).fixedSize()
                        Stepper("\(shiftHours) h", value: $shiftHours, in: -23 ... 23).fixedSize()
                        Stepper("\(shiftMinutes) min", value: $shiftMinutes, in: -59 ... 59).fixedSize()
                        Button("Shift") {
                            edit(.shiftDate(seconds: shiftDays * 86400 + shiftHours * 3600 + shiftMinutes * 60))
                            (shiftDays, shiftHours, shiftMinutes) = (0, 0, 0)
                        }
                        .controlSize(.small)
                        .disabled(shiftDays == 0 && shiftHours == 0 && shiftMinutes == 0)
                        .help("Moves the date and time taken by this much, as when the camera's clock was off")
                    }
                    HStack(spacing: 6) {
                        Picker("Time zone", selection: $zone) {
                            ForEach(Self.zones, id: \.self) { Text("UTC\($0)").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Set Time Zone") { edit(.timeZone(zone)) }
                            .controlSize(.small)
                            .help("Keeps the clock time and records the time zone it was taken in")
                    }
                }
            }
        }
    }

    /// Offsets in use around the world, from UTC−12:00 to UTC+14:00.
    static let zones: [String] = {
        let quarters = [-720, -660, -600, -570, -540, -480, -420, -360, -300, -240, -210, -180, -150, -120, -60, 0, 60, 120, 180, 210,
                        240, 270, 300, 330, 345, 360, 390, 420, 480, 525, 540, 570, 600, 630, 660, 720, 765, 780, 840]
        return quarters.map { MetadataEdit.offsetText(seconds: $0 * 60) }
    }()

    static func describe(_ taken: TakenDate?) -> String {
        guard let text = taken?.original ?? taken?.digitized else { return "No date recorded" }
        let offset = taken?.original != nil ? taken?.originalOffset : taken?.digitizedOffset
        let parsed = MetadataEdit.moment(text, offset: "+00:00")
        let shown = parsed.map {
            $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: TimeZone(secondsFromGMT: 0)!))
        } ?? text
        return MetadataEdit.offset(offset).map { "\(shown) (UTC\($0))" } ?? "\(shown) (no time zone)"
    }

    private func locationRows(_ loaded: Loaded) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Location").font(.callout).frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if targets.count == 1, let lat = loaded.values.latitude, let lon = loaded.values.longitude {
                    Text(app.analysis.placeName(latitude: lat, longitude: lon)?.display ?? String(format: "%.5f, %.5f", lat, lon))
                        .font(.callout)
                } else if targets.count == 1 {
                    Text("No location recorded").font(.callout).foregroundStyle(.secondary)
                }
                if pickingOnMap {
                    LocationPicker(latitude: loaded.values.latitude, longitude: loaded.values.longitude) { lat, lon in
                        pickingOnMap = false
                        edit(.location(latitude: lat, longitude: lon))
                    } onCancel: {
                        pickingOnMap = false
                    }
                }
                HStack(spacing: 6) {
                    if app.preferences.showMaps {
                        Button("Set on Map") { pickingOnMap = true }.controlSize(.small).disabled(pickingOnMap)
                    }
                    Button("Remove Location") { edit(.removeLocation) }
                        .controlSize(.small)
                        .disabled(targets.count == 1 && loaded.values.latitude == nil)
                }
                TextField("Find a place", text: $placeQuery)
                    .textFieldStyle(.roundedBorder)
                    .help("Searches MediaPull's own list of places; nothing is looked up online")
                ForEach(Array(placeResults.enumerated()), id: \.offset) { _, result in
                    Button(result.place.display) {
                        placeQuery = ""
                        placeResults = []
                        edit(.location(latitude: result.latitude, longitude: result.longitude))
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .task(id: placeQuery) {
            let query = placeQuery
            guard query.count >= 2 else {
                placeResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await app.analysis.searchPlaces(query)
            guard !Task.isCancelled, query == placeQuery else { return }
            placeResults = found
        }
    }
}
