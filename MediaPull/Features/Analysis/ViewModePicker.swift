import MediaPullCore
import SwiftUI

/// The Finder-style view switch in a pane's header: icons, a list and, for folder panes, columns (R-1708).
struct ViewModePicker: View {
    @Bindable var model: WindowModel
    let pane: PaneID

    var body: some View {
        Picker("View", selection: Binding(get: { model.viewMode(for: pane) }, set: { model.setViewMode($0, for: pane) })) {
            ForEach(model.availableViewModes(for: pane), id: \.self) { mode in
                Image(systemName: mode.symbol)
                    .help("View \(mode.label)")
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Change how this pane shows its media")
    }
}
