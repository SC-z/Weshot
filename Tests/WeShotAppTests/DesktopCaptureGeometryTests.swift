import AppKit
import Testing
@testable import WeShotApp

@Suite("Display-bound selection capture")
@MainActor
struct DesktopCaptureGeometryTests {
    @Test("Selection capture flips AppKit coordinates and aligns Retina pixels")
    func selectionSourceRect() throws {
        let source = try DesktopCaptureService.selectionSourceRect(
            localRect: CGRect(x: 10.25, y: 20.25, width: 40.25, height: 30.25),
            viewBounds: CGRect(x: 0, y: 0, width: 100, height: 80),
            screenSize: CGSize(width: 200, height: 160),
            scale: 2
        )
        #expect(source == CGRect(x: 20.5, y: 59, width: 80.5, height: 60.5))
    }

    @Test("Selection capture uses local display coordinates and clips to its bounds")
    func offsetAndClippedSelection() throws {
        let bounds = CGRect(x: -100, y: 200, width: 100, height: 80)
        let source = try DesktopCaptureService.selectionSourceRect(
            localRect: CGRect(x: -90, y: 220, width: 40, height: 30),
            viewBounds: bounds,
            screenSize: CGSize(width: 200, height: 160),
            scale: 1
        )
        #expect(source == CGRect(x: 20, y: 60, width: 80, height: 60))
        let clipped = try DesktopCaptureService.selectionSourceRect(
            localRect: bounds.insetBy(dx: -10, dy: -20),
            viewBounds: bounds,
            screenSize: CGSize(width: 200, height: 160),
            scale: 2
        )
        #expect(clipped == CGRect(x: 0, y: 0, width: 200, height: 160))
    }

    @Test("Invalid capture geometry fails before requesting screen pixels")
    func invalidSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        for rect in [CGRect.zero, CGRect(x: 200, y: 0, width: 10, height: 10),
                     CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            #expect(throws: ScreenCaptureFailure.self) {
                try DesktopCaptureService.selectionSourceRect(
                    localRect: rect, viewBounds: bounds, screenSize: bounds.size, scale: 2
                )
            }
        }
        #expect(throws: ScreenCaptureFailure.self) {
            try DesktopCaptureService.selectionSourceRect(
                localRect: bounds, viewBounds: .zero, screenSize: bounds.size, scale: 2
            )
        }
    }
}
