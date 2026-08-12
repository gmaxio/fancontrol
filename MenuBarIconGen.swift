//
//  MenuBarIconGen.swift
//  构建期工具: 渲染菜单栏图标 (macOS 原生五叶风扇, 18/36/54 px)
//  用法: MenuBarIconGen <输出目录>
//

import Cocoa

/// 使用 macOS 原生 fan.fill 轮廓，在小尺寸下比自绘螺旋桨更清晰，
/// 并与菜单栏里的其他系统图标保持一致。
func drawFanGlyph(rect: NSRect) {
    let pointSize = min(rect.width, rect.height) * 0.92
    let sizeConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [.black])
    let config = sizeConfig.applying(paletteConfig)
    guard let base = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil),
          let image = base.withSymbolConfiguration(config) else { return }

    let imageSize = image.size
    let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
    let target = NSRect(
        x: rect.midX - imageSize.width * scale / 2,
        y: rect.midY - imageSize.height * scale / 2,
        width: imageSize.width * scale,
        height: imageSize.height * scale
    )
    image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
}

/// 直接渲染到 bitmap 上下文, 输出 PNG data
func renderPNG(px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawFanGlyph(rect: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

@main
struct MenuBarIconGenTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("用法: MenuBarIconGen <输出目录>"); exit(1) }
        let dir = args[1]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let specs: [(String, Int)] = [
            ("menubar_icon.png", 18),
            ("menubar_icon@2x.png", 36),
            ("menubar_icon@3x.png", 54),
            ("menubar_preview_512.png", 512),
        ]
        var okAll = true
        for (name, px) in specs {
            if let data = renderPNG(px: px) {
                do {
                    try data.write(to: URL(fileURLWithPath: dir + "/" + name))
                    print("已生成: \(name)")
                } catch { okAll = false; print("写入失败: \(name)") }
            } else { okAll = false; print("渲染失败: \(name)") }
        }
        exit(okAll ? 0 : 1)
    }
}
