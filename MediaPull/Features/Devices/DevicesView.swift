import MediaPullCore
import MediaPullDevices
import SwiftUI

/// The Devices pane: what is plugged in, each device's storages, and what the phone needs from the person (R-4101, R-4102).
struct DevicesListPane: View {
    @Bindable var model: WindowModel
    @Bindable var devices: DevicesModel
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Devices", pane: .devicesList, model: model) {}
            Divider()
            if app.deviceCenter.devices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "cable.connector").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text("Plug in a phone or camera").font(.headline)
                    Text("Unlock an iPhone and tap Trust. On an Android phone, choose File transfer in the USB notification.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("MediaPull only reads devices. Nothing on them is changed or deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $devices.deviceID) {
                    ForEach(app.deviceCenter.devices) { device in
                        DeviceRow(device: device, devices: devices).tag(Optional(device.id))
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .onChange(of: app.deviceCenter.devices.map(\.id)) { _, _ in devices.pickDevice() }
        .onChange(of: readyIDs) { _, _ in devices.pickDevice() }
    }

    /// Devices whose state changed to ready, so a device that becomes readable opens.
    private var readyIDs: [String] {
        app.deviceCenter.devices.compactMap { device in
            if case .ready = device.state { return device.id }
            return nil
        }
    }
}

private struct DeviceRow: View {
    let device: ConnectedDevice
    @Bindable var devices: DevicesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(device.name, systemImage: device.symbol).font(.body.weight(.medium))
            switch device.state {
            case .opening:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Opening…").font(.caption).foregroundStyle(.secondary)
                }
            case .locked:
                Text(device.isApple ? "Unlock the iPhone and tap Trust." : "Unlock the phone to see its files.")
                    .font(.caption).foregroundStyle(.orange)
            case let .failed(message):
                Text(device.isApple ? message : "\(message) On the phone, choose File transfer in the USB notification.")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready:
                if devices.deviceID == device.id, devices.storages.count > 1 {
                    ForEach(devices.storages) { storage in
                        Button {
                            devices.openStorage(storage.id)
                        } label: {
                            Label(storage.name, systemImage: devices.storageID == storage.id ? "internaldrive.fill" : "internaldrive")
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if case .ready = device.state {
                Button("Forget Imports from This Device…") {
                    devices.deviceID = device.id
                    devices.forgetImports()
                }
            }
        }
    }
}

/// The Media pane: the chosen folder's folders, photos and videos, read from the device as folders open (R-4103).
struct DeviceMediaPane: View {
    @Bindable var model: WindowModel
    @Bindable var devices: DevicesModel

    private var mode: PaneViewMode { model.viewMode(for: .devicesMedia) }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Media", pane: .devicesMedia, model: model) {
                if devices.source != nil { ViewModePicker(model: model, pane: .devicesMedia) }
            }
            Divider()
            if devices.source != nil {
                pathBar
                Divider()
                ZStack {
                    PaneMediaView(mode: mode, sections: devices.gridSections, selection: devices.selection, cellSize: devices.cellSize,
                                  revision: devices.revision, owner: devices)
                    if devices.loading {
                        ProgressView().controlSize(.small)
                    } else if let error = devices.loadError {
                        Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    } else if devices.entries.isEmpty {
                        Text("No photos or videos here.").font(.callout).foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
            } else {
                Text(devices.device == nil ? "Choose a device." : "The device is not ready yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Where the pane is on the device, each step a button back to it.
    private var pathBar: some View {
        HStack(spacing: 4) {
            Button(devices.storages.first { $0.id == devices.storageID }?.name ?? devices.device?.name ?? "Device") {
                devices.goUp(to: -1)
            }
            .buttonStyle(.link)
            ForEach(Array(devices.path.enumerated()), id: \.element.id) { index, folder in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(folder.name) { devices.goUp(to: index) }
                    .buttonStyle(.link)
                    .disabled(index == devices.path.count - 1)
            }
            Spacer(minLength: 4)
            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var summary: String {
        var parts: [String] = []
        let media = devices.media.count, folders = devices.folders.count
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        parts.append("\(media) file\(media == 1 ? "" : "s")")
        let done = devices.media.count { devices.imported.contains($0.importKey) }
        if done > 0 { parts.append("\(done) imported") }
        if !devices.selection.isEmpty { parts.append("\(devices.selection.count) selected") }
        return parts.joined(separator: " · ")
    }
}

/// The Import pane: where files go, what to bring in, and how it is going (R-4104 to R-4106).
struct DeviceImportPane: View {
    @Bindable var model: WindowModel
    @Bindable var devices: DevicesModel
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Import", pane: .devicesImport, model: model) {}
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Import into").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        destinationMenu
                    }
                    Toggle("Include Live Photo clips", isOn: Binding(
                        get: { app.preferences.includeLivePhotoClips }, set: { app.preferences.includeLivePhotoClips = $0 }
                    ))
                    .help("Live Photos are a photo and a short clip. When on, the clip is imported too, named after its photo.")
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Import \(devices.selection.isEmpty ? "Selected" : "\(devices.selection.count) Selected")") {
                            devices.importSelected()
                        }
                        .disabled(devices.selection.isEmpty || busy)
                        Button("Import New") { devices.importNew() }
                            .buttonStyle(.borderedProminent)
                            .disabled(devices.source == nil || busy)
                            .help("Everything in this folder and the folders inside it that was not imported before")
                    }
                    if let job = devices.importJob {
                        ImportProgress(job: job, devices: devices)
                    }
                    Text("Files are copied exactly as they are on the device, with their own names and the dates they were taken. "
                        + "Nothing on the device is changed or deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var busy: Bool { devices.importJob?.state.isActive == true }

    private var destinationMenu: some View {
        Menu {
            Section("Library Folders") {
                ForEach(app.roots) { root in
                    Button(root.name) { devices.useDestination(root.url) }
                }
            }
            let recent = app.recentSaveFolders.prefix(6)
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(Array(recent), id: \.self) { folder in
                        Button(folder.lastPathComponent) { devices.useDestination(folder) }
                    }
                }
            }
            Divider()
            Button("Other Folder…") { devices.chooseDestination() }
            if let folder = devices.destination {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
        } label: {
            Label(devices.destination?.lastPathComponent ?? "Choose a folder", systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(devices.destination?.path ?? "Choose where imports go")
    }
}

private struct ImportProgress: View {
    let job: Job
    @Bindable var devices: DevicesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if job.state.isActive {
                ProgressView(value: job.total > 0 ? Double(job.saved) / Double(job.total) : nil)
                Text(job.currentItem.map { "Importing \($0)" } ?? "Importing \(job.saved) of \(job.total)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Cancel") { job.cancel() }.controlSize(.small)
            } else {
                Text(result).font(.callout)
                ForEach(job.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    if job.saved > 0 {
                        Button("Organise These…") { devices.organiseDestination() }
                    }
                    if job.failed > 0, let retry = job.retry {
                        Button("Retry Failed") { retry() }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    private var result: String {
        var parts = ["\(job.saved) imported"]
        if job.failed > 0 { parts.append("\(job.failed) not imported") }
        if job.state == .cancelled { parts.append("stopped") }
        return parts.joined(separator: ", ")
    }
}
