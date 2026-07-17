import AppKit
import CoreGraphics
import Testing
@testable import WeShotApp

@Suite("AppKit editor integration")
@MainActor
struct AppEditorIntegrationTests {
    @Test("Synthetic mouse events drive selection, move, resize, and annotation")
    func editorMouseWorkflow() throws {
        let screen = try #require(NSScreen.main)
        let size = screen.frame.size
        let snapshot = ScreenSnapshot(
            screen: screen,
            displayID: DesktopCaptureService.displayID(for: screen) ?? CGMainDisplayID(),
            image: DesktopCaptureService.fixtureImage(size: size, scale: 1)
        )
        let coordinator = CaptureCoordinator()
        let controller = OverlayWindowController(snapshot: snapshot, coordinator: coordinator)
        let view = try #require(controller.overlayView)
        let windowNumber = controller.window?.windowNumber ?? 0

        #expect(view.acceptsFirstMouse(for: nil))

        let start = CGPoint(x: size.width * 0.15, y: size.height * 0.18)
        let end = CGPoint(x: size.width * 0.68, y: size.height * 0.70)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: start, windowNumber: windowNumber))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end, windowNumber: windowNumber))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: end, windowNumber: windowNumber))

        let selected = try #require(view.state.selection)
        #expect(abs(selected.minX - start.x) < 0.5)
        #expect(abs(selected.minY - start.y) < 0.5)
        #expect(abs(selected.width - (end.x - start.x)) < 0.5)
        #expect(abs(selected.height - (end.y - start.y)) < 0.5)

        let center = CGPoint(x: selected.midX, y: selected.midY)
        let movedCenter = CGPoint(x: center.x + 24, y: center.y + 18)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: center, windowNumber: windowNumber))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: movedCenter, windowNumber: windowNumber))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: movedCenter, windowNumber: windowNumber))
        let moved = try #require(view.state.selection)
        #expect(abs(moved.minX - selected.minX - 24) < 0.5)
        #expect(abs(moved.minY - selected.minY - 18) < 0.5)

        let east = CGPoint(x: moved.maxX, y: moved.midY)
        let widerEast = CGPoint(x: east.x + 35, y: east.y)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: east, windowNumber: windowNumber))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: widerEast, windowNumber: windowNumber))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: widerEast, windowNumber: windowNumber))
        let resized = try #require(view.state.selection)
        #expect(abs(resized.width - moved.width - 35) < 0.5)

        view.state.tool = .rectangle
        let annotationStart = CGPoint(x: resized.minX + 28, y: resized.minY + 32)
        let annotationEnd = CGPoint(x: annotationStart.x + 120, y: annotationStart.y + 76)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: annotationStart, windowNumber: windowNumber))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: annotationEnd, windowNumber: windowNumber))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: annotationEnd, windowNumber: windowNumber))
        #expect(view.state.annotations.count == 1)
        guard case .rectangle(let rect, _, _) = view.state.annotations[0] else {
            Issue.record("Expected a rectangle annotation")
            return
        }
        #expect(abs(rect.width - 120) < 0.5)
        #expect(abs(rect.height - 76) < 0.5)

        view.state.tool = .emoji
        view.state.style.emoji = "🎉"
        let emojiPoint = CGPoint(x: resized.maxX - 32, y: resized.maxY - 32)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: emojiPoint, windowNumber: windowNumber))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: emojiPoint, windowNumber: windowNumber))
        #expect(view.state.annotations.count == 2)
        guard case .text(_, let emoji, _, let size) = view.state.annotations[1] else {
            Issue.record("Expected an emoji text annotation")
            return
        }
        #expect(emoji == "🎉")
        #expect(size == 30)

        let output = try #require(view.composedImage())
        #expect(output.width == Int(resized.width.rounded()))
        #expect(output.height == Int(resized.height.rounded()))
        controller.close()
    }

    @Test("Actual toolbar hit map and editor undo use the App target models")
    func toolbarAndUndo() {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let selection = CGRect(x: 320, y: 270, width: 640, height: 360)
        let toolbar = ToolbarLayout.frame(for: selection, in: bounds)
        #expect(bounds.contains(toolbar))
        #expect(ToolbarLayout.size == CGSize(width: 686, height: 48))
        #expect(ToolbarLayout.itemSize == CGSize(width: 44, height: 48))
        #expect(ToolbarLayout.horizontalPadding == 17)
        #expect(ToolbarLayout.separatorWidth == 18)
        #expect(ToolbarLayout.gap == 16)
        #expect(StylePaletteLayout.size(for: .rectangle) == CGSize(width: 314, height: 36))
        #expect(StylePaletteLayout.size(for: .mosaic) == CGSize(width: 164, height: 36))
        #expect(StylePaletteLayout.size(for: .emoji) == CGSize(width: 466, height: 472))
        #expect(
            ToolbarLayout.items.map(\.accessibilityName) == [
                "矩形", "椭圆", "表情", "箭头", "画笔", "马赛克", "文字",
                "翻译", "滚动截图",
                "撤销", "保存", "钉在桌面", "取消", "完成",
            ]
        )
        for (index, expected) in ToolbarLayout.items.enumerated() {
            let point = ToolbarLayout.itemFrame(at: index, toolbarFrame: toolbar).center
            let actual = ToolbarLayout.item(at: point, toolbarFrame: toolbar)
            #expect(actual?.accessibilityName == expected.accessibilityName)
        }
        for index in ToolbarLayout.separatorAfterIndices {
            let separator = ToolbarLayout.separatorFrame(after: index, toolbarFrame: toolbar)
            #expect(separator != nil)
            if let separator {
                #expect(ToolbarLayout.item(at: separator.center, toolbarFrame: toolbar) == nil)
            }
        }

        let state = CaptureEditorState()
        #expect(!state.canUndo)
        state.annotations = [
            .rectangle(CGRect(x: 1, y: 2, width: 30, height: 40), .systemRed, 3),
            .text(CGPoint(x: 4, y: 5), "test", .white, 14),
        ]
        #expect(state.canUndo)
        state.undo()
        #expect(state.annotations.count == 1)
    }

    @Test("Translation is composed as an undoable overlay inside the selection")
    func translationOverlay() throws {
        let screen = try #require(NSScreen.main)
        let size = screen.frame.size
        let snapshot = ScreenSnapshot(
            screen: screen,
            displayID: DesktopCaptureService.displayID(for: screen) ?? CGMainDisplayID(),
            image: DesktopCaptureService.fixtureImage(size: size, scale: 1)
        )
        let controller = OverlayWindowController(snapshot: snapshot, coordinator: CaptureCoordinator())
        let view = try #require(controller.overlayView)
        let selection = CGRect(x: 80, y: 70, width: 360, height: 180)
        view.state.selection = selection
        let before = try #require(view.composedImage())

        view.setTranslationOverlay("Translated text")

        #expect(view.state.annotations.count == 1)
        guard case .translation(let rect, let text) = view.state.annotations[0] else {
            Issue.record("Expected a translation overlay")
            return
        }
        #expect(rect == selection)
        #expect(text == "Translated text")
        let after = try #require(view.composedImage())
        #expect(before.dataProvider?.data != after.dataProvider?.data)
        view.state.undo()
        #expect(view.state.annotations.isEmpty)
        controller.close()
    }

    @Test("Custom selection starts at the pointer without window snapping")
    func customSelectionStartsAtPointer() throws {
        let screen = try #require(NSScreen.main)
        let snapshot = ScreenSnapshot(
            screen: screen,
            displayID: DesktopCaptureService.displayID(for: screen) ?? CGMainDisplayID(),
            image: DesktopCaptureService.fixtureImage(size: screen.frame.size, scale: 1)
        )
        let coordinator = CaptureCoordinator()
        let controller = OverlayWindowController(snapshot: snapshot, coordinator: coordinator)
        let view = try #require(controller.overlayView)
        let windowNumber = controller.window?.windowNumber ?? 0
        let start = CGPoint(x: 90, y: 110)
        let end = CGPoint(x: 510, y: 370)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: start, windowNumber: windowNumber))
        #expect(view.state.selection == nil)
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end, windowNumber: windowNumber))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: end, windowNumber: windowNumber))
        #expect(view.state.selection == CGRect.from(start, end))
        controller.close()
    }

    @Test("Default PNG filename is stable in a fixed time zone")
    func captureFilename() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        #expect(
            CaptureFileNamer.pngFilename(
                for: Date(timeIntervalSince1970: 0),
                timeZone: utc
            ) == "WeShot 1970-01-01 00.00.00.png"
        )
    }

    @Test("Short Han text still selects Chinese to English translation")
    func shortChineseLanguagePair() {
        let chinese = SystemTranslationController.languagePair(for: "你好")
        let english = SystemTranslationController.languagePair(for: "Hello")
        #expect(chinese.target == Locale.Language(identifier: "en"))
        #expect(english.target == Locale.Language(identifier: "zh-Hans"))
    }

    @Test("Custom hotkey validates, displays, and persists")
    func customHotKey() throws {
        let shortcut = try #require(HotKeyShortcut(
            keyCode: 1,
            modifierFlags: [.control, .shift],
            keyEquivalent: "s"
        ))
        #expect(shortcut.displayName == "⌃⇧S")
        #expect(shortcut.modifierFlags == [.control, .shift])
        #expect(HotKeyShortcut(keyCode: 1, modifierFlags: [], keyEquivalent: "s") == nil)
        #expect(HotKeyShortcut(keyCode: 1, modifierFlags: [.shift], keyEquivalent: "s") == nil)

        let suite = "WeShotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        shortcut.save(to: defaults)
        #expect(HotKeyShortcut.load(from: defaults) == shortcut)

        let recorder = HotKeyRecorderField(shortcut: .default)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40
        ))
        recorder.keyDown(with: event)
        #expect(recorder.shortcut.displayName == "⌥⌘K")
    }

    @Test("Pixel sampling normalizes RGBA and ScreenCaptureKit-style BGRA")
    func pixelSamplingNormalizesFormats() throws {
        let expected = PixelRGB(red: 214, green: 73, blue: 29)
        let rgba = try #require(makePixelImage(
            bytes: [214, 73, 29, 255],
            bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
        ))
        let bgra = try #require(makePixelImage(
            bytes: [29, 73, 214, 255],
            bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        ))

        #expect(PixelSampler.rgb(in: rgba, x: 0, y: 0) == expected)
        #expect(PixelSampler.rgb(in: bgra, x: 0, y: 0) == expected)
    }

    @Test("Stitched long images remain previewable and annotations affect export")
    func stitchedImageAnnotationWorkflow() throws {
        let screen = try #require(NSScreen.main)
        let snapshot = ScreenSnapshot(
            screen: screen,
            displayID: DesktopCaptureService.displayID(for: screen) ?? CGMainDisplayID(),
            image: DesktopCaptureService.fixtureImage(size: screen.frame.size, scale: 1)
        )
        let coordinator = CaptureCoordinator()
        let controller = OverlayWindowController(snapshot: snapshot, coordinator: coordinator)
        let view = try #require(controller.overlayView)
        view.state.selection = CGRect(x: 100, y: 100, width: 240, height: 180)

        let longImage = try #require(makeSolidImage(width: 120, height: 480, color: (32, 62, 91)))
        view.endScrollMode(with: longImage)
        let preview = try #require(view.state.selection)
        #expect(abs(preview.width / preview.height - 0.25) < 0.001)

        let baseline = try #require(view.composedImage())
        let baselinePNG = try #require(ImageComposer.pngData(baseline))
        #expect(baseline.width == 120)
        #expect(baseline.height == 480)

        view.state.annotations = [
            .rectangle(preview.insetBy(dx: 8, dy: 12), .systemRed, 6),
        ]
        let annotated = try #require(view.composedImage())
        let annotatedPNG = try #require(ImageComposer.pngData(annotated))
        #expect(annotated.width == 120)
        #expect(annotated.height == 480)
        #expect(annotatedPNG != baselinePNG)
        controller.close()
    }

    @Test("Scroll capture enforces a bounded frame budget")
    func scrollCaptureFrameBudget() throws {
        let screen = try #require(NSScreen.main)
        let snapshot = ScreenSnapshot(
            screen: screen,
            displayID: DesktopCaptureService.displayID(for: screen) ?? CGMainDisplayID(),
            image: DesktopCaptureService.fixtureImage(size: screen.frame.size, scale: 1)
        )
        let coordinator = CaptureCoordinator()
        let controller = OverlayWindowController(snapshot: snapshot, coordinator: coordinator)
        let view = try #require(controller.overlayView)
        view.state.selection = CGRect(x: 20, y: 20, width: 24, height: 24)
        #expect(view.beginScrollMode())

        for value in 0 ..< 50 {
            let frame = try #require(makeSolidImage(
                width: 24,
                height: 24,
                color: (
                    UInt8((value * 3) % 256),
                    UInt8((value * 5) % 256),
                    UInt8((value * 7) % 256)
                )
            ))
            view.scrollCaptureDidFinish(frame, error: nil)
        }
        #expect(view.scrollFrameCount == 40)
        #expect(!view.canCaptureAnotherScrollFrame)
        view.endScrollMode(with: nil)
        controller.close()
    }

    @Test("Scroll controls preserve the selected region and expose Finish")
    func scrollControls() throws {
        let screen = try #require(NSScreen.main)
        let selection = screen.visibleFrame.insetBy(dx: 240, dy: 180)
        let controller = ScrollControlPanelController(near: selection, on: screen)
        defer { controller.close() }

        #expect(controller.selectionBorderWindow.frame == selection)
        #expect(controller.selectionBorderWindow.ignoresMouseEvents)
        #expect(controller.selectionBorderWindow.sharingType == .none)
        #expect(controller.finishButton.title == "结束")
        let preview = try #require(makeSolidImage(width: 80, height: 220, color: (20, 80, 140)))
        controller.updatePreview(preview)
        #expect(controller.previewImageView.image?.size == CGSize(width: 80, height: 220))
        var finished = false
        controller.onFinish = { finished = true }
        controller.finishButton.performClick(nil)
        #expect(finished)
    }

    @Test("A short scroll capture can finish from one frame")
    func shortScrollCapture() async throws {
        let frame = try #require(makeSolidImage(width: 240, height: 180, color: (36, 92, 148)))
        let result = try await CoreServiceBridge.stitch(frames: [frame])
        #expect(result.width == frame.width)
        #expect(result.height == frame.height)
    }

    @Test("PNG clipboard payload and pin window use the production AppKit path")
    func clipboardAndPinWindow() throws {
        let image = try #require(makeSolidImage(width: 96, height: 48, color: (21, 142, 83)))
        let pasteboard = NSPasteboard(name: .init("WeShotTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(pasteboard.setString("before", forType: .string))
        let archive = CaptureOutputService.archive(pasteboard)
        let png = try CaptureOutputService.writeToPasteboard(image, pasteboard: pasteboard)
        let roundTrip = try #require(pasteboard.data(forType: .png))
        let decoded = try #require(NSBitmapImageRep(data: roundTrip)?.cgImage)
        #expect(decoded.width == 96)
        #expect(decoded.height == 48)
        try CaptureOutputService.restore(archive, to: pasteboard)
        try CaptureOutputService.requireRestored(archive, in: pasteboard)
        #expect(pasteboard.string(forType: .string) == "before")

        let savedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeShotTests-\(UUID().uuidString)")
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: savedURL) }
        try CaptureOutputService.writePNGData(png, to: savedURL)
        #expect(try Data(contentsOf: savedURL) == png)

        let pinnedSize = CGSize(width: 320, height: 160)
        let pin = PinWindowController(
            image: image,
            origin: CGPoint(x: 40, y: 40),
            preferredSize: pinnedSize
        )
        let window = try #require(pin.window)
        #expect(window.level == .floating)
        let pinView = try #require(window.contentView as? PinImageView)
        #expect(abs(window.aspectRatio.width / window.aspectRatio.height - 2) < 0.001)
        #expect(abs(window.frame.width - pinnedSize.width) < 0.001)
        #expect(abs(window.frame.height - pinnedSize.height) < 0.001)
        pin.showWindow(nil)
        #expect(window.isVisible)
        let initialSize = window.frame.size
        let scroll = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: 1,
                wheel2: 0,
                wheel3: 0
            )
        )
        pinView.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
        #expect(window.frame.width > initialSize.width)
        #expect(window.frame.height > initialSize.height)
        let doubleClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 7,
            clickCount: 2,
            pressure: 1
        ))
        pinView.mouseDown(with: doubleClick)
        #expect(!window.isVisible)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        windowNumber: Int
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    private func makePixelImage(bytes: [UInt8], bitmapInfo: CGBitmapInfo) -> CGImage? {
        guard bytes.count == 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { return nil }
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func makeSolidImage(
        width: Int,
        height: Int,
        color: (UInt8, UInt8, UInt8)
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(
            red: CGFloat(color.0) / 255,
            green: CGFloat(color.1) / 255,
            blue: CGFloat(color.2) / 255,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
