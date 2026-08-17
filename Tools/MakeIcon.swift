// Рисует иконку приложения и раскладывает её в .iconset для iconutil.
// Запуск: swift Tools/MakeIcon.swift <путь к .iconset>

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DaktRecorder.iconset"
let outputDir = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func drawIcon(side: CGFloat) {
    let full = CGRect(x: 0, y: 0, width: side, height: side)
    NSColor.clear.set()
    full.fill()

    // Корпус: тёмный скруглённый квадрат с вертикальным градиентом.
    let plate = NSBezierPath(roundedRect: full.insetBy(dx: side * 0.055, dy: side * 0.055),
                            xRadius: side * 0.225, yRadius: side * 0.225)
    let backdrop = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.23, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    ])
    backdrop?.draw(in: plate, angle: -90)

    // Красное свечение снизу — намёк на индикатор записи.
    let glow = NSGradient(colors: [
        NSColor(calibratedRed: 0.92, green: 0.16, blue: 0.22, alpha: 0.55),
        NSColor(calibratedRed: 0.92, green: 0.16, blue: 0.22, alpha: 0.0)
    ])
    plate.addClip()
    glow?.draw(in: NSRect(x: 0, y: 0, width: side, height: side * 0.55), angle: 90)

    // Микрофон: капсула, дуга и ножка.
    NSColor.white.set()
    let capsuleWidth = side * 0.22
    let capsuleHeight = side * 0.34
    let capsule = NSBezierPath(roundedRect: NSRect(x: (side - capsuleWidth) / 2,
                                                  y: side * 0.42,
                                                  width: capsuleWidth,
                                                  height: capsuleHeight),
                               xRadius: capsuleWidth / 2,
                               yRadius: capsuleWidth / 2)
    capsule.fill()

    let arc = NSBezierPath()
    arc.lineWidth = side * 0.055
    arc.lineCapStyle = .round
    arc.appendArc(withCenter: NSPoint(x: side / 2, y: side * 0.455),
                  radius: side * 0.2,
                  startAngle: 200,
                  endAngle: 340,
                  clockwise: false)
    arc.stroke()

    let stem = NSBezierPath()
    stem.lineWidth = side * 0.055
    stem.lineCapStyle = .round
    stem.move(to: NSPoint(x: side / 2, y: side * 0.255))
    stem.line(to: NSPoint(x: side / 2, y: side * 0.175))
    stem.stroke()
}

func render(side: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: side,
                                     pixelsHigh: side,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "MakeIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Не удалось создать контекст \(side)×\(side)"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawIcon(side: CGFloat(side))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MakeIcon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Не удалось закодировать PNG \(side)×\(side)"])
    }
    return data
}

// Имена, которые ждёт iconutil.
let variants: [(name: String, side: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let data = try render(side: variant.side)
    try data.write(to: outputDir.appendingPathComponent("\(variant.name).png"))
}
print("Иконка: \(outputDir.path) (\(variants.count) размеров)")
