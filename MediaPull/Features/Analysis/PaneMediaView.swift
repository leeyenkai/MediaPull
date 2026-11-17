import MediaPullCore
import SwiftUI

/// A pane's media in the view chosen for it: the icon grid or the list (R-1708). Column view replaces the pane's tree as
/// well, so the pane shows it itself.
struct PaneMediaView: View {
    let mode: PaneViewMode
    let sections: [GridSection]
    let selection: Set<String>
    let cellSize: CGFloat
    let revision: Int
    let owner: any MediaListOwner

    var body: some View {
        if mode == .list {
            MediaList(sections: sections, topFolders: owner.listTopFolders, selection: selection, revision: revision, owner: owner)
        } else {
            MediaGrid(sections: sections, selection: selection, cellSize: cellSize, revision: revision, owner: owner)
        }
    }
}
