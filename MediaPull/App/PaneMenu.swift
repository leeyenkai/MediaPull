import MediaPullCore
import SwiftUI

/// Move, stack and hide commands for one pane, shared by pane headers and the View menu.
struct PaneMoveCommands: View {
    let pane: PaneID
    var window: WindowModel?
    private var app: AppModel { .shared }

    var body: some View {
        let layout = app.preferences.paneArrangement
        let stacked = layout.isStacked(pane)
        Button(stacked ? "Move to New Column on the Left" : "Move Left") { change { $0.move(pane, .left) } }
            .disabled(!layout.canMove(pane, .left))
        Button(stacked ? "Move to New Column on the Right" : "Move Right") { change { $0.move(pane, .right) } }
            .disabled(!layout.canMove(pane, .right))
        Button("Stack in Column on the Left") { change { $0.stack(pane, onto: .left) } }
            .disabled(!layout.canStack(pane, onto: .left))
        Button("Stack in Column on the Right") { change { $0.stack(pane, onto: .right) } }
            .disabled(!layout.canStack(pane, onto: .right))
        if stacked {
            Button("Move Up") { change { $0.moveInStack(pane, .up) } }
                .disabled(!layout.canMoveInStack(pane, .up))
            Button("Move Down") { change { $0.moveInStack(pane, .down) } }
                .disabled(!layout.canMoveInStack(pane, .down))
        }
        if let window {
            Divider()
            Button(window.isShowing(pane) ? "Hide \(pane.title)" : "Show \(pane.title)") {
                window.setShowing(pane, !window.isShowing(pane))
            }
        }
    }

    private func change(_ edit: (inout PaneArrangement) -> Void) {
        var layout = app.preferences.paneArrangement
        edit(&layout)
        app.preferences.paneArrangement = layout
        window?.setShowing(pane, true)
    }
}

/// The preset arrangements.
struct LayoutPresetCommands: View {
    private var app: AppModel { .shared }

    var body: some View {
        ForEach(PaneArrangement.presets, id: \.name) { preset in
            Toggle(preset.name, isOn: Binding(
                get: { app.preferences.paneArrangement == preset.arrangement },
                set: { if $0 { app.preferences.paneArrangement = preset.arrangement } }
            ))
        }
    }
}

/// The small arrange button in a pane's header.
struct PaneMenu: View {
    let pane: PaneID
    var window: WindowModel

    var body: some View {
        Menu {
            PaneMoveCommands(pane: pane, window: window)
            Divider()
            Menu("Layout") { LayoutPresetCommands() }
        } label: {
            Image(systemName: "rectangle.3.group")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move, stack or hide this pane")
    }
}
