import AppKit
import ApplicationServices
import CoreGraphics

enum VisibleUISmokeFailure: LocalizedError {
    case noScreen
    case overlayLifecycle
    case selection
    case annotation
    case translation
    case render
    case savePanel
    case pinDrag(String)

    var errorDescription: String? {
        switch self {
        case .noScreen:
            return "没有可用于可见 UI 烟测的显示器"
        case .overlayLifecycle:
            return "可见 Overlay 生命周期验证失败"
        case .selection:
            return "可见 Overlay 自定义选区验证失败"
        case .annotation:
            return "可见 Overlay 标注交互验证失败"
        case .translation:
            return "译文图层或无独立结果窗口验证失败"
        case .render:
            return "无法缓存可见 Overlay 证据"
        case .savePanel:
            return "系统保存面板显示、取消或 Overlay 恢复失败"
        case .pinDrag(let detail):
            return "可见钉图拖动或关闭验证失败：\(detail)"
        }
    }
}

struct VisibleUISmokeResult {
    let evidenceURL: URL
    let savedURL: URL
}

@MainActor
enum VisibleUISmokeRunner {
    static func run(in directory: URL) async throws -> VisibleUISmokeResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureFailure.captureFailed("没有屏幕录制权限")
        }
        let snapshots = try await DesktopCaptureService.captureAllScreens()
        guard let snapshot = snapshots.first else {
            throw VisibleUISmokeFailure.noScreen
        }
        let coordinator = CaptureCoordinator()
        let controller = OverlayWindowController(snapshot: snapshot, coordinator: coordinator)
        guard let overlayWindow = controller.window else {
            throw VisibleUISmokeFailure.overlayLifecycle
        }
        defer {
            controller.close()
            NSApp.hide(nil)
        }

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 160_000_000)
        guard overlayWindow.isVisible,
              overlayWindow.level == .screenSaver,
              overlayWindow.firstResponder === controller.overlayView
        else {
            throw VisibleUISmokeFailure.overlayLifecycle
        }

        let view = controller.overlayView!
        let expectedSelection = CGRect(
            x: view.bounds.width * 0.2,
            y: view.bounds.height * 0.22,
            width: view.bounds.width * 0.52,
            height: view.bounds.height * 0.46
        )
        try drag(
            from: CGPoint(x: expectedSelection.minX, y: expectedSelection.minY),
            to: CGPoint(x: expectedSelection.maxX, y: expectedSelection.maxY),
            in: view,
            window: overlayWindow
        )
        guard let snapped = view.state.selection, approximatelyEqual(snapped, expectedSelection)
        else {
            throw VisibleUISmokeFailure.selection
        }

        let toolbar = ToolbarLayout.frame(for: snapped, in: view.bounds)
        guard let rectangleIndex = ToolbarLayout.items.firstIndex(of: .tool(.rectangle)) else {
            throw VisibleUISmokeFailure.annotation
        }
        let toolPoint = ToolbarLayout.itemFrame(
            at: rectangleIndex,
            toolbarFrame: toolbar
        ).center
        try click(at: toolPoint, in: view, window: overlayWindow)
        guard view.state.tool == .rectangle else {
            throw VisibleUISmokeFailure.annotation
        }

        let start = CGPoint(x: snapped.minX + 28, y: snapped.minY + 28)
        let end = CGPoint(
            x: min(snapped.maxX - 28, start.x + 150),
            y: min(snapped.maxY - 28, start.y + 90)
        )
        try drag(from: start, to: end, in: view, window: overlayWindow)
        guard view.state.annotations.count == 1 else {
            throw VisibleUISmokeFailure.annotation
        }

        let visibleWindowCount = NSApp.windows.filter(\.isVisible).count
        let translation = await CoreServiceBridge.translationController.translate("Hello")
        guard let translated = translation.translatedText, !translated.isEmpty else {
            throw VisibleUISmokeFailure.translation
        }
        view.setTranslationOverlay(translated)
        guard view.state.annotations.count == 2,
              NSApp.windows.filter(\.isVisible).count == visibleWindowCount,
              case .translation(let translationRect, let translationText) = view.state.annotations.last,
              translationRect == snapped,
              translationText == translated
        else {
            throw VisibleUISmokeFailure.translation
        }

        let evidenceURL = directory.appendingPathComponent("visible-overlay.png")
        try render(view: view, to: evidenceURL)

        overlayWindow.orderOut(nil)
        guard !overlayWindow.isVisible else {
            throw VisibleUISmokeFailure.savePanel
        }
        let panel = CaptureSavePanelFactory.make(
            defaultFilename: CaptureFileNamer.pngFilename(for: Date(timeIntervalSince1970: 0))
        )
        let panelWasVisible = try await showAndCancel(panel)
        guard panelWasVisible, !panel.isVisible else {
            throw VisibleUISmokeFailure.savePanel
        }

        controller.showWindow(nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        guard overlayWindow.isVisible, view.state.selection != nil else {
            throw VisibleUISmokeFailure.savePanel
        }

        guard let composedImage = view.composedImage() else {
            throw VisibleUISmokeFailure.render
        }
        overlayWindow.orderOut(nil)
        let savedURL = directory.appendingPathComponent(
            "visible-save-panel-\(ProcessInfo.processInfo.processIdentifier).png"
        )
        let confirmPanel = CaptureSavePanelFactory.make(
            defaultFilename: savedURL.lastPathComponent
        )
        let confirmedURL = try await showAndConfirm(
            confirmPanel,
            destination: savedURL,
            image: composedImage
        )
        guard confirmedURL.standardizedFileURL == savedURL.standardizedFileURL,
              let savedData = try? Data(contentsOf: savedURL)
        else {
            throw VisibleUISmokeFailure.savePanel
        }
        try CaptureOutputService.requireSize(
            CaptureOutputService.decodedSize(of: savedData),
            matches: composedImage
        )

        try await verifyPinDrag(image: composedImage, on: snapshot.screen)
        controller.close()
        guard !overlayWindow.isVisible else {
            throw VisibleUISmokeFailure.overlayLifecycle
        }

        return VisibleUISmokeResult(
            evidenceURL: evidenceURL,
            savedURL: savedURL
        )
    }

    private static func showAndCancel(_ panel: NSSavePanel) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            var wasVisible = false
            panel.begin { response in
                guard response == .cancel, wasVisible else {
                    continuation.resume(throwing: VisibleUISmokeFailure.savePanel)
                    return
                }
                continuation.resume(returning: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                wasVisible = panel.isVisible
                panel.cancel(nil)
            }
        }
    }

    private static func showAndConfirm(
        _ panel: NSSavePanel,
        destination: URL,
        image: CGImage
    ) async throws -> URL {
        panel.directoryURL = destination.deletingLastPathComponent()
        panel.nameFieldStringValue = destination.lastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            var wasVisible = false
            panel.begin { response in
                guard response == .OK, wasVisible, let url = panel.url else {
                    continuation.resume(throwing: VisibleUISmokeFailure.savePanel)
                    return
                }
                do {
                    _ = try CaptureOutputService.writePNG(image, to: url)
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                wasVisible = panel.isVisible && panel.isKeyWindow
                guard wasVisible, pressSaveButton() else {
                    panel.cancel(nil)
                    return
                }
            }
        }
    }

    private static func pressSaveButton() -> Bool {
        guard AXIsProcessTrusted(),
              let button = findAXElement(
                  in: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                  role: kAXButtonRole,
                  identifier: "OKButton"
              )
        else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private static func findAXElement(
        in element: AXUIElement,
        role expectedRole: String,
        identifier expectedIdentifier: String
    ) -> AXUIElement? {
        let role = axString(element, attribute: kAXRoleAttribute)
        let identifier = axString(element, attribute: kAXIdentifierAttribute)
        if role == expectedRole, identifier == expectedIdentifier {
            return element
        }
        guard let children = axChildren(element) else { return nil }
        for child in children {
            if let match = findAXElement(
                in: child,
                role: expectedRole,
                identifier: expectedIdentifier
            ) {
                return match
            }
        }
        return nil
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func verifyPinDrag(image: CGImage, on screen: NSScreen) async throws {
        guard CGPreflightPostEventAccess(), CGPreflightListenEventAccess(),
              let originalMouse = CGEvent(source: nil)?.location
        else {
            throw VisibleUISmokeFailure.pinDrag("缺少输入事件权限或鼠标位置")
        }
        let initialOrigin = CGPoint(
            x: screen.visibleFrame.minX + 42,
            y: screen.visibleFrame.minY + 42
        )
        let pin = PinWindowController(
            image: image,
            origin: initialOrigin,
            preferredSize: CGSize(width: 320, height: 180)
        )
        guard let pinWindow = pin.window else {
            throw VisibleUISmokeFailure.pinDrag("无法创建窗口")
        }
        defer {
            pin.close()
            CGWarpMouseCursorPosition(originalMouse)
        }
        pin.showWindow(nil)
        try await Task.sleep(nanoseconds: 120_000_000)
        let originalFrame = pinWindow.frame
        guard pinWindow.isVisible else {
            throw VisibleUISmokeFailure.pinDrag("窗口未显示")
        }

        let appKitStart = CGPoint(x: originalFrame.midX, y: originalFrame.midY)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let quartzStart = CGPoint(x: appKitStart.x, y: primaryTop - appKitStart.y)
        let quartzEnd = CGPoint(x: quartzStart.x + 80, y: quartzStart.y)
        guard await postMouseDrag(from: quartzStart, to: quartzEnd) else {
            throw VisibleUISmokeFailure.pinDrag("无法发送 HID 鼠标拖动序列")
        }
        try await Task.sleep(nanoseconds: 180_000_000)

        let deltaX = pinWindow.frame.minX - originalFrame.minX
        guard deltaX > 45 else {
            throw VisibleUISmokeFailure.pinDrag(
                "横向位移仅 \(Int(deltaX.rounded())) 点，原点 \(Int(originalFrame.minX)) → \(Int(pinWindow.frame.minX))"
            )
        }
        pin.close()
        guard !pinWindow.isVisible else {
            throw VisibleUISmokeFailure.pinDrag("关闭后窗口仍可见")
        }
    }

    private static func postMouseDrag(from start: CGPoint, to end: CGPoint) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGEventSource(stateID: .hidSystemState) else {
                return false
            }
            func post(_ type: CGEventType, _ point: CGPoint) -> Bool {
                guard let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: type,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else { return false }
                event.post(tap: .cghidEventTap)
                return true
            }

            guard post(.mouseMoved, start) else { return false }
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard post(.leftMouseDown, start) else { return false }
            try? await Task.sleep(nanoseconds: 90_000_000)
            let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            guard post(.leftMouseDragged, midpoint) else { return false }
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard post(.leftMouseDragged, end) else { return false }
            try? await Task.sleep(nanoseconds: 70_000_000)
            return post(.leftMouseUp, end)
        }.value
    }

    private static func click(
        at point: CGPoint,
        in view: OverlayView,
        window: NSWindow
    ) throws {
        guard let down = event(.leftMouseDown, at: point, window: window, number: 2, pressure: 1),
              let up = event(.leftMouseUp, at: point, window: window, number: 3, pressure: 0)
        else {
            throw VisibleUISmokeFailure.annotation
        }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }

    private static func drag(
        from start: CGPoint,
        to end: CGPoint,
        in view: OverlayView,
        window: NSWindow
    ) throws {
        guard let down = event(.leftMouseDown, at: start, window: window, number: 4, pressure: 1),
              let dragged = event(.leftMouseDragged, at: end, window: window, number: 5, pressure: 1),
              let up = event(.leftMouseUp, at: end, window: window, number: 6, pressure: 0)
        else {
            throw VisibleUISmokeFailure.annotation
        }
        view.mouseDown(with: down)
        view.mouseDragged(with: dragged)
        view.mouseUp(with: up)
    }

    private static func event(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        window: NSWindow,
        number: Int,
        pressure: Float
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: number,
            clickCount: type == .leftMouseDragged ? 0 : 1,
            pressure: pressure
        )
    }

    private static func render(view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw VisibleUISmokeFailure.render
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw VisibleUISmokeFailure.render
        }
        try CaptureOutputService.writePNGData(data, to: url)
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5 &&
            abs(lhs.minY - rhs.minY) < 0.5 &&
            abs(lhs.width - rhs.width) < 0.5 &&
            abs(lhs.height - rhs.height) < 0.5
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
