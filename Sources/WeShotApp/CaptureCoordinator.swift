import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import WeShotCore

@MainActor
struct ScreenSnapshot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
}

enum ScreenCaptureFailure: LocalizedError {
    case noScreens
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .noScreens: return "没有检测到可截图的显示器。"
        case .captureFailed(let detail): return "屏幕捕获失败：\(detail)"
        }
    }
}

@MainActor
enum DesktopCaptureService {
    private struct DisplayLayout: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }

    private static var filterLayout: [DisplayLayout] = []
    private static var filterTask: Task<[CGDirectDisplayID: SCContentFilter], Error>?

    static func captureAllScreens() async throws -> [ScreenSnapshot] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw ScreenCaptureFailure.noScreens }
        // Start every display before awaiting results, but preserve screen order.
        let captures = screens.map { screen in
            Task { @MainActor in
                guard let displayID = displayID(for: screen) else {
                    throw ScreenCaptureFailure.captureFailed("无法读取显示器标识")
                }
                let image: CGImage
                do {
                    image = try await captureDisplay(displayID: displayID, screen: screen)
                } catch {
                    if #available(macOS 15.2, *) {
                        image = try await capture(rect: CGDisplayBounds(displayID))
                    } else {
                        throw error
                    }
                }
                return ScreenSnapshot(screen: screen, displayID: displayID, image: image)
            }
        }
        var snapshots: [ScreenSnapshot] = []
        var failures: [String] = []
        for (screen, task) in zip(screens, captures) {
            do {
                snapshots.append(try await task.value)
            } catch {
                failures.append("\(screen.localizedName)：\(error.localizedDescription)")
            }
        }
        guard !snapshots.isEmpty else {
            let detail = failures.isEmpty ? "显示器返回了空图像" : failures.joined(separator: "；")
            throw ScreenCaptureFailure.captureFailed(detail)
        }
        return snapshots
    }

    /// Last-resort desktop capture; scrolling frames always remain display-bound.
    @available(macOS 15.2, *)
    static func capture(rect: CGRect) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? ScreenCaptureFailure.captureFailed("ScreenCaptureKit 未返回图像"))
                }
            }
        }
    }

    static func prewarmDisplayFilters() {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task { _ = try? await displayFilters() }
    }

    private static func displayFilters() async throws -> [CGDirectDisplayID: SCContentFilter] {
        let layout = NSScreen.screens.compactMap { screen -> DisplayLayout? in
            guard let id = displayID(for: screen) else { return nil }
            return DisplayLayout(id: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }
        if filterTask == nil || layout != filterLayout {
            filterLayout = layout
            // Only display metadata is retained. Pixel data is always captured on demand.
            filterTask = Task {
                let content = try await SCShareableContent.current
                return Dictionary(uniqueKeysWithValues: content.displays.map {
                    ($0.displayID, SCContentFilter(display: $0, excludingWindows: []))
                })
            }
        }
        do {
            return try await filterTask!.value
        } catch {
            if filterLayout == layout { filterTask = nil }
            throw error
        }
    }

    static func captureDisplay(displayID: CGDirectDisplayID, screen: NSScreen) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        return try await captureDisplay(displayID: displayID, configuration: configuration)
    }

    private static func captureDisplay(displayID: CGDirectDisplayID, configuration: SCStreamConfiguration, retrying: Bool = true) async throws -> CGImage {
        do {
            guard let filter = try await displayFilters()[displayID] else {
                throw ScreenCaptureFailure.captureFailed("无法匹配显示器 \(displayID)")
            }
            configuration.showsCursor = false
            return try await withCheckedThrowingContinuation { continuation in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? ScreenCaptureFailure.captureFailed("显示器捕获失败"))
                    }
                }
            }
        } catch {
            filterTask = nil
            guard retrying else { throw error }
            return try await captureDisplay(displayID: displayID, configuration: configuration, retrying: false)
        }
    }

    static func captureSelection(snapshot: ScreenSnapshot, localRect: CGRect, viewBounds: CGRect) async throws -> CGImage {
        let sourceRect = try selectionSourceRect(
            localRect: localRect,
            viewBounds: viewBounds,
            screenSize: snapshot.screen.frame.size,
            scale: snapshot.screen.backingScaleFactor
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int((sourceRect.width * snapshot.screen.backingScaleFactor).rounded())
        configuration.height = Int((sourceRect.height * snapshot.screen.backingScaleFactor).rounded())
        // Bind to the display to avoid stale rect-only captures after focus changes.
        return try await captureDisplay(displayID: snapshot.displayID, configuration: configuration)
    }

    static func selectionSourceRect(localRect: CGRect, viewBounds: CGRect, screenSize: CGSize, scale: CGFloat) throws -> CGRect {
        guard viewBounds.width > 0, viewBounds.height > 0,
              screenSize.width > 0, screenSize.height > 0, scale > 0,
              [localRect.minX, localRect.minY, localRect.width, localRect.height,
               viewBounds.minX, viewBounds.minY, viewBounds.width, viewBounds.height,
               screenSize.width, screenSize.height, scale].allSatisfy(\.isFinite)
        else { throw ScreenCaptureFailure.captureFailed("滚动截图选区无效") }
        let rect = localRect.standardized.intersection(viewBounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
            throw ScreenCaptureFailure.captureFailed("滚动截图选区无效")
        }
        let pixelRect = CGRect(
            x: (rect.minX - viewBounds.minX) / viewBounds.width * screenSize.width * scale,
            y: (viewBounds.maxY - rect.maxY) / viewBounds.height * screenSize.height * scale,
            width: rect.width / viewBounds.width * screenSize.width * scale,
            height: rect.height / viewBounds.height * screenSize.height * scale
        ).integral.intersection(CGRect(origin: .zero, size: CGSize(
            width: screenSize.width * scale, height: screenSize.height * scale
        )))
        return CGRect(x: pixelRect.minX / scale, y: pixelRect.minY / scale,
                      width: pixelRect.width / scale, height: pixelRect.height / scale)
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    static func fixtureImage(size: CGSize, scale: CGFloat = 2) -> CGImage {
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        let colors = [
            NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.23, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.52, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.45, green: 0.22, blue: 0.50, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.55, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        for row in 0..<8 {
            for column in 0..<12 where (row + column).isMultiple(of: 2) {
                NSColor.white.withAlphaComponent(0.035).setFill()
                context.fill(CGRect(x: CGFloat(column) * size.width / 12, y: CGFloat(row) * size.height / 8, width: size.width / 12, height: size.height / 8))
            }
        }
        context.setFillColor(NSColor.white.withAlphaComponent(0.94).cgColor)
        context.fill(CGRect(x: size.width * 0.09, y: size.height * 0.12, width: size.width * 0.82, height: size.height * 0.73))
        context.setFillColor(NSColor(calibratedWhite: 0.94, alpha: 1).cgColor)
        context.fill(CGRect(x: size.width * 0.09, y: size.height * 0.72, width: size.width * 0.82, height: size.height * 0.13))
        context.setFillColor(NSColor.systemGreen.cgColor)
        context.fillEllipse(in: CGRect(x: size.width * 0.12, y: size.height * 0.745, width: 28, height: 28))
        return context.makeImage()!
    }
}

@MainActor
final class CaptureCoordinator: NSObject {
    var hidesAuxiliaryWindowsDuringCapture = true
    private(set) var overlays: [OverlayWindowController] = []
    private var pins: [PinWindowController] = []
    private var messagePanels: [MessagePanelController] = []
    private var captureInProgress = false
    private(set) var lastCaptureTimings: (imageMilliseconds: Double, overlayMilliseconds: Double)?
    private var captureSessionID: UUID?
    private var permissionController: PermissionWindowController?
    private var requestedScreenCaptureAccess = false
    private var sourceApplication: NSRunningApplication?
    private weak var scrollingOverlay: OverlayWindowController?
    private var scrollControl: ScrollControlPanelController?
    private var scrollTimer: Timer?
    private var scrollCaptureInFlight = false
    private var scrollSessionID: UUID?
    private var scrollCaptureTask: Task<Void, Never>?
    private var scrollFinishTask: Task<Void, Never>?
    private var scrollPreviewTask: Task<Void, Never>?
    private var scrollPreviewImage: CGImage?

    func startCapture() {
        guard overlays.isEmpty, !captureInProgress else { return }
        let started = ProcessInfo.processInfo.systemUptime
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            sourceApplication = frontmost
        }
        var hasAccess = CGPreflightScreenCaptureAccess()
        if !hasAccess, !requestedScreenCaptureAccess {
            requestedScreenCaptureAccess = true
            hasAccess = CGRequestScreenCaptureAccess()
        }
        if !hasAccess {
            showPermissionWindow()
            return
        }
        captureInProgress = true
        lastCaptureTimings = nil
        Task { @MainActor in
            defer { captureInProgress = false }
            let hiddenWindows = temporarilyHideAuxiliaryWindows()
            defer { restoreAuxiliaryWindows(hiddenWindows) }
            do {
                let snapshots = try await DesktopCaptureService.captureAllScreens()
                let captured = ProcessInfo.processInfo.systemUptime
                showOverlays(for: snapshots)
                lastCaptureTimings = (
                    (captured - started) * 1_000,
                    (ProcessInfo.processInfo.systemUptime - captured) * 1_000
                )
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private struct HiddenWindowState {
        let window: NSWindow
        let wasKey: Bool
    }

    private func temporarilyHideAuxiliaryWindows() -> [HiddenWindowState] {
        guard hidesAuxiliaryWindowsDuringCapture else { return [] }
        let windows = (pins.compactMap(\.window) + messagePanels.compactMap(\.window))
            .filter(\.isVisible)
        let states = windows.map { HiddenWindowState(window: $0, wasKey: $0.isKeyWindow) }
        windows.forEach { $0.orderOut(nil) }
        return states
    }

    private func restoreAuxiliaryWindows(_ states: [HiddenWindowState]) {
        for state in states {
            state.window.orderFront(nil)
            if state.wasKey { state.window.makeKey() }
        }
    }

    private func showOverlays(for snapshots: [ScreenSnapshot]) {
        closeOverlays()
        captureSessionID = UUID()
        overlays = snapshots.map { snapshot in
            let controller = OverlayWindowController(snapshot: snapshot, coordinator: self)
            controller.showWindow(nil)
            return controller
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func overlayBecameActive(_ active: OverlayWindowController) {
        for overlay in overlays where overlay !== active {
            overlay.deactivateSelection()
        }
    }

    private func isActiveCapture(_ overlay: OverlayWindowController, sessionID: UUID) -> Bool {
        captureSessionID == sessionID && overlays.contains(where: { $0 === overlay })
    }

    func cancelCapture() {
        closeOverlays(restoringSourceApplication: true)
    }

    func finishCapture(from overlay: OverlayWindowController) {
        guard let image = overlay.composedImage() else {
            overlay.showTransientMessage("请先选择截图区域")
            return
        }
        do {
            try CaptureOutputService.writeToPasteboard(image)
        } catch {
            overlay.showTransientMessage("复制失败：\(error.localizedDescription)")
            return
        }
        closeOverlays(restoringSourceApplication: true)
    }

    func saveCapture(from overlay: OverlayWindowController) {
        guard let image = overlay.composedImage() else {
            overlay.showTransientMessage("请先选择截图区域")
            return
        }
        let data: Data
        do {
            data = try CaptureOutputService.pngData(for: image)
        } catch {
            overlay.showTransientMessage("保存失败：\(error.localizedDescription)")
            return
        }
        overlays.forEach { $0.window?.orderOut(nil) }
        let panel = CaptureSavePanelFactory.make(
            defaultFilename: CaptureFileNamer.pngFilename(for: Date())
        )
        panel.begin { [weak self, weak overlay] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                do {
                    try CaptureOutputService.writePNGData(data, to: url)
                    self.closeOverlays(restoringSourceApplication: true)
                } catch {
                    self.restoreOverlays(preferred: overlay)
                    self.showError("保存失败：\(error.localizedDescription)")
                }
            } else {
                self.restoreOverlays(preferred: overlay)
            }
        }
    }

    func pinCapture(from overlay: OverlayWindowController) {
        guard let image = overlay.composedImage() else { return }
        let selection = overlay.editorSelection ?? CGRect(origin: .zero, size: NSSize(width: image.width, height: image.height))
        let globalOrigin = overlay.window?.convertPoint(toScreen: selection.origin) ?? NSEvent.mouseLocation
        closeOverlays(restoringSourceApplication: true)
        let controller = PinWindowController(
            image: image,
            origin: globalOrigin,
            preferredSize: selection.size
        )
        pins.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.pins.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
    }

    func translateText(from overlay: OverlayWindowController) {
        guard let image = overlay.composedImage(excludingTranslation: true), let sessionID = captureSessionID else { return }
        overlay.showTransientMessage("正在提取并翻译…")
        Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay else { return }
            do {
                let source = try await CoreServiceBridge.recognizeText(in: image)
                guard self.isActiveCapture(overlay, sessionID: sessionID) else { return }
                let result = await CoreServiceBridge.translationController.translate(source)
                guard self.isActiveCapture(overlay, sessionID: sessionID) else { return }
                if let translated = result.translatedText, !translated.isEmpty {
                    overlay.setTranslationOverlay(translated)
                    overlay.showTransientMessage("翻译完成")
                } else {
                    overlay.showTransientMessage(result.statusMessage)
                }
            } catch {
                guard self.isActiveCapture(overlay, sessionID: sessionID) else { return }
                overlay.showTransientMessage("翻译失败：\(error.localizedDescription)")
            }
        }
    }

    func redactPrivacy(from overlay: OverlayWindowController) {
        guard let image = overlay.composedImage(),
              let selection = overlay.editorSelection,
              let sessionID = captureSessionID
        else { return }
        overlay.showTransientMessage("正在检测隐私信息…")
        Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay else { return }
            do {
                let regions = try await CoreServiceBridge.privacyRegions(in: image)
                guard self.isActiveCapture(overlay, sessionID: sessionID) else { return }
                guard overlay.editorSelection == selection else {
                    overlay.showTransientMessage("选区已变化，请重新检测隐私信息")
                    return
                }
                overlay.addPrivacyMosaics(regions.map { region in
                    CGRect(
                        x: selection.minX + region.minX * selection.width,
                        y: selection.minY + region.minY * selection.height,
                        width: region.width * selection.width,
                        height: region.height * selection.height
                    )
                })
                overlay.showTransientMessage(regions.isEmpty ? "未发现敏感信息" : "已添加 \(regions.count) 处可撤销打码")
            } catch {
                guard self.isActiveCapture(overlay, sessionID: sessionID) else { return }
                overlay.showTransientMessage("隐私检测失败：\(error.localizedDescription)")
            }
        }
    }

    func beginScrolling(from overlay: OverlayWindowController) {
        guard scrollControl == nil,
              scrollFinishTask == nil,
              scrollPreviewTask == nil,
              overlay.beginScrollMode(),
              let selection = overlay.editorSelection,
              let window = overlay.window
        else { return }

        let sessionID = UUID()
        scrollSessionID = sessionID
        scrollingOverlay = overlay
        let globalSelection = CGRect(
            origin: window.convertPoint(toScreen: selection.origin),
            size: selection.size
        )
        overlays.forEach { $0.window?.orderOut(nil) }

        let control = ScrollControlPanelController(near: globalSelection, on: window.screen)
        control.onFinish = { [weak self] in self?.finishScrollingCapture() }
        control.onCancel = { [weak self] in self?.cancelScrollingCapture() }
        scrollControl = control
        control.showWindow(nil)
        control.updateStatus("正在采集实时首帧…")
        if let sourceApplication {
            sourceApplication.activate()
        } else {
            NSApp.deactivate()
        }

        let timer = Timer(timeInterval: 0.32, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureScrollFrameTick() }
        }
        scrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        captureScrollFrameTick()
    }

    func captureScrollFrame(from overlay: OverlayWindowController, forwarding event: CGEvent?) {
        captureScrollFrameTick()
    }

    private func captureScrollFrameTick() {
        guard !scrollCaptureInFlight,
              scrollFinishTask == nil,
              scrollPreviewTask == nil,
              let sessionID = scrollSessionID,
              let overlay = scrollingOverlay,
              let selection = overlay.editorSelection,
              overlay.canCaptureAnotherScrollFrame
        else { return }
        scrollCaptureInFlight = true
        let task = Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay else { return }
            defer {
                if self.scrollSessionID == sessionID {
                    self.scrollCaptureInFlight = false
                    self.scrollCaptureTask = nil
                }
            }
            do {
                let image = try await DesktopCaptureService.captureSelection(
                    snapshot: overlay.snapshot,
                    localRect: selection,
                    viewBounds: CGRect(origin: .zero, size: overlay.snapshot.screen.frame.size)
                )
                guard !Task.isCancelled,
                      self.scrollSessionID == sessionID,
                      self.scrollingOverlay === overlay
                else { return }
                if overlay.scrollCaptureDidFinish(image, error: nil) {
                    self.scrollControl?.updateStatus("正在拼接第 \(overlay.scrollFrameCount) 帧…")
                    self.refreshScrollPreview(sessionID: sessionID, overlay: overlay)
                }
            } catch {
                guard !Task.isCancelled,
                      self.scrollSessionID == sessionID,
                      self.scrollingOverlay === overlay
                else { return }
                overlay.scrollCaptureDidFinish(nil, error: error)
                self.scrollControl?.updateStatus("采集失败")
            }
        }
        scrollCaptureTask = task
    }

    private func finishScrollingCapture() {
        guard scrollFinishTask == nil,
              let sessionID = scrollSessionID,
              let overlay = scrollingOverlay
        else { return }

        stopScrollTimer()
        scrollControl?.finishButton.isEnabled = false
        // Capture one settled frame at the moment the user presses Finish. If a
        // timer-driven capture is already running, wait for that exact frame.
        if scrollCaptureTask == nil, overlay.canCaptureAnotherScrollFrame {
            captureScrollFrameTick()
        }
        let pendingCapture = scrollCaptureTask
        let task = Task { @MainActor [weak self, weak overlay] in
            if let pendingCapture { await pendingCapture.value }
            if let pendingPreview = self?.scrollPreviewTask { await pendingPreview.value }
            guard let self, let overlay,
                  !Task.isCancelled,
                  self.scrollSessionID == sessionID,
                  self.scrollingOverlay === overlay
            else { return }

            guard let result = self.scrollPreviewImage ?? overlay.scrollFramesForCompletion.first else {
                self.cancelScrollingCapture()
                return
            }
            do {
                try CaptureOutputService.writeToPasteboard(result)
            } catch {
                self.cancelScrollingCapture()
                self.showError("长截图复制失败：\(error.localizedDescription)")
                return
            }
            self.scrollFinishTask = nil
            self.finishScrollSession()
            self.closeOverlays(restoringSourceApplication: true)
        }
        scrollFinishTask = task
    }

    private func refreshScrollPreview(sessionID: UUID, overlay: OverlayWindowController) {
        guard scrollPreviewTask == nil,
              let newest = overlay.scrollFramesForCompletion.last
        else { return }
        guard let current = scrollPreviewImage else {
            scrollPreviewImage = newest
            scrollControl?.updatePreview(newest)
            scrollControl?.updateStatus("首帧已就绪，开始滚动")
            return
        }
        guard let previous = overlay.scrollFramesForCompletion.dropLast().last else { return }
        let task = Task { @MainActor [weak self, weak overlay] in
            defer {
                if self?.scrollSessionID == sessionID { self?.scrollPreviewTask = nil }
            }
            do {
                let result = try await CoreServiceBridge.appendScrollFrame(newest, to: current, previous: previous)
                guard let self, let overlay,
                      !Task.isCancelled,
                      self.scrollSessionID == sessionID,
                      self.scrollingOverlay === overlay
                else { return }
                self.scrollPreviewImage = result
                self.scrollControl?.updatePreview(result)
                self.scrollControl?.updateStatus("已拼接 \(overlay.scrollFrameCount) 帧")
            } catch {
                guard let self, let overlay,
                      !Task.isCancelled,
                      self.scrollSessionID == sessionID,
                      self.scrollingOverlay === overlay
                else { return }
                overlay.discardLastScrollFrame()
                if case ScrollStitcherError.noNewContent = error {
                    self.scrollControl?.updateStatus("等待页面滚动…")
                    return
                }
                overlay.showTransientMessage("无法对齐，已保留当前预览；请回到中断位置再继续")
                self.scrollControl?.updateStatus("截图已中断，请回到中断位置再继续")
            }
        }
        scrollPreviewTask = task
    }

    private func cancelScrollingCapture() {
        guard let overlay = scrollingOverlay else { return }
        stopScrollCaptureUI()
        restoreOverlays(afterScrolling: overlay)
        overlay.endScrollMode(with: nil)
        overlay.showTransientMessage("已取消滚动截图")
    }

    private func restoreOverlays(afterScrolling overlay: OverlayWindowController) {
        restoreOverlays(preferred: overlay)
    }

    private func stopScrollControls() {
        stopScrollTimer()
        scrollControl?.close()
        scrollControl = nil
    }

    private func stopScrollTimer() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func finishScrollSession() {
        stopScrollControls()
        scrollSessionID = nil
        scrollingOverlay = nil
        scrollCaptureInFlight = false
        scrollCaptureTask = nil
        scrollPreviewTask = nil
        scrollPreviewImage = nil
    }

    private func stopScrollCaptureUI() {
        stopScrollControls()
        scrollSessionID = nil
        scrollingOverlay = nil
        scrollCaptureInFlight = false
        scrollCaptureTask?.cancel()
        scrollCaptureTask = nil
        scrollPreviewTask?.cancel()
        scrollPreviewTask = nil
        scrollPreviewImage = nil
        scrollFinishTask?.cancel()
        scrollFinishTask = nil
    }

    func cancelScrollingProcessing(from overlay: OverlayWindowController) {
        if scrollingOverlay === overlay { cancelScrollingCapture() }
    }

    private func closeOverlays(restoringSourceApplication shouldRestoreSource: Bool = false) {
        stopScrollCaptureUI()
        captureSessionID = nil
        let closing = overlays
        overlays.removeAll()
        for overlay in closing { overlay.close() }
        if shouldRestoreSource { restoreSourceApplication() }
    }

    private func restoreOverlays(preferred overlay: OverlayWindowController?) {
        overlays.forEach { $0.window?.orderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        let target = overlay.flatMap { preferred in
            overlays.first(where: { $0 === preferred })
        } ?? overlays.first
        target?.window?.makeKeyAndOrderFront(nil)
        if let target {
            target.window?.makeFirstResponder(target.overlayView)
        }
    }

    private func restoreSourceApplication() {
        defer { sourceApplication = nil }
        guard let sourceApplication, !sourceApplication.isTerminated else { return }
        sourceApplication.activate(options: [])
    }

    private func showPermissionWindow() {
        if let permissionController {
            permissionController.showWindow(nil)
            return
        }
        let controller = PermissionWindowController()
        controller.onRetry = { [weak self, weak controller] in
            guard CGPreflightScreenCaptureAccess() else {
                self?.showError("系统仍未认可当前版本的授权。若设置中已开启，请先退出并重新打开 /Applications 中的 WeShot；更新前后的签名身份不同也会导致旧授权失效。")
                return
            }
            controller?.close()
            self?.startCapture()
        }
        permissionController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showError(_ message: String) {
        showMessage(title: "WeShot", text: message, copyable: false)
    }

    private func showMessage(title: String, text: String, copyable: Bool) {
        let controller = MessagePanelController(title: title, text: text, copyable: copyable)
        messagePanels.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.messagePanels.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
    }
}
