import MediaPullCore
import SwiftUI

/// The video's timeline (R-4609): the whole original, with the parts kept in colour and the playhead; a click moves the
/// playhead there.
struct EditTimelineView: View {
    @Bindable var edit: EditModel

    var body: some View {
        let duration = max(edit.mediaDuration, 0.001)
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.25))
                ForEach(Array(edit.keptRanges.enumerated()), id: \.offset) { _, part in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(2, (part.end - part.start) / duration * width))
                        .offset(x: part.start / duration * width)
                }
                if !edit.playingResult {
                    Rectangle().fill(.white).frame(width: 2)
                        .shadow(radius: 1)
                        .offset(x: min(width - 2, edit.player.time / duration * width))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if edit.playingResult { edit.loadPlayer() }
                edit.player.seek(min(max(0, value.location.x / width), 1) * duration)
            })
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(Self.clock(edit.player.time)) of \(Self.clock(edit.mediaDuration))")
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let whole = Int(seconds)
        let tenths = Int((seconds - Double(whole)) * 10)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }
}
