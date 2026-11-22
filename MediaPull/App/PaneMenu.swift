import MediaPullCore
import SwiftUI

/// Move, stack and hide commands for one pane, shared by pane headers and the View menu.
struct PaneMoveCommands: View {
    let pane: PaneID
    var window: WindowModel?
    private var app: AppModel { .shared }

    var body: some View {
        let layout = app.preferences.arrangement(for: pane.group)
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
        var layout = app.preferences.arrangement(for: pane.group)
        edit(&layout)
        app.preferences.setArrangement(layout)
        window?.setShowing(pane, true)
    }
}

/// The preset arrangements.
struct LayoutPresetCommands: View {
    var group: PaneGroup = .collect
    private var app: AppModel { .shared }

    var body: some View {
        ForEach(PaneArrangement.presets(for: group), id: \.name) { preset in
            Toggle(preset.name, isOn: Binding(
                get: { app.preferences.arrangement(for: group) == preset.arrangement },
                set: { if $0 { app.preferences.setArrangement(preset.arrangement) } }
            ))
        }
    }
}

/// The small arrange button in a pane's header.
struct PaneMenu: View {
    let pane: PaneID
    var window: WindowModel

    var body: some View {
        // Arranging panes is rare, so its icon stays faint until the pointer is on it (D-132).
        QuietIconMenu(title: "Arrange \(pane.title)", symbol: "rectangle.3.group", help: "Move, stack or hide this pane", faint: true) {
            PaneMoveCommands(pane: pane, window: window)
            Divider()
            Menu("Layout") { LayoutPresetCommands(group: pane.group) }
        }
    }
}
