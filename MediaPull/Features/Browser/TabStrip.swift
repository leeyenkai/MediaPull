import AppKit
import MediaPullCore
import SwiftUI

/// The browser's tabs (SPEC R-805).
struct TabStrip: View {
    @Bindable var model: WindowModel
    private var app: AppModel { .shared }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                let width = min(220, max(110, (proxy.size.width - 4) / CGFloat(max(model.tabs.count, 1))))
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(model.tabs) { tab in
                                TabChip(model: model, tab: tab, selected: tab.id == model.selectedTabID)
                                    .frame(width: width)
                                    .id(tab.id)
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(height: proxy.size.height)
                    }
                    .onChange(of: model.selectedTabID) { _, id in
                        // Reduce Motion (R-2401): the strip jumps instead of sliding.
                        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                            reader.scrollTo(id)
                        } else {
                            withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id) }
                        }
                    }
                }
            }
            Button { model.newTab() } label: {
                Image(systemName: "plus")
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New Tab (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct TabChip: View {
    @Bindable var model: WindowModel
    var tab: BrowserController
    var selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if tab.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: tab.url == nil ? "plus.square.dashed" : (tab.isShowingPDF ? "doc.richtext" : "globe"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 14)
            Text(title)
                .font(.caption.weight(selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if (hovering || selected) && model.tabs.count > 1 {
                Button { model.closeTab(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(hovering ? Color.secondary.opacity(0.18) : .clear, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    selected ? AnyShapeStyle(Color.primary.opacity(0.11)) : AnyShapeStyle(hovering ? Color.primary.opacity(0.05) : .clear)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? Color.primary.opacity(0.12) : .clear, lineWidth: 0.5)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectTab(tab.id) }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selectTab(tab.id) }
        .onHover { hovering = $0 }
        .help(tab.url?.absoluteString ?? "New Tab")
        .contextMenu {
            Button("New Tab") { model.newTab() }
            if let url = tab.url {
                Button("Duplicate Tab") { model.newTab(url, after: tab.id) }
                Button(AppModel.shared.browsing.bookmark(for: url) == nil ? "Bookmark This Page" : "Already Bookmarked") {
                    AppModel.shared.browsing.addBookmark(title: tab.title, url: url)
                }
                .disabled(AppModel.shared.browsing.bookmark(for: url) != nil)
            }
            Divider()
            Button("Close Tab") { model.closeTab(tab.id) }
            Button("Close Other Tabs") {
                for other in model.tabs where other.id != tab.id { model.closeTab(other.id) }
            }
            .disabled(model.tabs.count < 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var title: String {
        if !tab.title.isEmpty { return tab.title }
        if let host = tab.url?.host { return host }
        return "New Tab"
    }
}
