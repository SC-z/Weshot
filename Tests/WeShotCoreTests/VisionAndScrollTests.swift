import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import WeShotCore

@Suite("Vision privacy detection and scroll stitching")
struct VisionAndScrollTests {
    @Test
    func testSensitiveTextRegexIsDeterministicAndRejectsDates() {
        let text = "联系 13800138000 或 +86 139-0013-8000；邮箱 alice.zhang+shot@example.com；日期 2026-07-15。"

        let first = PrivacyRedactor.sensitiveTextMatches(in: text)
        let second = PrivacyRedactor.sensitiveTextMatches(in: text)

        #expect(first == second)
        #expect(first.filter { $0.kind == .phoneNumber }.count == 2)
        #expect(first.filter { $0.kind == .emailAddress }.map(\.value) == [
            "alice.zhang+shot@example.com",
        ])
        #expect(PrivacyRedactor.sensitiveTextMatches(in: "张三").contains { $0.kind == .personName })
        #expect(first.contains { $0.value == "13800138000" })
        #expect(first.contains { $0.value == "+86 139-0013-8000" })
        #expect(!first.contains { $0.value.contains("2026-07-15") })

        for match in first {
            #expect((text as NSString).substring(with: match.utf16Range) == match.value)
        }
    }

    @Test
    func testSensitiveTextRulesRejectObviousFalsePositivesAndFindLabelledNames() {
        let names = PrivacyRedactor.sensitiveTextMatches(
            in: "姓名：欧阳娜娜；联系人张三电话；文件 关闭 高温"
        )
        .filter { $0.kind == .personName }
        .map(\.value)
        #expect(names == ["欧阳娜娜", "张三"])
        #expect(
            PrivacyRedactor.sensitiveTextMatches(in: "欧阳娜娜")
                .filter { $0.kind == .personName }
                .map(\.value) == ["欧阳娜娜"]
        )

        let emails = PrivacyRedactor.sensitiveTextMatches(
            in: ".alice@example.com alice@example..com alice@-example.com valid.user+tag@example.co.uk"
        )
        .filter { $0.kind == .emailAddress }
        .map(\.value)
        #expect(emails == ["valid.user+tag@example.co.uk"])

        let mixedPhoneText =
            "13800138000@example.com 202607151234 1234-5678-9012 +1 (415) 555-2671 13800138000"
        let mixedMatches = PrivacyRedactor.sensitiveTextMatches(in: mixedPhoneText)
        let phones = mixedMatches.filter { $0.kind == .phoneNumber }.map(\.value)
        let mixedEmails = mixedMatches.filter { $0.kind == .emailAddress }.map(\.value)
        #expect(mixedEmails == ["13800138000@example.com"])
        #expect(phones == ["+1 (415) 555-2671", "13800138000"])
    }

    @Test
    func testVisionConfigurationNormalizesNonFinitePaddingAndTextHeight() {
        let ocr = OCRService.Configuration(minimumTextHeight: .nan)
        let privacy = PrivacyRedactor.Configuration(
            facePaddingFraction: .nan,
            textPaddingPixels: .nan
        )
        let infiniteOCR = OCRService.Configuration(minimumTextHeight: .infinity)
        let infinitePrivacy = PrivacyRedactor.Configuration(
            facePaddingFraction: .infinity,
            textPaddingPixels: .infinity
        )
        let clampedOCR = OCRService.Configuration(minimumTextHeight: 2)

        #expect(ocr.minimumTextHeight == 0)
        #expect(privacy.facePaddingFraction == 0)
        #expect(privacy.textPaddingPixels == 0)
        #expect(infiniteOCR.minimumTextHeight == 0)
        #expect(infinitePrivacy.facePaddingFraction == 0)
        #expect(infinitePrivacy.textPaddingPixels == 0)
        #expect(clampedOCR.minimumTextHeight == 1)
    }

    @Test
    func testScrollStitcherFindsOverlapAndReconstructsPixels() throws {
        let width = 47
        let frameHeight = 60
        let frameOffsets = [0, 35, 70]
        let frames = frameOffsets.map {
            makePatternImage(width: width, height: frameHeight, globalYOffset: $0)
        }
        let stitcher = ScrollStitcher(
            configuration: .init(
                minimumOverlapPixels: 8,
                maximumOverlapFraction: 0.8,
                maximumMeanAbsoluteError: 0.1,
                sampledRowsPerCandidate: 60,
                sampledColumns: width
            )
        )

        let result = try stitcher.stitch(frames)
        let expected = makePatternImage(width: width, height: 130, globalYOffset: 0)

        #expect(result.overlaps.map(\.pixels) == [25, 25])
        #expect(result.overlaps.map(\.meanAbsoluteError) == [0, 0])
        #expect(result.image.width == width)
        #expect(result.image.height == 130)
        #expect(try rgbaPixels(of: result.image) == rgbaPixels(of: expected))
    }

    @Test
    func testScrollStitcherReportsWidthMismatch() {
        let frames = [
            makePatternImage(width: 20, height: 30, globalYOffset: 0),
            makePatternImage(width: 21, height: 30, globalYOffset: 10),
        ]

        do {
            _ = try ScrollStitcher().stitch(frames)
            Issue.record("预期宽度不一致错误，但拼接成功。")
        } catch {
            #expect(
                error as? ScrollStitcherError
                    == .widthMismatch(frameIndex: 1, expected: 20, actual: 21)
            )
        }
    }

    @Test
    func testScrollStitcherReportsMissingOverlap() {
        let first = makeSolidImage(width: 24, height: 30, red: 0, green: 0, blue: 0)
        let second = makeSolidImage(width: 24, height: 30, red: 255, green: 255, blue: 255)
        let stitcher = ScrollStitcher(
            configuration: .init(
                minimumOverlapPixels: 5,
                maximumOverlapFraction: 0.8,
                maximumMeanAbsoluteError: 1
            )
        )

        do {
            _ = try stitcher.stitch([first, second])
            Issue.record("预期明确的重叠错误，但拼接成功。")
        } catch {
            guard case let ScrollStitcherError.overlapNotFound(index, bestError, allowedError)? =
                error as? ScrollStitcherError
            else {
                Issue.record("预期明确的重叠错误，实际为 \(error)")
                return
            }
            #expect(index == 1)
            #expect(bestError == 255)
            #expect(allowedError == 1)
        }
    }

    @Test
    func testScrollStitcherReportsEmptyAndDuplicateFrames() {
        do {
            _ = try ScrollStitcher().stitch([])
            Issue.record("预期空帧错误，但拼接成功。")
        } catch {
            #expect(error as? ScrollStitcherError == .emptyFrames)
        }

        let frame = makePatternImage(width: 28, height: 36, globalYOffset: 0)
        let stitcher = ScrollStitcher(
            configuration: .init(
                minimumOverlapPixels: 6,
                maximumMeanAbsoluteError: 0.1,
                sampledRowsPerCandidate: 36,
                sampledColumns: 28
            )
        )
        do {
            _ = try stitcher.stitch([frame, frame])
            Issue.record("预期重复帧错误，但拼接成功。")
        } catch {
            #expect(error as? ScrollStitcherError == .noNewContent(frameIndex: 1))
        }
    }

    @Test
    func testOCRRecognizesProgrammaticallyRenderedBilingualImage() async {
        let image = makeTextImage()
        let service = OCRService()

        #expect(service.configuration.recognitionLanguages == ["zh-Hans", "en-US"])
        let observations: [OCRTextObservation]
        do {
            observations = try await service.recognize(in: image)
        } catch {
            // Vision services can fail their first lazy startup under test runners.
            // Retry once, but never skip the bilingual quality assertions below.
            await Task.yield()
            do {
                observations = try await service.recognize(in: image)
            } catch {
                Issue.record("Vision OCR 连续两次启动失败：\(error)")
                return
            }
        }
        let compactText = observations
            .map(\.text)
            .joined(separator: " ")
            .uppercased()
            .filter { !$0.isWhitespace }

        #expect(compactText.contains("WESHOT"), "未识别英文 WESHOT：\(observations.map(\.text))")
        #expect(
            compactText.contains("本地") || compactText.contains("截图"),
            "未识别中文‘本地’或‘截图’：\(observations.map(\.text))"
        )
        #expect(observations.allSatisfy { $0.boundingBox.width > 0 && $0.boundingBox.height > 0 })
    }

    private func makePatternImage(width: Int, height: Int, globalYOffset: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            let globalY = y + globalYOffset
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 37 + globalY * 17 + globalY * globalY * 3) & 0xff)
                pixels[offset + 1] = UInt8((x * 11 + globalY * 43 + x * globalY * 5) & 0xff)
                pixels[offset + 2] = UInt8((x * 71 + globalY * 29 + globalY * globalY) & 0xff)
                pixels[offset + 3] = 255
            }
        }
        return makeImage(width: width, height: height, pixels: pixels)
    }

    private func makeSolidImage(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = red
            pixels[offset + 1] = green
            pixels[offset + 2] = blue
        }
        return makeImage(width: width, height: height, pixels: pixels)
    }

    private func makeImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage {
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

    private func rgbaPixels(of image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ).union(.byteOrder32Big)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        if !rendered {
            throw NSError(domain: "VisionAndScrollTests", code: 1)
        }
        return pixels
    }

    private func makeTextImage() -> CGImage {
        let width = 720
        let height = 240
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ).union(.byteOrder32Big)
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = .identity

        drawText(
            "WESHOT OCR 2026",
            fontName: "Helvetica-Bold" as CFString,
            fontSize: 58,
            at: CGPoint(x: 28, y: 142),
            in: context
        )
        drawText(
            "本地截图测试",
            fontName: "PingFangSC-Semibold" as CFString,
            fontSize: 52,
            at: CGPoint(x: 28, y: 48),
            in: context
        )
        return context.makeImage()!
    }

    private func drawText(
        _ text: String,
        fontName: CFString,
        fontSize: CGFloat,
        at point: CGPoint,
        in context: CGContext
    ) {
        let font = CTFontCreateWithName(fontName, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
