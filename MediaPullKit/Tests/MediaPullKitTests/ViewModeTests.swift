import Foundation
@testable import MediaPullCore
import XCTest

/// Finder-style views per pane (R-1708 to R-1711, D-76).
final class ViewModeTests: XCTestCase {
    func testAllowedViewsPerPane() {
        XCTAssertEqual(PaneViewMode.allowed(for: .library), [.icon, .list, .column])
        // Profile only in Organise, and only where the folder qualifies (WindowModel.availableViewModes, D-113).
        XCTAssertEqual(PaneViewMode.allowed(for: .organiseSource), [.icon, .list, .column, .profile])
        XCTAssertEqual(PaneViewMode.allowed(for: .organiseTarget), [.icon, .list, .column, .profile])
        var modes = PaneViewModes()
        modes.set(.profile, for: .library)
        XCTAssertEqual(modes.mode(for: .library), .icon, "the Library has no profile view")
        XCTAssertEqual(PaneViewMode.allowed(for: .extracted), [.icon, .list])
        XCTAssertEqual(PaneViewMode.allowed(for: .preview), [.icon])
    }

    func testStoredViewsFallBackToIcons() throws {
        let json = #"{"library":"list","extracted":"column","organiseSource":"gallery","organiseTarget":"column"}"#
        let modes = try JSONDecoder().decode(PaneViewModes.self, from: Data(json.utf8))
        XCTAssertEqual(modes.mode(for: .library), .list)
        XCTAssertEqual(modes.mode(for: .extracted), .icon, "Extracted Media has no column view")
        XCTAssertEqual(modes.mode(for: .organiseSource), .icon, "a view this version does not know")
        XCTAssertEqual(modes.mode(for: .organiseTarget), .column)
        XCTAssertEqual(PaneViewModes().mode(for: .library), .icon)

        var changed = modes
        changed.set(.column, for: .extracted)
        XCTAssertEqual(changed.mode(for: .extracted), .icon)
        changed.set(.list, for: .extracted)
        let round = try JSONDecoder().decode(PaneViewModes.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(round.mode(for: .extracted), .list)
    }

    func testColumnsMapToSortsBothWays() {
        let library: [(ListColumn, LibrarySort?)] = [(.name, .name), (.date, .date), (.size, .fileSize), (.dimensions, .pixelSize),
                                                    (.duration, .videoLength), (.kind, nil)]
        for (column, sort) in library {
            XCTAssertEqual(column.librarySort, sort, column.rawValue)
            if let sort { XCTAssertEqual(ListColumn(librarySort: sort), column) }
        }
        XCTAssertNil(ListColumn(librarySort: .events), "grouped sorts have no column")
        let extracted: [(ListColumn, MediaPullCore.SortOrder?)] = [
            (.dimensions, .resolution), (.size, .fileSize), (.kind, .type), (.duration, .duration),
            (.source, .domain), (.found, .discovery), (.name, nil),
        ]
        for (column, sort) in extracted {
            XCTAssertEqual(column.extractedSort, sort, column.rawValue)
            if let sort { XCTAssertEqual(ListColumn(extractedSort: sort), column) }
        }
    }

    func testHeaderClicks() {
        XCTAssertTrue(ListSortState.next(clicked: .name, current: nil).ascending)
        XCTAssertFalse(ListSortState.next(clicked: .size, current: (.name, true)).ascending, "largest first, as in the Finder")
        let flipped = ListSortState.next(clicked: .size, current: (.size, false))
        XCTAssertEqual(flipped.column, .size)
        XCTAssertTrue(flipped.ascending)
    }
}
