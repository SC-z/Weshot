import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import WeShotCore

@Suite("Annotation model and image renderer")
struct RendererTests {
    @Test("Color, stroke style, and document history normalize invalid input")
    func annotationDocumentHistory() {
        let color = RGBAColor(red: -1, green: 0.4, blue: 2, alpha: .nan)
        #expect(color == RGBAColor(red: 0, green: 0.4, blue: 1, alpha: 0))
        #expect(StrokeStyle(color: color, lineWidth: -4).lineWidth == 0.5)

        let document = AnnotationDocument(maximumHistoryDepth: 3)
        let first = Annotation.rectangle(
            rect: CGRect(x: 10, y: 10, width: -8, height: -6),
            color: .red,
            lineWidth: 2
        )
        let second = Annotation.pen(
            points: [CGPoint(x: 1, y: 1), CGPoint(x: 8, y: 9)],
            color: .blue,
            lineWidth: 3
        )

        document.append(first)
        document.add(second)
        #expect(document.annotations.count == 2)
        #expect(
            document.annotations.first
                == .rectangle(
                    rect: CGRect(x: 2, y: 4, width: 8, height: 6),
                    color: .red,
                    lineWidth: 2
                )
        )
        #expect(document.canUndo)
        #expect(document.undo())
        #expect(document.annotations.count == 1)
        #expect(document.canRedo)
        #expect(document.redo())
        #expect(document.annotations.count == 2)
        #expect(document.clear())
        #expect(document.annotations.isEmpty)
        #expect(document.undo())
        #expect(document.annotations.count == 2)

        document.append(.mosaic(rect: CGRect(x: 0, y: 0, width: 5, height: 5), blockSize: 4))
        #expect(!document.canRedo)
    }

    @Test("Compose crops the source with top-left pixel semantics")
    func cropAndOrientation() throws {
        let base = try #require(makeImage(width: 7, height: 6) { x, y in
            Pixel(red: UInt8(20 + x * 10), green: UInt8(30 + y * 20), blue: UInt8(x + y), alpha: 255)
        })
        let result = try #require(
            ImageRenderer.compose(
                base: base,
                selection: CGRect(x: 2, y: 1, width: 3, height: 2),
                annotations: []
            )
        )
        let output = pixels(of: result)

        #expect(result.width == 3)
        #expect(result.height == 2)
        #expect(output[0].isClose(to: Pixel(red: 40, green: 50, blue: 3, alpha: 255)))
        #expect(output[5].isClose(to: Pixel(red: 60, green: 70, blue: 6, alpha: 255)))

        let clipped = try #require(
            ImageRenderer.compose(
                base: base,
                selection: CGRect(x: -2, y: -3, width: 5, height: 5),
                annotations: []
            )
        )
        #expect(clipped.width == 3)
        #expect(clipped.height == 2)
        #expect(
            ImageRenderer.compose(
                base: base,
                selection: CGRect(x: 30, y: 30, width: 4, height: 4),
                annotations: []
            ) == nil
        )
    }

    @Test("Selection offset keeps annotations in full-image coordinates")
    func selectionOffsetAndTopLeftAnnotation() throws {
        let base = try #require(makeSolidImage(width: 30, height: 30, pixel: .black))
        let result = try #require(
            ImageRenderer.compose(
                base: base,
                selection: CGRect(x: 10, y: 8, width: 12, height: 12),
                annotations: [
                    .pen(points: [CGPoint(x: 12, y: 10)], color: .red, lineWidth: 3),
                ]
            )
        )
        let output = pixels(of: result)

        #expect(output.pixel(x: 2, y: 2, width: result.width).red > 180)
        #expect(output.pixel(x: 2, y: 9, width: result.width).red < 20)
    }

    @Test("Rectangle, ellipse, arrow, and pen all render")
    func vectorAnnotations() throws {
        let base = try #require(makeSolidImage(width: 34, height: 26, pixel: .black))
        let result = try #require(
            ImageRenderer.compose(
                base: base,
                selection: CGRect(x: 0, y: 0, width: 34, height: 26),
                annotations: [
                    .rectangle(
                        rect: CGRect(x: 2, y: 2, width: 10, height: 8),
                        color: .green,
                        lineWidth: 2
                    ),
                    .ellipse(
                        rect: CGRect(x: 17, y: 2, width: 10, height: 8),
                        color: .red,
                        lineWidth: 2
                    ),
                    .arrow(
                        start: CGPoint(x: 2, y: 17),
                        end: CGPoint(x: 13, y: 17),
                        color: .blue,
                        lineWidth: 2
                    ),
                    .pen(
                        points: [CGPoint(x: 18, y: 16), CGPoint(x: 28, y: 21)],
                        color: .yellow,
                        lineWidth: 3
                    ),
                ]
            )
        )
        let output = pixels(of: result)
        let rectanglePixel = output.pixel(x: 7, y: 2, width: result.width)
        let ellipsePixel = output.pixel(x: 22, y: 2, width: result.width)
        let arrowPixel = output.pixel(x: 12, y: 17, width: result.width)
        let penPixel = output.pixel(x: 25, y: 19, width: result.width)

        #expect(rectanglePixel.green > rectanglePixel.red + 50)
        #expect(ellipsePixel.red > ellipsePixel.green + 50)
        #expect(arrowPixel.blue > arrowPixel.red + 50)
        #expect(penPixel.red > 120 && penPixel.green > 90)
    }

    @Test("Mosaic creates blocks and leaves pixels outside its region unchanged")
    func mosaic() throws {
        let base = try #require(makeImage(width: 16, height: 16) { x, y in
            Pixel(
                red: UInt8(10 + x * 11),
                green: UInt8(10 + y * 11),
                blue: UInt8(10 + (x + y) * 5),
                alpha: 255
            )
        })
        let plain = try #require(
            ImageRenderer.compose(
                base: base,
                selection: CGRect(x: 0, y: 0, width: 16, height: 16),
                annotations: []
            )
        )
        let mosaiced = try #require(
            ImageRenderer.compose(
                base: base,
                selection: CGRect(x: 0, y: 0, width: 16, height: 16),
                annotations: [
                    .mosaic(rect: CGRect(x: 4, y: 4, width: 8, height: 8), blockSize: 4),
                ]
            )
        )
        let before = pixels(of: plain)
        let after = pixels(of: mosaiced)

        #expect(after.pixel(x: 1, y: 1, width: 16) == before.pixel(x: 1, y: 1, width: 16))
        #expect(after.pixel(x: 5, y: 5, width: 16) == after.pixel(x: 6, y: 6, width: 16))
        #expect(after.pixel(x: 5, y: 5, width: 16) != before.pixel(x: 5, y: 5, width: 16))
    }

    @Test("Mosaic replaces translucent pixels instead of compositing them twice")
    func mosaicPreservesAlpha() throws {
        // premultiplied red=64 at alpha=128 represents 50%-opaque mid red.
        let base = try #require(
            makeSolidImage(
                width: 8,
                height: 8,
                pixel: Pixel(red: 64, green: 0, blue: 0, alpha: 128)
            )
        )
        let plain = try #require(
            ImageRenderer.compose(
                base: base,
                selection: CGRect(x: 0, y: 0, width: 8, height: 8),
                annotations: []
            )
        )
        let mosaiced = try #require(
            ImageRenderer.compose(
                base: base,
                selection: CGRect(x: 0, y: 0, width: 8, height: 8),
                annotations: [
                    .mosaic(rect: CGRect(x: 0, y: 0, width: 8, height: 8), blockSize: 4),
                ]
            )
        )

        let expected = pixels(of: plain).pixel(x: 3, y: 3, width: 8)
        let actual = pixels(of: mosaiced).pixel(x: 3, y: 3, width: 8)
        #expect(expected.alpha == 128)
        #expect(actual.isClose(to: expected, tolerance: 1))
    }

    @Test("Text draws downward from its top-left origin")
    func textOrientation() throws {
        let base = try #require(makeSolidImage(width: 80, height: 42, pixel: .black))
        let result = try #require(
            ImageRenderer.compose(
                base: base,
                selection: CGRect(x: 0, y: 0, width: 80, height: 42),
                annotations: [
                    .text(origin: CGPoint(x: 3, y: 2), text: "We", color: .red, fontSize: 22),
                ]
            )
        )
        let output = pixels(of: result)
        let upperInk = countInk(output, width: result.width, rows: 0..<29)
        let lowerInk = countInk(output, width: result.width, rows: 32..<42)

        #expect(upperInk > 20)
        #expect(lowerInk == 0)
    }
}

private struct Pixel: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    static let black = Pixel(red: 0, green: 0, blue: 0, alpha: 255)

    func isClose(to other: Pixel, tolerance: Int = 3) -> Bool {
        abs(Int(red) - Int(other.red)) <= tolerance
            && abs(Int(green) - Int(other.green)) <= tolerance
            && abs(Int(blue) - Int(other.blue)) <= tolerance
            && abs(Int(alpha) - Int(other.alpha)) <= tolerance
    }
}

private extension Array where Element == Pixel {
    func pixel(x: Int, y: Int, width: Int) -> Pixel {
        self[y * width + x]
    }
}

private func makeSolidImage(width: Int, height: Int, pixel: Pixel) -> CGImage? {
    makeImage(width: width, height: height) { _, _ in pixel }
}

private func makeImage(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> Pixel
) -> CGImage? {
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value = pixel(x, y)
            bytes.append(value.red)
            bytes.append(value.green)
            bytes.append(value.blue)
            bytes.append(value.alpha)
        }
    }

    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )
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
    )
}

private func pixels(of image: CGImage) -> [Pixel] {
    let bytesPerRow = image.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
    bytes.withUnsafeMutableBytes { buffer in
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let context = CGContext(
            data: buffer.baseAddress,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        )!
        context.setBlendMode(.copy)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
    }

    return stride(from: 0, to: bytes.count, by: 4).map { index in
        Pixel(
            red: bytes[index],
            green: bytes[index + 1],
            blue: bytes[index + 2],
            alpha: bytes[index + 3]
        )
    }
}

private func countInk(_ pixels: [Pixel], width: Int, rows: Range<Int>) -> Int {
    rows.reduce(into: 0) { count, y in
        for x in 0..<width {
            let pixel = pixels.pixel(x: x, y: y, width: width)
            if pixel.red > 20 || pixel.green > 20 || pixel.blue > 20 {
                count += 1
            }
        }
    }
}
