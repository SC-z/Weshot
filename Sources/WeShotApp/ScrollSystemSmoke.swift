import AppKit
import CoreGraphics

enum ScrollSystemSmokeFailure: LocalizedError {
    case noScreen
    case duplicateFrame(Int)
    case invalidFrameSize(expected: CGSize, actual: CGSize)
    case invalidStitchedSize

    var errorDescription: String? {
        switch self {
        case .noScreen:
            return "没有可用于真实滚动烟测的显示器"
        case .duplicateFrame(let index):
            return "滚动后第 \(index + 1) 帧没有发生变化"
        case .invalidFrameSize(let expected, let actual):
            return "框选区域应为 \(Int(expected.width))x\(Int(expected.height))，实际为 \(Int(actual.width))x\(Int(actual.height))"
        case .invalidStitchedSize:
            return "真实滚动帧的拼接尺寸无效"
        }
    }
}

struct ScrollSystemSmokeResult {
    let frameCount: Int
    let frameSize: CGSize
    let stitchedSize: CGSize
    let outputURL: URL
}

@MainActor
enum ScrollSystemSmokeRunner {
    static func run(in directory: URL) async throws -> ScrollSystemSmokeResult {
        guard let screen = NSScreen.main,
              let displayID = DesktopCaptureService.displayID(for: screen)
        else {
            throw ScrollSystemSmokeFailure.noScreen
        }

        let viewport = CGSize(width: 480, height: 240)
        let documentSize = CGSize(width: viewport.width, height: 900)
        let visibleFrame = screen.visibleFrame
        let origin = CGPoint(
            x: max(visibleFrame.minX + 12, visibleFrame.maxX - viewport.width - 12),
            y: visibleFrame.minY + 12
        )
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: viewport),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .white
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: viewport))
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let document = ScrollSmokeDocumentView(frame: CGRect(origin: .zero, size: documentSize))
        scrollView.documentView = document
        window.contentView = scrollView
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }

        let snapshot = ScreenSnapshot(
            screen: screen,
            displayID: displayID,
            image: DesktopCaptureService.fixtureImage(size: screen.frame.size, scale: 1),
            candidates: []
        )
        let localRect = DesktopCoordinateMapper.localFrame(
            fromAppKit: window.frame,
            screenFrame: screen.frame
        )
        let viewBounds = CGRect(origin: .zero, size: screen.frame.size)
        let offsets: [CGFloat] = [0, 90, 180, 270]
        var frames: [CGImage] = []
        var signatures: [Data] = []

        for (index, offset) in offsets.enumerated() {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            document.needsDisplay = true
            scrollView.needsDisplay = true
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: index == 0 ? 180_000_000 : 110_000_000)

            let frame = try await DesktopCaptureService.captureSelection(
                snapshot: snapshot,
                localRect: localRect,
                viewBounds: viewBounds
            )
            let expected = CGSize(
                width: localRect.width * screen.backingScaleFactor,
                height: localRect.height * screen.backingScaleFactor
            )
            let actual = CGSize(width: frame.width, height: frame.height)
            guard actual == expected else {
                throw ScrollSystemSmokeFailure.invalidFrameSize(expected: expected, actual: actual)
            }
            let signature = try CaptureOutputService.pngData(for: frame)
            if let previous = signatures.last, previous == signature {
                throw ScrollSystemSmokeFailure.duplicateFrame(index)
            }
            frames.append(frame)
            signatures.append(signature)
        }

        var stitched = frames[0]
        for frame in frames.dropFirst() {
            stitched = try await CoreServiceBridge.stitch(frames: [stitched, frame])
        }
        guard let first = frames.first,
              stitched.width == first.width,
              stitched.height > first.height + first.height / 2
        else {
            throw ScrollSystemSmokeFailure.invalidStitchedSize
        }

        let outputURL = directory.appendingPathComponent("scroll-workflow.png")
        _ = try CaptureOutputService.writePNG(stitched, to: outputURL)
        try CaptureOutputService.requireSize(
            CaptureOutputService.decodedSize(of: try Data(contentsOf: outputURL)),
            matches: stitched
        )

        return ScrollSystemSmokeResult(
            frameCount: frames.count,
            frameSize: CGSize(width: first.width, height: first.height),
            stitchedSize: CGSize(width: stitched.width, height: stitched.height),
            outputURL: outputURL
        )
    }
}

@MainActor
private final class ScrollSmokeDocumentView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()

        let rowHeight: CGFloat = 45
        let rowCount = Int(ceil(bounds.height / rowHeight))
        for index in 0 ..< rowCount {
            let row = CGRect(
                x: 0,
                y: CGFloat(index) * rowHeight,
                width: bounds.width,
                height: rowHeight
            )
            guard row.intersects(dirtyRect) else { continue }
            let hue = CGFloat((index * 47) % 360) / 360
            NSColor(calibratedHue: hue, saturation: 0.42, brightness: 0.94, alpha: 1).setFill()
            row.fill()

            let markerX = 18 + CGFloat((index * 61) % 390)
            NSColor.black.withAlphaComponent(0.7).setFill()
            CGRect(x: markerX, y: row.minY + 8, width: 42, height: 8).fill()
            CGRect(x: bounds.width - markerX - 22, y: row.minY + 27, width: 24, height: 6).fill()

            ("WeShot scroll row \(index)" as NSString).draw(
                at: CGPoint(x: 14, y: row.minY + 18),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.black.withAlphaComponent(0.8),
                ]
            )
        }
    }
}
