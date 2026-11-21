@preconcurrency import AVFoundation
import Foundation
@testable import MediaPullCore
@testable import MediaPullEdit
@testable import MediaPullEngines
import XCTest

extension VideoEditTests {
    /// C7-1: fades scaled to meet (C6-1) are rounded to 1/600 s separately, so the fade-out's ramp can start one tick
    /// before the fade-in's ends: AVFoundation throws and the app stops. A 5 s sound at 1.5x with 5 s fades each.
    func testC7ScaledFadesThatMeetNeverOverlapAfterRounding() async throws {
        let source = try await clip(soundLonger: 1)
        var edit = recipe(source)
        var time = EditTimeline()
        time.speed = 1.5
        time.fadeIn = 5
        time.fadeOut = 5
        edit.timeline = time
        _ = try await VideoComposer.playerItem(AVURLAsset(url: source), recipe: edit)
        let output = folder.appendingPathComponent("meet.mp4")
        _ = try await VideoComposer.export(source, recipe: edit, to: output) { _ in }
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 5 / 1.5, accuracy: 0.2)
    }
}

final class Audit2026Round7AudioTests: XCTestCase {
    /// The waveform's buckets cover the whole sound, so a peak near the end is drawn where it is.
    func testC7WaveformBucketsCoverTheWholeFile() {
        // 5 s at the waveform's 2 kHz: a click at 4.9 s.
        var samples = [Float](repeating: 0, count: 10000)
        samples[9800] = 1
        let peaks = AudioEdit.peaks(samples, buckets: 1200)
        XCTAssertEqual(peaks.count, 1200)
        let index = peaks.firstIndex(of: 1)
        XCTAssertNotNil(index, "the click at 4.9 s is not drawn")
        if let index { XCTAssertEqual(Double(index) / 1200 * 5, 4.9, accuracy: 0.01) }
    }

    /// Play Result starts where the playhead is in the result, not at its time in the original (C7-2).
    func testThePlayheadIsFoundInTheResult() {
        var time = EditTimeline()
        time.kept = [TimeRange(start: 20, end: 30)]
        XCTAssertEqual(time.resultTime(of: 25, duration: 30), 5, accuracy: 1e-9)
        time.kept = [TimeRange(start: 0, end: 5), TimeRange(start: 10, end: 20)]
        time.speed = 2
        XCTAssertEqual(time.resultTime(of: 12, duration: 20), 3.5, accuracy: 1e-9)
        XCTAssertEqual(time.resultTime(of: 7, duration: 20), 2.5, accuracy: 1e-9)
    }

    /// A tag typed as spaces is not a request to remove the file's own tag.
    func testC7ATagOfSpacesDoesNotRemoveTheTag() {
        var tags = AudioTagEdit()
        tags.title = " "
        XCTAssertFalse(tags.metadata.contains { $0.key == "title" && $0.value.isEmpty })
    }
}
