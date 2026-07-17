import CoreGraphics
import Foundation

/// The eight resize handles around a selection in top-left-origin coordinates.
public enum ResizeHandle: String, CaseIterable, Hashable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    public func point(in rect: CGRect) -> CGPoint {
        let rect = rect.standardized
        switch self {
        case .topLeft:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .top:
            return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .right:
            return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:
            return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:
            return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    fileprivate var movesLeftEdge: Bool {
        self == .topLeft || self == .left || self == .bottomLeft
    }

    fileprivate var movesRightEdge: Bool {
        self == .topRight || self == .right || self == .bottomRight
    }

    fileprivate var movesTopEdge: Bool {
        self == .topLeft || self == .top || self == .topRight
    }

    fileprivate var movesBottomEdge: Bool {
        self == .bottomLeft || self == .bottom || self == .bottomRight
    }
}

public enum SelectionHit: Equatable {
    case outside
    case inside
    case handle(ResizeHandle)
}

/// Selection geometry expressed in image coordinates, where `(0, 0)` is the
/// top-left pixel and positive y points down.
public struct SelectionGeometry: Equatable {
    public private(set) var rect: CGRect
    public private(set) var bounds: CGRect?

    public init(rect: CGRect, bounds: CGRect? = nil) {
        let normalizedBounds = bounds.flatMap(Self.validRect)
        let normalizedRect = Self.validRect(rect) ?? .zero
        self.bounds = normalizedBounds
        self.rect = normalizedBounds.map { Self.intersection(normalizedRect, $0) } ?? normalizedRect
    }

    public init(start: CGPoint, end: CGPoint, bounds: CGRect? = nil) {
        self.init(rect: Self.normalized(from: start, to: end), bounds: bounds)
    }

    public static func normalized(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    public static func normalized(_ rect: CGRect) -> CGRect {
        validRect(rect) ?? .zero
    }

    public var isEmpty: Bool {
        rect.isEmpty || rect.width <= 0 || rect.height <= 0
    }

    public func clipped(to bounds: CGRect) -> SelectionGeometry {
        SelectionGeometry(rect: rect, bounds: bounds)
    }

    public func contains(_ point: CGPoint) -> Bool {
        rect.contains(point)
    }

    public func controlPoint(for handle: ResizeHandle) -> CGPoint {
        handle.point(in: rect)
    }

    /// Returns a handle when the point falls within `tolerance` points of one.
    /// Corners are checked before edge handles to make corner resizing stable.
    public func handle(at point: CGPoint, tolerance: CGFloat = 6) -> ResizeHandle? {
        guard !isEmpty else { return nil }
        let radius = max(0, tolerance)
        let radiusSquared = radius * radius
        let order: [ResizeHandle] = [
            .topLeft, .topRight, .bottomRight, .bottomLeft,
            .top, .right, .bottom, .left,
        ]
        return order.first { handle in
            let control = handle.point(in: rect)
            let dx = control.x - point.x
            let dy = control.y - point.y
            return dx * dx + dy * dy <= radiusSquared
        }
    }

    public func hitTest(_ point: CGPoint, handleTolerance: CGFloat = 6) -> SelectionHit {
        guard !isEmpty else { return .outside }
        if let handle = handle(at: point, tolerance: handleTolerance) {
            return .handle(handle)
        }
        return rect.contains(point) ? .inside : .outside
    }

    /// Moves the selection without changing its size. If bounds are supplied,
    /// the result is clamped so it stays wholly inside them.
    public func moved(by translation: CGSize, bounds explicitBounds: CGRect? = nil) -> SelectionGeometry {
        let activeBounds = explicitBounds.flatMap(Self.validRect) ?? bounds
        var moved = rect.offsetBy(dx: translation.width, dy: translation.height)
        guard let activeBounds else {
            return SelectionGeometry(rect: moved)
        }

        if moved.width >= activeBounds.width {
            moved.origin.x = activeBounds.minX
            moved.size.width = activeBounds.width
        } else {
            moved.origin.x = Self.clamp(
                moved.origin.x,
                lower: activeBounds.minX,
                upper: activeBounds.maxX - moved.width
            )
        }

        if moved.height >= activeBounds.height {
            moved.origin.y = activeBounds.minY
            moved.size.height = activeBounds.height
        } else {
            moved.origin.y = Self.clamp(
                moved.origin.y,
                lower: activeBounds.minY,
                upper: activeBounds.maxY - moved.height
            )
        }
        return SelectionGeometry(rect: moved, bounds: activeBounds)
    }

    public func moved(by translation: CGSize, within bounds: CGRect) -> SelectionGeometry {
        moved(by: translation, bounds: bounds)
    }

    /// Resizes from this selection's current rectangle.
    public func resized(
        handle: ResizeHandle,
        translation: CGSize,
        bounds explicitBounds: CGRect? = nil,
        minimumSize: CGSize = CGSize(width: 8, height: 8)
    ) -> SelectionGeometry {
        resized(
            from: rect,
            handle: handle,
            translation: translation,
            bounds: explicitBounds,
            minimumSize: minimumSize
        )
    }

    /// Resizes an original rectangle using a drag translation. The opposite
    /// edge remains anchored and the dragged edge stops at the minimum size.
    public func resized(
        from originalRect: CGRect,
        handle: ResizeHandle,
        translation: CGSize,
        bounds explicitBounds: CGRect? = nil,
        minimumSize: CGSize = CGSize(width: 8, height: 8)
    ) -> SelectionGeometry {
        let original = Self.validRect(originalRect) ?? .zero
        let activeBounds = explicitBounds.flatMap(Self.validRect) ?? bounds
        let minWidth = min(
            max(0, minimumSize.width),
            activeBounds?.width ?? .greatestFiniteMagnitude
        )
        let minHeight = min(
            max(0, minimumSize.height),
            activeBounds?.height ?? .greatestFiniteMagnitude
        )

        var left = original.minX
        var right = original.maxX
        var top = original.minY
        var bottom = original.maxY

        if handle.movesLeftEdge {
            left = min(original.minX + translation.width, right - minWidth)
            if let activeBounds { left = max(left, activeBounds.minX) }
        } else if handle.movesRightEdge {
            right = max(original.maxX + translation.width, left + minWidth)
            if let activeBounds { right = min(right, activeBounds.maxX) }
        }

        if handle.movesTopEdge {
            top = min(original.minY + translation.height, bottom - minHeight)
            if let activeBounds { top = max(top, activeBounds.minY) }
        } else if handle.movesBottomEdge {
            bottom = max(original.maxY + translation.height, top + minHeight)
            if let activeBounds { bottom = min(bottom, activeBounds.maxY) }
        }

        let result = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        return SelectionGeometry(rect: result, bounds: activeBounds)
    }

    /// Resizes by moving a handle directly to an image-coordinate point.
    public func resized(
        handle: ResizeHandle,
        to point: CGPoint,
        bounds explicitBounds: CGRect? = nil,
        minimumSize: CGSize = CGSize(width: 8, height: 8)
    ) -> SelectionGeometry {
        let current = handle.point(in: rect)
        return resized(
            handle: handle,
            translation: CGSize(width: point.x - current.x, height: point.y - current.y),
            bounds: explicitBounds,
            minimumSize: minimumSize
        )
    }

    private static func validRect(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull,
              !rect.isInfinite,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite
        else { return nil }
        return rect.standardized
    }

    private static func intersection(_ lhs: CGRect, _ rhs: CGRect) -> CGRect {
        let result = lhs.intersection(rhs)
        guard !result.isNull, !result.isEmpty else {
            let x = clamp(lhs.minX, lower: rhs.minX, upper: rhs.maxX)
            let y = clamp(lhs.minY, lower: rhs.minY, upper: rhs.maxY)
            return CGRect(x: x, y: y, width: 0, height: 0)
        }
        return result
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return lower }
        return min(max(value, lower), upper)
    }
}

/// Preferred vertical side for the floating annotation toolbar.
public enum ToolbarPlacement: Equatable {
    case below
    case above

    public static func preferred(
        selection: CGRect,
        toolbarSize: CGSize,
        screen: CGRect,
        gap: CGFloat = 8,
        margin: CGFloat = 8
    ) -> ToolbarPlacement {
        let selection = selection.standardized
        let screen = screen.standardized
        let belowSpace = screen.maxY - margin - selection.maxY - gap
        let aboveSpace = selection.minY - gap - (screen.minY + margin)
        if toolbarSize.height <= belowSpace { return .below }
        if toolbarSize.height <= aboveSpace { return .above }
        return belowSpace >= aboveSpace ? .below : .above
    }

    /// Places the toolbar right-aligned to the selection, preferring below and
    /// flipping above when required. The resulting origin is clamped to screen.
    public static func place(
        selection: CGRect,
        toolbarSize: CGSize,
        screen: CGRect,
        gap: CGFloat = 8,
        margin: CGFloat = 8
    ) -> CGRect {
        let selection = selection.standardized
        let screen = screen.standardized
        let width = max(0, toolbarSize.width)
        let height = max(0, toolbarSize.height)
        let horizontalLower = screen.minX + margin
        let horizontalUpper = max(horizontalLower, screen.maxX - margin - width)
        let x = min(max(selection.maxX - width, horizontalLower), horizontalUpper)

        let side = preferred(
            selection: selection,
            toolbarSize: CGSize(width: width, height: height),
            screen: screen,
            gap: gap,
            margin: margin
        )
        let proposedY: CGFloat
        switch side {
        case .below:
            proposedY = selection.maxY + gap
        case .above:
            proposedY = selection.minY - gap - height
        }
        let verticalLower = screen.minY + margin
        let verticalUpper = max(verticalLower, screen.maxY - margin - height)
        let y = min(max(proposedY, verticalLower), verticalUpper)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
