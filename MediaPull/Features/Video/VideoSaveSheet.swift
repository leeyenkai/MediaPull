import MediaPullCore
import MediaPullStore
import SwiftUI

/// A page whose video the person wants to save (SPEC section 35).
struct VideoRequest: Identifiable, Equatable {
    let id = UUID()
    var url: URL
}

/// "Save Video…": choose the format and resolution of the video on the page, then download it.
struct VideoSaveSheet: View {
    @Bindable var model: WindowModel
    let request: VideoRequest
    @State private var info: VideoInfo?
    @State private var failure: String?
    @State private var format: VideoDownloadFormat = .bestMP4
    @State private var height: Int?
    @State private var rootID: UUID?
    @State private var thumbnail: CGImage?
    @Environment(\.dismiss) private var dismiss
    private var app: AppModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Video").font(.title2.weight(.semibold))
            if let info {
                header(info)
                Form {
                    Picker("Format", selection: $format) {
                        ForEach(VideoDownloadFormat.allCases, id: \.self) { choice in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.label)
                                Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(choice)
                            .disabled(!choice.isAudioOnly && choice.heights(in: info.formats).isEmpty)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    if !format.isAudioOnly {
                        Picker("Resolution", selection: $height) {
                            Text(bestLabel(info)).tag(Int?.none)
                            ForEach(format.heights(in: info.formats), id: \.self) { value in
                                Text(heightLabel(value, in: info)).tag(Optional(value))
                            }
                        }
                    }
                    Picker("Library folder", selection: $rootID) {
                        ForEach(app.roots) { root in Text(root.name).tag(Optional(root.id)) }
                    }
                }
                .formStyle(.grouped)
                .onChange(of: format) { _, newFormat in
                    if let height, !newFormat.heights(in: info.formats).contains(height) { self.height = nil }
                }
                Text(summary(info))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure {
                Label(failure, systemImage: "film.stack")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up the formats of this video…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Video") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(info == nil || root == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            rootID = app.lastSaveFolderURL.flatMap { app.root(containing: $0)?.id } ?? app.defaultRoot?.id
            switch await app.engines.videoInfo(for: request.url) {
            case let .success(found):
                info = found
                if let url = found.thumbnail {
                    thumbnail = await app.thumbnails.thumbnail(for: url, maxPixel: 320, context: .init(userAgent: app.userAgent))?.image
                }
            case let .failure(error):
                failure = error.message
            }
        }
    }

    private var root: LibraryRootInfo? { app.roots.first { $0.id == rootID } }

    private func header(_ info: VideoInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title).font(.headline).lineLimit(2)
                Text(details(info)).font(.caption).foregroundStyle(.secondary)
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
        let fps = format.videoFormats(in: info.formats).filter { $0.height == value }.compactMap(\.fps).max()
        let name = value >= 2160 ? "\(value)p (4K)" : value >= 1440 ? "\(value)p (2K)" : "\(value)p"
        return fps.map { $0 > 30 ? "\(name), \(Int($0)) fps" : name } ?? name
    }

    private func bestLabel(_ info: VideoInfo) -> String {
        guard let top = format.heights(in: info.formats).first else { return "Best available" }
        return "Best available (\(heightLabel(top, in: info)))"
    }

    private func summary(_ info: VideoInfo) -> String {
        var parts: [String] = []
        if let bytes = format.estimatedBytes(in: info.formats, height: height, duration: info.duration) {
            parts.append("About \(Format.bytes(bytes)).")
        }
        if format.needsConversion(in: info.formats, height: height) {
            let codec = format.chosenVideo(in: info.formats, height: height)?.codecFamily.uppercased() ?? "This"
            parts.append("\(codec) video will be converted to HEVC, which takes a while at high resolutions. Choose MP4, original codec to keep it as sent.")
        }
        if let root {
            let site = info.webpageURL.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? info.extractor
            parts.append("Saved in \(root.name)/\(site)/\(info.uploader ?? "Videos").")
        }
        return parts.joined(separator: " ")
    }

    private func save() {
        guard let info, let root else { return }
        app.engines.saveVideo(info, format: format, height: format.isAudioOnly ? nil : height, root: root, window: model)
        dismiss()
    }
}
