import AppKit
import CoreGraphics

enum CaptureOutputFailure: LocalizedError {
    case pngEncoding
    case pasteboardItem
    case pasteboardWrite
    case pasteboardRestore
    case pngDecode
    case dimensionMismatch(expected: CGSize, actual: CGSize)
    case pinWindow
    case pasteboardConsumer(String)

    var errorDescription: String? {
        switch self {
        case .pngEncoding:
            return "无法编码 PNG"
        case .pasteboardItem:
            return "无法创建剪贴板 PNG 数据"
        case .pasteboardWrite:
            return "系统剪贴板拒绝写入"
        case .pasteboardRestore:
            return "无法恢复测试前的剪贴板内容"
        case .pngDecode:
            return "无法解码输出 PNG"
        case .dimensionMismatch(let expected, let actual):
            return "输出尺寸不一致：期望 \(Int(expected.width))×\(Int(expected.height))，实际 \(Int(actual.width))×\(Int(actual.height))"
        case .pinWindow:
            return "钉图窗口生命周期验证失败"
        case .pasteboardConsumer(let detail):
            return "跨进程剪贴板消费失败：\(detail)"
        }
    }
}

struct PasteboardArchive: Equatable {
    fileprivate let items: [[NSPasteboard.PasteboardType: Data]]
}

@MainActor
enum CaptureOutputService {
    static func pngData(for image: CGImage) throws -> Data {
        guard let data = ImageComposer.pngData(image) else {
            throw CaptureOutputFailure.pngEncoding
        }
        return data
    }

    @discardableResult
    static func writeToPasteboard(
        _ image: CGImage,
        pasteboard: NSPasteboard = .general
    ) throws -> Data {
        let png = try pngData(for: image)
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png) else {
            throw CaptureOutputFailure.pasteboardItem
        }
        if let tiff = nsImage.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw CaptureOutputFailure.pasteboardWrite
        }
        return png
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) throws -> Data {
        let data = try pngData(for: image)
        try writePNGData(data, to: url)
        return data
    }

    static func writePNGData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func archive(_ pasteboard: NSPasteboard) -> PasteboardArchive {
        PasteboardArchive(
            items: (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        )
    }

    static func restore(_ archive: PasteboardArchive, to pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        guard !archive.items.isEmpty else { return }
        let items = archive.items.compactMap { archived -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            var wroteType = false
            for (type, data) in archived {
                wroteType = item.setData(data, forType: type) || wroteType
            }
            return wroteType ? item : nil
        }
        guard !items.isEmpty, pasteboard.writeObjects(items) else {
            throw CaptureOutputFailure.pasteboardRestore
        }
    }

    static func requireRestored(_ archive: PasteboardArchive, in pasteboard: NSPasteboard) throws {
        guard self.archive(pasteboard) == archive else {
            throw CaptureOutputFailure.pasteboardRestore
        }
    }

    static func decodedSize(of data: Data) throws -> CGSize {
        guard let image = NSBitmapImageRep(data: data)?.cgImage else {
            throw CaptureOutputFailure.pngDecode
        }
        return CGSize(width: image.width, height: image.height)
    }

    static func requireSize(_ actual: CGSize, matches image: CGImage) throws {
        let expected = CGSize(width: image.width, height: image.height)
        guard actual == expected else {
            throw CaptureOutputFailure.dimensionMismatch(expected: expected, actual: actual)
        }
    }

    static func verifyPasteboardInChildProcess(matches image: CGImage) throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw CaptureOutputFailure.pasteboardConsumer("无法定位应用可执行文件")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--verify-pasteboard-png",
            "\(image.width)x\(image.height)",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CaptureOutputFailure.pasteboardConsumer(
                detail?.isEmpty == false ? detail! : "子进程状态 \(process.terminationStatus)"
            )
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        guard String(data: output, encoding: .utf8)?.contains("PASTEBOARD_CONSUMER PASS") == true else {
            throw CaptureOutputFailure.pasteboardConsumer("子进程未返回成功标记")
        }
    }
}
