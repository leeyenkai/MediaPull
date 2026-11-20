import SwiftUI

/// The section tabs at the left of the title bar (D-62): drawn like the browser's tab chips, with the same small corners as
/// the address and search fields, so the top of the window reads as one set of straight-edged controls.
struct SectionTabs: View {
    @Binding var section: WindowSection

    var body: some View {
        ChipTabs(selection: $section, items: WindowSection.allCases, label: \.label, symbol: \.symbol)
            .help("Collect media from the web, or organise media in folders (⌃⌘1, ⌃⌘2)")
    }
}

/// Tabs drawn as chips with small corners, used wherever the app switches between views (title bar, Organise pane).
struct ChipTabs<Item: Hashable>: View {
    @Binding var selection: Item
    let items: [Item]
    let label: KeyPath<Item, String>
    var symbol: KeyPath<Item, String>?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                ChipTab(title: item[keyPath: label], symbol: symbol.map { item[keyPath: $0] }, selected: selection == item) {
                    selection = item
                }
            }
        }
    }
}

private struct ChipTab: View {
    let title: String
    let symbol: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                }
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
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
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A title-bar button without the capsule: an icon on a square with the shared small corners, shaded on hover.
struct TopBarButton: View {
    let title: String
    let symbol: String
    var active = false
    var badge = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(active ? Color.accentColor : .primary)
                .frame(width: 30, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: TopBarStyle.radius, style: .continuous)
                        .fill(active ? Color.primary.opacity(0.11) : (hovering ? Color.primary.opacity(0.07) : .clear))
                )
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .offset(x: 3, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

enum TopBarStyle {
    /// The corner radius shared by the title bar, the address field, search fields and tab chips.
    static let radius: CGFloat = 6
}

extension WindowSection {
    var symbol: String {
        switch self {
        case .collect: "square.and.arrow.down.on.square"
        case .organise: "folder"
        case .devices: "iphone"
        }
    }
}
