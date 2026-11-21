import Foundation
@testable import MediaPullCore
import XCTest

/// Section 44: map pins and timeline bars.
final class MapTimelineTests: XCTestCase {
    func point(_ id: String, _ lat: Double, _ lon: Double) -> MapClusters.Point { .init(id: id, latitude: lat, longitude: lon) }

    func testPinsJoinWhenZoomedOutAndSplitWhenZoomedIn() {
        let paris = [point("p1", 48.858, 2.294), point("p2", 48.853, 2.349), point("p3", 48.860, 2.337)]
        let tokyo = [point("t1", 35.658, 139.745)]
        let world = MapClusters.Area(south: -85, west: -180, north: 85, east: 180)
        let far = MapClusters.clusters(paris + tokyo, in: world)
        XCTAssertEqual(far.map(\.ids.count).sorted(), [1, 3], "Paris is one pin from far away")
        let city = MapClusters.Area(south: 48.80, west: 2.25, north: 48.90, east: 2.42)
        let near = MapClusters.clusters(paris + tokyo, in: city)
        XCTAssertEqual(near.flatMap(\.ids).sorted(), ["p1", "p2", "p3"], "Tokyo is outside the area")
        XCTAssertGreaterThan(near.count, 1, "close up, the pins split")
        let many = (0 ..< 2000).map { point("m\($0)", Double($0 % 80) - 40, Double($0 / 80 * 7) - 170) }
        XCTAssertLessThanOrEqual(MapClusters.clusters(many, in: world, cells: 200, limit: 100).count, 100, "never more than the limit")
        let pacific = MapClusters.Area(south: -30, west: 170, north: 30, east: -170)
        XCTAssertTrue(pacific.contains(latitude: 0, longitude: 179))
        XCTAssertTrue(pacific.contains(latitude: 0, longitude: -175))
        XCTAssertFalse(pacific.contains(latitude: 0, longitude: 0))
    }

    func testTimelineBucketsKeepGaps() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
        let dated = [("a", day(2024, 1, 5)), ("b", day(2024, 1, 20)), ("c", day(2024, 3, 2))].map { (id: $0.0, date: $0.1) }
        let months = Timeline.buckets(dated, scale: .month, calendar: calendar)
        XCTAssertEqual(months.map(\.ids.count), [2, 0, 1], "February shows as an empty bar")
        XCTAssertEqual(Timeline.buckets(dated, scale: .year, calendar: calendar).map(\.ids.count), [3])
        XCTAssertEqual(Timeline.scale(from: day(2024, 1, 1), to: day(2024, 1, 30)), .day)
        XCTAssertEqual(Timeline.scale(from: day(2020, 1, 1), to: day(2024, 1, 1)), .month)
        XCTAssertEqual(Timeline.scale(from: day(2001, 1, 1), to: day(2024, 1, 1)), .year)
        XCTAssertTrue(Timeline.buckets([], scale: .day).isEmpty)
    }

    func testTheMapPaneJoinsSavedArrangements() throws {
        let json = Data(#"[["organiseSource"],["organiseWork"],["organiseTarget"]]"#.utf8)
        let saved = try JSONDecoder().decode(PaneArrangement.self, from: json)
        XCTAssertNotNil(saved.column(of: .organiseMap), "an arrangement saved before the pane existed gains it")
        XCTAssertEqual(PaneID.organiseMap.group, .organise)
    }
}
