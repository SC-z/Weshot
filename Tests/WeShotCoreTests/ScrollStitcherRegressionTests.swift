import CoreGraphics
import Foundation
import Testing
@testable import WeShotCore

@Suite("Scroll stitcher regressions")
struct ScrollStitcherRegressionTests {
    @Test("Identical solid frames report no new content")
    func identicalSolidFramesReportNoNewContent() {
        let frame = makeImage(width: 9, height: 12) { _, _ in
            (red: 42, green: 99, blue: 173)
        }

        expectNoNewContent(for: frame)
    }

    @Test("Identical periodic frames report no new content")
    func identicalPeriodicFramesReportNoNewContent() {
        let frame = makeImage(width: 9, height: 12) { x, y in
            let phase = y % 3
            return (
                red: UInt8(phase * 80 + x),
                green: UInt8(phase * 40 + x * 2),
                blue: UInt8(phase * 20 + x * 3)
            )
        }

        expectNoNewContent(for: frame)
    }

    @Test("An unsampled changed column cannot masquerade as full overlap")
    func changedUnsampledColumnIsVerifiedAcrossAllPixels() {
        let width = 9
        let height = 12
        let previous = makePatternImage(width: width, height: height)
        let next = makeImage(width: width, height: height) { x, y in
            if x == width / 2 {
                return (red: 255, green: 255, blue: 255)
            }
            return patternPixel(x: x, y: y)
        }
        let stitcher = ScrollStitcher(
            configuration: .init(
                minimumOverlapPixels: 3,
                maximumOverlapFraction: 1,
                maximumMeanAbsoluteError: 1,
                sampledRowsPerCandidate: height,
                sampledColumns: 2
            )
        )

        expectOverlapNotFound(for: [previous, next], using: stitcher)
    }

    @Test("An unsampled changed row cannot masquerade as full overlap")
    func changedUnsampledRowIsVerifiedAcrossAllPixels() {
        let width = 9
        let height = 12
        let previous = makePatternImage(width: width, height: height)
        let next = makeImage(width: width, height: height) { x, y in
            if y == height / 2 {
                return (red: 255, green: 255, blue: 255)
            }
            return patternPixel(x: x, y: y)
        }
        let stitcher = ScrollStitcher(
            configuration: .init(
                minimumOverlapPixels: 3,
                maximumOverlapFraction: 1,
                maximumMeanAbsoluteError: 1,
                sampledRowsPerCandidate: 2,
                sampledColumns: width
            )
        )

        expectOverlapNotFound(for: [previous, next], using: stitcher)
    }

    @Test("Default tolerance accepts a fixed browser toolbar")
    func defaultToleranceAcceptsFixedBrowserToolbar() throws {
        let width = 32
        let height = 120
        let toolbarHeight = 20
        let scrollDistance = 30
        let frame = { (offset: Int) in
            makeImage(width: width, height: height) { x, y in
                y < toolbarHeight
                    ? (red: 255, green: 255, blue: 255)
                    : self.patternPixel(x: x, y: y - toolbarHeight + offset)
            }
        }

        let result = try ScrollStitcher().stitch([frame(0), frame(scrollDistance)])

        #expect(result.overlaps.map(\.pixels) == [height - scrollDistance])
        #expect(result.overlaps[0].meanAbsoluteError <= 8)
        #expect(result.image.height == height + scrollDistance)
    }

    private func expectNoNewContent(for frame: CGImage) {
        let stitcher = ScrollStitcher(
            configuration: .init(
                minimumOverlapPixels: 3,
                maximumOverlapFraction: 1,
                maximumMeanAbsoluteError: 0,
                sampledRowsPerCandidate: 4,
                sampledColumns: 4
            )
        )

        do {
            _ = try stitcher.stitch([frame, frame])
            Issue.record("Expected noNewContent, but stitching succeeded.")
        } catch {
            #expect(error as? ScrollStitcherError == .noNewContent(frameIndex: 1))
        }
    }

    private func expectOverlapNotFound(
        for frames: [CGImage],
        using stitcher: ScrollStitcher
    ) {
        do {
            _ = try stitcher.stitch(frames)
            Issue.record("Expected overlapNotFound, but stitching succeeded.")
        } catch {
            guard case let .overlapNotFound(frameIndex, bestError, allowedError) =
                error as? ScrollStitcherError
            else {
                Issue.record("Expected overlapNotFound, got \(error).")
                return
            }
            #expect(frameIndex == 1)
            #expect(bestError > allowedError)
            #expect(allowedError == 1)
        }
    }

    private func makePatternImage(width: Int, height: Int) -> CGImage {
        makeImage(width: width, height: height, pixel: patternPixel)
    }

    private func patternPixel(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        (
            red: UInt8((y * 11 + x) & 0xff),
            green: UInt8((y * 13 + x * 2) & 0xff),
            blue: UInt8((y * 17 + x * 3) & 0xff)
        )
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (red: UInt8, green: UInt8, blue: UInt8)
    ) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let color = pixel(x, y)
                let offset = (y * width + x) * 4
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
            }
        }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ).union(.byteOrder32Big)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
