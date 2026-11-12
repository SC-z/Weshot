import AppKit
import Testing
@testable import WeShotApp

@Suite("Editor input regression")
@MainActor
struct EditorInteractionRegressionTests {
    @Test("Escape cancels the active text field without committing its draft")
    func cancelTextDraft() throws {
        let controller = try makeEditor()
        defer { controller.close() }
        let view = controller.overlayView!
        view.state.tool = .text
        mouse(.leftMouseDown, CGPoint(x: 200, y: 200), in: controller)
        let field = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "discard this draft"
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(view.subviews.compactMap { $0 as? NSTextField }.isEmpty)
        #expect(view.state.annotations.isEmpty)
        #expect(controller.window?.firstResponder === view)
        #expect(view.state.selection != nil)
    }

    @Test("Return commits text once and an old end-editing notification cannot commit a new field")
    func commitTextOnce() throws {
        let controller = try makeEditor()
        defer { controller.close() }
        let view = controller.overlayView!
        view.state.tool = .text
        mouse(.leftMouseDown, CGPoint(x: 200, y: 200), in: controller)
        let oldField = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
        let editor = try #require(oldField.currentEditor() as? NSTextView)
        editor.string = "confirmed"
        editor.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        #expect(view.state.annotations.count == 1)
        mouse(.leftMouseDown, CGPoint(x: 240, y: 220), in: controller)
        let newField = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
        view.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: oldField))
        #expect(newField.superview === view)
        #expect(view.state.annotations.count == 1)
        view.deactivateSelection()
        #expect(view.subviews.compactMap { $0 as? NSTextField }.isEmpty)
        #expect(view.state.annotations.isEmpty)
    }

    @Test("A pen click creates a visible dot and Command-Z removes it")
    func penClickAndUndo() throws {
        let controller = try makeEditor()
        defer { controller.close() }
        let view = controller.overlayView!
        view.state.tool = .pen
        mouse(.leftMouseDown, CGPoint(x: 200, y: 200), in: controller)
        mouse(.leftMouseUp, CGPoint(x: 200, y: 200), in: controller)
        #expect(view.state.annotations.count == 1)
        guard case .pen(let points, _, _) = view.state.annotations.first else {
            Issue.record("Expected a pen annotation")
            return
        }
        #expect(points == [CGPoint(x: 200, y: 200)])
        let base = DesktopCaptureService.fixtureImage(size: CGSize(width: 48, height: 48), scale: 1)
        let bounds = CGRect(x: 0, y: 0, width: 48, height: 48)
        let image = try #require(ImageComposer.compose(base: base, viewBounds: bounds, selection: bounds,
            annotations: [.pen([CGPoint(x: 24, y: 24)], .red, 8)]))
        let pixel = try #require(PixelSampler.rgb(in: image, x: 24, y: 24))
        #expect(pixel.red > 240 && pixel.green < 20 && pixel.blue < 20)
        let undo = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        view.keyDown(with: undo)
        #expect(view.state.annotations.isEmpty)
    }

    @Test("Pen release retains the final pointer position and clips it to the selection")
    func penFinalPoint() throws {
        let controller = try makeEditor()
        defer { controller.close() }
        let view = controller.overlayView!
        view.state.tool = .pen
        mouse(.leftMouseDown, CGPoint(x: 200, y: 200), in: controller)
        mouse(.leftMouseDragged, CGPoint(x: 250, y: 230), in: controller)
        mouse(.leftMouseUp, CGPoint(x: 900, y: 250), in: controller)
        guard case .pen(let points, _, _) = view.state.annotations.first else {
            Issue.record("Expected a pen annotation")
            return
        }
        #expect(points == [CGPoint(x: 200, y: 200), CGPoint(x: 250, y: 230), CGPoint(x: 680, y: 250)])
    }

    private func makeEditor() throws -> OverlayWindowController {
        let screen = try #require(NSScreen.screens.first)
        let snapshot = ScreenSnapshot(screen: screen,
            displayID: DesktopCaptureService.displayID(for: screen) ?? CGMainDisplayID(),
            image: DesktopCaptureService.fixtureImage(size: screen.frame.size, scale: 1))
        let controller = OverlayWindowController(snapshot: snapshot, coordinator: CaptureCoordinator())
        controller.overlayView.state.selection = CGRect(x: 80, y: 80, width: 600, height: 400)
        return controller
    }

    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in controller: OverlayWindowController) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        switch type {
        case .leftMouseDown: controller.overlayView.mouseDown(with: event)
        case .leftMouseDragged: controller.overlayView.mouseDragged(with: event)
        case .leftMouseUp: controller.overlayView.mouseUp(with: event)
        default: break
        }
    }
}
