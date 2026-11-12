import AppKit

guard CommandLine.arguments.count == 3 else {
    throw POSIXError(.EINVAL)
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: source) else {
    throw CocoaError(.fileReadCorruptFile)
}

let width = Int(image.size.width)
let height = Int(image.size.height)
// Render into a transparent canvas because Quick Look thumbnails add a white background.
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB), let canvas = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    throw CocoaError(.fileWriteUnknown)
}
let bounds = CGRect(x: 0, y: 0, width: width, height: height)
canvas.clear(bounds)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
image.draw(in: bounds)
NSGraphicsContext.restoreGraphicsState()

guard let rendered = canvas.makeImage(),
      let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
}
try png.write(to: output)
