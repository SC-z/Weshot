import AppKit
import UniformTypeIdentifiers

@MainActor
enum CaptureSavePanelFactory {
    static func make(defaultFilename: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename
        return panel
    }
}
