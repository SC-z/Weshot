import AppKit
import CoreGraphics
import Foundation

/// A color independent of AppKit's dynamic color spaces, suitable for model
/// storage and deterministic bitmap rendering.
public struct RGBAColor: Equatable, Hashable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = Self.component(red)
        self.green = Self.component(green)
        self.blue = Self.component(blue)
        self.alpha = Self.component(alpha)
    }

    public init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.deviceRGB) ?? .black
        self.init(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }

    public var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [red, green, blue, alpha]
        )!
    }

    public var nsColor: NSColor {
        NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let red = RGBAColor(red: 0.96, green: 0.22, blue: 0.20)
    public static let yellow = RGBAColor(red: 1.00, green: 0.78, blue: 0.12)
    public static let green = RGBAColor(red: 0.12, green: 0.78, blue: 0.34)
    public static let blue = RGBAColor(red: 0.16, green: 0.48, blue: 0.95)

    private static func component(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct StrokeStyle: Equatable, Hashable, Sendable {
    public var color: RGBAColor
    public var lineWidth: CGFloat

    public init(color: RGBAColor = .red, lineWidth: CGFloat = 3) {
        self.color = color
        self.lineWidth = lineWidth.isFinite ? max(0.5, lineWidth) : 3
    }
}

/// An annotation in full-image, top-left-origin coordinates.
public enum Annotation: Equatable, Sendable {
    case rectangle(rect: CGRect, color: RGBAColor, lineWidth: CGFloat)
    case ellipse(rect: CGRect, color: RGBAColor, lineWidth: CGFloat)
    case arrow(start: CGPoint, end: CGPoint, color: RGBAColor, lineWidth: CGFloat)
    case pen(points: [CGPoint], color: RGBAColor, lineWidth: CGFloat)
    case mosaic(rect: CGRect, blockSize: CGFloat)
    case text(origin: CGPoint, text: String, color: RGBAColor, fontSize: CGFloat)

    public static func rectangle(rect: CGRect, style: StrokeStyle) -> Annotation {
        .rectangle(rect: rect, color: style.color, lineWidth: style.lineWidth)
    }

    public static func ellipse(rect: CGRect, style: StrokeStyle) -> Annotation {
        .ellipse(rect: rect, color: style.color, lineWidth: style.lineWidth)
    }

    public static func arrow(start: CGPoint, end: CGPoint, style: StrokeStyle) -> Annotation {
        .arrow(start: start, end: end, color: style.color, lineWidth: style.lineWidth)
    }

    public static func pen(points: [CGPoint], style: StrokeStyle) -> Annotation {
        .pen(points: points, color: style.color, lineWidth: style.lineWidth)
    }

    public var strokeStyle: StrokeStyle? {
        switch self {
        case .rectangle(_, let color, let lineWidth),
             .ellipse(_, let color, let lineWidth),
             .arrow(_, _, let color, let lineWidth),
             .pen(_, let color, let lineWidth):
            return StrokeStyle(color: color, lineWidth: lineWidth)
        case .mosaic, .text:
            return nil
        }
    }

    /// A normalized copy for rectangle-based tools. Other tools are unchanged.
    public var normalized: Annotation {
        switch self {
        case .rectangle(let rect, let color, let lineWidth):
            return .rectangle(rect: rect.standardized, color: color, lineWidth: lineWidth)
        case .ellipse(let rect, let color, let lineWidth):
            return .ellipse(rect: rect.standardized, color: color, lineWidth: lineWidth)
        case .mosaic(let rect, let blockSize):
            return .mosaic(rect: rect.standardized, blockSize: blockSize)
        default:
            return self
        }
    }

    public var bounds: CGRect {
        switch self {
        case .rectangle(let rect, _, let lineWidth),
             .ellipse(let rect, _, let lineWidth):
            return rect.standardized.insetBy(dx: -max(0, lineWidth) / 2, dy: -max(0, lineWidth) / 2)
        case .arrow(let start, let end, _, let lineWidth):
            let rect = SelectionGeometry.normalized(from: start, to: end)
            let padding = max(10, max(0, lineWidth) * 4.5)
            return rect.insetBy(dx: -padding, dy: -padding)
        case .pen(let points, _, let lineWidth):
            guard let first = points.first else { return .zero }
            var minX = first.x
            var minY = first.y
            var maxX = first.x
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -max(0, lineWidth) / 2, dy: -max(0, lineWidth) / 2)
        case .mosaic(let rect, _):
            return rect.standardized
        case .text(let origin, let text, _, let fontSize):
            let font = NSFont.systemFont(ofSize: max(1, fontSize), weight: .medium)
            let measured = (text as NSString).size(withAttributes: [.font: font])
            return CGRect(origin: origin, size: measured)
        }
    }
}

/// Mutable editing history with redo support. Every successful mutation is one
/// undo step; adding after undo invalidates the redo branch.
public final class AnnotationDocument {
    public private(set) var annotations: [Annotation]
    public let maximumHistoryDepth: Int

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    public init(annotations: [Annotation] = [], maximumHistoryDepth: Int = 100) {
        self.annotations = annotations
        self.maximumHistoryDepth = max(1, maximumHistoryDepth)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    public func append(_ annotation: Annotation) -> Annotation {
        recordMutation()
        let normalized = annotation.normalized
        annotations.append(normalized)
        return normalized
    }

    public func add(_ annotation: Annotation) {
        append(annotation)
    }

    @discardableResult
    public func clear() -> Bool {
        guard !annotations.isEmpty else { return false }
        recordMutation()
        annotations.removeAll(keepingCapacity: true)
        return true
    }

    @discardableResult
    public func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(annotations)
        annotations = previous
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(annotations)
        trimUndoHistory()
        annotations = next
        return true
    }

    public func reset(to annotations: [Annotation] = []) {
        self.annotations = annotations.map(\.normalized)
        undoStack.removeAll(keepingCapacity: false)
        redoStack.removeAll(keepingCapacity: false)
    }

    private func recordMutation() {
        undoStack.append(annotations)
        trimUndoHistory()
        redoStack.removeAll(keepingCapacity: true)
    }

    private func trimUndoHistory() {
        let excess = undoStack.count - maximumHistoryDepth
        if excess > 0 {
            undoStack.removeFirst(excess)
        }
    }
}
