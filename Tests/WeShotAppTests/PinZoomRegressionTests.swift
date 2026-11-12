import AppKit
import Testing
@testable import WeShotApp

@Suite("Pinned image zoom geometry")
@MainActor
struct PinZoomRegressionTests {
    @Test("Shrinking an oversized pin preserves the point under the pointer")
    func oversizedPinStaysVisible() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 20, y: 20, width: 200, height: 5400)
        let pointer = CGPoint(x: 100, y: 100)

        let result = PinImageView.scaledFrame(frame, scale: 0.3, anchor: pointer)

        #expect(result.intersects(screen))
        #expect(result.contains(pointer))
        #expect(abs((pointer.x - result.minX) / result.width - (pointer.x - frame.minX) / frame.width) < 0.000_001)
        #expect(abs((pointer.y - result.minY) / result.height - (pointer.y - frame.minY) / frame.height) < 0.000_001)
    }

    @Test("Zoom keeps the image ratio and pointer position on a secondary display")
    func zoomOnSecondaryDisplay() {
        let frame = CGRect(x: -1200, y: -500, width: 600, height: 400)
        let pointer = CGPoint(x: -1100, y: -450)

        for scale in [CGFloat(0.5), 1, 2] {
            let result = PinImageView.scaledFrame(frame, scale: scale, anchor: pointer)
            #expect(result.size == CGSize(width: frame.width * scale, height: frame.height * scale))
            #expect(result.contains(pointer))
            #expect(abs((pointer.x - result.minX) / result.width - (pointer.x - frame.minX) / frame.width) < 0.000_001)
            #expect(abs((pointer.y - result.minY) / result.height - (pointer.y - frame.minY) / frame.height) < 0.000_001)
        }
    }
}
