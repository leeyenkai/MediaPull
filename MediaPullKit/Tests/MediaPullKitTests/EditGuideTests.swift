import CoreGraphics
import CoreImage
import Foundation
@testable import MediaPullCore
@testable import MediaPullEdit
import XCTest

/// D-133: guides, snapping and rulers on the Edit/Frame canvas, and the photo moved in its frame.
final class EditGuideTests: XCTestCase {
    private let canvas = CGRect(x: 20, y: 10, width: 300, height: 200)

    func testGridLines() {
        XCTAssertEqual(CanvasGrid.none.lines(in: canvas).xs, [])
        let thirds = CanvasGrid.thirds.lines(in: canvas)
        XCTAssertEqual(thirds.xs, [120, 220])
        XCTAssertEqual(thirds.ys[0], 10 + 200.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(thirds.ys[1], 10 + 400.0 / 3, accuracy: 1e-9)
        // Squares: eight across the shorter side, about the centre lines, never on the edges.
        let squares = CanvasGrid.squares.lines(in: canvas)
        XCTAssertEqual(squares.ys.count, 7)
        XCTAssertEqual(squares.ys[3], canvas.midY)
        XCTAssertEqual(squares.ys[1] - squares.ys[0], 25, accuracy: 1e-9)
        XCTAssertTrue(squares.xs.contains(canvas.midX))
        XCTAssertTrue(squares.xs.allSatisfy { $0 > canvas.minX && $0 < canvas.maxX })
    }

    func testABoxSnapsByItsNearestEdgeOrCentre() {
        let targets = CanvasSnap.targets(canvas: canvas)
        let cases: [(CGRect, CGRect, String)] = [
            // Centre 3 points from the canvas's centre line on x; nothing near on y.
            (CGRect(x: 123, y: 60, width: 100, height: 30), CGRect(x: 120, y: 60, width: 100, height: 30), "centre x"),
            // Left edge 4 points inside the canvas's left edge, top edge 2 below the top.
            (CGRect(x: 24, y: 12, width: 50, height: 20), CGRect(x: 20, y: 10, width: 50, height: 20), "left and top edges"),
            // Right edge 1 point from the right edge beats the centre 4 away.
            (CGRect(x: 319 - 302, y: 60, width: 302, height: 30), CGRect(x: 18, y: 60, width: 302, height: 30), "nearest wins"),
            // Too far: stays.
            (CGRect(x: 40, y: 40, width: 10, height: 10), CGRect(x: 40, y: 40, width: 10, height: 10), "too far"),
        ]
        for (box, expected, message) in cases {
            let snapped = CanvasSnap.snap(box, to: targets)
            XCTAssertEqual(snapped.minX, expected.minX, accuracy: 1e-9, message)
            XCTAssertEqual(snapped.minY, expected.minY, accuracy: 1e-9, message)
            XCTAssertEqual(snapped.size, box.size, message)
        }
    }

    func testTargetsIncludeThePhotoOtherLayersAndTheGridShown() {
        let photo = CGRect(x: 40, y: 30, width: 200, height: 120)
        let other = CGRect(x: 250, y: 160, width: 40, height: 20)
        let targets = CanvasSnap.targets(canvas: canvas, photo: photo, others: [other], grid: .thirds)
        for x in [40.0, 140, 240, 250, 270, 290, 120, 220] {
            XCTAssertTrue(targets.xs.contains(x), "\(x)")
        }
        XCTAssertFalse(CanvasSnap.targets(canvas: canvas).xs.contains(120), "thirds only while shown")
        // A text box lines up with the other layer's left edge.
        let snapped = CanvasSnap.snap(CGRect(x: 252, y: 60, width: 30, height: 10), to: targets)
        XCTAssertEqual(snapped.minX, 250)
        XCTAssertEqual(CanvasSnap.lines(for: snapped, targets: targets), [SnapLine(.vertical, 250)])
    }

    func testLinesShowWhatABoxMeets() {
        let targets = CanvasSnap.targets(canvas: canvas)
        let centred = CGRect(x: canvas.midX - 50, y: canvas.midY - 10, width: 100, height: 20)
        XCTAssertEqual(CanvasSnap.lines(for: centred, targets: targets),
                       [SnapLine(.vertical, canvas.midX), SnapLine(.horizontal, canvas.midY)])
        XCTAssertEqual(CanvasSnap.lines(for: centred, targets: targets, horizontal: false), [SnapLine(.vertical, canvas.midX)])
        XCTAssertEqual(CanvasSnap.lines(for: centred.offsetBy(dx: 2, dy: 2), targets: targets), [])
        // The whole canvas meets each line once, though edges and centres both match.
        XCTAssertEqual(CanvasSnap.lines(for: canvas, targets: targets).count, 6)
    }

    func testCornersAndTurnedBoxes() {
        let targets = CanvasSnap.targets(canvas: canvas)
        XCTAssertEqual(CanvasSnap.snap(CGPoint(x: 317, y: 106), to: targets), CGPoint(x: 320, y: 110))
        XCTAssertEqual(CanvasSnap.snap(CGPoint(x: 300, y: 50), to: targets), CGPoint(x: 300, y: 50))
        // A square turned 45° is snapped by the box around it.
        let bounds = CanvasSnap.bounds(centre: CGPoint(x: 100, y: 100), size: CGSize(width: 10, height: 10), degrees: 45)
        XCTAssertEqual(bounds.width, 10 * 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(bounds.midX, 100, accuracy: 1e-9)
    }

    func testRulerSteps() {
        // (points per pixel, major step in pixels, divisions)
        let cases: [(Double, Double, Int)] = [
            (1, 100, 10), (0.5, 200, 4), (0.25, 500, 10), (0.1, 1000, 10), (0.05, 2000, 4), (2, 50, 10), (10, 10, 10), (40, 2, 2),
            (100, 1, 1),
        ]
        for (scale, major, divisions) in cases {
            let step = RulerScale.step(pointsPerPixel: scale)
            XCTAssertEqual(step.major, major, "\(scale)")
            XCTAssertEqual(step.divisions, divisions, "\(scale)")
            XCTAssertGreaterThanOrEqual(step.major * scale, 56)
        }
        XCTAssertEqual(RulerScale.step(pointsPerPixel: 0).major, 1)
    }

    // MARK: The photo in its frame (R-4605)

    func testThePhotoSitsWhereTheFrameSays() {
        var frame = Frame()
        frame.shape = .square
        (frame.top, frame.left, frame.right, frame.bottom) = (0.1, 0.1, 0.1, 0.1)
        let picture = CGSize(width: 1000, height: 500)
        // Fitted: 800 × 400 in an 800 × 800 box; centred by default, then moved to the top and the bottom.
        XCTAssertEqual(FrameRenderer.placement(picture: picture, frame: frame).photo, CGRect(x: 100, y: 300, width: 800, height: 400))
        frame.photoY = 0
        XCTAssertEqual(FrameRenderer.placement(picture: picture, frame: frame).photo.minY, 100)
        frame.photoY = 1
        XCTAssertEqual(FrameRenderer.placement(picture: picture, frame: frame).photo.maxY, 900)
        frame.photoY = 7
        XCTAssertEqual(FrameRenderer.placement(picture: picture, frame: frame).photo.maxY, 900, "clamped")
        // Filling: the photo covers the box and the picture slides behind it.
        frame.fill = true
        frame.photoY = 0.5
        frame.photoX = 0
        var placed = FrameRenderer.placement(picture: picture, frame: frame)
        XCTAssertEqual(placed.photo, placed.box)
        XCTAssertEqual(placed.picture, CGRect(x: 100, y: 100, width: 1600, height: 800))
        frame.photoX = 1
        placed = FrameRenderer.placement(picture: picture, frame: frame)
        XCTAssertEqual(placed.picture.maxX, 900)
        // Its own shape leaves no room to move.
        frame.shape = .photo
        placed = FrameRenderer.placement(picture: picture, frame: frame)
        XCTAssertEqual(placed.picture, placed.box)
    }

    func testPositionIsTheInverseOfPlacement() throws {
        var frame = Frame()
        frame.shape = .portrait45
        let picture = CGSize(width: 1200, height: 800)
        for fill in [false, true] {
            frame.fill = fill
            for along in [0.0, 0.3, 1] {
                frame.photoY = along
                frame.photoX = along
                let placed = FrameRenderer.placement(picture: picture, frame: frame)
                if fill {
                    let x = try XCTUnwrap(FrameRenderer.position(edge: placed.picture.minX, size: placed.picture.width,
                                                                 low: placed.box.minX, length: placed.box.width))
                    XCTAssertEqual(x, along, accuracy: 0.001, "fill \(along)")
                } else {
                    let y = try XCTUnwrap(FrameRenderer.position(edge: placed.picture.minY, size: placed.picture.height,
                                                                 low: placed.box.minY, length: placed.box.height))
                    XCTAssertEqual(y, along, accuracy: 0.01, "fit \(along)")
                    XCTAssertNil(FrameRenderer.position(edge: placed.picture.minX, size: placed.picture.width, low: placed.box.minX,
                                                        length: placed.box.width), "fills the width: no room across")
                }
            }
        }
        XCTAssertEqual(FrameRenderer.position(edge: -50, size: 300, low: 0, length: 200), 0.5)
        XCTAssertEqual(FrameRenderer.position(edge: 500, size: 300, low: 0, length: 200), 0, "clamped")
    }

    func testTheRendererDrawsThePhotoWhereItWasMoved() throws {
        // Left half red, right half blue, 200 × 100, filling a square: only part of it shows.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let input = blue.composited(over: red)
        var recipe = EditRecipe(source: EditSource(path: "/x/a.png", kind: .image))
        var frame = Frame()
        frame.shape = .square
        frame.fill = true
        (frame.top, frame.left, frame.right, frame.bottom) = (0, 0, 0, 0)
        func centre(_ along: Double) throws -> Int {
            frame.photoX = along
            recipe.frame = frame
            let image = try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.render(input, recipe: recipe), exact: true))
            XCTAssertEqual([image.width, image.height], [200, 200])
            var data = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -100, y: -100, width: image.width, height: image.height))
            return Int(data[0]) - Int(data[2])
        }
        XCTAssertGreaterThan(try centre(0), 200, "the left, red half shows")
        XCTAssertLessThan(try centre(1), -200, "the right, blue half shows")
    }

    func testOlderRecipesReadAsCentred() throws {
        let json = #"{"id":"\#(UUID().uuidString)","source":{"path":"/x/a.jpg","kind":"image"},"frame":{"shape":"square","fill":true}}"#
        let read = try XCTUnwrap(EditRecipe.decode(Data(json.utf8)))
        XCTAssertEqual(read.frame?.photoX, 0.5)
        XCTAssertEqual(read.frame?.photoY, 0.5)
        var moved = Frame()
        moved.photoX = 0.2
        var recipe = EditRecipe(source: EditSource(path: "/x/a.jpg", kind: .image))
        recipe.frame = moved
        XCTAssertEqual(EditRecipe.decode(try JSONEncoder().encode(recipe))?.frame?.photoX, 0.2)
    }
}
