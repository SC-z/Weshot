import AppKit
import CoreGraphics

@MainActor
final class OverlayWindowController: NSWindowController {
    let snapshot: ScreenSnapshot
    weak var coordinator: CaptureCoordinator?
    private(set) var overlayView: OverlayView!

    var editorSelection: CGRect? { overlayView.state.selection }

    init(snapshot: ScreenSnapshot, coordinator: CaptureCoordinator) {
        self.snapshot = snapshot
        self.coordinator = coordinator
        let panel = OverlayPanel(contentRect: snapshot.screen.frame)
        super.init(window: panel)
        overlayView = OverlayView(frame: CGRect(origin: .zero, size: snapshot.screen.frame.size), snapshot: snapshot, controller: self)
        panel.contentView = overlayView
        panel.initialFirstResponder = overlayView
        panel.acceptsMouseMovedEvents = true
        panel.setFrame(snapshot.screen.frame, display: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(overlayView)
    }

    func configureFixtureSelection() { overlayView.configureFixtureSelection() }
    func deactivateSelection() { overlayView.deactivateSelection() }
    func composedImage() -> CGImage? { overlayView.composedImage() }
    func showTransientMessage(_ message: String) { overlayView.showTransientMessage(message) }
    func addPrivacyMosaics(_ rects: [CGRect]) { overlayView.addPrivacyMosaics(rects) }
    func setTranslationOverlay(_ text: String) { overlayView.setTranslationOverlay(text) }
    func beginScrollMode() -> Bool { overlayView.beginScrollMode() }
    func endScrollMode(with image: CGImage?) { overlayView.endScrollMode(with: image) }
    var scrollFramesForCompletion: [CGImage] { overlayView.scrollFramesForCompletion }
    var scrollFrameCount: Int { overlayView.scrollFrameCount }
    var canCaptureAnotherScrollFrame: Bool { overlayView.canCaptureAnotherScrollFrame }
    func discardLastScrollFrame() { overlayView.discardLastScrollFrame() }
    @discardableResult
    func scrollCaptureDidFinish(_ image: CGImage?, error: Error?) -> Bool {
        overlayView.scrollCaptureDidFinish(image, error: error)
    }
}

final class OverlayPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private enum EditorInteraction {
    case none
    case selecting(start: CGPoint)
    case moving(start: CGPoint, original: CGRect)
    case resizing(anchor: ResizeAnchor, start: CGPoint, original: CGRect)
    case annotating(start: CGPoint, current: CGPoint, points: [CGPoint])
}

@MainActor
final class OverlayView: NSView, NSTextFieldDelegate {
    let snapshot: ScreenSnapshot
    unowned let controller: OverlayWindowController
    let state = CaptureEditorState()
    private var interaction: EditorInteraction = .none
    private var cursorPoint: CGPoint = .zero
    private var trackingArea: NSTrackingArea?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var messageExpiry: Date?
    private var messageTimer: Timer?
    private var scrollFrames: [CGImage] = []
    private var scrollFrameSignatures: [UInt64] = []
    private var stitchedImage: CGImage?
    private var isCapturingScrollFrame = false
    private var scrollCapturedBytes = 0
    private var scrollFrameLimitReached = false

    private static let maximumScrollFrames = 40
    private static let maximumScrollBytes = 256 * 1_024 * 1_024
    private static let emojiChoices = Array(
        "😀 😃 😄 😁 😆 😅 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 ☺️ 😚 😋 😛 😜 🤪 🤨 🧐 🤓 😎 🥳 😏 😒 😞 😔 😟 😕 🙁 ☹️ 😣 😖 😫 😩 🥺 😢 😭 😤 😠 😡 🤬 🤯 😳 🥵 🥶 😱 😨 😰 😥 😓 🤗 🤔 🫣 🤭 🫢 🤫 🤥 😶 😐 😑 😬 🙄 😯 😦 😧 😮 😲 🥱 😴 🤤 😪 😵 🤐 🤢 🤮 🤧 😷 🤒 🤕".split(separator: " ").map(String.init).prefix(90)
    )

    private let accent = NSColor(calibratedRed: 88 / 255, green: 192 / 255, blue: 125 / 255, alpha: 1)
    private let toolbarBackground = NSColor(calibratedWhite: 250 / 255, alpha: 1)
    private let toolbarInk = NSColor(calibratedWhite: 24 / 255, alpha: 1)
    private let dimColor = NSColor(calibratedWhite: 0, alpha: 0.53)

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame frameRect: NSRect, snapshot: ScreenSnapshot, controller: OverlayWindowController) {
        self.snapshot = snapshot
        self.controller = controller
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: snapshot.image, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1)

        if let stitchedImage, let selection = state.selection {
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
            selection.fill()
            NSImage(cgImage: stitchedImage, size: selection.size).draw(
                in: selection,
                from: .zero,
                operation: .copy,
                fraction: 1
            )
        }

        if state.scrolling {
            drawScrollInstruction()
            return
        }

        drawDimming(excluding: state.selection)

        if let selection = state.selection {
            drawAnnotations()
            drawSelection(selection, showsResizeHandles: stitchedImage == nil)
            drawSizeLabel(for: selection)
            drawToolbar(for: selection)
        }

        drawDraftAnnotation()
        if state.selection == nil || isSelecting {
            drawMagnifier(at: cursorPoint)
        }
        drawTransientMessage()
    }

    private var isSelecting: Bool {
        if case .selecting = interaction { return true }
        return false
    }

    private func drawDimming(excluding rect: CGRect?) {
        dimColor.setFill()
        guard let rect else {
            bounds.fill()
            return
        }
        let path = NSBezierPath(rect: bounds)
        path.appendRect(rect.intersection(bounds))
        path.windingRule = .evenOdd
        path.fill()
    }

    private func drawSelection(_ rect: CGRect, showsResizeHandles: Bool) {
        accent.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 2
        border.stroke()
        guard showsResizeHandles else { return }
        for anchor in ResizeAnchor.allCases {
            let point = anchor.point(in: rect)
            accent.setFill()
            CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7).fill()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text: String
        if let stitchedImage {
            text = "\(stitchedImage.width) x \(stitchedImage.height)"
        } else {
            let scaleX = CGFloat(snapshot.image.width) / bounds.width
            let scaleY = CGFloat(snapshot.image.height) / bounds.height
            text = "\(Int((rect.width * scaleX).rounded())) x \(Int((rect.height * scaleY).rounded()))"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var origin = CGPoint(x: rect.minX + 5, y: rect.maxY + 6)
        if origin.y + size.height > bounds.maxY { origin.y = rect.maxY - size.height - 7 }
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func drawToolbar(for selection: CGRect) {
        let frame = ToolbarLayout.frame(for: selection, in: bounds)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        toolbarBackground.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
        outline.lineWidth = 1
        outline.stroke()

        for (index, item) in ToolbarLayout.items.enumerated() {
            let itemFrame = ToolbarLayout.itemFrame(at: index, toolbarFrame: frame)
            let isSelected: Bool
            if case .tool(let tool) = item, state.tool == tool {
                isSelected = true
                NSColor(calibratedWhite: 224 / 255, alpha: 1).setFill()
                NSBezierPath(
                    roundedRect: CGRect(x: itemFrame.midX - 12, y: itemFrame.midY - 12, width: 24, height: 24),
                    xRadius: 4,
                    yRadius: 4
                ).fill()
            } else { isSelected = false }
            let tint: NSColor
            if case .action(.undo) = item, !state.canUndo {
                tint = NSColor(calibratedWhite: 0.66, alpha: 1)
            } else if case .action(.cancel) = item {
                tint = NSColor(calibratedRed: 1, green: 77 / 255, blue: 79 / 255, alpha: 1)
            } else if case .action(.finish) = item {
                tint = accent
            } else if isSelected {
                tint = accent
            } else {
                tint = toolbarInk
            }
            drawSymbol(item.symbolName, in: itemFrame, tint: tint, accessibilityName: item.accessibilityName)
            if let separatorFrame = ToolbarLayout.separatorFrame(after: index, toolbarFrame: frame) {
                NSColor(calibratedWhite: 0.88, alpha: 1).setStroke()
                let separator = NSBezierPath()
                separator.move(to: CGPoint(x: separatorFrame.midX, y: separatorFrame.minY + 14))
                separator.line(to: CGPoint(x: separatorFrame.midX, y: separatorFrame.maxY - 14))
                separator.stroke()
            }
        }
        if state.tool != .selection { drawStylePalette(near: frame) }
    }

    private func stylePaletteFrame(near toolbar: CGRect) -> CGRect {
        let size = StylePaletteLayout.size(for: state.tool)
        let selectedIndex = ToolbarLayout.items.firstIndex(of: .tool(state.tool)) ?? 0
        let anchorX = ToolbarLayout.itemFrame(at: selectedIndex, toolbarFrame: toolbar).midX
        let proposedX = state.tool == .rectangle
            ? toolbar.minX
            : anchorX - size.width / 2
        let x = min(max(bounds.minX + 8, proposedX), bounds.maxX - size.width - 8)
        let below = toolbar.minY - 8 - size.height
        let y = below >= 8 ? below : min(toolbar.maxY + 8, bounds.maxY - size.height - 8)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func drawStylePalette(near toolbar: CGRect) {
        let frame = stylePaletteFrame(near: toolbar)
        drawPaletteBackground(frame, toolbar: toolbar)
        if state.tool == .emoji {
            drawEmojiPalette(in: frame)
            return
        }
        if state.tool == .mosaic {
            drawMosaicPalette(in: frame)
            return
        }
        drawStrokePalette(in: frame)
    }

    private func drawPaletteBackground(_ frame: CGRect, toolbar: CGRect) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -3)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        toolbarBackground.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
        let toolIndex = ToolbarLayout.items.firstIndex(of: .tool(state.tool)) ?? 0
        let anchorX = ToolbarLayout.itemFrame(at: toolIndex, toolbarFrame: toolbar).midX
        let clampedX = min(max(anchorX, frame.minX + 12), frame.maxX - 12)
        let arrow = NSBezierPath()
        if frame.maxY <= toolbar.minY {
            arrow.move(to: CGPoint(x: clampedX - 8, y: frame.maxY))
            arrow.line(to: CGPoint(x: clampedX, y: frame.maxY + 8))
            arrow.line(to: CGPoint(x: clampedX + 8, y: frame.maxY))
        } else {
            arrow.move(to: CGPoint(x: clampedX - 8, y: frame.minY))
            arrow.line(to: CGPoint(x: clampedX, y: frame.minY - 8))
            arrow.line(to: CGPoint(x: clampedX + 8, y: frame.minY))
        }
        arrow.close()
        arrow.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
        outline.lineWidth = 1
        outline.stroke()
    }

    private func drawEmojiPalette(in frame: CGRect) {
        ("所有表情" as NSString).draw(
            at: CGPoint(x: frame.minX + 22, y: frame.maxY - 37),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1),
            ]
        )
        let emojiFont = NSFont(name: "Apple Color Emoji", size: 23) ?? NSFont.systemFont(ofSize: 23)
        for (index, emoji) in Self.emojiChoices.enumerated() {
            let column = index % 10
            let row = index / 10
            let itemFrame = CGRect(
                x: frame.minX + 20 + CGFloat(column) * 44,
                y: frame.maxY - 88 - CGFloat(row) * 44,
                width: 36,
                height: 36
            )
            if emoji == state.style.emoji {
                NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
                NSBezierPath(roundedRect: itemFrame, xRadius: 5, yRadius: 5).fill()
            }
            (emoji as NSString).draw(
                at: CGPoint(x: itemFrame.midX - 13, y: itemFrame.midY - 14),
                withAttributes: [.font: emojiFont]
            )
        }
        NSColor(calibratedWhite: 0.9, alpha: 1).setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: frame.minX, y: frame.minY + 48))
        divider.line(to: CGPoint(x: frame.maxX, y: frame.minY + 48))
        divider.stroke()
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: frame.minX + 20, y: frame.minY + 8, width: 32, height: 32), xRadius: 4, yRadius: 4).fill()
        drawSymbol("face.smiling", in: CGRect(x: frame.minX + 20, y: frame.minY + 8, width: 32, height: 32), tint: toolbarInk, accessibilityName: "表情")
        drawSymbol("heart", in: CGRect(x: frame.minX + 66, y: frame.minY + 8, width: 32, height: 32), tint: toolbarInk, accessibilityName: "收藏")
    }

    private func drawMosaicPalette(in frame: CGRect) {
        let blockSizes: [CGFloat] = [8, 12, 18]
        for (index, blockSize) in blockSizes.enumerated() {
            let center = CGPoint(x: frame.minX + 18 + CGFloat(index) * 22, y: frame.midY)
            let side = CGFloat(4 + index * 3)
            (abs(state.style.mosaicBlockSize - blockSize) < 0.1 ? accent : NSColor(calibratedWhite: 0.7, alpha: 1)).setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)).fill()
        }
        NSColor(calibratedWhite: 0.87, alpha: 1).setStroke()
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: frame.minX + 82, y: frame.minY + 9))
        separator.line(to: CGPoint(x: frame.minX + 82, y: frame.maxY - 9))
        separator.stroke()
        drawSymbol(
            "viewfinder",
            in: CGRect(x: frame.minX + 90, y: frame.minY, width: 28, height: frame.height),
            tint: toolbarInk,
            accessibilityName: "一键打码"
        )
        ("一键打码" as NSString).draw(
            at: CGPoint(x: frame.minX + 116, y: frame.minY + 10),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: toolbarInk,
            ]
        )
    }

    private func drawStrokePalette(in frame: CGRect) {
        let widths: [CGFloat] = [2, 4, 7]
        for (index, width) in widths.enumerated() {
            let center = CGPoint(x: frame.minX + 20 + CGFloat(index) * 26, y: frame.midY)
            (abs(state.style.lineWidth - width) < 0.1 ? accent : NSColor(calibratedWhite: 0.7, alpha: 1)).setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - width / 2, y: center.y - width / 2, width: width, height: width)).fill()
        }
        NSColor(calibratedWhite: 0.87, alpha: 1).setStroke()
        for x in [frame.minX + 104, frame.minX + 142] {
            let separator = NSBezierPath()
            separator.move(to: CGPoint(x: x, y: frame.minY + 9))
            separator.line(to: CGPoint(x: x, y: frame.maxY - 9))
            separator.stroke()
        }
        let outline = CGRect(x: frame.minX + 116, y: frame.midY - 7, width: 14, height: 14)
        NSColor(calibratedWhite: 0.57, alpha: 1).setStroke()
        let outlinePath = NSBezierPath(rect: outline)
        outlinePath.lineWidth = 2
        outlinePath.stroke()

        let colors: [NSColor] = [
            .systemBlue, .systemGreen, .systemYellow,
            NSColor(calibratedWhite: 0.3, alpha: 1), .white, .systemRed,
        ]
        for (index, color) in colors.enumerated() {
            let center = CGPoint(x: frame.minX + 158 + CGFloat(index) * 28, y: frame.midY)
            let swatch = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
            color.setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 1.5, yRadius: 1.5).fill()
            if colorsEqual(color, state.style.color) {
                NSColor(calibratedWhite: 0.88, alpha: 1).setStroke()
                let ring = NSBezierPath(roundedRect: swatch.insetBy(dx: -3, dy: -3), xRadius: 3, yRadius: 3)
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }

    private func drawSymbol(_ symbol: String, in frame: CGRect, tint: NSColor, accessibilityName: String) {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityName) else {
            let fallback = String(accessibilityName.prefix(1))
            (fallback as NSString).draw(at: CGPoint(x: frame.midX - 6, y: frame.midY - 8), withAttributes: [
                .foregroundColor: tint,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ])
            return
        }
        let pointConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [tint])
        let sizedImage = image.withSymbolConfiguration(pointConfiguration)
        let configured = sizedImage?.withSymbolConfiguration(colorConfiguration) ?? sizedImage ?? image
        configured.isTemplate = false
        let size = configured.size
        let destination = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        configured.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func drawAnnotations() {
        let base = stitchedImage ?? snapshot.image
        let baseBounds = stitchedImage == nil ? bounds : (state.selection ?? bounds)
        for annotation in state.annotations {
            ImageComposer.draw(annotation, base: base, viewBounds: baseBounds)
        }
    }

    private func drawDraftAnnotation() {
        guard case .annotating(let start, let current, let points) = interaction else { return }
        let draft: AppAnnotation?
        switch state.tool {
        case .rectangle: draft = .rectangle(.from(start, current), state.style.color, state.style.lineWidth)
        case .ellipse: draft = .ellipse(.from(start, current), state.style.color, state.style.lineWidth)
        case .arrow: draft = .arrow(start, current, state.style.color, state.style.lineWidth)
        case .pen: draft = .pen(points, state.style.color, state.style.lineWidth)
        case .mosaic: draft = .mosaic(.from(start, current), state.style.mosaicBlockSize)
        default: draft = nil
        }
        if let draft {
            let base = stitchedImage ?? snapshot.image
            let baseBounds = stitchedImage == nil ? bounds : (state.selection ?? bounds)
            ImageComposer.draw(draft, base: base, viewBounds: baseBounds)
        }
    }

    private func drawMagnifier(at point: CGPoint) {
        guard bounds.contains(point), point != .zero else { return }
        let bubbleSize = CGSize(width: 116, height: 88)
        var origin = CGPoint(x: point.x + 18, y: point.y - bubbleSize.height - 18)
        if origin.x + bubbleSize.width > bounds.maxX { origin.x = point.x - bubbleSize.width - 18 }
        if origin.y < bounds.minY { origin.y = point.y + 18 }
        let bubble = CGRect(origin: origin, size: bubbleSize)
        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 6, yRadius: 6).fill()
        let preview = CGRect(x: bubble.minX + 5, y: bubble.minY + 23, width: bubble.width - 10, height: bubble.height - 28)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: preview, xRadius: 3, yRadius: 3).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        let source = CGRect(x: point.x - 7, y: point.y - 4, width: 14, height: 8)
        NSImage(cgImage: snapshot.image, size: bounds.size).draw(in: preview, from: source, operation: .copy, fraction: 1)
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: preview.midX, y: preview.minY))
        cross.line(to: CGPoint(x: preview.midX, y: preview.maxY))
        cross.move(to: CGPoint(x: preview.minX, y: preview.midY))
        cross.line(to: CGPoint(x: preview.maxX, y: preview.midY))
        cross.lineWidth = 0.5
        cross.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let color = sampledColor(at: point)
        let rgb = String(
            format: "RGB %d %d %d   #%02X%02X%02X",
            color.red,
            color.green,
            color.blue,
            color.red,
            color.green,
            color.blue
        )
        (rgb as NSString).draw(at: CGPoint(x: bubble.minX + 7, y: bubble.minY + 5), withAttributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
        ])
    }

    private func sampledColor(at point: CGPoint) -> PixelRGB {
        let image = stitchedImage ?? snapshot.image
        let imageRect = stitchedImage == nil ? bounds : (state.selection ?? bounds)
        guard imageRect.width > 0, imageRect.height > 0 else {
            return PixelRGB(red: 0, green: 0, blue: 0)
        }
        let normalizedX = (point.x - imageRect.minX) / imageRect.width
        let normalizedY = (imageRect.maxY - point.y) / imageRect.height
        let x = Int(normalizedX * CGFloat(image.width))
        let y = Int(normalizedY * CGFloat(image.height))
        return PixelSampler.rgb(in: image, x: x, y: y) ?? PixelRGB(red: 0, green: 0, blue: 0)
    }

    private func drawScrollInstruction() {
        let text = "滚动页面截取更多内容"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ]
        (text as NSString).draw(at: CGPoint(x: bounds.minX + 8, y: bounds.maxY - 24), withAttributes: attributes)
    }

    private func drawPill(_ text: String, at point: CGPoint, fontSize: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let frame = CGRect(origin: point, size: CGSize(width: size.width + 12, height: size.height + 6))
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: frame.minX + 6, y: frame.minY + 3), withAttributes: attributes)
    }

    private func drawTransientMessage() {
        guard let message = state.transientMessage else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        let frame = CGRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY + 52, width: size.width + 32, height: 38)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
        (message as NSString).draw(at: CGPoint(x: frame.minX + 16, y: frame.minY + 11), withAttributes: attributes)
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        if state.selection != nil { updateCursor(at: cursorPoint) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point

        if let selection = state.selection {
            if event.clickCount == 2, selection.contains(point), state.tool == .selection {
                controller.coordinator?.finishCapture(from: controller)
                return
            }
            let toolbar = ToolbarLayout.frame(for: selection, in: bounds)
            if let item = ToolbarLayout.item(at: point, toolbarFrame: toolbar) {
                handleToolbarItem(item)
                return
            }
            if state.tool != .selection, handleStylePaletteClick(point, toolbar: toolbar) { return }
            if stitchedImage == nil, let anchor = resizeAnchor(at: point, rect: selection) {
                interaction = .resizing(anchor: anchor, start: point, original: selection)
                return
            }
            if selection.contains(point), state.tool != .selection {
                if state.tool == .text {
                    beginTextEditing(at: point)
                } else if state.tool == .emoji {
                    state.annotations.append(
                        .text(
                            CGPoint(x: point.x - 15, y: point.y - 15),
                            state.style.emoji,
                            .white,
                            30
                        )
                    )
                    showTransientMessage("已添加表情")
                } else {
                    interaction = .annotating(start: point, current: point, points: [point])
                }
                return
            }
            if selection.contains(point) {
                interaction = .moving(start: point, original: selection)
                return
            }
            // A stitched long image is a complete document, not a new desktop
            // selection. Clicking outside its preview must not silently replace
            // the preview while retaining the old export buffer.
            if stitchedImage != nil { return }
        }
        controller.coordinator?.overlayBecameActive(controller)
        interaction = .selecting(start: point)
        state.selection = nil
        state.annotations.removeAll()
        state.tool = .selection
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = bounded(convert(event.locationInWindow, from: nil))
        cursorPoint = point
        switch interaction {
        case .none: break
        case .selecting(let start):
            state.selection = CGRect.from(start, point).intersection(bounds)
        case .moving(let start, let original):
            var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            if moved.minX < bounds.minX { moved.origin.x = bounds.minX }
            if moved.maxX > bounds.maxX { moved.origin.x = bounds.maxX - moved.width }
            if moved.minY < bounds.minY { moved.origin.y = bounds.minY }
            if moved.maxY > bounds.maxY { moved.origin.y = bounds.maxY - moved.height }
            let delta = CGSize(width: moved.minX - original.minX, height: moved.minY - original.minY)
            state.selection = moved
            if delta != .zero {
                state.annotations = state.annotations.map { shifted($0, by: delta) }
            }
            interaction = .moving(start: point, original: moved)
        case .resizing(let anchor, let start, let original):
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            state.selection = anchor.resized(original, translation: delta, inside: bounds)
        case .annotating(let start, _, var points):
            if state.tool == .pen { points.append(point) }
            interaction = .annotating(start: start, current: point, points: points)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = bounded(convert(event.locationInWindow, from: nil))
        switch interaction {
        case .annotating(let start, _, let points):
            appendAnnotation(from: start, to: point, points: points)
        case .selecting:
            if let selection = state.selection, selection.width < 2 || selection.height < 2 { state.selection = nil }
        default: break
        }
        interaction = .none
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard state.scrolling else {
            super.scrollWheel(with: event)
            return
        }
        requestScrollFrame(forwarding: event.cgEvent?.copy())
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if command, event.charactersIgnoringModifiers?.lowercased() == "z" {
            state.undo()
            needsDisplay = true
            return
        }
        if !command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            let color = sampledColor(at: cursorPoint)
            let value = String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            showTransientMessage("已复制色值 \(value)")
            return
        }
        switch event.keyCode {
        case 53: // Esc
            if textField != nil { cancelTextEditing() }
            else if state.scrolling { controller.coordinator?.cancelScrollingProcessing(from: controller) }
            else { controller.coordinator?.cancelCapture() }
        case 36, 76: // Return / keypad Enter
            if state.scrolling {
                showTransientMessage("正在采集或拼接长图…")
            } else {
                controller.coordinator?.finishCapture(from: controller)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func handleToolbarItem(_ item: ToolbarItem) {
        if state.scrolling {
            if case .action(.cancel) = item {
                controller.coordinator?.cancelScrollingProcessing(from: controller)
            } else {
                showTransientMessage("正在采集或拼接长图…")
            }
            return
        }
        switch item {
        case .tool(let tool):
            state.tool = state.tool == tool ? .selection : tool
            showTransientMessage(state.tool == .selection ? "选择" : tool.accessibilityName)
        case .action(let action):
            switch action {
            case .translate: controller.coordinator?.translateText(from: controller)
            case .scroll: controller.coordinator?.beginScrolling(from: controller)
            case .undo:
                guard state.canUndo else { return }
                state.undo()
                showTransientMessage("已撤销")
            case .pin: controller.coordinator?.pinCapture(from: controller)
            case .save: controller.coordinator?.saveCapture(from: controller)
            case .cancel: controller.coordinator?.cancelCapture()
            case .finish: controller.coordinator?.finishCapture(from: controller)
            }
        }
        needsDisplay = true
    }

    private func handleStylePaletteClick(_ point: CGPoint, toolbar: CGRect) -> Bool {
        let palette = stylePaletteFrame(near: toolbar)
        guard palette.contains(point) else { return false }
        if state.tool == .emoji {
            for (index, emoji) in Self.emojiChoices.enumerated() {
                let column = index % 10
                let row = index / 10
                let itemFrame = CGRect(
                    x: palette.minX + 20 + CGFloat(column) * 44,
                    y: palette.maxY - 88 - CGFloat(row) * 44,
                    width: 36,
                    height: 36
                )
                if itemFrame.contains(point) {
                    state.style.emoji = emoji
                    needsDisplay = true
                    return true
                }
            }
            return true
        }
        if state.tool == .mosaic {
            let blockSizes: [CGFloat] = [8, 12, 18]
            for (index, blockSize) in blockSizes.enumerated() {
                let center = CGPoint(x: palette.minX + 18 + CGFloat(index) * 22, y: palette.midY)
                if hypot(point.x - center.x, point.y - center.y) <= 10 {
                    state.style.mosaicBlockSize = blockSize
                    needsDisplay = true
                    return true
                }
            }
            let aiFrame = CGRect(x: palette.minX + 88, y: palette.minY, width: 76, height: palette.height)
            if aiFrame.contains(point) {
                controller.coordinator?.redactPrivacy(from: controller)
                return true
            }
            return true
        }
        let colors: [NSColor] = [
            .systemBlue, .systemGreen, .systemYellow,
            NSColor(calibratedWhite: 0.3, alpha: 1), .white, .systemRed,
        ]
        for (index, color) in colors.enumerated() {
            let center = CGPoint(x: palette.minX + 158 + CGFloat(index) * 28, y: palette.midY)
            if hypot(point.x - center.x, point.y - center.y) <= 12 {
                state.style.color = color
                needsDisplay = true
                return true
            }
        }
        let widths: [CGFloat] = [2, 4, 7]
        for (index, width) in widths.enumerated() {
            let center = CGPoint(x: palette.minX + 20 + CGFloat(index) * 26, y: palette.midY)
            if hypot(point.x - center.x, point.y - center.y) <= 10 {
                state.style.lineWidth = width
                needsDisplay = true
                return true
            }
        }
        return true
    }

    private func appendAnnotation(from start: CGPoint, to end: CGPoint, points: [CGPoint]) {
        guard let selection = state.selection else { return }
        let clippedEnd = CGPoint(x: min(max(end.x, selection.minX), selection.maxX), y: min(max(end.y, selection.minY), selection.maxY))
        let annotation: AppAnnotation?
        switch state.tool {
        case .rectangle: annotation = .rectangle(CGRect.from(start, clippedEnd), state.style.color, state.style.lineWidth)
        case .ellipse: annotation = .ellipse(CGRect.from(start, clippedEnd), state.style.color, state.style.lineWidth)
        case .arrow: annotation = .arrow(start, clippedEnd, state.style.color, state.style.lineWidth)
        case .pen: annotation = points.count > 1 ? .pen(points.map { boundedToSelection($0) }, state.style.color, state.style.lineWidth) : nil
        case .mosaic: annotation = .mosaic(CGRect.from(start, clippedEnd), state.style.mosaicBlockSize)
        default: annotation = nil
        }
        if let annotation { state.annotations.append(annotation) }
    }

    private func beginTextEditing(at point: CGPoint) {
        commitTextEditing()
        guard let selection = state.selection else { return }
        textOrigin = point
        let field = NSTextField(frame: CGRect(x: point.x, y: max(selection.minY, point.y - 4), width: min(220, selection.maxX - point.x), height: 28))
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.76)
        field.textColor = state.style.color
        field.font = .systemFont(ofSize: max(14, state.style.lineWidth * 5), weight: .medium)
        field.focusRingType = .none
        field.placeholderString = "输入文字，按 Return 完成"
        field.delegate = self
        field.target = self
        field.action = #selector(commitTextFromField(_:))
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    @objc private func commitTextFromField(_ sender: NSTextField) { commitTextEditing() }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextEditing() }

    private func commitTextEditing() {
        guard let field = textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            state.annotations.append(.text(textOrigin, text, state.style.color, max(14, state.style.lineWidth * 5)))
        }
        field.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func cancelTextEditing() {
        textField?.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func resizeAnchor(at point: CGPoint, rect: CGRect) -> ResizeAnchor? {
        ResizeAnchor.allCases.first { anchor in
            let target = anchor.point(in: rect)
            return hypot(point.x - target.x, point.y - target.y) <= 8
        }
    }

    private func updateCursor(at point: CGPoint) {
        guard let selection = state.selection else { return }
        if stitchedImage == nil, let anchor = resizeAnchor(at: point, rect: selection) {
            switch anchor {
            case .north, .south: NSCursor.resizeUpDown.set()
            case .east, .west: NSCursor.resizeLeftRight.set()
            case .northWest, .southEast: NSCursor.crosshair.set()
            case .northEast, .southWest: NSCursor.crosshair.set()
            }
        } else if selection.contains(point) {
            state.tool == .selection ? NSCursor.openHand.set() : NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func boundedToSelection(_ point: CGPoint) -> CGPoint {
        guard let selection = state.selection else { return point }
        return CGPoint(x: min(max(point.x, selection.minX), selection.maxX), y: min(max(point.y, selection.minY), selection.maxY))
    }

    private func shifted(_ annotation: AppAnnotation, by delta: CGSize) -> AppAnnotation {
        switch annotation {
        case .rectangle(let rect, let color, let width): return .rectangle(rect.offsetBy(dx: delta.width, dy: delta.height), color, width)
        case .ellipse(let rect, let color, let width): return .ellipse(rect.offsetBy(dx: delta.width, dy: delta.height), color, width)
        case .arrow(let start, let end, let color, let width):
            return .arrow(CGPoint(x: start.x + delta.width, y: start.y + delta.height), CGPoint(x: end.x + delta.width, y: end.y + delta.height), color, width)
        case .pen(let points, let color, let width):
            return .pen(points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }, color, width)
        case .text(let point, let text, let color, let size):
            return .text(CGPoint(x: point.x + delta.width, y: point.y + delta.height), text, color, size)
        case .mosaic(let rect, let block): return .mosaic(rect.offsetBy(dx: delta.width, dy: delta.height), block)
        case .translation(let rect, let text):
            return .translation(rect.offsetBy(dx: delta.width, dy: delta.height), text)
        }
    }

    private func colorsEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.deviceRGB), let right = rhs.usingColorSpace(.deviceRGB) else { return lhs == rhs }
        return abs(left.redComponent - right.redComponent) < 0.01 &&
            abs(left.greenComponent - right.greenComponent) < 0.01 &&
            abs(left.blueComponent - right.blueComponent) < 0.01
    }

    func configureFixtureSelection() {
        stitchedImage = nil
        let selection = CGRect(x: bounds.width * 0.16, y: bounds.height * 0.18, width: bounds.width * 0.68, height: bounds.height * 0.62)
        state.selection = selection
        state.tool = .rectangle
        state.annotations = [
            .rectangle(CGRect(x: selection.minX + 40, y: selection.maxY - 120, width: 170, height: 70), .systemRed, 3),
            .ellipse(CGRect(x: selection.midX - 55, y: selection.midY - 35, width: 110, height: 70), .systemOrange, 4),
            .arrow(CGPoint(x: selection.minX + 55, y: selection.minY + 80), CGPoint(x: selection.midX, y: selection.midY), .systemGreen, 4),
            .pen([
                CGPoint(x: selection.midX + 80, y: selection.minY + 60),
                CGPoint(x: selection.midX + 105, y: selection.minY + 92),
                CGPoint(x: selection.midX + 130, y: selection.minY + 70),
                CGPoint(x: selection.midX + 165, y: selection.minY + 115),
            ], .systemBlue, 4),
            .text(CGPoint(x: selection.minX + 40, y: selection.minY + 30), "WeShot · 本地截图", .white, 18),
            .text(CGPoint(x: selection.midX + 210, y: selection.minY + 32), "🎉", .white, 30),
            .mosaic(CGRect(x: selection.maxX - 150, y: selection.maxY - 95, width: 110, height: 46), 10),
        ]
        cursorPoint = CGPoint(x: selection.maxX - 28, y: selection.maxY - 28)
        interaction = .selecting(start: cursorPoint)
        needsDisplay = true
        displayIfNeeded()
    }

    func deactivateSelection() {
        stitchedImage = nil
        state.selection = nil
        state.annotations.removeAll()
        state.tool = .selection
        needsDisplay = true
    }

    func composedImage() -> CGImage? {
        guard let selection = state.selection else { return nil }
        if let stitchedImage {
            return ImageComposer.compose(
                base: stitchedImage,
                viewBounds: selection,
                selection: selection,
                annotations: state.annotations
            )
        }
        return ImageComposer.compose(base: snapshot.image, viewBounds: bounds, selection: selection, annotations: state.annotations)
    }

    func showTransientMessage(_ message: String) {
        state.transientMessage = message
        messageExpiry = Date().addingTimeInterval(2.2)
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 2.25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let expiry = self.messageExpiry, expiry <= Date() else { return }
                self.state.transientMessage = nil
                self.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    func addPrivacyMosaics(_ rects: [CGRect]) {
        state.annotations.append(contentsOf: rects.map { .mosaic($0, state.style.mosaicBlockSize) })
        needsDisplay = true
    }

    func setTranslationOverlay(_ text: String) {
        guard let selection = state.selection else { return }
        let translated = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { return }
        state.annotations.removeAll {
            if case .translation = $0 { return true }
            return false
        }
        state.annotations.append(.translation(selection, translated))
        state.tool = .selection
        needsDisplay = true
    }

    @discardableResult
    func beginScrollMode() -> Bool {
        guard !state.scrolling else {
            showTransientMessage("正在采集或拼接长图…")
            return false
        }
        guard stitchedImage == nil else {
            showTransientMessage("请先完成当前长图")
            return false
        }
        guard state.annotations.isEmpty else {
            showTransientMessage("请先撤销标注再开始滚动截图")
            return false
        }
        guard let selection = state.selection,
              let initial = ImageComposer.compose(base: snapshot.image, viewBounds: bounds, selection: selection, annotations: []) else { return false }
        state.scrolling = true
        scrollFrames = [initial]
        scrollFrameSignatures = [Self.scrollFrameSignature(initial)]
        scrollCapturedBytes = Self.byteCount(of: initial)
        scrollFrameLimitReached = false
        state.tool = .selection
        showTransientMessage("滚动页面开始采集")
        needsDisplay = true
        return true
    }

    private func requestScrollFrame(forwarding event: CGEvent?) {
        guard !isCapturingScrollFrame, canCaptureAnotherScrollFrame else { return }
        isCapturingScrollFrame = true
        controller.coordinator?.captureScrollFrame(from: controller, forwarding: event)
    }

    @discardableResult
    func scrollCaptureDidFinish(_ image: CGImage?, error: Error?) -> Bool {
        isCapturingScrollFrame = false
        if let image {
            let signature = Self.scrollFrameSignature(image)
            if scrollFrameSignatures.last != signature {
                let imageBytes = Self.byteCount(of: image)
                let (nextBytes, overflow) = scrollCapturedBytes.addingReportingOverflow(imageBytes)
                guard !overflow,
                      scrollFrames.count < Self.maximumScrollFrames,
                      nextBytes <= Self.maximumScrollBytes
                else {
                    scrollFrameLimitReached = true
                    showTransientMessage("已达长图采集上限，请完成拼接")
                    return false
                }
                scrollFrames.append(image)
                scrollFrameSignatures.append(signature)
                scrollCapturedBytes = nextBytes
                showTransientMessage("已采集 \(scrollFrames.count) 帧")
                return true
            }
        } else if let error {
            showTransientMessage("采集失败：\(error.localizedDescription)")
        }
        return false
    }

    func discardLastScrollFrame() {
        guard scrollFrames.count > 1 else { return }
        let removed = scrollFrames.removeLast()
        scrollFrameSignatures.removeLast()
        scrollCapturedBytes = max(0, scrollCapturedBytes - Self.byteCount(of: removed))
        scrollFrameLimitReached = false
    }

    var scrollFramesForCompletion: [CGImage] { scrollFrames }
    var scrollFrameCount: Int { scrollFrames.count }
    var canCaptureAnotherScrollFrame: Bool {
        state.scrolling &&
            !scrollFrameLimitReached &&
            scrollFrames.count < Self.maximumScrollFrames &&
            scrollCapturedBytes < Self.maximumScrollBytes
    }

    func endScrollMode(with image: CGImage?) {
        state.scrolling = false
        isCapturingScrollFrame = false
        if let image {
            stitchedImage = image
            state.annotations.removeAll()
            state.tool = .selection
            state.selection = Self.previewRect(for: image, inside: bounds)
        }
        scrollFrames.removeAll()
        scrollFrameSignatures.removeAll()
        scrollCapturedBytes = 0
        scrollFrameLimitReached = false
        needsDisplay = true
    }

    private static func byteCount(of image: CGImage) -> Int {
        let (count, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        return overflow ? Int.max : count
    }

    private static func previewRect(for image: CGImage, inside bounds: CGRect) -> CGRect {
        let available = bounds.insetBy(dx: 32, dy: 64)
        guard available.width > 0, available.height > 0, image.width > 0, image.height > 0 else {
            return bounds
        }
        let scale = min(
            available.width / CGFloat(image.width),
            available.height / CGFloat(image.height)
        )
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func scrollFrameSignature(_ image: CGImage) -> UInt64 {
        let width = 24
        let height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { storage in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels.reduce(UInt64(1_469_598_103_934_665_603)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

private extension CGRect {
    func fill() { NSBezierPath(rect: self).fill() }
}
