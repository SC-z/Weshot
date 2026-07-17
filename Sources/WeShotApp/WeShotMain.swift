import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

@main
enum WeShotMain {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--self-test") {
            let result = CommandLineMode.runSelfTest()
            print(result.message)
            fflush(stdout)
            exit(result.passed ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        if arguments.contains("--permission-status") {
            print("SCREEN_CAPTURE_PERMISSION \(CGPreflightScreenCaptureAccess() ? "GRANTED" : "NOT_GRANTED")")
            fflush(stdout)
            exit(EXIT_SUCCESS)
        }

        if let index = arguments.firstIndex(of: "--verify-pasteboard-png") {
            let size = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
            do {
                try CommandLineMode.verifyPasteboardPNG(expectedSize: size)
                print("PASTEBOARD_CONSUMER PASS size=\(size)")
                fflush(stdout)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("PASTEBOARD_CONSUMER FAIL \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        if let index = arguments.firstIndex(of: "--render-fixture") {
            let path = arguments.indices.contains(index + 1) ? arguments[index + 1] : "weshot-render-fixture.png"
            do {
                let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                try CommandLineMode.renderFixture(to: url.standardizedFileURL)
                print("RENDER_FIXTURE PASS \(url.standardizedFileURL.path)")
                fflush(stdout)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("RENDER_FIXTURE FAIL \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        let application = NSApplication.shared
        if let index = arguments.firstIndex(of: "--render-editor-fixture") {
            let path = arguments.indices.contains(index + 1) ? arguments[index + 1] : "weshot-editor-fixture.png"
            do {
                let url = URL(
                    fileURLWithPath: path,
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
                try CommandLineMode.renderEditorFixture(to: url)
                print("RENDER_EDITOR_FIXTURE PASS \(url.path)")
                fflush(stdout)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("RENDER_EDITOR_FIXTURE FAIL \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        let translationSmokeText: String?
        if let index = arguments.firstIndex(of: "--translation-smoke") {
            translationSmokeText = arguments.indices.contains(index + 1) ? arguments[index + 1] : "Hello"
        } else {
            translationSmokeText = nil
        }

        let captureSmokePath: String?
        if let index = arguments.firstIndex(of: "--capture-smoke") {
            captureSmokePath = arguments.indices.contains(index + 1)
                ? arguments[index + 1]
                : "weshot-capture-smoke.png"
        } else {
            captureSmokePath = nil
        }

        let workflowSmokeDirectory: String?
        if let index = arguments.firstIndex(of: "--workflow-smoke") {
            workflowSmokeDirectory = arguments.indices.contains(index + 1)
                ? arguments[index + 1]
                : "weshot-workflow-smoke"
        } else {
            workflowSmokeDirectory = nil
        }

        let scrollSystemSmokeDirectory: String?
        if let index = arguments.firstIndex(of: "--scroll-system-smoke") {
            scrollSystemSmokeDirectory = arguments.indices.contains(index + 1)
                ? arguments[index + 1]
                : "weshot-scroll-system-smoke"
        } else {
            scrollSystemSmokeDirectory = nil
        }

        let visibleUISmokeDirectory: String?
        if let index = arguments.firstIndex(of: "--visible-ui-smoke") {
            visibleUISmokeDirectory = arguments.indices.contains(index + 1)
                ? arguments[index + 1]
                : "weshot-visible-ui-smoke"
        } else {
            visibleUISmokeDirectory = nil
        }

        let delegate = AppDelegate(
            translationSmokeText: translationSmokeText,
            captureSmokePath: captureSmokePath,
            workflowSmokeDirectory: workflowSmokeDirectory,
            scrollSystemSmokeDirectory: scrollSystemSmokeDirectory,
            visibleUISmokeDirectory: visibleUISmokeDirectory,
            hotKeySmoke: arguments.contains("--hotkey-smoke"),
            hotKeyEventSmoke: arguments.contains("--hotkey-event-smoke"),
            hotKeyPhysicalSmoke: arguments.contains("--hotkey-physical-smoke"),
            launchCapture: arguments.contains("--capture-now")
        )
        application.delegate = delegate
        // NSApplication.delegate is weak. Keep the programmatic delegate alive
        // for the whole event loop or a release build may silently lose the
        // status item and hot key before the first event.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hideAuxiliaryWindowsKey = "hideAuxiliaryWindowsDuringCapture"
    let coordinator = CaptureCoordinator()
    private let translationSmokeText: String?
    private let captureSmokePath: String?
    private let workflowSmokeDirectory: String?
    private let scrollSystemSmokeDirectory: String?
    private let visibleUISmokeDirectory: String?
    private let hotKeySmoke: Bool
    private let hotKeyEventSmoke: Bool
    private let hotKeyPhysicalSmoke: Bool
    private let launchCapture: Bool
    private var statusItem: NSStatusItem?
    private var captureMenuItem: NSMenuItem?
    private var hideAuxiliaryWindowsItem: NSMenuItem?
    private var hotKeyManager: GlobalHotKeyManager?
    private var shortcut = HotKeyShortcut.default

    init(
        translationSmokeText: String?,
        captureSmokePath: String?,
        workflowSmokeDirectory: String?,
        scrollSystemSmokeDirectory: String?,
        visibleUISmokeDirectory: String?,
        hotKeySmoke: Bool,
        hotKeyEventSmoke: Bool,
        hotKeyPhysicalSmoke: Bool,
        launchCapture: Bool
    ) {
        self.translationSmokeText = translationSmokeText
        self.captureSmokePath = captureSmokePath
        self.workflowSmokeDirectory = workflowSmokeDirectory
        self.scrollSystemSmokeDirectory = scrollSystemSmokeDirectory
        self.visibleUISmokeDirectory = visibleUISmokeDirectory
        self.hotKeySmoke = hotKeySmoke
        self.hotKeyEventSmoke = hotKeyEventSmoke
        self.hotKeyPhysicalSmoke = hotKeyPhysicalSmoke
        self.launchCapture = launchCapture
        if !hotKeySmoke, !hotKeyEventSmoke, !hotKeyPhysicalSmoke {
            shortcut = HotKeyShortcut.load()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.hidesAuxiliaryWindowsDuringCapture =
            UserDefaults.standard.object(forKey: Self.hideAuxiliaryWindowsKey) as? Bool ?? true
        installStatusItem()
        let hotKeyRegistered = registerHotKey(shortcut)
        if !hotKeyRegistered {
            statusItem?.button?.toolTip = "WeShot · \(shortcut.displayName) 已被其他应用占用，可从菜单截图"
        }
        if hotKeySmoke {
            print("HOTKEY_SMOKE \(hotKeyRegistered ? "PASS" : "FAIL") shortcut=⌃⌘A")
            fflush(stdout)
            exit(hotKeyRegistered ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if hotKeyEventSmoke {
            guard hotKeyRegistered else {
                fputs("HOTKEY_EVENT_SMOKE FAIL registration\n", stderr)
                exit(EXIT_FAILURE)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard self.hotKeyManager?.sendRegisteredEventForTesting() == true else {
                    fputs("HOTKEY_EVENT_SMOKE FAIL carbon-event-dispatch\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                fputs("HOTKEY_EVENT_SMOKE FAIL timeout\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        if hotKeyPhysicalSmoke {
            guard hotKeyRegistered else {
                fputs("HOTKEY_PHYSICAL_SMOKE FAIL registration\n", stderr)
                exit(EXIT_FAILURE)
            }
            guard CGPreflightPostEventAccess(), CGPreflightListenEventAccess() else {
                fputs("HOTKEY_PHYSICAL_SMOKE FAIL input-monitoring-permission\n", stderr)
                exit(EXIT_FAILURE)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard GlobalHotKeyManager.postPhysicalShortcutForTesting() else {
                    fputs("HOTKEY_PHYSICAL_SMOKE FAIL cghid-event-post\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                fputs("HOTKEY_PHYSICAL_SMOKE FAIL timeout\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        if let workflowSmokeDirectory {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                fputs("WORKFLOW_SMOKE FAIL timeout\n", stderr)
                exit(EXIT_FAILURE)
            }
            Task { @MainActor in
                do {
                    let directory = URL(
                        fileURLWithPath: workflowSmokeDirectory,
                        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    ).standardizedFileURL
                    let result = try await CommandLineMode.runWorkflowSmoke(in: directory)
                    print(
                        "WORKFLOW_SMOKE PASS displays=\(result.displayCount) " +
                            "size=\(result.width)x\(result.height) " +
                            "customSelection=PASS clipboard=PASS crossProcess=PASS " +
                            "file=PASS pin=PASS " +
                            "path=\(result.outputURL.path)"
                    )
                    fflush(stdout)
                    exit(EXIT_SUCCESS)
                } catch {
                    fputs("WORKFLOW_SMOKE FAIL \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        if let scrollSystemSmokeDirectory {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                fputs("SCROLL_SYSTEM_SMOKE FAIL timeout\n", stderr)
                exit(EXIT_FAILURE)
            }
            Task { @MainActor in
                do {
                    let directory = URL(
                        fileURLWithPath: scrollSystemSmokeDirectory,
                        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    ).standardizedFileURL
                    let result = try await ScrollSystemSmokeRunner.run(in: directory)
                    print(
                        "SCROLL_SYSTEM_SMOKE PASS frames=\(result.frameCount) " +
                            "frame=\(Int(result.frameSize.width))x\(Int(result.frameSize.height)) " +
                            "stitched=\(Int(result.stitchedSize.width))x\(Int(result.stitchedSize.height)) " +
                            "path=\(result.outputURL.path)"
                    )
                    fflush(stdout)
                    exit(EXIT_SUCCESS)
                } catch {
                    fputs("SCROLL_SYSTEM_SMOKE FAIL \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        if let visibleUISmokeDirectory {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                fputs("VISIBLE_UI_SMOKE FAIL timeout\n", stderr)
                exit(EXIT_FAILURE)
            }
            Task { @MainActor in
                do {
                    let directory = URL(
                        fileURLWithPath: visibleUISmokeDirectory,
                        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    ).standardizedFileURL
                    let result = try await VisibleUISmokeRunner.run(in: directory)
                    print(
                        "VISIBLE_UI_SMOKE PASS overlay=PASS customSelection=PASS annotation=PASS translationOverlay=PASS noResultWindow=PASS " +
                            "savePanelCancel=PASS restore=PASS savePanelConfirm=PASS " +
                            "pinDrag=PASS path=\(result.evidenceURL.path) saved=\(result.savedURL.path)"
                    )
                    fflush(stdout)
                    exit(EXIT_SUCCESS)
                } catch {
                    fputs("VISIBLE_UI_SMOKE FAIL \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        if let translationSmokeText {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                fputs("TRANSLATION_SMOKE FAIL timeout\n", stderr)
                exit(EXIT_FAILURE)
            }
            Task { @MainActor in
                let result = await CoreServiceBridge.translationController.translate(translationSmokeText)
                if let translated = result.translatedText, !translated.isEmpty {
                    print("TRANSLATION_SMOKE PASS source=\(result.sourceText) target=\(translated)")
                } else {
                    print("TRANSLATION_SMOKE FAIL \(result.statusMessage)")
                }
                fflush(stdout)
                exit(result.translatedText?.isEmpty == false ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            return
        }
        if let captureSmokePath {
            Task { @MainActor in
                guard CGPreflightScreenCaptureAccess() else {
                    fputs("CAPTURE_SMOKE FAIL screen-capture-permission-not-granted\n", stderr)
                    exit(EXIT_FAILURE)
                }
                do {
                    let snapshots = try await DesktopCaptureService.captureAllScreens()
                    guard let first = snapshots.first,
                          let png = ImageComposer.pngData(first.image)
                    else {
                        throw ScreenCaptureFailure.captureFailed("没有可写入的屏幕图像")
                    }
                    let url = URL(
                        fileURLWithPath: captureSmokePath,
                        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    ).standardizedFileURL
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try png.write(to: url, options: .atomic)
                    print(
                        "CAPTURE_SMOKE PASS displays=\(snapshots.count) " +
                            "size=\(first.image.width)x\(first.image.height) path=\(url.path)"
                    )
                    fflush(stdout)
                    exit(EXIT_SUCCESS)
                } catch {
                    fputs("CAPTURE_SMOKE FAIL \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        if launchCapture {
            DispatchQueue.main.async { [weak self] in self?.coordinator.startCapture() }
            return
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.unregister()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "WeShot")
            button.image?.isTemplate = true
            button.toolTip = "WeShot · 截图 \(shortcut.displayName)"
        }
        let menu = NSMenu()
        let capture = NSMenuItem(
            title: "截取屏幕",
            action: #selector(captureFromMenu),
            keyEquivalent: shortcut.keyEquivalent
        )
        capture.keyEquivalentModifierMask = shortcut.modifierFlags
        capture.target = self
        menu.addItem(capture)
        captureMenuItem = capture
        let changeShortcut = NSMenuItem(
            title: "修改快捷键…",
            action: #selector(changeShortcutFromMenu),
            keyEquivalent: ""
        )
        changeShortcut.target = self
        menu.addItem(changeShortcut)
        menu.addItem(.separator())
        let permission = NSMenuItem(title: "检查屏幕录制权限", action: #selector(checkPermission), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        let hideWindows = NSMenuItem(
            title: "截图时隐藏 WeShot 浮窗",
            action: #selector(toggleHideAuxiliaryWindows),
            keyEquivalent: ""
        )
        hideWindows.target = self
        hideWindows.state = coordinator.hidesAuxiliaryWindowsDuringCapture ? .on : .off
        menu.addItem(hideWindows)
        hideAuxiliaryWindowsItem = hideWindows
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 WeShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func captureFromMenu() { coordinator.startCapture() }

    @objc private func changeShortcutFromMenu() {
        let recorder = HotKeyRecorderField(shortcut: shortcut)
        let alert = NSAlert()
        alert.messageText = "修改截图快捷键"
        alert.informativeText = "请按下包含 ⌘、⌃ 或 ⌥ 的组合键，可同时使用 ⇧。"
        alert.accessoryView = recorder
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { alert.window.makeFirstResponder(recorder) }
        guard alert.runModal() == .alertFirstButtonReturn, recorder.shortcut != shortcut else { return }

        let previous = shortcut
        hotKeyManager?.unregister()
        hotKeyManager = nil
        guard registerHotKey(recorder.shortcut) else {
            _ = registerHotKey(previous)
            coordinator.showError("快捷键 \(recorder.shortcut.displayName) 已被系统或其他应用占用。")
            return
        }
        shortcut = recorder.shortcut
        shortcut.save()
        captureMenuItem?.keyEquivalent = shortcut.keyEquivalent
        captureMenuItem?.keyEquivalentModifierMask = shortcut.modifierFlags
        statusItem?.button?.toolTip = "WeShot · 截图 \(shortcut.displayName)"
    }

    @objc private func checkPermission() {
        if CGPreflightScreenCaptureAccess() {
            coordinator.showError("屏幕录制权限已启用。")
        } else {
            coordinator.startCapture()
        }
    }

    @objc private func toggleHideAuxiliaryWindows() {
        coordinator.hidesAuxiliaryWindowsDuringCapture.toggle()
        hideAuxiliaryWindowsItem?.state = coordinator.hidesAuxiliaryWindowsDuringCapture ? .on : .off
        UserDefaults.standard.set(
            coordinator.hidesAuxiliaryWindowsDuringCapture,
            forKey: Self.hideAuxiliaryWindowsKey
        )
    }

    private func waitForPhysicalHotKeyOverlay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let overlays = self.coordinator.overlays
            guard !overlays.isEmpty else {
                self.waitForPhysicalHotKeyOverlay()
                return
            }
            guard overlays.allSatisfy({
                $0.window?.isVisible == true && $0.window?.level == .screenSaver
            }) else {
                fputs("HOTKEY_PHYSICAL_SMOKE FAIL overlay-lifecycle\n", stderr)
                self.coordinator.cancelCapture()
                exit(EXIT_FAILURE)
            }
            let displayCount = overlays.count
            self.coordinator.cancelCapture()
            print(
                "HOTKEY_PHYSICAL_SMOKE PASS shortcut=⌃⌘A dispatch=cghid-event-tap " +
                    "capture=PASS overlay=PASS displays=\(displayCount)"
            )
            fflush(stdout)
            exit(EXIT_SUCCESS)
        }
    }

    private func registerHotKey(_ shortcut: HotKeyShortcut) -> Bool {
        let manager = GlobalHotKeyManager(shortcut: shortcut) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.hotKeyEventSmoke {
                    print("HOTKEY_EVENT_SMOKE PASS shortcut=⌃⌘A dispatch=registered-carbon-event")
                    fflush(stdout)
                    exit(EXIT_SUCCESS)
                }
                if self.hotKeyPhysicalSmoke {
                    self.coordinator.startCapture()
                    self.waitForPhysicalHotKeyOverlay()
                    return
                }
                self.coordinator.startCapture()
            }
        }
        guard manager.register() else { return false }
        hotKeyManager = manager
        return true
    }
}

struct HotKeyShortcut: Codable, Equatable {
    private static let storageKey = "captureHotKey"
    private static let supportedCarbonModifiers =
        UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey) | UInt32(cmdKey)

    static let `default` = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(controlKey) | UInt32(cmdKey),
        keyEquivalent: "a",
        keyName: "A"
    )

    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyEquivalent: String
    let keyName: String

    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, keyEquivalent: String) {
        let modifiers = Self.carbonModifiers(from: modifierFlags)
        guard modifiers & ~UInt32(shiftKey) != 0, let character = keyEquivalent.first else { return nil }
        self.init(
            keyCode: UInt32(keyCode),
            carbonModifiers: modifiers,
            keyEquivalent: String(character).lowercased(),
            keyName: Self.keyName(for: keyCode, fallback: String(character).uppercased())
        )
    }

    private init(keyCode: UInt32, carbonModifiers: UInt32, keyEquivalent: String, keyName: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyEquivalent = keyEquivalent
        self.keyName = keyName
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    var displayName: String {
        var value = ""
        if modifierFlags.contains(.control) { value += "⌃" }
        if modifierFlags.contains(.option) { value += "⌥" }
        if modifierFlags.contains(.shift) { value += "⇧" }
        if modifierFlags.contains(.command) { value += "⌘" }
        return value + keyName
    }

    static func load(from defaults: UserDefaults = .standard) -> HotKeyShortcut {
        guard let data = defaults.data(forKey: storageKey),
              let shortcut = try? PropertyListDecoder().decode(HotKeyShortcut.self, from: data),
              shortcut.carbonModifiers & ~UInt32(shiftKey) != 0,
              shortcut.carbonModifiers & ~supportedCarbonModifiers == 0,
              shortcut.keyCode <= UInt16.max,
              !shortcut.keyEquivalent.isEmpty,
              !shortcut.keyName.isEmpty
        else {
            return .default
        }
        return shortcut
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? PropertyListEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    private static func keyName(for keyCode: UInt16, fallback: String) -> String {
        [
            UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space",
            UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_DownArrow): "↓", UInt16(kVK_UpArrow): "↑",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        ][keyCode] ?? fallback
    }
}

final class HotKeyRecorderField: NSTextField {
    private(set) var shortcut: HotKeyShortcut

    init(shortcut: HotKeyShortcut) {
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 34))
        stringValue = shortcut.displayName
        alignment = .center
        font = .monospacedSystemFont(ofSize: 17, weight: .medium)
        isEditable = false
        isSelectable = false
        bezelStyle = .roundedBezel
        setAccessibilityLabel("截图快捷键")
        setAccessibilityHelp("按下包含修饰键的组合键")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers,
              let shortcut = HotKeyShortcut(
                  keyCode: event.keyCode,
                  modifierFlags: event.modifierFlags,
                  keyEquivalent: characters
              )
        else {
            NSSound.beep()
            return
        }
        self.shortcut = shortcut
        stringValue = shortcut.displayName
    }
}

final class GlobalHotKeyManager {
    private let handler: () -> Void
    private let shortcut: HotKeyShortcut
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let identifier = EventHotKeyID(signature: 0x57534854, id: 1) // WSHT

    init(shortcut: HotKeyShortcut = .default, handler: @escaping () -> Void) {
        self.shortcut = shortcut
        self.handler = handler
    }

    func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var received = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &received
                )
                guard status == noErr, received.signature == 0x57534854, received.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handler()
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else { return false }
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registerStatus == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        self.hotKeyRef = nil
        self.eventHandlerRef = nil
    }

    /// Dispatches the exact Carbon hot-key event shape to the installed
    /// application event target. This verifies registration, event decoding,
    /// identifier matching, and callback delivery without requiring macOS
    /// Accessibility permission to synthesize hardware input.
    func sendRegisteredEventForTesting() -> Bool {
        guard hotKeyRef != nil, eventHandlerRef != nil else { return false }
        var event: EventRef?
        let createStatus = CreateEvent(
            nil,
            OSType(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            GetCurrentEventTime(),
            EventAttributes(kEventAttributeUserEvent),
            &event
        )
        guard createStatus == noErr, let event else { return false }
        defer { ReleaseEvent(event) }

        var eventIdentifier = identifier
        let parameterStatus = SetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            &eventIdentifier
        )
        guard parameterStatus == noErr else { return false }
        return SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr
    }

    static func postPhysicalShortcutForTesting() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_A),
                  keyDown: true
              ),
              let up = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_A),
                  keyDown: false
              )
        else {
            return false
        }
        down.flags = [.maskControl, .maskCommand]
        up.flags = [.maskControl, .maskCommand]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    deinit { unregister() }
}

@MainActor
enum CommandLineMode {
    struct TestResult { let passed: Bool; let message: String }
    struct WorkflowSmokeResult {
        let displayCount: Int
        let width: Int
        let height: Int
        let outputURL: URL
    }

    static func runSelfTest() -> TestResult {
        var failures: [String] = []
        let normalized = CGRect.from(CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 5))
        if normalized != CGRect(x: 10, y: 5, width: 20, height: 35) { failures.append("selection normalization") }

        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let resized = ResizeAnchor.east.resized(CGRect(x: 100, y: 100, width: 200, height: 160), translation: CGSize(width: 50, height: 0), inside: bounds)
        if resized.width != 250 { failures.append("east resize") }

        let toolbar = ToolbarLayout.frame(for: CGRect(x: 180, y: 100, width: 420, height: 320), in: bounds)
        if !bounds.contains(toolbar) { failures.append("toolbar placement") }

        let base = DesktopCaptureService.fixtureImage(size: CGSize(width: 640, height: 400), scale: 1)
        let selection = CGRect(x: 40, y: 35, width: 500, height: 300)
        let annotations: [AppAnnotation] = [
            .rectangle(CGRect(x: 70, y: 70, width: 120, height: 80), .systemRed, 3),
            .ellipse(CGRect(x: 220, y: 90, width: 100, height: 60), .systemBlue, 4),
            .arrow(CGPoint(x: 100, y: 210), CGPoint(x: 310, y: 260), .systemGreen, 4),
            .pen([CGPoint(x: 350, y: 90), CGPoint(x: 390, y: 140), CGPoint(x: 440, y: 110)], .systemOrange, 3),
            .text(CGPoint(x: 90, y: 280), "WeShot", .white, 18),
            .mosaic(CGRect(x: 390, y: 220, width: 90, height: 45), 9),
        ]
        guard let output = ImageComposer.compose(base: base, viewBounds: CGRect(origin: .zero, size: CGSize(width: 640, height: 400)), selection: selection, annotations: annotations) else {
            failures.append("image composition")
            return TestResult(passed: false, message: "SELF_TEST FAIL: \(failures.joined(separator: ", "))")
        }
        if output.width != 500 || output.height != 300 { failures.append("output dimensions \(output.width)x\(output.height)") }
        guard let png = ImageComposer.pngData(output), png.count > 8 else { failures.append("PNG encoding"); return TestResult(passed: false, message: "SELF_TEST FAIL: \(failures.joined(separator: ", "))") }
        if Array(png.prefix(4)) != [0x89, 0x50, 0x4E, 0x47] { failures.append("PNG signature") }

        if failures.isEmpty {
            return TestResult(passed: true, message: "SELF_TEST PASS — geometry, toolbar, six annotations, composition, PNG")
        }
        return TestResult(passed: false, message: "SELF_TEST FAIL: \(failures.joined(separator: ", "))")
    }

    static func renderFixture(to url: URL) throws {
        let canvas = CGSize(width: 1120, height: 720)
        let base = DesktopCaptureService.fixtureImage(size: canvas, scale: 1)
        let selection = CGRect(x: 100, y: 90, width: 920, height: 540)
        let annotations: [AppAnnotation] = [
            .rectangle(CGRect(x: 150, y: 440, width: 230, height: 105), .systemRed, 4),
            .ellipse(CGRect(x: 430, y: 420, width: 175, height: 120), .systemOrange, 5),
            .arrow(CGPoint(x: 180, y: 180), CGPoint(x: 470, y: 350), .systemGreen, 6),
            .pen([CGPoint(x: 560, y: 170), CGPoint(x: 615, y: 230), CGPoint(x: 665, y: 185), CGPoint(x: 735, y: 285)], .systemBlue, 5),
            .text(CGPoint(x: 160, y: 125), "WeShot 截图编辑器 · 2026", .white, 26),
            .mosaic(CGRect(x: 745, y: 430, width: 190, height: 82), 13),
        ]
        guard let result = ImageComposer.compose(base: base, viewBounds: CGRect(origin: .zero, size: canvas), selection: selection, annotations: annotations),
              let data = ImageComposer.pngData(result) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func renderEditorFixture(to url: URL) throws {
        guard let screen = NSScreen.main,
              let displayID = DesktopCaptureService.displayID(for: screen)
        else {
            throw ScreenCaptureFailure.noScreens
        }
        let snapshot = ScreenSnapshot(
            screen: screen,
            displayID: displayID,
            image: DesktopCaptureService.fixtureImage(size: screen.frame.size, scale: 1)
        )
        let coordinator = CaptureCoordinator()
        let controller = OverlayWindowController(snapshot: snapshot, coordinator: coordinator)
        defer { controller.close() }
        controller.configureFixtureSelection()
        let view = controller.overlayView!
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func runWorkflowSmoke(in directory: URL) async throws -> WorkflowSmokeResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureFailure.captureFailed("没有屏幕录制权限")
        }
        let snapshots = try await DesktopCaptureService.captureAllScreens()
        guard let snapshot = snapshots.first else {
            throw ScreenCaptureFailure.noScreens
        }

        let coordinator = CaptureCoordinator()
        let controller = OverlayWindowController(snapshot: snapshot, coordinator: coordinator)
        defer { controller.close() }
        let view = controller.overlayView!
        let selectionSize = CGSize(
            width: min(640, max(160, view.bounds.width * 0.42)),
            height: min(360, max(100, view.bounds.height * 0.36))
        )
        let selection = CGRect(
            x: view.bounds.midX - selectionSize.width / 2,
            y: view.bounds.midY - selectionSize.height / 2,
            width: selectionSize.width,
            height: selectionSize.height
        ).integral
        view.state.selection = selection
        view.state.annotations = [
            .rectangle(selection.insetBy(dx: 12, dy: 12), .systemGreen, 3),
            .text(
                CGPoint(x: selection.minX + 24, y: selection.minY + 20),
                "WeShot workflow smoke",
                .white,
                18
            ),
        ]
        guard let image = view.composedImage() else {
            throw ScreenCaptureFailure.captureFailed("无法合成真实捕获选区")
        }

        let pasteboard = NSPasteboard.general
        let archive = CaptureOutputService.archive(pasteboard)
        var restoredPasteboard = false
        defer {
            if !restoredPasteboard {
                try? CaptureOutputService.restore(archive, to: pasteboard)
            }
        }
        _ = try CaptureOutputService.writeToPasteboard(image, pasteboard: pasteboard)
        try CaptureOutputService.verifyPasteboardInChildProcess(matches: image)
        guard let clipboardPNG = pasteboard.data(forType: .png) else {
            throw CaptureOutputFailure.pasteboardWrite
        }
        try CaptureOutputService.requireSize(
            CaptureOutputService.decodedSize(of: clipboardPNG),
            matches: image
        )
        try CaptureOutputService.restore(archive, to: pasteboard)
        try CaptureOutputService.requireRestored(archive, in: pasteboard)
        restoredPasteboard = true

        let outputURL = directory.appendingPathComponent("workflow-capture.png")
        let filePNG = try CaptureOutputService.writePNG(image, to: outputURL)
        let roundTrip = try Data(contentsOf: outputURL)
        guard roundTrip == filePNG else {
            throw ScreenCaptureFailure.captureFailed("原子保存后的 PNG 数据不一致")
        }
        try CaptureOutputService.requireSize(
            CaptureOutputService.decodedSize(of: roundTrip),
            matches: image
        )

        let pin = PinWindowController(
            image: image,
            origin: snapshot.screen.visibleFrame.origin,
            preferredSize: selection.size
        )
        guard let pinWindow = pin.window,
              pinWindow.level == .floating,
              pinWindow.contentView is NSImageView
        else {
            throw CaptureOutputFailure.pinWindow
        }
        pinWindow.alphaValue = 0
        pin.showWindow(nil)
        guard pinWindow.isVisible else {
            throw CaptureOutputFailure.pinWindow
        }
        pin.close()
        guard !pinWindow.isVisible else {
            throw CaptureOutputFailure.pinWindow
        }

        return WorkflowSmokeResult(
            displayCount: snapshots.count,
            width: image.width,
            height: image.height,
            outputURL: outputURL
        )
    }

    static func verifyPasteboardPNG(expectedSize: String) throws {
        let parts = expectedSize.split(separator: "x", maxSplits: 1)
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0,
              let data = NSPasteboard.general.data(forType: .png)
        else {
            throw CaptureOutputFailure.pasteboardConsumer("参数或系统 PNG 数据无效")
        }
        let actual = try CaptureOutputService.decodedSize(of: data)
        let expected = CGSize(width: width, height: height)
        guard actual == expected else {
            throw CaptureOutputFailure.dimensionMismatch(expected: expected, actual: actual)
        }
    }
}
