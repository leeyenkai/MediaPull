import MediaPullCore
import MediaPullEngines
import MediaPullStore
import SwiftUI

/// Video options in the Downloads pane (SPEC section 35): format, resolution and yt-dlp's other choices.
struct VideoForm: View {
    @Bindable var model: WindowModel
    let url: URL
    @State private var info: VideoInfo?
    @State private var failure: String?
    @State private var format: VideoDownloadFormat = .bestMP4
    @State private var height: Int?
    @State private var thumbnail: CGImage?
    @State private var extras = BridgeRequest.Extras()
    @State private var subtitleChoice = SubtitleChoice.none
    @State private var subtitleLanguages = "en"
    @State private var useDates = false
    @State private var after = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var before = Date()
    @State private var speed = 0
    @State private var showMore = false
    private var app: AppModel { .shared }
    private var codecPolicy: VideoCodecPolicy { app.preferences.video }
    private var canDecodeAV1: Bool { FFmpeg.canDecodeAV1 }

    /// The resolutions and the video a choice takes under the video setting, as the download will (A2-m5).
    private func heights(_ format: VideoDownloadFormat, _ info: VideoInfo) -> [Int] {
        format.heights(in: info.formats, policy: codecPolicy, av1Decodable: canDecodeAV1)
    }

    private func chosen(_ format: VideoDownloadFormat, _ info: VideoInfo) -> VideoFormatInfo? {
        format.chosenVideo(in: info.formats, height: height, policy: codecPolicy, av1Decodable: canDecodeAV1)
    }

    enum SubtitleChoice: String, CaseIterable {
        case none, original, automatic

        var label: String {
            switch self {
            case .none: "None"
            case .original: "Uploaded"
            case .automatic: "Uploaded or Automatic"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let info {
                header(info)
                Picker("Format", selection: $format) {
                    ForEach(VideoDownloadFormat.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                            .disabled(!choice.isAudioOnly && heights(choice, info).isEmpty)
                    }
                }
                .help(format.detail)
                if !format.isAudioOnly {
                    Picker("Resolution", selection: $height) {
                        Text(bestLabel(info)).tag(Int?.none)
                        ForEach(heights(format, info), id: \.self) { value in
                            Text(heightLabel(value, in: info)).tag(Optional(value))
                        }
                    }
                }
                SaveFolderRow(model: model)
                DisclosureGroup("More Options", isExpanded: $showMore) { moreOptions.padding(.top, 4) }
                Text(summary(info)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(extras.playlist ? "Download All" : "Download") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(root == nil)
                }
            } else if let failure {
                Label(failure, systemImage: "film.stack").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if model.downloads.lookUpsHeld {
                HStack(spacing: 8) {
                    Text("Sent from another app. Nothing is asked of the site until you look it up.").foregroundStyle(.secondary)
                    Button("Look Up") { model.downloads.lookUpsHeld = false }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up the formats of this video…").foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: format) { _, newFormat in
            if let info, let height, !heights(newFormat, info).contains(height) { self.height = nil }
        }
        .task(id: "\(url.absoluteString)|\(model.downloads.lookUpsHeld)") {
            // An address another app sent is looked up only when the person asks (D-82, audit 7, C7-M5).
            guard !model.downloads.lookUpsHeld else { return }
            await lookUp()
        }
    }

    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Whole playlist or channel", isOn: $extras.playlist)
                .help("Download every video of the playlist or channel this page belongs to")
            if extras.playlist {
                HStack {
                    TextField("Items, such as 1-20 (all if empty)", text: Binding(get: { extras.playlistItems ?? "" },
                                                                                set: { extras.playlistItems = $0.nonEmpty }))
                    TextField("At most", value: $extras.maxDownloads, format: .number).frame(width: 70)
                }
                Toggle("Only videos uploaded between", isOn: $useDates)
                if useDates {
                    HStack {
                        DatePicker("From", selection: $after, displayedComponents: .date).labelsHidden()
                        Text("and")
                        DatePicker("To", selection: $before, displayedComponents: .date).labelsHidden()
                    }
                }
            }
            Picker("Subtitles", selection: $subtitleChoice) {
                ForEach(SubtitleChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if subtitleChoice != .none {
                TextField("Languages, such as en, fr (all for every language)", text: $subtitleLanguages)
            }
            Toggle("Save the thumbnail", isOn: $extras.thumbnail)
            Toggle("Save the description", isOn: $extras.description)
            Picker("Download speed", selection: $speed) {
                Text("Unlimited").tag(0)
                Text("10 MB/s").tag(10)
                Text("5 MB/s").tag(5)
                Text("1 MB/s").tag(1)
            }
        }
    }

    private var root: SaveDestination? { model.saveFolder.map(app.destination(for:)) }

    private func lookUp() async {
        info = nil
        failure = nil
        height = nil
        thumbnail = nil
        extras.playlist = Self.looksLikeList(url)
        switch await app.engines.videoInfo(for: url) {
        case let .success(found):
            info = found
            if let thumb = found.thumbnail {
                thumbnail = await app.thumbnails.thumbnail(for: thumb, maxPixel: 320, context: .init(userAgent: app.userAgent))?.image
            }
        case let .failure(error):
            failure = error.message
        }
    }

    /// Playlist, channel and user pages default to downloading the whole list.
    static func looksLikeList(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        return path.hasPrefix("/playlist") || path.hasPrefix("/@") || path.hasPrefix("/channel/") || path.hasPrefix("/c/")
            || (query.contains("list=") && !path.hasPrefix("/watch"))
    }

    private func header(_ info: VideoInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.headline).lineLimit(2)
                Text(details(info)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func details(_ info: VideoInfo) -> String {
        var parts: [String] = []
        if let uploader = info.uploader { parts.append(uploader) }
        if let duration = info.duration { parts.append(Format.duration(duration)) }
        if let date = info.uploadDate { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let host = info.webpageURL.host { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    private func heightLabel(_ value: Int, in info: VideoInfo) -> String {
        let fps = format.videoFormats(in: info.formats, policy: codecPolicy, av1Decodable: canDecodeAV1).filter { $0.height == value }
            .compactMap(\.fps).max()
        let name = value >= 2160 ? "\(value)p (4K)" : value >= 1440 ? "\(value)p (2K)" : "\(value)p"
        return fps.map { $0 > 30 ? "\(name), \(Int($0)) fps" : name } ?? name
    }

    private func bestLabel(_ info: VideoInfo) -> String {
        guard let top = heights(format, info).first else { return "Best available" }
        return "Best available (\(heightLabel(top, in: info)))"
    }

    private func summary(_ info: VideoInfo) -> String {
        var parts: [String] = []
        if !extras.playlist, let bytes = format.estimatedBytes(in: info.formats, height: height, duration: info.duration,
                                                               policy: codecPolicy, av1Decodable: canDecodeAV1)
        {
            parts.append("About \(Format.bytes(bytes)).")
        }
        if format.needsConversion(in: info.formats, height: height, policy: codecPolicy, av1Decodable: canDecodeAV1) {
            let codec = chosen(format, info)?.codecFamily.uppercased() ?? "This"
            parts.append("\(codec) video will be converted to HEVC, which takes a while at high resolutions.")
        }
        if let root {
            let site = info.webpageURL.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? info.extractor
            parts.append("Saved in \(root.url.lastPathComponent)/\(site)/\(extras.playlist ? "<channel>" : info.uploader ?? "Videos").")
        }
        return parts.joined(separator: " ")
    }

    private func save() {
        guard let info, let root else { return }
        var chosen = extras
        if subtitleChoice != .none {
            chosen.subtitles = subtitleLanguages.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
            chosen.autoSubtitles = subtitleChoice == .automatic
        }
        if chosen.playlist, useDates {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd"
            chosen.dateAfter = formatter.string(from: after)
            chosen.dateBefore = formatter.string(from: before)
        }
        chosen.rateLimit = speed > 0 ? speed * 1_000_000 : nil
        app.engines.saveVideo(info, pageURL: url, format: format, height: format.isAudioOnly ? nil : height,
                              extras: chosen, root: root, window: model)
    }
}
