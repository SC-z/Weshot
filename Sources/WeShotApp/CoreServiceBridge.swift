import AppKit
import CoreGraphics
import Foundation
import WeShotCore

/// Keeps AppKit concerns out of WeShotCore while making every advanced toolbar
/// entry call the real local core service.
@MainActor
enum CoreServiceBridge {
    private static let ocr = OCRService()
    private static let redactor = PrivacyRedactor()
    static let translationController = SystemTranslationController()

    static func recognizeText(in image: CGImage) async throws -> String {
        let observations = try await ocr.recognize(in: image)
        return observations.map(\.text).joined(separator: "\n")
    }

    /// Returns normalized AppKit-style rectangles (origin at lower left).
    static func privacyRegions(in image: CGImage) async throws -> [CGRect] {
        let regions = try await redactor.detect(in: image)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return [] }
        return regions.map { region in
            CGRect(
                x: region.rect.minX / width,
                y: 1 - region.rect.maxY / height,
                width: region.rect.width / width,
                height: region.rect.height / height
            )
        }
    }

    static func stitch(frames: [CGImage]) async throws -> CGImage {
        let inputs = frames.map(SendableCGImage.init)
        let output = try await Task.detached(priority: .userInitiated) {
            let images = inputs.map(\.image)
            return SendableCGImage(try ScrollStitcher().stitch(images).image)
        }.value
        return output.image
    }
}

/// CGImage is immutable, but older SDK overlays do not consistently annotate
/// it as Sendable. This wrapper documents the boundary used by the detached
/// stitching task without making AppKit state cross actors.
private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

struct TranslationResult {
    let sourceText: String
    let translatedText: String?
    let statusMessage: String
}

@MainActor
protocol TranslationController {
    func translate(_ text: String) async -> TranslationResult
}
