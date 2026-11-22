import CoreGraphics
import Foundation
@testable import MediaPullCore
@testable import MediaPullEdit
import XCTest

/// D-132: the arithmetic behind direct editing on the canvas and the timeline.
final class EditCanvasTests: XCTestCase {
    private func close(_ a: CGPoint, _ b: CGPoint, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, message, file: file, line: line)
    }

    func testHandlesStayOnTheCornersOfATurnedLayer() {
        let centre = CGPoint(x: 100, y: 50)
        let size = CGSize(width: 40, height: 20)
        let flat = CanvasMath.corners(centre: centre, size: size, degrees: 0)
        close(flat[0], CGPoint(x: 80, y: 40), "top left, unturned")
        close(flat[3], CGPoint(x: 120, y: 60), "bottom right, unturned")
        // A quarter turn clockwise (y down): the top left corner goes to the top right of the turned box.
        let quarter = CanvasMath.corners(centre: centre, size: size, degrees: 90)
        close(quarter[0], CGPoint(x: 110, y: 30), "top left after a quarter turn")
        close(quarter[3], CGPoint(x: 90, y: 70), "bottom right after a quarter turn")
        for degrees in stride(from: -180.0, through: 180, by: 15) {
            let corners = CanvasMath.corners(centre: centre, size: size, degrees: degrees)
            for corner in corners {
                let distance = hypot(corner.x - centre.x, corner.y - centre.y)
                XCTAssertEqual(distance, hypot(20, 10), accuracy: 0.001, "every corner stays as far from the centre at \(degrees)°")
            }
        }
    }

    func testResizingATurnedLayerKeepsTheOppositeCorner() {
        let centre = CGPoint(x: 200, y: 150)
        let size = CGSize(width: 80, height: 40)
        for degrees in [0.0, 30, 90, -45, 170] {
            for corner in 0 ..< 4 {
                let before = CanvasMath.corners(centre: centre, size: size, degrees: degrees)
                let resized = CanvasMath.resize(centre: centre, size: size, degrees: degrees, corner: corner,
                                                by: CGSize(width: 13, height: -7))
                let after = CanvasMath.corners(centre: resized.centre, size: resized.size, degrees: degrees)
                close(after[3 - corner], before[3 - corner], "the opposite corner stays at \(degrees)°, corner \(corner)")
            }
        }
        // Dragging the bottom right corner outward along the turned box's own axes grows it by that much.
        let turned = CanvasMath.turned(CGPoint(x: 10, y: 6), by: 30)
        let grown = CanvasMath.resize(centre: centre, size: size, degrees: 30, corner: 3, by: CGSize(width: turned.x, height: turned.y))
        XCTAssertEqual(grown.size.width, 90, accuracy: 0.001)
        XCTAssertEqual(grown.size.height, 46, accuracy: 0.001)
        let tiny = CanvasMath.resize(centre: centre, size: size, degrees: 0, corner: 3, by: CGSize(width: -500, height: -500))
        XCTAssertEqual(tiny.size.width, 8, "never smaller than the minimum")
    }

    func testSnappingToTheCentreLines() {
        XCTAssertEqual(CanvasMath.snap(198, to: 200, within: 4).value, 200)
        XCTAssertTrue(CanvasMath.snap(204, to: 200, within: 4).snapped)
        XCTAssertEqual(CanvasMath.snap(205, to: 200, within: 4).value, 205)
        XCTAssertFalse(CanvasMath.snap(195.9, to: 200, within: 4).snapped)
    }

    func testTrimHandlesKeepPartsInOrder() {
        let parts = [TimeRange(start: 1, end: 4), TimeRange(start: 6, end: 9)]
        // The first part's end cannot pass the second part's start, nor its start pass its own end.
        XCTAssertEqual(EditTimeline.moving(parts, index: 0, start: false, to: 7.5, duration: 10)[0].end, 6)
        XCTAssertEqual(EditTimeline.moving(parts, index: 0, start: true, to: 5, duration: 10)[0].start, 3.9, accuracy: 0.0001)
        XCTAssertEqual(EditTimeline.moving(parts, index: 0, start: true, to: -2, duration: 10)[0].start, 0, "not before the file")
        // The second part's start cannot go back past the first part's end, nor its end past the file's.
        XCTAssertEqual(EditTimeline.moving(parts, index: 1, start: true, to: 2, duration: 10)[1].start, 4)
        XCTAssertEqual(EditTimeline.moving(parts, index: 1, start: false, to: 12, duration: 10)[1].end, 10)
        XCTAssertEqual(EditTimeline.moving(parts, index: 1, start: false, to: 8, duration: 10),
                       [TimeRange(start: 1, end: 4), TimeRange(start: 6, end: 8)], "only that end moves")
        XCTAssertEqual(EditTimeline.moving(parts, index: 5, start: true, to: 2, duration: 10), parts, "a part that is not there")
        for _ in 0 ..< 500 {
            let index = Int.random(in: 0 ... 1), start = Bool.random(), to = Double.random(in: -3 ... 13)
            let moved = EditTimeline.moving(parts, index: index, start: start, to: to, duration: 10)
            XCTAssertGreaterThanOrEqual(moved[0].start, 0)
            XCTAssertLessThan(moved[0].start, moved[0].end)
            XCTAssertLessThanOrEqual(moved[0].end, moved[1].start)
            XCTAssertLessThan(moved[1].start, moved[1].end)
            XCTAssertLessThanOrEqual(moved[1].end, 10)
        }
    }

    func testTheBorderSliderEndsWhereTheBorderStops() {
        XCTAssertEqual(Frame.borderRange(extra: 0).upperBound, 0.4, accuracy: 0.0001)
        XCTAssertEqual(Frame.borderRange(extra: 0.15).upperBound, 0.25, accuracy: 0.0001)
        XCTAssertGreaterThan(Frame.borderRange(extra: 0.5).upperBound, 0, "never an empty range")
    }

    func testATemplateAsksFirstOnlyBeforeReplacingThePersonsOwnLayers() {
        XCTAssertFalse(EditTemplate.wouldReplaceOwnLayers([]), "nothing to replace")
        for template in EditTemplate.allCases {
            var recipe = EditRecipe(source: EditSource(path: "/a.jpg", kind: .image))
            template.apply(to: &recipe)
            XCTAssertFalse(EditTemplate.wouldReplaceOwnLayers(recipe.layers), "\(template.label)'s own layers, unchanged")
            guard !recipe.layers.isEmpty else { continue }
            var moved = recipe.layers
            moved[0].x += 0.1
            XCTAssertTrue(EditTemplate.wouldReplaceOwnLayers(moved), "\(template.label)'s layers once the person moved one")
            var retyped = recipe.layers
            if case var .text(style) = retyped[0].kind {
                style.text = "Our day"
                retyped[0].kind = .text(style)
            }
            XCTAssertTrue(EditTemplate.wouldReplaceOwnLayers(retyped), "\(template.label)'s layers once the person typed in one")
        }
        XCTAssertTrue(EditTemplate.wouldReplaceOwnLayers([Layer(kind: .text(TextStyle(text: "Mine")))]))
    }

    func testTheSizesShownAreTheSizesWritten() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let session = PhotoSession(image: try XCTUnwrap(context.makeImage()), url: URL(fileURLWithPath: "/a.png"))
        var recipe = EditRecipe(source: EditSource(path: "/a.png", kind: .image))
        XCTAssertEqual(session.outputSize(recipe), CGSize(width: 400, height: 300), "unedited")
        recipe.geometry.crop = UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)
        XCTAssertEqual(session.cropPixels(recipe.geometry), CGSize(width: 200, height: 150))
        XCTAssertEqual(session.outputSize(recipe), CGSize(width: 200, height: 150), "cropped")
        recipe.geometry.crop = nil
        recipe.geometry.quarterTurns = 1
        XCTAssertEqual(session.outputSize(recipe), CGSize(width: 300, height: 400), "turned")
        recipe.geometry.quarterTurns = 0
        var frame = Frame()
        frame.shape = .square
        recipe.frame = frame
        let framed = session.outputSize(recipe)
        XCTAssertEqual(framed.width, framed.height, accuracy: 1, "a square frame is square")
        recipe.export.size = .long1080
        XCTAssertLessThanOrEqual(max(session.outputSize(recipe).width, session.outputSize(recipe).height), 1080)
    }
}
