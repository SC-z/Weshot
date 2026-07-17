import CoreGraphics
import Foundation
import Testing
@testable import WeShotCore

@Suite("Top-left selection geometry")
struct GeometryTests {
    @Test("Drag rectangles normalize and clip to bounds")
    func normalizationAndClipping() {
        let selection = SelectionGeometry(
            start: CGPoint(x: 90, y: 80),
            end: CGPoint(x: 20, y: 10),
            bounds: CGRect(x: 0, y: 0, width: 70, height: 60)
        )

        #expect(selection.rect == CGRect(x: 20, y: 10, width: 50, height: 50))
        #expect(selection.bounds == CGRect(x: 0, y: 0, width: 70, height: 60))
        #expect(
            SelectionGeometry.normalized(
                CGRect(x: 30, y: 40, width: -20, height: -15)
            ) == CGRect(x: 10, y: 25, width: 20, height: 15)
        )

        let outside = SelectionGeometry(
            rect: CGRect(x: 200, y: 200, width: 10, height: 10),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(outside.rect == CGRect(x: 100, y: 100, width: 0, height: 0))
        #expect(outside.isEmpty)
    }

    @Test("All eight control points use a top-left origin")
    func controlPoints() {
        let rect = CGRect(x: 10, y: 20, width: 80, height: 40)
        let expected: [ResizeHandle: CGPoint] = [
            .topLeft: CGPoint(x: 10, y: 20),
            .top: CGPoint(x: 50, y: 20),
            .topRight: CGPoint(x: 90, y: 20),
            .right: CGPoint(x: 90, y: 40),
            .bottomRight: CGPoint(x: 90, y: 60),
            .bottom: CGPoint(x: 50, y: 60),
            .bottomLeft: CGPoint(x: 10, y: 60),
            .left: CGPoint(x: 10, y: 40),
        ]

        #expect(ResizeHandle.allCases.count == 8)
        for handle in ResizeHandle.allCases {
            #expect(handle.point(in: rect) == expected[handle])
        }
    }

    @Test("Handle and body hit testing prioritize handles")
    func hitTesting() {
        let selection = SelectionGeometry(rect: CGRect(x: 10, y: 10, width: 80, height: 60))

        #expect(selection.handle(at: CGPoint(x: 13, y: 13), tolerance: 5) == .topLeft)
        #expect(selection.hitTest(CGPoint(x: 50, y: 10), handleTolerance: 2) == .handle(.top))
        #expect(selection.hitTest(CGPoint(x: 50, y: 35)) == .inside)
        #expect(selection.hitTest(CGPoint(x: 2, y: 2)) == .outside)
        #expect(selection.handle(at: CGPoint(x: 13, y: 13), tolerance: -1) == nil)
    }

    @Test("Empty selections never expose resize handles")
    func emptySelectionHitTesting() {
        let clippedOutside = SelectionGeometry(
            rect: CGRect(x: 200, y: 200, width: 10, height: 10),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let zero = SelectionGeometry(rect: .zero)

        #expect(clippedOutside.isEmpty)
        #expect(clippedOutside.handle(at: CGPoint(x: 100, y: 100)) == nil)
        #expect(clippedOutside.hitTest(CGPoint(x: 100, y: 100)) == .outside)
        #expect(zero.handle(at: .zero) == nil)
        #expect(zero.hitTest(.zero) == .outside)
    }

    @Test("Movement preserves size and clamps every edge")
    func movement() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let selection = SelectionGeometry(
            rect: CGRect(x: 20, y: 20, width: 40, height: 30),
            bounds: bounds
        )

        #expect(
            selection.moved(by: CGSize(width: 100, height: 100)).rect
                == CGRect(x: 60, y: 50, width: 40, height: 30)
        )
        #expect(
            selection.moved(by: CGSize(width: -100, height: -100)).rect
                == CGRect(x: 0, y: 0, width: 40, height: 30)
        )
        #expect(
            selection.moved(by: CGSize(width: 7, height: -4), bounds: nil).rect
                == CGRect(x: 27, y: 16, width: 40, height: 30)
        )
    }

    @Test("Every handle changes only its own edges")
    func allHandleResizes() {
        let original = CGRect(x: 20, y: 20, width: 40, height: 30)
        let selection = SelectionGeometry(rect: original)
        let translation = CGSize(width: 5, height: 7)
        let expected: [ResizeHandle: CGRect] = [
            .topLeft: CGRect(x: 25, y: 27, width: 35, height: 23),
            .top: CGRect(x: 20, y: 27, width: 40, height: 23),
            .topRight: CGRect(x: 20, y: 27, width: 45, height: 23),
            .right: CGRect(x: 20, y: 20, width: 45, height: 30),
            .bottomRight: CGRect(x: 20, y: 20, width: 45, height: 37),
            .bottom: CGRect(x: 20, y: 20, width: 40, height: 37),
            .bottomLeft: CGRect(x: 25, y: 20, width: 35, height: 37),
            .left: CGRect(x: 25, y: 20, width: 35, height: 30),
        ]

        for handle in ResizeHandle.allCases {
            let resized = selection.resized(
                from: original,
                handle: handle,
                translation: translation,
                minimumSize: CGSize(width: 8, height: 8)
            )
            #expect(resized.rect == expected[handle])
        }
    }

    @Test("Resize honors minimum size, direct control points, and bounds")
    func constrainedResize() {
        let selection = SelectionGeometry(
            rect: CGRect(x: 20, y: 20, width: 40, height: 30),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 80)
        )

        let minimum = selection.resized(
            handle: .topLeft,
            translation: CGSize(width: 100, height: 100),
            minimumSize: CGSize(width: 12, height: 10)
        )
        #expect(minimum.rect == CGRect(x: 48, y: 40, width: 12, height: 10))

        let bounded = selection.resized(
            handle: .bottomRight,
            to: CGPoint(x: 200, y: 200)
        )
        #expect(bounded.rect == CGRect(x: 20, y: 20, width: 80, height: 60))
    }

    @Test("Toolbar prefers below then flips above and remains on-screen")
    func toolbarPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 500, height: 300)
        let size = CGSize(width: 180, height: 42)
        let upperSelection = CGRect(x: 100, y: 30, width: 200, height: 80)
        let lowerSelection = CGRect(x: 430, y: 240, width: 60, height: 50)

        #expect(
            ToolbarPlacement.preferred(
                selection: upperSelection,
                toolbarSize: size,
                screen: screen
            ) == .below
        )
        #expect(
            ToolbarPlacement.place(
                selection: upperSelection,
                toolbarSize: size,
                screen: screen
            ) == CGRect(x: 120, y: 118, width: 180, height: 42)
        )
        #expect(
            ToolbarPlacement.preferred(
                selection: lowerSelection,
                toolbarSize: size,
                screen: screen
            ) == .above
        )
        #expect(
            ToolbarPlacement.place(
                selection: lowerSelection,
                toolbarSize: size,
                screen: screen
            ) == CGRect(x: 310, y: 190, width: 180, height: 42)
        )
    }
}
