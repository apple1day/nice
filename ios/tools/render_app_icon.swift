// macOS build tool only; not part of the iOS app target.
// Uses Apple's built-in WebP reader and writes an opaque sRGB PNG for actool.
import Foundation
import CoreGraphics
import ImageIO

struct IconError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func renderIcon(source: URL, destination: URL) throws {
    guard source.standardizedFileURL != destination.standardizedFileURL else {
        throw IconError(message: "图标源文件与输出文件不能相同。")
    }
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        throw IconError(message: "无法读取图标源文件：\(source.path)")
    }
    guard image.width == 1024 && image.height == 1024 else {
        throw IconError(message: "图标源文件必须是 1024 × 1024 像素。")
    }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: 1024, height: 1024,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw IconError(message: "无法创建不透明 RGB 图标画布。")
    }
    let bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    context.setFillColor(CGColor(red: 0.02, green: 0.03, blue: 0.12, alpha: 1))
    context.fill(bounds)
    context.interpolationQuality = .high
    context.draw(image, in: bounds)
    guard let rendered = context.makeImage() else {
        throw IconError(message: "无法生成 App 图标像素。")
    }
    let bytes = NSMutableData()
    guard let encoder = CGImageDestinationCreateWithData(bytes as CFMutableData, "public.png" as CFString, 1, nil) else {
        throw IconError(message: "无法创建 PNG 编码器。")
    }
    CGImageDestinationAddImage(encoder, rendered, nil)
    guard CGImageDestinationFinalize(encoder) else {
        throw IconError(message: "PNG 图标编码失败。")
    }
    let data = bytes as Data
    // PNG IHDR: 8-bit RGB (color type 2), not RGBA; no transparency chunks.
    guard data.count > 26, Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
          data[24] == 8, data[25] == 2 else {
        throw IconError(message: "生成的图标不是 8 位不透明 RGB PNG。")
    }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    // Avoid touching a valid identical image on every setup invocation.
    if (try? Data(contentsOf: destination)) != data {
        try data.write(to: destination, options: .atomic)
    }
    print("App 图标已准备：\(destination.path)（1024 × 1024，RGB，无 Alpha）")
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw IconError(message: "用法：xcrun swift render_app_icon.swift <1024源图片> <输出.png>")
    }
    try renderIcon(source: URL(fileURLWithPath: CommandLine.arguments[1]),
                   destination: URL(fileURLWithPath: CommandLine.arguments[2]))
} catch {
    FileHandle.standardError.write(Data(("图标生成失败：\(error.localizedDescription)\n").utf8))
    exit(1)
}
