import CoreGraphics
import Foundation
import NaturalLanguage
import Vision

public enum RedactionRegionKind: String, Equatable, Sendable, CaseIterable {
    case face
    case phoneNumber
    case emailAddress
    case personName
}

/// A region recommended for pixelation or blur.
///
/// `rect` is expressed in source-image pixels with a top-left origin, so the
/// type can be consumed directly by an image renderer without Annotation models.
public struct RedactionRegion: Equatable, Sendable {
    public let kind: RedactionRegionKind
    public let rect: CGRect
    public let confidence: Float

    public init(kind: RedactionRegionKind, rect: CGRect, confidence: Float) {
        self.kind = kind
        self.rect = rect
        self.confidence = confidence
    }
}

/// A deterministic regular-expression match, exposed separately from Vision so
/// callers and tests can inspect the privacy rules without running OCR.
public struct SensitiveTextMatch: Equatable, Sendable {
    public let kind: RedactionRegionKind
    public let value: String
    public let utf16Range: NSRange

    public init(kind: RedactionRegionKind, value: String, utf16Range: NSRange) {
        self.kind = kind
        self.value = value
        self.utf16Range = utf16Range
    }
}

public enum PrivacyRedactorError: Error, Equatable, LocalizedError, Sendable {
    case detectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .detectionFailed(message):
            return "隐私信息检测失败：\(message)"
        }
    }
}

/// Detects faces, names, mobile phone numbers, and email addresses entirely on-device.
public final class PrivacyRedactor: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var recognitionLanguages: [String]
        public var recognitionAccuracy: OCRRecognitionAccuracy
        /// Extra space around a face, expressed as a fraction of its width/height.
        public var facePaddingFraction: CGFloat
        /// Extra space around recognized sensitive text, in image pixels.
        public var textPaddingPixels: CGFloat

        public init(
            recognitionLanguages: [String] = ["zh-Hans", "en-US"],
            recognitionAccuracy: OCRRecognitionAccuracy = .accurate,
            facePaddingFraction: CGFloat = 0.08,
            textPaddingPixels: CGFloat = 2
        ) {
            self.recognitionLanguages = recognitionLanguages
            self.recognitionAccuracy = recognitionAccuracy
            self.facePaddingFraction = facePaddingFraction.isFinite
                ? max(facePaddingFraction, 0)
                : 0
            self.textPaddingPixels = textPaddingPixels.isFinite
                ? max(textPaddingPixels, 0)
                : 0
        }
    }

    public let configuration: Configuration
    private let workQueue = DispatchQueue(
        label: "com.weshot.privacy-redactor",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static let emailExpression = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}._%+\-])[A-Z0-9_%+\-]+(?:\.[A-Z0-9_%+\-]+)*@(?:[A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?\.)+[A-Z]{2,63}(?![\p{L}\p{N}._%+\-])"#
    )
    private static let chineseMobileExpression = try! NSRegularExpression(
        pattern: #"(?<!\d)(?:(?:(?:\+|00)?86)[\s\-]?)?1[3-9]\d(?:[\s\-]?\d){8}(?!\d)"#
    )
    private static let internationalPhoneExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\d])(?:\+\d{1,3}[\s.\-]?)?(?:\(?\d{2,4}\)?[\s.\-]?){2,3}\d{3,4}(?![\p{L}\d])"#
    )
    private static let chineseNameExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{Han}])[赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳唐罗薛伍余米贝姚孟顾尹江钟徐邱骆高夏蔡田樊胡凌霍虞万支柯管卢莫经房裘缪干解应宗丁宣贲邓郁单杭洪包诸左石崔吉龚程嵇邢裴陆荣翁荀羊甄家封芮储靳汲邴糜松井段富巫乌焦巴弓牧隗山谷车侯宓蓬全郗班仰秋仲伊宫宁仇栾暴甘钭厉戎祖武符刘景詹束龙叶幸司黎乔苍双闻莘党翟谭贡劳逄姬申扶堵冉宰郦雍却璩桑桂濮牛寿通边扈燕冀浦尚农温别庄晏柴瞿阎充慕连茹习艾鱼容向古易慎戈廖庾终暨居衡步都耿满弘匡国文寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷訾辛阚那简饶空曾毋沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公][\p{Han}]{1,2}(?![\p{Han}])"#
    )
    private static let chineseCompoundNameExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{Han}])(?:欧阳|司马|上官|诸葛|东方|皇甫|尉迟|公孙|慕容|司徒|司空|夏侯|令狐|宇文|长孙|端木|独孤|南宫)[\p{Han}]{1,2}(?![\p{Han}])"#
    )
    private static let labelledChineseNameExpression = try! NSRegularExpression(
        pattern: #"(?:姓名|联系人|收件人|昵称|名字)\s*[:：]?\s*([\p{Han}]{2,4}?)(?=\s|[，,;；。]|电话|手机|邮箱|地址|账号|号码|$)"#
    )
    private static let nonNameChineseTokens: Set<String> = [
        "文件", "关闭", "高温", "打开", "保存", "取消", "完成", "确认",
        "设置", "系统", "用户", "登录", "退出", "消息", "图片", "视频",
        "语音", "时间", "日期", "今天", "昨天", "电话", "手机", "邮箱",
    ]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Runs the phone/email regular expressions without Vision.
    public static func sensitiveTextMatches(in text: String) -> [SensitiveTextMatch] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [SensitiveTextMatch] = []

        for result in emailExpression.matches(in: text, range: fullRange) {
            guard let range = Range(result.range, in: text) else { continue }
            matches.append(
                SensitiveTextMatch(
                    kind: .emailAddress,
                    value: String(text[range]),
                    utf16Range: result.range
                )
            )
        }

        for (expression, acceptsUnformattedNumber) in [
            (chineseMobileExpression, true),
            (internationalPhoneExpression, false),
        ] {
            for result in expression.matches(in: text, range: fullRange) {
                guard let range = Range(result.range, in: text) else { continue }
                let value = String(text[range])
                let digitCount = value.unicodeScalars.reduce(into: 0) { count, scalar in
                    if CharacterSet.decimalDigits.contains(scalar) {
                        count += 1
                    }
                }
                // Reject dates and short identifiers while retaining common domestic
                // and international phone formatting.
                guard (10 ... 15).contains(digitCount) else { continue }
                guard Self.isPlausiblePhone(
                    value,
                    acceptsUnformattedNumber: acceptsUnformattedNumber
                ) else { continue }

                let candidate = SensitiveTextMatch(
                    kind: .phoneNumber,
                    value: value,
                    utf16Range: result.range
                )
                let overlapsExistingSensitiveToken = matches.contains {
                    ($0.kind == .phoneNumber || $0.kind == .emailAddress)
                        && NSIntersectionRange($0.utf16Range, result.range).length > 0
                }
                if !overlapsExistingSensitiveToken {
                    matches.append(candidate)
                }
            }
        }

        for expression in [chineseNameExpression, chineseCompoundNameExpression] {
            for result in expression.matches(in: text, range: fullRange) {
                Self.appendPersonName(range: result.range, in: text, to: &matches)
            }
        }

        for result in labelledChineseNameExpression.matches(in: text, range: fullRange) {
            let nameRange = result.range(at: 1)
            guard nameRange.location != NSNotFound,
                  let range = Range(nameRange, in: text),
                  Self.isStructurallyValidChineseName(String(text[range]))
            else { continue }
            Self.appendPersonName(range: nameRange, in: text, to: &matches)
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex ..< text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard tag == .personalName else { return true }
            let utf16Range = NSRange(range, in: text)
            Self.appendPersonName(range: utf16Range, in: text, to: &matches)
            return true
        }

        return matches.sorted { lhs, rhs in
            if lhs.utf16Range.location != rhs.utf16Range.location {
                return lhs.utf16Range.location < rhs.utf16Range.location
            }
            if lhs.utf16Range.length != rhs.utf16Range.length {
                return lhs.utf16Range.length > rhs.utf16Range.length
            }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private static func isPlausiblePhone(
        _ value: String,
        acceptsUnformattedNumber: Bool
    ) -> Bool {
        if acceptsUnformattedNumber { return true }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasInternationalPrefix = trimmed.hasPrefix("+")
        let formattingCharacters = CharacterSet(charactersIn: " -().")
        let hasFormatting = value.unicodeScalars.contains {
            formattingCharacters.contains($0)
        }
        guard hasInternationalPrefix || hasFormatting else { return false }

        // Three or more groups of four digits are substantially more likely to
        // be a card/order identifier than a telephone number.
        let digitGroups = value.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
        if digitGroups.count >= 3, digitGroups.allSatisfy({ $0.count == 4 }) {
            return false
        }
        return true
    }

    private static func isStructurallyValidChineseName(_ value: String) -> Bool {
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        return [chineseNameExpression, chineseCompoundNameExpression].contains { expression in
            expression.firstMatch(in: value, range: range)?.range == range
        }
    }

    private static func appendPersonName(
        range: NSRange,
        in text: String,
        to matches: inout [SensitiveTextMatch]
    ) {
        guard range.location != NSNotFound,
              let stringRange = Range(range, in: text)
        else { return }
        let value = String(text[stringRange])
        guard !nonNameChineseTokens.contains(value) else { return }

        // Prefer the already validated structured token when a statistical name
        // tagger labels part of an email address or phone number as a person.
        let overlaps = matches.contains {
            NSIntersectionRange($0.utf16Range, range).length > 0
        }
        guard !overlaps else { return }
        matches.append(
            SensitiveTextMatch(kind: .personName, value: value, utf16Range: range)
        )
    }

    /// Runs face detection and OCR-based sensitive-text detection concurrently in
    /// one local Vision request handler.
    public func detect(in image: CGImage) async throws -> [RedactionRegion] {
        let configuration = configuration

        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                let faceRequest = VNDetectFaceRectanglesRequest()
                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = configuration.recognitionAccuracy.visionRecognitionLevel
                textRequest.recognitionLanguages = configuration.recognitionLanguages
                textRequest.usesLanguageCorrection = true

                do {
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([faceRequest, textRequest])

                    let imageSize = CGSize(width: image.width, height: image.height)
                    let imageBounds = CGRect(origin: .zero, size: imageSize)
                    var regions: [RedactionRegion] = []

                    for face in faceRequest.results ?? [] {
                        let padded = face.boundingBox.insetBy(
                            dx: -face.boundingBox.width * configuration.facePaddingFraction,
                            dy: -face.boundingBox.height * configuration.facePaddingFraction
                        )
                        let rect = Self.pixelRect(fromVisionRect: padded, imageSize: imageSize)
                            .intersection(imageBounds)
                        guard !rect.isNull, !rect.isEmpty else { continue }
                        regions.append(
                            RedactionRegion(kind: .face, rect: rect, confidence: face.confidence)
                        )
                    }

                    for observation in textRequest.results ?? [] {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let matches = Self.sensitiveTextMatches(in: candidate.string)

                        for match in matches {
                            var visionRect = observation.boundingBox
                            if let stringRange = Range(match.utf16Range, in: candidate.string) {
                                let preciseBox: VNRectangleObservation?
                                do {
                                    preciseBox = try candidate.boundingBox(for: stringRange)
                                } catch {
                                    preciseBox = nil
                                }
                                if let preciseBox {
                                    visionRect = preciseBox.boundingBox
                                }
                            }

                            let pixelRect = Self.pixelRect(
                                fromVisionRect: visionRect,
                                imageSize: imageSize
                            )
                            .insetBy(
                                dx: -configuration.textPaddingPixels,
                                dy: -configuration.textPaddingPixels
                            )
                            .intersection(imageBounds)
                            guard !pixelRect.isNull, !pixelRect.isEmpty else { continue }

                            regions.append(
                                RedactionRegion(
                                    kind: match.kind,
                                    rect: pixelRect,
                                    confidence: candidate.confidence
                                )
                            )
                        }
                    }

                    regions.sort { lhs, rhs in
                        if abs(lhs.rect.minY - rhs.rect.minY) > 0.5 {
                            return lhs.rect.minY < rhs.rect.minY
                        }
                        if abs(lhs.rect.minX - rhs.rect.minX) > 0.5 {
                            return lhs.rect.minX < rhs.rect.minX
                        }
                        return lhs.kind.rawValue < rhs.kind.rawValue
                    }
                    continuation.resume(returning: regions)
                } catch {
                    continuation.resume(
                        throwing: PrivacyRedactorError.detectionFailed(error.localizedDescription)
                    )
                }
            }
        }
    }

    private static func pixelRect(fromVisionRect rect: CGRect, imageSize: CGSize) -> CGRect {
        let clipped = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull else { return .zero }
        return CGRect(
            x: clipped.minX * imageSize.width,
            y: (1 - clipped.maxY) * imageSize.height,
            width: clipped.width * imageSize.width,
            height: clipped.height * imageSize.height
        )
    }
}
