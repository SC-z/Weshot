import AppKit
import Foundation
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

enum TranslationSource: String, CaseIterable {
    case other, chinese

    var menuTitle: String { self == .chinese ? "中文译成" : "其他语言译成" }
    var defaultTarget: Locale.Language {
        Locale.Language(identifier: self == .chinese ? "en" : "zh-Hans")
    }

    private var preferenceKey: String { "translationTarget.\(rawValue)" }

    func target(in defaults: UserDefaults = .standard) -> Locale.Language {
        defaults.string(forKey: preferenceKey).map(Locale.Language.init(identifier:)) ?? defaultTarget
    }

    func setTarget(_ language: Locale.Language, in defaults: UserDefaults = .standard) {
        defaults.set(language.minimalIdentifier, forKey: preferenceKey)
    }

    static func displayName(for language: Locale.Language) -> String {
        if language.languageCode?.identifier == "zh" {
            return language.maximalIdentifier.hasPrefix("zh-Hant") ? "繁体中文" : "简体中文"
        }
        let identifier = language.minimalIdentifier
        return Locale(identifier: "zh-Hans").localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// AppKit cannot initialize TranslationSession directly. WeShot mounts an
/// invisible NSHostingView into the active capture overlay so SwiftUI can vend
/// the session without opening a separate translation window.
@MainActor
final class SystemTranslationController: TranslationController {
    private struct PendingRequest {
        let id: UUID
        let sourceText: String
        let continuation: CheckedContinuation<TranslationResult, Never>
    }

    private var pending: PendingRequest?
    private var hostView: NSView?
    private var fallbackHostWindow: NSWindow?

    func translate(_ text: String) async -> TranslationResult {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            return TranslationResult(
                sourceText: source,
                translatedText: nil,
                statusMessage: "截图中未识别到可翻译文字。"
            )
        }

        finishPending(
            with: TranslationResult(
                sourceText: pending?.sourceText ?? "",
                translatedText: nil,
                statusMessage: "新的翻译请求已替换上一个请求。"
            )
        )

        let requestID = UUID()
        let pair = Self.languagePair(
            for: source,
            otherTarget: TranslationSource.other.target(),
            chineseTarget: TranslationSource.chinese.target()
        )
        if pair.source?.minimalIdentifier == pair.target.minimalIdentifier {
            return TranslationResult(
                sourceText: source, translatedText: nil, statusMessage: "原文已是目标语言"
            )
        }
        let configuration = TranslationSession.Configuration(
            source: pair.source,
            target: pair.target
        )

        return await withCheckedContinuation { continuation in
            pending = PendingRequest(
                id: requestID,
                sourceText: source,
                continuation: continuation
            )
            mountRequestHost(
                sourceText: source,
                configuration: configuration,
                requestID: requestID
            )

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.pending?.id == requestID else { return }
                self.finishPending(
                    with: TranslationResult(
                        sourceText: source,
                        translatedText: nil,
                        statusMessage: "系统翻译等待超时。请检查网络或目标语言包后重试。"
                    )
                )
            }
        }
    }

    fileprivate func complete(_ result: TranslationResult, requestID: UUID) {
        guard pending?.id == requestID else { return }
        finishPending(with: result)
    }

    private func finishPending(with result: TranslationResult) {
        guard let request = pending else { return }
        pending = nil
        if fallbackHostWindow == nil {
            hostView?.removeFromSuperview()
        } else {
            fallbackHostWindow?.close()
        }
        fallbackHostWindow = nil
        hostView = nil
        request.continuation.resume(returning: result)
    }

    private func mountRequestHost(
        sourceText: String,
        configuration: TranslationSession.Configuration,
        requestID: UUID
    ) {
        let rootView = TranslationRequestView(
            sourceText: sourceText,
            configuration: configuration,
            requestID: requestID
        ) { [weak self] result, id in
            self?.complete(result, requestID: id)
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(x: -400, y: -200, width: 360, height: 116)
        hostingView.alphaValue = 0.001
        if let contentView = NSApp.keyWindow?.contentView {
            contentView.addSubview(hostingView)
            hostView = hostingView
            return
        }

        // Command-line translation smoke tests do not have an active overlay.
        let window = NSPanel(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 360, height: 116),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        hostingView.frame = CGRect(x: 0, y: 0, width: 360, height: 116)
        window.alphaValue = 0.001
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostView = hostingView
        fallbackHostWindow = window
    }

    static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    static func languagePair(
        for text: String,
        otherTarget: Locale.Language = TranslationSource.other.defaultTarget,
        chineseTarget: Locale.Language = TranslationSource.chinese.defaultTarget
    ) -> (source: Locale.Language?, target: Locale.Language) {
        let code = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        let containsHan = text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        // Japanese and Korean can contain Han characters without being Chinese.
        let isChinese = code?.hasPrefix("zh") == true || (containsHan && code != "ja" && code != "ko")
        let sourceIdentifier = isChinese ? (code?.lowercased().hasPrefix("zh") == true ? code : "zh-Hans") : code
        let source = sourceIdentifier.map { Locale.Language(identifier: $0) }
        let target = isChinese ? chineseTarget : otherTarget
        return (source, target)
    }
}

@available(macOS 15.0, *)
private struct TranslationRequestView: View {
    let sourceText: String
    let configuration: TranslationSession.Configuration
    let requestID: UUID
    let completion: @MainActor (TranslationResult, UUID) -> Void

    var body: some View {
        Color.clear
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
                let response = try await session.translate(sourceText)
                await MainActor.run {
                    completion(
                        TranslationResult(
                            sourceText: response.sourceText,
                            translatedText: response.targetText,
                            statusMessage: "已使用 macOS 本地翻译完成。"
                        ),
                        requestID
                    )
                }
            } catch {
                await MainActor.run {
                    completion(
                        TranslationResult(
                            sourceText: sourceText,
                            translatedText: nil,
                            statusMessage: "系统翻译失败：\(error.localizedDescription)"
                        ),
                        requestID
                    )
                }
            }
        }
    }
}
