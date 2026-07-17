import AppKit
import CoreGraphics
import Foundation

/// Deterministic renderer shared by preview export and final clipboard output.
/// The selection and every annotation use full-image, top-left-origin pixels.
public enum ImageRenderer {
    public static func compose(
        base: CGImage,
        selection: SelectionGeometry,
        annotations: [Annotation]
    ) -> CGImage? {
        compose(base: base, selection: selection.rect, annotations: annotations)
    }

    /// Crops `base` to `selection` and composites annotations in array order.
    /// The returned image has one output pixel per source image pixel.
    public static func compose(
        base: CGImage,
        selection: CGRect,
        annotations: [Annotation]
    ) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let requested = selection.standardized.intersection(imageBounds)
        guard !requested.isNull, requested.width > 0, requested.height > 0 else { return nil }

        let crop = pixelAligned(requested).intersection(imageBounds)
        guard !crop.isNull,
              let croppedBase = base.cropping(to: crop),
              croppedBase.width > 0,
              croppedBase.height > 0,
              let context = bitmapContext(width: croppedBase.width, height: croppedBase.height)
        else { return nil }

        let outputBounds = CGRect(x: 0, y: 0, width: croppedBase.width, height: croppedBase.height)
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(croppedBase, in: outputBounds)
        context.setBlendMode(.normal)
        context.setShouldAntialias(true)

        // Change vector user space to absolute top-left-origin image pixels.
        context.saveGState()
        context.translateBy(x: 0, y: outputBounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        context.clip(to: crop)

        for annotation in annotations {
            draw(annotation.normalized, in: context, crop: crop)
        }
        context.restoreGState()
        return context.makeImage()
    }

    private static func draw(_ annotation: Annotation, in context: CGContext, crop: CGRect) {
        switch annotation {
        case .rectangle(let rect, let color, let lineWidth):
            configureStroke(context, color: color, lineWidth: lineWidth)
            context.stroke(rect.standardized)

        case .ellipse(let rect, let color, let lineWidth):
            configureStroke(context, color: color, lineWidth: lineWidth)
            context.strokeEllipse(in: rect.standardized)

        case .arrow(let start, let end, let color, let lineWidth):
            drawArrow(from: start, to: end, color: color, lineWidth: lineWidth, in: context)

        case .pen(let points, let color, let lineWidth):
            drawPen(points, color: color, lineWidth: lineWidth, in: context)

        case .mosaic(let rect, let blockSize):
            drawMosaic(rect: rect.standardized, blockSize: blockSize, in: context, crop: crop)

        case .text(let origin, let text, let color, let fontSize):
            drawText(text, at: origin, color: color, fontSize: fontSize, in: context)
        }
    }

    private static func configureStroke(
        _ context: CGContext,
        color: RGBAColor,
        lineWidth: CGFloat
    ) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(validLineWidth(lineWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)
    }

    private static func drawPen(
        _ points: [CGPoint],
        color: RGBAColor,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        guard let first = points.first else { return }
        let width = validLineWidth(lineWidth)
        if points.count == 1 {
            context.setFillColor(color.cgColor)
            context.fillEllipse(
                in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)
            )
            return
        }
        configureStroke(context, color: color, lineWidth: width)
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: RGBAColor,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        let width = validLineWidth(lineWidth)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else {
            context.setFillColor(color.cgColor)
            context.fillEllipse(
                in: CGRect(x: end.x - width / 2, y: end.y - width / 2, width: width, height: width)
            )
            return
        }

        configureStroke(context, color: color, lineWidth: width)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let unitX = dx / length
        let unitY = dy / length
        let headLength = min(length, max(10, width * 4.5))
        let halfWidth = max(4, headLength * 0.42)
        let base = CGPoint(x: end.x - unitX * headLength, y: end.y - unitY * headLength)
        let perpendicularX = -unitY
        let perpendicularY = unitX
        let left = CGPoint(
            x: base.x + perpendicularX * halfWidth,
            y: base.y + perpendicularY * halfWidth
        )
        let right = CGPoint(
            x: base.x - perpendicularX * halfWidth,
            y: base.y - perpendicularY * halfWidth
        )

        context.setFillColor(color.cgColor)
        context.beginPath()
        context.move(to: end)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }

    private static func drawText(
        _ text: String,
        at origin: CGPoint,
        color: RGBAColor,
        fontSize: CGFloat,
        in context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let size = fontSize.isFinite ? max(1, fontSize) : 14
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color.nsColor,
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Pixelates what has already been composited, so annotation array order is
    /// respected just like the other tools.
    private static func drawMosaic(
        rect: CGRect,
        blockSize: CGFloat,
        in context: CGContext,
        crop: CGRect
    ) {
        let affected = pixelAligned(rect.intersection(crop)).intersection(crop)
        guard !affected.isNull, affected.width > 0, affected.height > 0,
              let currentOutput = context.makeImage()
        else { return }

        let local = CGRect(
            x: affected.minX - crop.minX,
            y: affected.minY - crop.minY,
            width: affected.width,
            height: affected.height
        )
        guard let patch = currentOutput.cropping(to: local) else { return }
        let block = blockSize.isFinite ? max(2, blockSize) : 10
        let tinyWidth = max(1, Int(ceil(affected.width / block)))
        let tinyHeight = max(1, Int(ceil(affected.height / block)))
        guard let tinyContext = bitmapContext(width: tinyWidth, height: tinyHeight) else { return }
        tinyContext.interpolationQuality = .medium
        tinyContext.draw(
            patch,
            in: CGRect(x: 0, y: 0, width: tinyWidth, height: tinyHeight)
        )
        guard let tinyImage = tinyContext.makeImage() else { return }

        context.saveGState()
        context.interpolationQuality = .none
        // The patch was sampled from the current destination. Replacing those
        // pixels preserves alpha; normal blending would composite the patch over
        // itself and make translucent pixels progressively more opaque.
        context.setBlendMode(.copy)
        drawImageTopLeft(tinyImage, in: affected, context: context)
        context.restoreGState()
    }

    /// Draws an image right-side-up while the context's user space points down.
    private static func drawImageTopLeft(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func pixelAligned(_ rect: CGRect) -> CGRect {
        guard !rect.isNull, !rect.isInfinite else { return .null }
        return CGRect(
            x: floor(rect.minX),
            y: floor(rect.minY),
            width: ceil(rect.maxX) - floor(rect.minX),
            height: ceil(rect.maxY) - floor(rect.minY)
        )
    }

    private static func validLineWidth(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0.5, value) : 3
    }
}
