import CoreGraphics
import Foundation
import Vision

/// The quality/speed trade-off used by local Vision text recognition.
public enum OCRRecognitionAccuracy: String, Sendable, CaseIterable {
    case fast
    case accurate

    var visionRecognitionLevel: VNRequestTextRecognitionLevel {
        switch self {
        case .fast:
            return .fast
        case .accurate:
            return .accurate
        }
    }
}

/// One line (or text run) recognized by Vision.
///
/// `boundingBox` uses Vision's normalized coordinate system: the origin is at
/// the lower-left corner and both axes are in the range `0 ... 1`.
public struct OCRTextObservation: Equatable, Sendable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }

    /// Converts the Vision rectangle to image pixels with a top-left origin.
    public func pixelRect(in imageSize: CGSize) -> CGRect {
        let unitRect = boundingBox.standardized.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard !unitRect.isNull, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        return CGRect(
            x: unitRect.minX * imageSize.width,
            y: (1 - unitRect.maxY) * imageSize.height,
            width: unitRect.width * imageSize.width,
            height: unitRect.height * imageSize.height
        )
    }
}

public enum OCRServiceError: Error, Equatable, LocalizedError, Sendable {
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .recognitionFailed(message):
            return "截图取词失败：\(message)"
        }
    }
}

/// Performs Chinese and English OCR entirely on-device using Vision.
public final class OCRService: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var recognitionLanguages: [String]
        public var accuracy: OCRRecognitionAccuracy
        public var usesLanguageCorrection: Bool
        public var minimumTextHeight: Float

        public init(
            recognitionLanguages: [String] = ["zh-Hans", "en-US"],
            accuracy: OCRRecognitionAccuracy = .accurate,
            usesLanguageCorrection: Bool = true,
            minimumTextHeight: Float = 0
        ) {
            self.recognitionLanguages = recognitionLanguages
            self.accuracy = accuracy
            self.usesLanguageCorrection = usesLanguageCorrection
            self.minimumTextHeight = minimumTextHeight.isFinite
                ? min(max(minimumTextHeight, 0), 1)
                : 0
        }
    }

    public let configuration: Configuration
    private let workQueue = DispatchQueue(
        label: "com.weshot.ocr-service",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Recognizes text without sending the image or recognized content off-device.
    public func recognize(in image: CGImage) async throws -> [OCRTextObservation] {
        let configuration = configuration

        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = configuration.accuracy.visionRecognitionLevel
                request.recognitionLanguages = configuration.recognitionLanguages
                request.usesLanguageCorrection = configuration.usesLanguageCorrection
                request.minimumTextHeight = configuration.minimumTextHeight

                do {
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])

                    let observations = (request.results ?? []).compactMap { observation in
                        observation.topCandidates(1).first.map { candidate in
                            OCRTextObservation(
                                text: candidate.string,
                                confidence: candidate.confidence,
                                boundingBox: observation.boundingBox
                            )
                        }
                    }

                    // Vision usually returns reading order, but explicitly sorting makes
                    // the API deterministic across revisions and test runs.
                    let sorted = observations.sorted { lhs, rhs in
                        if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > 0.001 {
                            return lhs.boundingBox.maxY > rhs.boundingBox.maxY
                        }
                        return lhs.boundingBox.minX < rhs.boundingBox.minX
                    }
                    continuation.resume(returning: sorted)
                } catch {
                    continuation.resume(
                        throwing: OCRServiceError.recognitionFailed(error.localizedDescription)
                    )
                }
            }
        }
    }
}
