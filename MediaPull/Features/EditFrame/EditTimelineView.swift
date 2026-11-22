import MediaPullCore
import SwiftUI

/// The video's timeline (R-4609): the whole original, with the parts kept in colour and the playhead; a click moves the
/// playhead there, and each kept part has handles at its ends to drag them (R-4612, D-132).
struct EditTimelineView: View {
    @Bindable var edit: EditModel
    @State private var dragging = false

    var body: some View {
        let duration = max(edit.mediaDuration, 0.001)
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.25))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if edit.playingResult { edit.loadPlayer() }
                        edit.player.seek(min(max(0, value.location.x / width), 1) * duration)
                    })
                let parts = edit.keptRanges
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(2, (part.end - part.start) / duration * width))
                        .offset(x: part.start / duration * width)
                        .allowsHitTesting(false)
                    handle(index: index, start: true, at: part.start / duration * width, width: width, duration: duration)
                    handle(index: index, start: false, at: part.end / duration * width, width: width, duration: duration)
                }
                if !edit.playingResult {
                    Rectangle().fill(.white).frame(width: 2)
                        .shadow(radius: 1)
                        .offset(x: min(width - 2, edit.player.time / duration * width))
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(Self.clock(edit.player.time)) of \(Self.clock(edit.mediaDuration))")
    }

    /// A grip at one end of a kept part; dragging it moves that end and the playhead with it, so the cut is seen.
    private func handle(index: Int, start: Bool, at x: CGFloat, width: CGFloat, duration: Double) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1))
            .frame(width: 7, height: 28)
            .shadow(color: .black.opacity(0.3), radius: 1)
            .contentShape(Rectangle().inset(by: -4))
            .offset(x: min(max(0, x - (start ? 0 : 7)), width - 7))
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline")).onChanged { value in
                if !dragging {
                    dragging = true
                    if edit.playingResult { edit.loadPlayer() }
                    edit.beginGesture()
                }
                let seconds = min(max(0, value.location.x / width), 1) * duration
                edit.setPartEdge(index: index, start: start, to: seconds)
                edit.player.seek(seconds)
            }.onEnded { _ in
                dragging = false
                edit.endGesture()
            })
            .help(start ? "Drag to move where this part starts" : "Drag to move where this part ends")
            .accessibilityLabel(start ? "Start of part \(index + 1)" : "End of part \(index + 1)")
            .disabled(edit.playingResult)
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let whole = Int(seconds)
        let tenths = Int((seconds - Double(whole)) * 10)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }
}
