import AppKit
import CoreGraphics
import CoreImage

enum CaptureTool: String, CaseIterable {
    case selection
    case rectangle
    case ellipse
    case emoji
    case arrow
    case pen
    case text
    case mosaic

    var symbolName: String {
        switch self {
        case .selection: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .emoji: return "face.smiling"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3"
        }
    }

    var accessibilityName: String {
        switch self {
        case .selection: return "选择"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .emoji: return "表情"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }
}

enum ResizeAnchor: CaseIterable {
    case northWest, north, northEast, east, southEast, south, southWest, west

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .northWest: return CGPoint(x: rect.minX, y: rect.maxY)
        case .north: return CGPoint(x: rect.midX, y: rect.maxY)
        case .northEast: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .east: return CGPoint(x: rect.maxX, y: rect.midY)
        case .southEast: return CGPoint(x: rect.maxX, y: rect.minY)
        case .south: return CGPoint(x: rect.midX, y: rect.minY)
        case .southWest: return CGPoint(x: rect.minX, y: rect.minY)
        case .west: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    func resized(_ rect: CGRect, translation: CGSize, inside bounds: CGRect, minimum: CGFloat = 10) -> CGRect {
        var left = rect.minX
        var right = rect.maxX
        var bottom = rect.minY
        var top = rect.maxY
        switch self {
        case .northWest: left += translation.width; top += translation.height
        case .north: top += translation.height
        case .northEast: right += translation.width; top += translation.height
        case .east: right += translation.width
        case .southEast: right += translation.width; bottom += translation.height
        case .south: bottom += translation.height
        case .southWest: left += translation.width; bottom += translation.height
        case .west: left += translation.width
        }
        if right - left < minimum {
            if [.northWest, .southWest, .west].contains(self) { left = right - minimum } else { right = left + minimum }
        }
        if top - bottom < minimum {
            if [.southEast, .south, .southWest].contains(self) { bottom = top - minimum } else { top = bottom + minimum }
        }
        left = max(bounds.minX, left)
        right = min(bounds.maxX, right)
        bottom = max(bounds.minY, bottom)
        top = min(bounds.maxY, top)
        return CGRect(x: left, y: bottom, width: max(minimum, right - left), height: max(minimum, top - bottom)).intersection(bounds)
    }
}

enum AppAnnotation {
    case rectangle(CGRect, NSColor, CGFloat)
    case ellipse(CGRect, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case pen([CGPoint], NSColor, CGFloat)
    case text(CGPoint, String, NSColor, CGFloat)
    case mosaic(CGRect, CGFloat)
    case translation(CGRect, String)
}

struct EditorStyle {
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var mosaicBlockSize: CGFloat = 12
    var emoji = "😀"
}

struct WindowCandidate {
    let frame: CGRect
    let windowID: CGWindowID
    let ownerName: String
    let title: String
    let layer: Int

    func snapFrame(on screenFrame: CGRect) -> CGRect? {
        let clipped = frame.intersection(screenFrame)
        guard !clipped.isNull,
              clipped.width >= 1,
              clipped.height >= 1,
              clipped.width * clipped.height < screenFrame.width * screenFrame.height * 0.9
        else { return nil }
        return clipped
    }
}

enum DesktopCoordinateMapper {
    /// Quartz window-list rectangles use a top-left desktop origin while AppKit
    /// uses a bottom-left origin anchored to the primary display.
    static func appKitFrame(fromQuartz frame: CGRect, primaryDesktopTop: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryDesktopTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func localFrame(fromAppKit frame: CGRect, screenFrame: CGRect) -> CGRect {
        frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
}

enum CaptureFileNamer {
    static func pngFilename(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "WeShot \(formatter.string(from: date)).png"
    }
}

struct PixelRGB: Equatable {
    let red: Int
    let green: Int
    let blue: Int
}

/// Reads one source pixel through a known RGBA bitmap context. ScreenCaptureKit
/// commonly returns BGRA images, so reading the provider bytes directly swaps
/// red and blue and also ignores row layout and color-space conversion.
enum PixelSampler {
    static func rgb(in image: CGImage, x: Int, y: Int) -> PixelRGB? {
        guard image.width > 0, image.height > 0 else { return nil }
        let pixelX = min(image.width - 1, max(0, x))
        let pixelY = min(image.height - 1, max(0, y))
        guard let pixel = image.cropping(to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1)) else {
            return nil
        }

        var rgba = [UInt8](repeating: 0, count: 4)
        let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered else { return nil }

        let alpha = Int(rgba[3])
        guard alpha > 0 else { return PixelRGB(red: 0, green: 0, blue: 0) }
        func unpremultiply(_ value: UInt8) -> Int {
            min(255, (Int(value) * 255 + alpha / 2) / alpha)
        }
        return PixelRGB(
            red: unpremultiply(rgba[0]),
            green: unpremultiply(rgba[1]),
            blue: unpremultiply(rgba[2])
        )
    }
}

enum OverlayAction: Equatable {
    case translate
    case scroll
    case undo
    case pin
    case save
    case cancel
    case finish

    var symbolName: String {
        switch self {
        case .translate: return "translate"
        case .scroll: return "arrow.up.and.down.square"
        case .undo: return "arrow.uturn.backward"
        case .pin: return "pin"
        case .save: return "square.and.arrow.down"
        case .cancel: return "xmark"
        case .finish: return "checkmark"
        }
    }

    var accessibilityName: String {
        switch self {
        case .translate: return "翻译"
        case .scroll: return "滚动截图"
        case .undo: return "撤销"
        case .pin: return "钉在桌面"
        case .save: return "保存"
        case .cancel: return "取消"
        case .finish: return "完成"
        }
    }
}

enum ToolbarItem: Equatable {
    case tool(CaptureTool)
    case action(OverlayAction)

    var symbolName: String {
        switch self {
        case .tool(let tool): return tool.symbolName
        case .action(let action): return action.symbolName
        }
    }

    var accessibilityName: String {
        switch self {
        case .tool(let tool): return tool.accessibilityName
        case .action(let action): return action.accessibilityName
        }
    }
}

struct ToolbarLayout {
    static let itemSize = CGSize(width: 44, height: 48)
    static let horizontalPadding: CGFloat = 17
    static let separatorWidth: CGFloat = 18
    static let height: CGFloat = 48
    static let gap: CGFloat = 16
    static let items: [ToolbarItem] = [
        .tool(.rectangle), .tool(.ellipse), .tool(.emoji), .tool(.arrow), .tool(.pen), .tool(.mosaic), .tool(.text),
        .action(.translate), .action(.scroll),
        .action(.undo), .action(.save), .action(.pin), .action(.cancel), .action(.finish),
    ]
    static let separatorAfterIndices: Set<Int> = [6, 8]

    static var size: CGSize {
        CGSize(
            width: CGFloat(items.count) * itemSize.width +
                CGFloat(separatorAfterIndices.count) * separatorWidth +
                horizontalPadding * 2,
            height: height
        )
    }

    static func frame(for selection: CGRect, in bounds: CGRect) -> CGRect {
        let size = size
        var x = min(max(bounds.minX + 8, selection.maxX - size.width), bounds.maxX - size.width - 8)
        if bounds.width < size.width + 16 { x = bounds.minX + 8 }
        let below = selection.minY - gap - size.height
        let above = selection.maxY + gap
        let y = below >= bounds.minY + 8 ? below : min(above, bounds.maxY - size.height - 8)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func item(at point: CGPoint, toolbarFrame: CGRect) -> ToolbarItem? {
        guard toolbarFrame.contains(point) else { return nil }
        for index in items.indices where itemFrame(at: index, toolbarFrame: toolbarFrame).contains(point) {
            return items[index]
        }
        return nil
    }

    static func itemFrame(at index: Int, toolbarFrame: CGRect) -> CGRect {
        let precedingSeparators = separatorAfterIndices.filter { $0 < index }.count
        return CGRect(
            x: toolbarFrame.minX + horizontalPadding + CGFloat(index) * itemSize.width +
                CGFloat(precedingSeparators) * separatorWidth,
            y: toolbarFrame.minY,
            width: itemSize.width,
            height: toolbarFrame.height
        )
    }

    static func separatorFrame(after index: Int, toolbarFrame: CGRect) -> CGRect? {
        guard separatorAfterIndices.contains(index) else { return nil }
        let item = itemFrame(at: index, toolbarFrame: toolbarFrame)
        return CGRect(x: item.maxX, y: toolbarFrame.minY, width: separatorWidth, height: toolbarFrame.height)
    }

    static func frame(for action: OverlayAction, toolbarFrame: CGRect) -> CGRect? {
        guard let index = items.firstIndex(of: .action(action)) else { return nil }
        return itemFrame(at: index, toolbarFrame: toolbarFrame)
    }
}

struct StylePaletteLayout {
    static func size(for tool: CaptureTool) -> CGSize {
        switch tool {
        case .emoji: CGSize(width: 466, height: 472)
        case .mosaic: CGSize(width: 164, height: 36)
        default: CGSize(width: 314, height: 36)
        }
    }
}

final class CaptureEditorState {
    var selection: CGRect?
    var hoveredWindow: WindowCandidate?
    var tool: CaptureTool = .selection
    var style = EditorStyle()
    var annotations: [AppAnnotation] = []
    var scrolling = false
    var transientMessage: String?
    var canUndo: Bool { !annotations.isEmpty }

    func undo() {
        if !annotations.isEmpty { annotations.removeLast() }
    }
}

enum ImageComposer {
    static func compose(base: CGImage, viewBounds: CGRect, selection: CGRect, annotations: [AppAnnotation]) -> CGImage? {
        let normalized = selection.standardized.intersection(viewBounds)
        guard normalized.width >= 1, normalized.height >= 1 else { return nil }
        let scaleX = CGFloat(base.width) / viewBounds.width
        let scaleY = CGFloat(base.height) / viewBounds.height
        let pixelsWide = max(1, Int((normalized.width * scaleX).rounded()))
        let pixelsHigh = max(1, Int((normalized.height * scaleY).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = normalized.size
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.translateBy(x: -normalized.minX, y: -normalized.minY)
        NSImage(cgImage: base, size: viewBounds.size).draw(in: viewBounds, from: .zero, operation: .copy, fraction: 1)
        for annotation in annotations {
            draw(annotation, base: base, viewBounds: viewBounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    static func draw(_ annotation: AppAnnotation, base: CGImage, viewBounds: CGRect) {
        switch annotation {
        case .rectangle(let rect, let color, let width):
            color.setStroke()
            let path = NSBezierPath(rect: rect.standardized)
            path.lineWidth = width
            path.stroke()
        case .ellipse(let rect, let color, let width):
            color.setStroke()
            let path = NSBezierPath(ovalIn: rect.standardized)
            path.lineWidth = width
            path.stroke()
        case .arrow(let start, let end, let color, let width):
            drawArrow(from: start, to: end, color: color, width: width)
        case .pen(let points, let color, let width):
            guard let first = points.first else { return }
            color.setStroke()
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = width
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            path.stroke()
        case .text(let point, let text, let color, let fontSize):
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .strokeColor: NSColor.black.withAlphaComponent(0.16),
                .strokeWidth: -1.0,
            ]
            (text as NSString).draw(at: point, withAttributes: attributes)
        case .mosaic(let rect, let blockSize):
            drawMosaic(base: base, viewBounds: viewBounds, rect: rect.standardized, blockSize: blockSize)
        case .translation(let rect, let text):
            let layer = rect.standardized
            NSColor.black.withAlphaComponent(0.52).setFill()
            NSBezierPath(roundedRect: layer, xRadius: 7, yRadius: 7).fill()
            let fontSize = min(24, max(14, layer.width / 36))
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            ]
            (text as NSString).draw(
                with: layer.insetBy(dx: 14, dy: 14),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
        }
    }

    static func drawArrow(from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat) {
        color.setStroke()
        color.setFill()
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineWidth = width
        path.move(to: start)
        path.line(to: end)
        path.stroke()
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(9, width * 3.5)
        let wing = CGFloat.pi / 7
        let p1 = CGPoint(x: end.x - cos(angle - wing) * length, y: end.y - sin(angle - wing) * length)
        let p2 = CGPoint(x: end.x - cos(angle + wing) * length, y: end.y - sin(angle + wing) * length)
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: p1)
        head.line(to: p2)
        head.close()
        head.fill()
    }

    static func drawMosaic(base: CGImage, viewBounds: CGRect, rect: CGRect, blockSize: CGFloat) {
        guard rect.width > 1, rect.height > 1 else { return }
        let image = NSImage(cgImage: base, size: viewBounds.size)
        let sourceRect = rect.offsetBy(dx: -viewBounds.minX, dy: -viewBounds.minY)
        let smallWidth = max(1, Int(rect.width / max(3, blockSize)))
        let smallHeight = max(1, Int(rect.height / max(3, blockSize)))
        guard let tiny = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: smallWidth,
            pixelsHigh: smallHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let tinyContext = NSGraphicsContext(bitmapImageRep: tiny) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = tinyContext
        tinyContext.imageInterpolation = .medium
        image.draw(
            in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight),
            from: sourceRect,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let pixelated = tiny.cgImage else { return }
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: pixelated, size: rect.size).draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}

extension CGRect {
    static func from(_ first: CGPoint, _ second: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }
}
