import CoreGraphics
import Foundation
import Testing
@testable import WeShotCore

@Suite("Scroll stitcher regressions")
struct ScrollStitcherRegressionTests {
    @Test("Unrelated sparse text cannot match through its white background")
    func unrelatedSparseTextIsRejected() {
        let previous = makeImage(width: 600, height: 400) { x, y in
            let value: UInt8 = (20 ..< 80).contains(x) && (10 ..< 15).contains(y % 50) ? 0 : 255
            return (value, value, value)
        }
        let next = makeImage(width: 600, height: 400) { x, y in
            let value: UInt8 = (200 ..< 260).contains(x) && (10 ..< 15).contains(y % 43) ? 0 : 255
            return (value, value, value)
        }

        do {
            _ = try ScrollStitcher().stitch([previous, next])
            Issue.record("Unrelated text was accepted as an overlap.")
        } catch {
            guard case .overlapNotFound = error as? ScrollStitcherError else {
                Issue.record("Expected rejected alignment, got \(error).")
                return
            }
        }
    }

    @Test("Sparse text retains the correct overlap and every output pixel")
    func sparseTextScrollReconstructsPixels() throws {
        let width = 300
        let height = 200
        let distance = 47
        let pixel = { (x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) in
            let line = y / 19
            let value: UInt8 = y % 19 < 3 && (10 ..< 30 + line * 7 % 110).contains(x) ? 0 : 255
            return (value, value, value)
        }
        let previous = makeImage(width: width, height: height, pixel: pixel)
        let next = makeImage(width: width, height: height) { x, y in pixel(x, y + distance) }
        let expected = makeImage(width: width, height: height + distance, pixel: pixel)

        let result = try ScrollStitcher().stitch([previous, next])

        #expect(result.overlaps.map(\.pixels) == [height - distance])
        #expect((result.image.dataProvider!.data! as Data) == (expected.dataProvider!.data! as Data))
    }

    @Test("Fixed page edges appear only once across an incremental seam")
    func fixedFooterIsRemovedFromTheMiddleOfTheImage() throws {
        let width = 64
        let height = 240
        let distance = 30
        let header = 20
        let footer = 8
        let pixel = { (x: Int, y: Int, offset: Int) -> (red: UInt8, green: UInt8, blue: UInt8) in
            y < header || y >= height - footer
                ? (255, 255, 255)
                : self.patternPixel(x: x, y: y - header + offset)
        }
        let first = makeImage(width: width, height: height) { x, y in pixel(x, y, 0) }
        let second = makeImage(width: width, height: height) { x, y in pixel(x, y, distance) }
        let third = makeImage(width: width, height: height) { x, y in pixel(x, y, distance * 2) }
        let expected = makeImage(width: width, height: height + distance * 2) { x, y in
            y < header || y >= height + distance * 2 - footer
                ? (255, 255, 255)
                : self.patternPixel(x: x, y: y - header)
        }
        let stitcher = ScrollStitcher()
        let pair = try stitcher.stitch([first, second])
        let incremental = try stitcher.append(third, to: pair.image, previous: second)
        let batch = try stitcher.stitch([first, second, third])

        #expect(batch.overlaps.map(\.pixels) == [height - distance, height - distance])
        #expect(incremental.overlaps.map(\.pixels) == [height - distance])
        #expect((batch.image.dataProvider!.data! as Data) == (expected.dataProvider!.data! as Data))
        #expect((incremental.image.dataProvider!.data! as Data) == (expected.dataProvider!.data! as Data))
    }

    @Test("Scrolling upward cannot append unrelated rows")
    func upwardScrollIsRejected() {
        let previous = makeImage(width: 60, height: 160) { x, y in
            patternPixel(x: x, y: y + 35)
        }
        let next = makePatternImage(width: 60, height: 160)

        do {
            _ = try ScrollStitcher().stitch([previous, next])
            Issue.record("An upward scroll was appended as downward content.")
        } catch {
            guard case .overlapNotFound = error as? ScrollStitcherError else {
                Issue.record("Expected rejected upward alignment, got \(error).")
                return
            }
        }
    }

    @Test("A stationary page with a small brightness change adds no rows")
    func stationaryPageWithSmallChangeAddsNoRows() {
        let previous = makePatternImage(width: 60, height: 160)
        let next = makeImage(width: 60, height: 160) { x, y in
            let color = patternPixel(x: x, y: y)
            return (color.red == 255 ? 254 : color.red + 1,
                    color.green == 255 ? 254 : color.green + 1,
                    color.blue == 255 ? 254 : color.blue + 1)
        }

        do {
            _ = try ScrollStitcher().stitch([previous, next])
            Issue.record("A stationary page added rows.")
        } catch {
            #expect(error as? ScrollStitcherError == .noNewContent(frameIndex: 1))
        }
    }

    @Test("Small pixel noise preserves a genuine scroll displacement")
    func noisyScrollRetainsCorrectOverlap() throws {
        let width = 60
        let height = 160
        let distance = 35
        let previous = makePatternImage(width: width, height: height)
        let next = makeImage(width: width, height: height) { x, y in
            let color = patternPixel(x: x, y: y + distance)
            let noise = (x + y) % 3 - 1
            func noisy(_ value: UInt8) -> UInt8 { UInt8(clamping: Int(value) + noise) }
            return (noisy(color.red), noisy(color.green), noisy(color.blue))
        }

        let result = try ScrollStitcher().stitch([previous, next])

        #expect(result.overlaps.map(\.pixels) == [height - distance])
        #expect(result.image.height == height + distance)
    }

    @Test("Incremental alignment rejects a stationary viewport after the image grows")
    func incrementalStationaryViewportAddsNoRows() throws {
        let width = 60
        let height = 160
        let previous = makePatternImage(width: width, height: height)
        let next = makeImage(width: width, height: height) { x, y in patternPixel(x: x, y: y + 35) }
        let changed = makeImage(width: width, height: height) { x, y in
            let color = patternPixel(x: x, y: y + 35)
            func changed(_ value: UInt8) -> UInt8 { value == 255 ? 254 : value + 1 }
            return (changed(color.red), changed(color.green), changed(color.blue))
        }
        let stitcher = ScrollStitcher()
        let pair = try stitcher.stitch([previous, next])

        do {
            _ = try stitcher.append(changed, to: pair.image, previous: next)
            Issue.record("A stationary viewport added rows after the image grew.")
        } catch {
            #expect(error as? ScrollStitcherError == .noNewContent(frameIndex: 1))
        }
    }

    @Test("A one-level pixel change cannot choose between repeated rows")
    func noisyPeriodicContentIsAmbiguous() {
        let previous = makeImage(width: 40, height: 160) { x, y in
            patternPixel(x: x, y: y % 13)
        }
        let next = makeImage(width: 40, height: 160) { x, y in
            let color = patternPixel(x: x, y: (y + 35) % 13)
            let noise = y.isMultiple(of: 3) ? 1 : 0
            func noisy(_ value: UInt8) -> UInt8 { UInt8(clamping: Int(value) + noise) }
            return (noisy(color.red), noisy(color.green), noisy(color.blue))
        }

        do {
            _ = try ScrollStitcher().stitch([previous, next])
            Issue.record("Noise selected an arbitrary repeated row.")
        } catch {
            guard case .ambiguousOverlap = error as? ScrollStitcherError else {
                Issue.record("Expected ambiguous repeated content, got \(error).")
                return
            }
        }
    }

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
