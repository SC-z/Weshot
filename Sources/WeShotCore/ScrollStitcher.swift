import CoreGraphics
import Foundation

public enum ScrollStitcherError: Error, Equatable, LocalizedError, Sendable {
    case emptyFrames
    case invalidConfiguration(String)
    case widthMismatch(frameIndex: Int, expected: Int, actual: Int)
    case overlapSearchRangeEmpty(frameIndex: Int, minimum: Int, maximum: Int)
    case overlapNotFound(frameIndex: Int, bestError: Double, allowedError: Double)
    case ambiguousOverlap(frameIndex: Int, first: Int, second: Int)
    case noNewContent(frameIndex: Int)
    case pixelConversionFailed(frameIndex: Int)
    case outputTooLarge
    case outputCreationFailed

    public var errorDescription: String? {
        switch self {
        case .emptyFrames:
            return "滚动截图至少需要一帧图像。"
        case let .invalidConfiguration(message):
            return "滚动拼接参数无效：\(message)"
        case let .widthMismatch(index, expected, actual):
            return "第 \(index + 1) 帧宽度为 \(actual) 像素，预期为 \(expected) 像素。"
        case let .overlapSearchRangeEmpty(index, minimum, maximum):
            return "第 \(index + 1) 帧没有可搜索的重叠范围（\(minimum)...\(maximum) 像素）。"
        case let .overlapNotFound(index, bestError, allowedError):
            return "第 \(index + 1) 帧无法对齐（最佳误差 \(bestError)，允许误差 \(allowedError)）。"
        case let .ambiguousOverlap(index, first, second):
            return "第 \(index + 1) 帧存在歧义重叠（\(first) 或 \(second) 像素）。"
        case let .noNewContent(index):
            return "第 \(index + 1) 帧与上一帧相同，没有新增滚动内容。"
        case let .pixelConversionFailed(index):
            return "第 \(index + 1) 帧无法转换为 RGBA 像素。"
        case .outputTooLarge:
            return "滚动截图总尺寸过大。"
        case .outputCreationFailed:
            return "无法创建滚动截图结果图像。"
        }
    }
}

public struct ScrollOverlap: Equatable, Sendable {
    public let pixels: Int
    /// Maximum of whole-region and content-edge mean RGB error, in `0 ... 255`.
    public let meanAbsoluteError: Double

    public init(pixels: Int, meanAbsoluteError: Double) {
        self.pixels = pixels
        self.meanAbsoluteError = meanAbsoluteError
    }
}

public struct ScrollStitchResult {
    public let image: CGImage
    /// One item for every frame after the first.
    public let overlaps: [ScrollOverlap]

    public init(image: CGImage, overlaps: [ScrollOverlap]) {
        self.image = image
        self.overlaps = overlaps
    }
}

/// Estimates vertical overlap between equal-width screenshots and appends only
/// the newly revealed rows from each subsequent frame.
public struct ScrollStitcher: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var minimumOverlapPixels: Int
        public var maximumOverlapFraction: Double
        public var maximumMeanAbsoluteError: Double
        public var sampledRowsPerCandidate: Int
        public var sampledColumns: Int

        public init(
            minimumOverlapPixels: Int = 12,
            maximumOverlapFraction: Double = 1,
            maximumMeanAbsoluteError: Double = 8,
            sampledRowsPerCandidate: Int = 64,
            sampledColumns: Int = 96
        ) {
            self.minimumOverlapPixels = minimumOverlapPixels
            self.maximumOverlapFraction = maximumOverlapFraction
            self.maximumMeanAbsoluteError = maximumMeanAbsoluteError
            self.sampledRowsPerCandidate = sampledRowsPerCandidate
            self.sampledColumns = sampledColumns
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func estimateVerticalOverlap(
        previous: CGImage,
        next: CGImage
    ) throws -> ScrollOverlap {
        try validateConfiguration()
        guard previous.width == next.width else {
            throw ScrollStitcherError.widthMismatch(
                frameIndex: 1,
                expected: previous.width,
                actual: next.width
            )
        }
        let first = try Self.rgbaImage(from: previous, frameIndex: 0)
        let second = try Self.rgbaImage(from: next, frameIndex: 1)
        return try estimateOverlap(first, second, frameIndex: 1, fixedRows: Self.fixedRows(first, second))
    }

    /// Appends one viewport using the last accepted viewport for alignment.
    public func append(_ next: CGImage, to image: CGImage, previous: CGImage) throws -> ScrollStitchResult {
        try validateConfiguration()
        for frame in [previous, next] where frame.width != image.width {
            throw ScrollStitcherError.widthMismatch(frameIndex: 1, expected: image.width, actual: frame.width)
        }
        guard image.height >= previous.height else {
            throw ScrollStitcherError.invalidConfiguration("累计图高度小于上一张原始截图。")
        }
        let output = try Self.rgbaImage(from: image, frameIndex: 0)
        let first = image === previous ? output : try Self.rgbaImage(from: previous, frameIndex: 0)
        let second = try Self.rgbaImage(from: next, frameIndex: 1)
        var pixels = output.pixels
        var height = output.height
        let overlap = try appendRows(first, second, frameIndex: 1, pixels: &pixels, totalHeight: &height)
        guard let result = Self.makeImage(pixels: pixels, width: image.width, height: height) else {
            throw ScrollStitcherError.outputCreationFailed
        }
        return ScrollStitchResult(image: result, overlaps: [overlap])
    }

    public func stitch(_ frames: [CGImage]) throws -> ScrollStitchResult {
        try validateConfiguration()
        guard let firstFrame = frames.first else {
            throw ScrollStitcherError.emptyFrames
        }

        let expectedWidth = firstFrame.width
        for (index, frame) in frames.enumerated().dropFirst() where frame.width != expectedWidth {
            throw ScrollStitcherError.widthMismatch(
                frameIndex: index,
                expected: expectedWidth,
                actual: frame.width
            )
        }

        let converted = try frames.enumerated().map { index, frame in
            try Self.rgbaImage(from: frame, frameIndex: index)
        }
        var pixels = converted[0].pixels
        var totalHeight = converted[0].height
        var overlaps: [ScrollOverlap] = []
        for index in 1 ..< converted.count {
            let overlap = try appendRows(
                converted[index - 1],
                converted[index],
                frameIndex: index,
                pixels: &pixels,
                totalHeight: &totalHeight
            )
            overlaps.append(overlap)
        }

        guard let image = Self.makeImage(
            pixels: pixels,
            width: expectedWidth,
            height: totalHeight
        ) else {
            throw ScrollStitcherError.outputCreationFailed
        }
        return ScrollStitchResult(image: image, overlaps: overlaps)
    }

    private func appendRows(
        _ previous: RGBAImage, _ next: RGBAImage, frameIndex: Int,
        pixels: inout [UInt8], totalHeight: inout Int
    ) throws -> ScrollOverlap {
        let fixedRows = Self.fixedRows(previous, next)
        let overlap = try estimateOverlap(previous, next, frameIndex: frameIndex, fixedRows: fixedRows)
        guard overlap.pixels < next.height else {
            throw ScrollStitcherError.noNewContent(frameIndex: frameIndex)
        }
        let rowBytes = try Self.rowByteCount(width: previous.width)
        let (newHeight, heightOverflow) = totalHeight.addingReportingOverflow(next.height - overlap.pixels)
        guard !heightOverflow else { throw ScrollStitcherError.outputTooLarge }
        let (_, byteOverflow) = newHeight.multipliedReportingOverflow(by: rowBytes)
        guard !byteOverflow else { throw ScrollStitcherError.outputTooLarge }

        // Replace the old fixed footer with newly revealed content and the final footer.
        pixels.removeLast(fixedRows.bottom * rowBytes)
        let appendOffset = (overlap.pixels - fixedRows.bottom) * rowBytes
        pixels.append(contentsOf: next.pixels[appendOffset...])
        totalHeight = newHeight
        return overlap
    }

    private func validateConfiguration() throws {
        guard configuration.minimumOverlapPixels > 0 else {
            throw ScrollStitcherError.invalidConfiguration("最小重叠必须大于 0。")
        }
        guard configuration.maximumOverlapFraction > 0,
              configuration.maximumOverlapFraction <= 1
        else {
            throw ScrollStitcherError.invalidConfiguration("最大重叠比例必须位于 (0, 1]。")
        }
        guard configuration.maximumMeanAbsoluteError >= 0,
              configuration.maximumMeanAbsoluteError.isFinite
        else {
            throw ScrollStitcherError.invalidConfiguration("像素误差必须是非负有限值。")
        }
        guard configuration.sampledRowsPerCandidate > 0,
              configuration.sampledColumns > 0
        else {
            throw ScrollStitcherError.invalidConfiguration("采样行列数必须大于 0。")
        }
    }

    private func estimateOverlap(
        _ previous: RGBAImage,
        _ next: RGBAImage,
        frameIndex: Int,
        fixedRows: (top: Int, bottom: Int)
    ) throws -> ScrollOverlap {
        let maximum = min(
            min(previous.height, next.height),
            Int((Double(min(previous.height, next.height)) * configuration.maximumOverlapFraction).rounded(.down))
        )
        let minimum = configuration.minimumOverlapPixels
        guard minimum <= maximum else {
            throw ScrollStitcherError.overlapSearchRangeEmpty(
                frameIndex: frameIndex,
                minimum: minimum,
                maximum: maximum
            )
        }

        // Exact duplicate frames have every possible overlap in flat or periodic
        // content. Classify them before ambiguity detection so the result is
        // deterministic and callers never mistake a duplicate for new content.
        if previous.height == next.height, previous.pixels == next.pixels {
            throw ScrollStitcherError.noNewContent(frameIndex: frameIndex)
        }

        var sampledCandidates: [ScrollOverlap] = []
        sampledCandidates.reserveCapacity(maximum - minimum + 1)
        for overlap in minimum ... maximum {
            sampledCandidates.append(
                ScrollOverlap(
                    pixels: overlap,
                    meanAbsoluteError: sampledMeanAbsoluteError(
                        previous,
                        next,
                        overlap: overlap,
                        fixedRows: fixedRows
                    )
                )
            )
        }
        sampledCandidates.sort { lhs, rhs in
            if abs(lhs.meanAbsoluteError - rhs.meanAbsoluteError) > 1e-12 {
                return lhs.meanAbsoluteError < rhs.meanAbsoluteError
            }
            return lhs.pixels > rhs.pixels
        }

        let sampledBest = sampledCandidates[0]
        guard sampledBest.meanAbsoluteError <= configuration.maximumMeanAbsoluteError else {
            throw ScrollStitcherError.overlapNotFound(
                frameIndex: frameIndex,
                bestError: sampledBest.meanAbsoluteError,
                allowedError: configuration.maximumMeanAbsoluteError
            )
        }

        // Sampling is only a coarse filter. Re-score a bounded shortlist across
        // every RGB pixel so an unobserved row or column cannot produce a false
        // zero-error/full-height overlap. Keeping the shortlist fixed avoids the
        // O(width * height²) worst case of verifying every possible overlap; this
        // stage is O(maximumVerifiedCandidates * width * height).
        var verifiedCandidates = sampledCandidates
            .prefix(Self.maximumVerifiedCandidates)
            .map { candidate in
                ScrollOverlap(
                    pixels: candidate.pixels,
                    meanAbsoluteError: fullMeanAbsoluteError(
                        previous,
                        next,
                        overlap: candidate.pixels,
                        fixedRows: fixedRows
                    )
                )
            }
        verifiedCandidates.sort { lhs, rhs in
            if abs(lhs.meanAbsoluteError - rhs.meanAbsoluteError) > 1e-12 {
                return lhs.meanAbsoluteError < rhs.meanAbsoluteError
            }
            return lhs.pixels > rhs.pixels
        }

        let best = verifiedCandidates[0]
        guard best.meanAbsoluteError <= configuration.maximumMeanAbsoluteError else {
            throw ScrollStitcherError.overlapNotFound(
                frameIndex: frameIndex,
                bestError: best.meanAbsoluteError,
                allowedError: configuration.maximumMeanAbsoluteError
            )
        }
        if let equallyGood = verifiedCandidates.dropFirst().first(where: {
            // One 8-bit channel level is insufficient evidence to choose an alignment.
            $0.meanAbsoluteError - best.meanAbsoluteError <= 1
        }) {
            throw ScrollStitcherError.ambiguousOverlap(
                frameIndex: frameIndex,
                first: best.pixels,
                second: equallyGood.pixels
            )
        }
        return best
    }

    private func sampledMeanAbsoluteError(
        _ previous: RGBAImage,
        _ next: RGBAImage,
        overlap: Int,
        fixedRows: (top: Int, bottom: Int)
    ) -> Double {
        let sampledRows = min(overlap, configuration.sampledRowsPerCandidate)
        let sampledColumns = min(previous.width, configuration.sampledColumns)
        return meanAbsoluteError(
            previous,
            next,
            overlap: overlap,
            sampledRows: sampledRows,
            sampledColumns: sampledColumns,
            fixedRows: fixedRows
        )
    }

    private func fullMeanAbsoluteError(
        _ previous: RGBAImage,
        _ next: RGBAImage,
        overlap: Int,
        fixedRows: (top: Int, bottom: Int)
    ) -> Double {
        meanAbsoluteError(
            previous,
            next,
            overlap: overlap,
            sampledRows: overlap,
            sampledColumns: previous.width,
            fixedRows: fixedRows
        )
    }

    private func meanAbsoluteError(
        _ previous: RGBAImage,
        _ next: RGBAImage,
        overlap: Int,
        sampledRows: Int,
        sampledColumns: Int,
        fixedRows: (top: Int, bottom: Int)
    ) -> Double {
        let comparableRows = overlap - fixedRows.top - fixedRows.bottom
        guard comparableRows > 0 else { return .infinity }
        let rowCount = min(comparableRows, sampledRows)
        var totalDifference: UInt64 = 0
        var channelCount: UInt64 = 0
        var edgeDifference: UInt64 = 0
        var edgeChannelCount: UInt64 = 0

        for rowSample in 0 ..< rowCount {
            let row = fixedRows.top + Self.samplePosition(
                sample: rowSample,
                count: rowCount,
                extent: comparableRows
            )
            let previousRow = previous.height - overlap + row
            let nextRow = row

            for columnSample in 0 ..< sampledColumns {
                let column = Self.samplePosition(
                    sample: columnSample,
                    count: sampledColumns,
                    extent: previous.width
                )
                let previousOffset = (previousRow * previous.width + column) * 4
                let nextOffset = (nextRow * next.width + column) * 4

                let previousLeft = previousOffset - (column > 0 ? 4 : 0)
                let nextLeft = nextOffset - (column > 0 ? 4 : 0)
                let previousAbove = previousOffset - (previousRow > 0 ? previous.width * 4 : 0)
                let nextAbove = nextOffset - (nextRow > 0 ? next.width * 4 : 0)
                var difference: UInt64 = 0
                var isEdge = false
                for channel in 0 ..< 3 {
                    let first = Int(previous.pixels[previousOffset + channel])
                    let second = Int(next.pixels[nextOffset + channel])
                    difference += UInt64(abs(first - second))
                    if !isEdge {
                        isEdge = abs(first - Int(previous.pixels[previousLeft + channel])) > 8
                            || abs(second - Int(next.pixels[nextLeft + channel])) > 8
                            || abs(first - Int(previous.pixels[previousAbove + channel])) > 8
                            || abs(second - Int(next.pixels[nextAbove + channel])) > 8
                    }
                }
                totalDifference += difference
                channelCount += 3
                // White margins cannot dilute disagreement between text or other content edges.
                if isEdge {
                    edgeDifference += difference
                    edgeChannelCount += 3
                }
            }
        }

        let mean = channelCount == 0 ? .infinity : Double(totalDifference) / Double(channelCount)
        let edgeMean = edgeChannelCount == 0 ? mean : Double(edgeDifference) / Double(edgeChannelCount)
        return max(mean, edgeMean)
    }

    private static func fixedRows(_ previous: RGBAImage, _ next: RGBAImage) -> (top: Int, bottom: Int) {
        guard previous.height == next.height else { return (0, 0) }
        let rowBytes = previous.width * 4
        // shortcut: detect unchanged edges within a quarter viewport, revisit for larger sticky panels.
        let limit = previous.height / 4
        func matches(_ row: Int) -> Bool {
            let range = row * rowBytes ..< (row + 1) * rowBytes
            return previous.pixels[range] == next.pixels[range]
        }
        var top = 0
        while top < limit, matches(top) { top += 1 }
        var bottom = 0
        while bottom < limit, matches(previous.height - bottom - 1) { bottom += 1 }
        return (top, bottom)
    }

    private static func samplePosition(sample: Int, count: Int, extent: Int) -> Int {
        guard count > 1 else { return extent / 2 }
        return sample * (extent - 1) / (count - 1)
    }

    private static let maximumVerifiedCandidates = 4

    private struct RGBAImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private static func rgbaImage(from image: CGImage, frameIndex: Int) throws -> RGBAImage {
        let width = image.width
        let height = image.height
        let rowBytes = try rowByteCount(width: width)
        let (byteCount, overflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !overflow else { throw ScrollStitcherError.outputTooLarge }

        var pixels = [UInt8](repeating: 0, count: byteCount)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: rgbaBitmapInfo.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw ScrollStitcherError.pixelConversionFailed(frameIndex: frameIndex)
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    private static func makeImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let rowBytes = width * 4
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: rgbaBitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func rowByteCount(width: Int) throws -> Int {
        let (rowBytes, overflow) = width.multipliedReportingOverflow(by: 4)
        guard !overflow else { throw ScrollStitcherError.outputTooLarge }
        return rowBytes
    }

    private static let rgbaBitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
    ).union(.byteOrder32Big)
}
