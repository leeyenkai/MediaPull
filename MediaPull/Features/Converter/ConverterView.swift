import MediaPullCore
import MediaPullStore
import SwiftUI
import UniformTypeIdentifiers

/// The standalone converter (SPEC 16.2). It never changes or deletes the originals.
struct ConverterView: View {
    @State private var results: [(String, String)] = []
    @State private var targeted = false
    @State private var nextToOriginals = true
    @State private var destination: URL?
    @State private var animated: AnimatedPolicy = AppModel.shared.preferences.animated
    @State private var video: VideoCodecPolicy = AppModel.shared.preferences.video
    private var app: AppModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Converter").font(.title2.weight(.semibold))
            Text("Drop WebP, AVIF, HEIC, JPEG XL, BMP or TIFF images, animated images, or WebM and MKV videos. MediaPull writes high-quality JPEG, PNG, GIF or MP4 copies and keeps the originals.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5))
                .background(targeted ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Drop files or folders here")
                        Button("Choose Files…") {
                            FolderPicker.chooseFiles(title: "Choose Files to Convert", window: nil) { urls in convert(urls) }
                        }
                        .controlSize(.small)
                    }
                }
                .frame(height: 150)
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    Task {
                        var urls: [URL] = []
                        for provider in providers {
                            if let data = await provider.loadData(type: UTType.fileURL.identifier),
                               let url = URL(dataRepresentation: data, relativeTo: nil)
                            {
                                urls.append(url)
                            }
                        }
                        convert(urls)
                    }
                    return true
                }
            Form {
                Picker("Animated images become", selection: $animated) {
                    ForEach(AnimatedPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("VP9 and AV1 video", selection: $video) {
                    ForEach(VideoCodecPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Save next to the originals", isOn: $nextToOriginals)
                if !nextToOriginals {
                    HStack {
                        Text(destination?.path ?? "No folder chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") {
                            FolderPicker.chooseFolder(title: "Converted Files Folder", prompt: "Choose", start: app.defaultRoot?.url,
                                                      window: nil) { url in destination = url }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if !results.isEmpty {
                List(Array(results.enumerated()), id: \.offset) { _, result in
                    VStack(alignment: .leading) {
                        Text(result.0).lineLimit(1).truncationMode(.middle)
                        Text(result.1).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 520)
    }

    private func convert(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard nextToOriginals || destination != nil else {
            results.insert(("", "Choose a folder for the converted files first."), at: 0)
            return
        }
        var policy = app.preferences.conversion
        policy.animated = animated
        policy.video = video
        app.convertFiles(urls, destination: nextToOriginals ? nil : destination, policy: policy) { file, message in
            results.insert((file.lastPathComponent, message), at: 0)
        }
    }
}
