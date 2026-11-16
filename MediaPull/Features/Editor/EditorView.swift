import MediaPullCore
import SwiftUI

/// The editor inside the Preview pane (SPEC section 32): crop, rotate, flip and rename.
struct EditorView: View {
    @State private var model: EditorModel
    private var app: AppModel { .shared }
    private let onClose: () -> Void

    init(request: EditorRequest, window: WindowModel?, onClose: @escaping () -> Void) {
        _model = State(initialValue: EditorModel(request: request, window: window))
        self.onClose = onClose
    }

    private func dismiss() {
        onClose()
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Name").foregroundStyle(.secondary)
                TextField("File name", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                Text(".\(model.fileExtension)").foregroundStyle(.secondary).monospaced()
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.85))
                if model.isLoading {
                    ProgressView()
                } else if let image = model.working, model.isImage {
                    CropCanvas(model: model, image: image)
                        .padding(18)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "pencil.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text(model.message ?? "Only the name can be changed for this item.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
            if model.isImage, model.working != nil {
                HStack(spacing: 10) {
                    Button { model.rotate(clockwise: false) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                        .keyboardShortcut("[", modifiers: [.command, .option])
                    Button { model.rotate(clockwise: true) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                        .keyboardShortcut("]", modifiers: [.command, .option])
                    Button { model.flip() } label: { Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    Picker("Crop", selection: Binding(get: { model.aspect }, set: { model.aspect = $0; model.applyAspect() })) {
                        ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    Button("Reset") { model.reset() }
                        .disabled(!model.hasImageEdits)
                    Spacer(minLength: 0)
                    if let size = model.outputSize {
                        Text("\(size.width) × \(size.height) px").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
            }
            if let message = model.message, model.isImage {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    actions
                }
                VStack(alignment: .trailing) {
                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }
                    }
                    HStack { actions }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .task {
            model.window?.activeEditor = model
            await model.load()
        }
        .disabled(model.isSaving)
    }

    private var hint: String {
        switch model.request.subject {
        case .file: "Saving replaces the file; the original goes to the Trash. Edited images are saved at maximum quality."
        case .item: "Edits and the name are used when this item is saved."
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.request.subject {
        case .file:
            Button("Save as Copy") {
                Task { if let url = await model.saveFile(asCopy: true) { finish(url) } }
            }
            Button("Save") {
                Task { if let url = await model.saveFile(asCopy: false) { finish(url) } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasImageEdits && !model.hasNameChange)
        case .item:
            Button("Save to…") {
                FolderPicker.chooseFolder(title: "Save Edited Item", prompt: "Save Here", start: model.window?.saveFolder,
                                          window: model.window?.hostWindow) { url in
                    guard let url else { return }
                    model.window?.useSaveFolder(url)
                    Task { if await model.saveItem(to: url) { dismiss() } }
                }
            }
            Button("Keep Name Only") {
                if model.hasNameChange { model.window?.customNames[itemID] = FileNaming.sanitize(model.name, maxBytes: 200) }
                dismiss()
            }
            .disabled(!model.hasNameChange || model.hasImageEdits)
            Button("Save to “\(model.window?.saveFolderName ?? "Library")”") {
                Task { if await model.saveItem(to: nil) { dismiss() } }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var itemID: String {
        if case let .item(id) = model.request.subject { return id }
        return ""
    }

    private func finish(_ url: URL) {
        model.window?.library.reload()
        model.window?.library.refreshTree()
        app.libraryRevision += 1
        model.window?.editorRequest = nil
        model.window?.previewSubject = .file(url)
    }
}

/// The image with a draggable crop rectangle.
struct CropCanvas: View {
    @Bindable var model: EditorModel
    let image: CGImage
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let frame = fitted(in: proxy.size)
            let cropFrame = CGRect(x: frame.minX + model.crop.minX * frame.width, y: frame.minY + model.crop.minY * frame.height,
                                   width: model.crop.width * frame.width, height: model.crop.height * frame.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                Path { path in
                    path.addRect(frame)
                    path.addRect(cropFrame)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(.white, lineWidth: 1.5)
                    .frame(width: cropFrame.width, height: cropFrame.height)
                    .position(x: cropFrame.midX, y: cropFrame.midY)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(frame: frame))
                ThirdsGrid()
                    .stroke(.white.opacity(0.35), lineWidth: 0.5)
                    .frame(width: cropFrame.width, height: cropFrame.height)
                    .position(x: cropFrame.midX, y: cropFrame.midY)
                    .allowsHitTesting(false)
                ForEach(Corner.allCases, id: \.self) { corner in
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(radius: 2)
                        .position(corner.point(in: cropFrame))
                        .gesture(resizeGesture(corner: corner, frame: frame))
                }
            }
        }
        .accessibilityLabel("Crop area")
    }

    private func fitted(in size: CGSize) -> CGRect {
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func moveGesture(frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? model.crop
                if dragStart == nil { dragStart = start }
                var next = start
                next.origin.x = min(max(0, start.minX + value.translation.width / frame.width), 1 - start.width)
                next.origin.y = min(max(0, start.minY + value.translation.height / frame.height), 1 - start.height)
                model.crop = next
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(corner: Corner, frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? model.crop
                if dragStart == nil { dragStart = start }
                let dx = value.translation.width / frame.width
                let dy = value.translation.height / frame.height
                var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
                switch corner {
                case .topLeft: minX += dx; minY += dy
                case .topRight: maxX += dx; minY += dy
                case .bottomLeft: minX += dx; maxY += dy
                case .bottomRight: maxX += dx; maxY += dy
                }
                minX = max(0, min(minX, maxX - 0.03))
                minY = max(0, min(minY, maxY - 0.03))
                maxX = min(1, max(maxX, minX + 0.03))
                maxY = min(1, max(maxY, minY + 0.03))
                var next = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                if let ratio = model.aspect.ratio(for: image) {
                    let unitRatio = ratio * CGFloat(image.height) / CGFloat(image.width)
                    var width = next.width
                    var height = width / unitRatio
                    let maxHeight = corner.isTop ? start.maxY : 1 - start.minY
                    if height > maxHeight {
                        height = maxHeight
                        width = height * unitRatio
                    }
                    let maxWidth = corner.isLeft ? start.maxX : 1 - start.minX
                    if width > maxWidth {
                        width = maxWidth
                        height = width / unitRatio
                    }
                    next.size = CGSize(width: width, height: height)
                    next.origin.x = corner.isLeft ? start.maxX - width : start.minX
                    next.origin.y = corner.isTop ? start.maxY - height : start.minY
                }
                model.crop = next
            }
            .onEnded { _ in dragStart = nil }
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isTop: Bool { self == .topLeft || self == .topRight }
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }

        func point(in rect: CGRect) -> CGPoint {
            CGPoint(x: isLeft ? rect.minX : rect.maxX, y: isTop ? rect.minY : rect.maxY)
        }
    }
}

nonisolated struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        return path
    }
}
