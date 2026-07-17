import AppKit
import CoreGraphics

@MainActor
final class PermissionWindowController: NSWindowController {
    var onRetry: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "允许 WeShot 截取屏幕"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let icon = NSImageView(image: NSImage(systemSymbolName: "rectangle.dashed.badge.record", accessibilityDescription: "屏幕录制权限") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        icon.contentTintColor = .systemGreen

        let title = NSTextField(labelWithString: "需要“屏幕与系统音频录制”权限")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center

        let detail = NSTextField(wrappingLabelWithString: "WeShot 只在你发起截图时读取屏幕，截图在内存中处理；除非你主动保存，否则不会写入磁盘。请在系统设置中启用 WeShot，然后返回重新检测。")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 4

        let settings = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        settings.bezelStyle = .rounded
        let retry = NSButton(title: "重新检测", target: self, action: #selector(retryPermission))
        retry.bezelStyle = .rounded
        retry.keyEquivalent = "\r"
        let buttons = NSStackView(views: [settings, retry])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [icon, title, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -36),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { break }
        }
    }

    @objc private func retryPermission() { onRetry?() }
}

@MainActor
final class MessagePanelController: NSWindowController {
    var onClose: (() -> Void)?
    private let text: String

    init(title: String, text: String, copyable: Bool) {
        self.text = text
        let window = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = copyable
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = CGSize(width: 10, height: 10)
        scroll.documentView = textView

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        closeButton.keyEquivalent = "\u{1b}"
        let copyButton = NSButton(title: "复制", target: self, action: #selector(copyText))
        copyButton.isHidden = !copyable
        copyButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [closeButton, copyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(buttons)
        window.contentView = content
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func closePanel() { close() }
}

extension MessagePanelController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.onClose?() }
    }
}

@MainActor
final class PinWindowController: NSWindowController {
    var onClose: (() -> Void)?

    init(image: CGImage, origin: CGPoint, preferredSize: CGSize? = nil) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) }) ?? NSScreen.main
        let visibleFrame = (screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
            .insetBy(dx: 8, dy: 8)
        let backingScale = max(1, screen?.backingScaleFactor ?? 2)
        let pixelPointSize = CGSize(
            width: CGFloat(image.width) / backingScale,
            height: CGFloat(image.height) / backingScale
        )
        let requested = preferredSize.flatMap { size in
            size.width > 0 && size.height > 0 ? size : nil
        } ?? pixelPointSize

        let minimumScale = max(120 / requested.width, 80 / requested.height)
        let capScale = min(
            720 / max(requested.width, requested.height),
            visibleFrame.width / requested.width,
            visibleFrame.height / requested.height
        )
        let displayScale = min(max(1, minimumScale), capScale)
        let effectiveMinimumScale = min(minimumScale, capScale)
        let displaySize = CGSize(
            width: requested.width * displayScale,
            height: requested.height * displayScale
        )
        let minimumSize = CGSize(
            width: requested.width * effectiveMinimumScale,
            height: requested.height * effectiveMinimumScale
        )
        let panelOrigin = CGPoint(
            x: min(max(visibleFrame.minX, origin.x), max(visibleFrame.minX, visibleFrame.maxX - displaySize.width)),
            y: min(max(visibleFrame.minY, origin.y), max(visibleFrame.minY, visibleFrame.maxY - displaySize.height))
        )
        let panel = PinPanel(
            contentRect: CGRect(origin: panelOrigin, size: displaySize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(
            width: min(minimumSize.width, visibleFrame.width),
            height: min(minimumSize.height, visibleFrame.height)
        )
        panel.maxSize = visibleFrame.size
        panel.aspectRatio = requested
        super.init(window: panel)
        panel.delegate = self

        let imageView = PinImageView(frame: CGRect(origin: .zero, size: displaySize))
        imageView.image = NSImage(cgImage: image, size: displaySize)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        imageView.autoresizingMask = [.width, .height]
        panel.contentView = imageView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless()
    }
}

extension PinWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.onClose?() }
    }
}

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PinImageView: NSImageView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.close()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let closeItem = NSMenuItem(title: "关闭钉图", action: #selector(closePin), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func closePin() { window?.close() }
}

@MainActor
final class ScrollControlPanelController: NSWindowController {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    let selectionBorderWindow: NSWindow
    let previewWindow: NSWindow
    let previewImageView: NSImageView
    let finishButton: NSButton
    private let makesKeyOnShow: Bool

    init(near selection: CGRect, on screen: NSScreen?, excludedFromCapture: Bool = true) {
        let size = CGSize(width: 330, height: 38)
        let available = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(selection.maxX - size.width, available.minX + 8), available.maxX - size.width - 8)
        let below = selection.minY - size.height - 8
        let y = below >= available.minY + 8
            ? below
            : min(selection.maxY + 8, available.maxY - size.height - 8)
        let origin = CGPoint(x: x, y: y)

        let panel = ScrollControlPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = excludedFromCapture ? .none : .readOnly
        makesKeyOnShow = excludedFromCapture

        let border = NSPanel(
            contentRect: selection,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        border.level = .screenSaver
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.isReleasedWhenClosed = false
        border.sharingType = excludedFromCapture ? .none : .readOnly
        border.contentView = ScrollSelectionBorderView(frame: CGRect(origin: .zero, size: selection.size))
        selectionBorderWindow = border

        let previewSize = CGSize(width: 150, height: min(260, max(120, selection.height)))
        let previewX: CGFloat
        if selection.maxX + previewSize.width + 8 <= available.maxX {
            previewX = selection.maxX + 8
        } else if selection.minX - previewSize.width - 8 >= available.minX {
            previewX = selection.minX - previewSize.width - 8
        } else {
            previewX = min(max(selection.maxX - previewSize.width - 8, available.minX + 8), available.maxX - previewSize.width - 8)
        }
        let previewY = min(max(selection.maxY - previewSize.height, available.minY + 8), available.maxY - previewSize.height - 8)
        let preview = NSPanel(
            contentRect: CGRect(origin: CGPoint(x: previewX, y: previewY), size: previewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        preview.level = .screenSaver
        preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        preview.isOpaque = true
        preview.backgroundColor = NSColor.black.withAlphaComponent(0.82)
        preview.hasShadow = true
        preview.ignoresMouseEvents = true
        preview.isReleasedWhenClosed = false
        preview.sharingType = excludedFromCapture ? .none : .readOnly
        let imageView = NSImageView(frame: CGRect(origin: .zero, size: previewSize).insetBy(dx: 5, dy: 5))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        preview.contentView = imageView
        previewWindow = preview
        previewImageView = imageView

        let finish = NSButton(title: "结束", target: nil, action: nil)
        finish.bezelStyle = .rounded
        finish.bezelColor = NSColor(calibratedRed: 88 / 255, green: 192 / 255, blue: 125 / 255, alpha: 1)
        finish.contentTintColor = .white
        finish.translatesAutoresizingMaskIntoConstraints = false
        finishButton = finish
        super.init(window: panel)

        panel.onFinish = { [weak self] in self?.onFinish?() }
        panel.onCancel = { [weak self] in self?.onCancel?() }

        let background = NSView(frame: CGRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        background.layer?.cornerRadius = 7
        let title = NSTextField(labelWithString: "滚动页面截取更多内容")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false
        finish.target = self
        finish.action = #selector(finishScrolling)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelScrolling))
        cancel.bezelStyle = .rounded
        cancel.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(title)
        background.addSubview(cancel)
        background.addSubview(finish)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 52),
            finish.leadingAnchor.constraint(equalTo: cancel.trailingAnchor, constant: 6),
            finish.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            finish.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            finish.widthAnchor.constraint(equalToConstant: 52),
        ])
        panel.contentView = background
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        selectionBorderWindow.orderFrontRegardless()
        previewWindow.orderFrontRegardless()
        if makesKeyOnShow {
            super.showWindow(sender)
            window?.orderFrontRegardless()
            window?.makeKey()
        } else {
            // Visual smoke mode must not become key: an approval/Return event
            // from the harness would otherwise look like the user's Finish.
            window?.orderFrontRegardless()
        }
    }

    override func close() {
        selectionBorderWindow.close()
        previewWindow.close()
        super.close()
    }

    func updatePreview(_ image: CGImage) {
        previewImageView.image = NSImage(
            cgImage: image,
            size: CGSize(width: image.width, height: image.height)
        )
    }

    @objc private func finishScrolling() { onFinish?() }
    @objc private func cancelScrolling() { onCancel?() }
}

private final class ScrollSelectionBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedRed: 88 / 255, green: 192 / 255, blue: 125 / 255, alpha: 1).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}

final class ScrollControlPanel: NSPanel {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onFinish?()
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}
