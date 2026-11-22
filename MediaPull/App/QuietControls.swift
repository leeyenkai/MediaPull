import SwiftUI

/// A secondary icon action (D-132): grey, brighter on hover, never tinted by the window's accent. The accent is kept
/// for selection and the main action of a pane.
struct QuietIconButton: View {
    let title: String
    let symbol: String
    var help: String?
    var size: CGFloat = 12
    var emphasised = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            QuietIconLabel(symbol: symbol, size: size, hovering: hovering && enabled, emphasised: emphasised)
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

/// A menu behind a quiet icon (D-132), for choices that are not everyday tools (arranging panes, sorting).
struct QuietIconMenu<Content: View>: View {
    let title: String
    let symbol: String
    var help: String?
    var size: CGFloat = 12
    var faint = false
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content
        } label: {
            QuietIconLabel(symbol: symbol, size: size, hovering: hovering, emphasised: false)
                .opacity(faint && !hovering ? 0.6 : 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

private struct QuietIconLabel: View {
    let symbol: String
    let size: CGFloat
    let hovering: Bool
    let emphasised: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(hovering || emphasised ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(width: size + 12, height: size + 10)
            .background(
                RoundedRectangle(cornerRadius: TopBarStyle.radius - 1, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
    }
}

/// A tool tab: an icon over a short name, filling its share of the strip (D-132). Used for Edit/Frame's tools.
struct ToolTab: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(height: 16)
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: TopBarStyle.radius, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.11) : (hovering ? Color.primary.opacity(0.05) : .clear))
                    .overlay {
                        RoundedRectangle(cornerRadius: TopBarStyle.radius, style: .continuous)
                            .strokeBorder(selected ? Color.primary.opacity(0.12) : .clear, lineWidth: 0.5)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small chip for one of a few values shown side by side (a crop shape, a zoom), drawn like the tab chips.
struct ValueChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background {
                    RoundedRectangle(cornerRadius: TopBarStyle.radius - 1, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(hovering ? 0.07 : 0.04))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A group of tools in an inspector (D-132): a title that folds the group, a dot and Reset while it has changes.
/// Folds are remembered by `key`.
struct InspectorSection<Content: View>: View {
    let title: String
    var key: String?
    var changed = false
    var reset: (() -> Void)?
    @ViewBuilder var content: Content
    private var preferences: Preferences { AppModel.shared.preferences }
    private var id: String { key ?? title }

    var body: some View {
        let folded = preferences.foldedSections.contains(id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    if folded { preferences.foldedSections.remove(id) } else { preferences.foldedSections.insert(id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(folded ? 0 : 90))
                        Text(title).font(.caption.weight(.semibold))
                        if changed {
                            Circle().fill(Color.accentColor).frame(width: 5, height: 5).accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(folded ? "Show \(title)" : "Hide \(title)")
                Spacer(minLength: 4)
                if changed, let reset {
                    Button("Reset", action: reset)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Reset \(title)")
                        .accessibilityLabel("Reset \(title)")
                }
            }
            if !folded { content }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

/// The three kinds of pane surface (D-132): lists of files, the stage where media is shown, and tools.
enum PaneSurface {
    case list, stage, tools

    var color: Color {
        switch self {
        case .list: Color(nsColor: .controlBackgroundColor)
        case .stage: Color(nsColor: .underPageBackgroundColor)
        case .tools: Color(nsColor: .windowBackgroundColor)
        }
    }
}
