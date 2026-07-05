// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

private let outputDirectory = URL(fileURLWithPath: "Aquarius/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

private struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> Double {
        state = 2862933555777941757 &* state &+ 3037000493
        return Double((state >> 33) & 0x7fffffff) / Double(0x7fffffff)
    }
}

private func font(named name: String, size: CGFloat, fallbackWeight: NSFont.Weight = .regular) -> NSFont {
    if let preferred = NSFont(name: name, size: size) {
        return preferred
    }
    return NSFont.systemFont(ofSize: size, weight: fallbackWeight)
}

private func drawLine(_ points: [NSPoint], color: NSColor, width: CGFloat) {
    guard let first = points.first else { return }
    let path = NSBezierPath()
    path.move(to: first)
    for point in points.dropFirst() {
        path.line(to: point)
    }
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

private func drawWave(y: CGFloat, amplitude: CGFloat, period: CGFloat, x0: CGFloat, x1: CGFloat, color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    let step: CGFloat = 8
    var x = x0
    path.move(to: NSPoint(x: x0, y: y))
    while x <= x1 {
        let phase = (x - x0) / period * 2 * .pi
        path.line(to: NSPoint(x: x, y: y + sin(phase) * amplitude))
        x += step
    }
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

private func drawStar(at point: NSPoint, radius: CGFloat, color: NSColor) {
    color.setStroke()
    NSColor(white: 0.94, alpha: 0.95).setFill()
    let outer = NSBezierPath(ovalIn: NSRect(
        x: point.x - radius,
        y: point.y - radius,
        width: radius * 2,
        height: radius * 2
    ))
    outer.lineWidth = max(1.0, radius * 0.22)
    outer.fill()
    outer.stroke()

    let cross = NSBezierPath()
    cross.move(to: NSPoint(x: point.x - radius * 1.45, y: point.y))
    cross.line(to: NSPoint(x: point.x + radius * 1.45, y: point.y))
    cross.move(to: NSPoint(x: point.x, y: point.y - radius * 1.45))
    cross.line(to: NSPoint(x: point.x, y: point.y + radius * 1.45))
    cross.lineWidth = max(0.8, radius * 0.12)
    cross.stroke()
}

private func drawEngravedStroke(from start: NSPoint, to end: NSPoint, count: Int, color: NSColor, width: CGFloat) {
    guard count > 1 else { return }
    for index in 0..<count {
        let t = CGFloat(index) / CGFloat(count - 1)
        let sx = start.x + (end.x - start.x) * t
        let sy = start.y + (end.y - start.y) * t
        let offset = CGFloat(index - count / 2) * width * 2.1
        drawLine(
            [
                NSPoint(x: sx - width * 8, y: sy + offset),
                NSPoint(x: sx + width * 20, y: sy - offset * 0.28)
            ],
            color: color,
            width: width
        )
    }
}

private func drawPaperTexture(in rect: NSRect, seed: UInt64, density: Int, alpha: CGFloat) {
    var random = LCG(seed: seed)
    for _ in 0..<density {
        let x = rect.minX + CGFloat(random.next()) * rect.width
        let y = rect.minY + CGFloat(random.next()) * rect.height
        let gray = CGFloat(0.55 + random.next() * 0.25)
        NSColor(white: gray, alpha: alpha).setFill()
        NSRect(x: x, y: y, width: 1, height: 1).fill()
    }
}

private func drawEngravingField(size: CGFloat, topRect: NSRect, blue: NSColor) {
    NSColor(white: 0.925, alpha: 1).setFill()
    topRect.fill()
    drawPaperTexture(in: topRect, seed: 22092009, density: 8_500, alpha: 0.18)

    let gridColor = NSColor(white: 0.25, alpha: 0.19)
    for x in stride(from: topRect.minX - 80, through: topRect.maxX + 80, by: 116) {
        drawLine(
            [NSPoint(x: x, y: topRect.minY), NSPoint(x: x + 38, y: topRect.maxY)],
            color: gridColor,
            width: 1.1
        )
    }
    for y in stride(from: topRect.minY + 38, through: topRect.maxY - 24, by: 92) {
        drawLine(
            [NSPoint(x: topRect.minX, y: y), NSPoint(x: topRect.maxX, y: y + 14)],
            color: gridColor,
            width: 1.1
        )
    }

    let arcColor = NSColor(white: 0.16, alpha: 0.18)
    for radius in stride(from: size * 0.42, through: size * 0.92, by: size * 0.12) {
        let rect = NSRect(x: size * 0.08, y: topRect.minY - radius * 0.42, width: radius, height: radius)
        let path = NSBezierPath()
        path.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: radius / 2,
            startAngle: 8,
            endAngle: 125,
            clockwise: false
        )
        path.lineWidth = 1.0
        arcColor.setStroke()
        path.stroke()
    }

    let ink = NSColor(white: 0.12, alpha: 0.56)
    let paleInk = NSColor(white: 0.12, alpha: 0.23)
    let waterBlue = blue.withAlphaComponent(0.34)

    let stars = [
        NSPoint(x: 130, y: 860), NSPoint(x: 225, y: 760), NSPoint(x: 330, y: 815),
        NSPoint(x: 430, y: 705), NSPoint(x: 540, y: 780), NSPoint(x: 640, y: 650),
        NSPoint(x: 735, y: 740), NSPoint(x: 838, y: 610), NSPoint(x: 918, y: 705)
    ].map { NSPoint(x: $0.x / 1024 * size, y: $0.y / 1024 * size) }
    drawLine(stars, color: NSColor(white: 0.08, alpha: 0.22), width: 1.6)
    for (index, star) in stars.enumerated() {
        drawStar(at: star, radius: CGFloat(index % 3 + 4) / 1024 * size, color: ink)
    }

    let symbolInk = NSColor(white: 0.10, alpha: 0.11)
    for row in 0..<2 {
        let y = topRect.minY + size * (0.14 + CGFloat(row) * 0.095)
        for segment in 0..<3 {
            let startX = size * (0.08 + CGFloat(segment) * 0.13)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: startX, y: y))
            path.line(to: NSPoint(x: startX + size * 0.040, y: y + size * 0.058))
            path.line(to: NSPoint(x: startX + size * 0.080, y: y))
            path.line(to: NSPoint(x: startX + size * 0.120, y: y + size * 0.058))
            path.lineWidth = size * 0.030
            path.lineCapStyle = .butt
            symbolInk.setStroke()
            path.stroke()
        }
    }

    let figureFill = NSColor(white: 0.97, alpha: 0.52)
    let figureStroke = NSColor(white: 0.10, alpha: 0.48)

    let head = NSBezierPath(ovalIn: NSRect(
        x: size * 0.155,
        y: topRect.minY + size * 0.405,
        width: size * 0.105,
        height: size * 0.125
    ))
    NSColor(white: 0.96, alpha: 0.58).setFill()
    figureStroke.setStroke()
    head.lineWidth = size * 0.0045
    head.fill()
    head.stroke()

    let hair = NSBezierPath()
    hair.move(to: NSPoint(x: size * 0.160, y: topRect.minY + size * 0.500))
    hair.curve(
        to: NSPoint(x: size * 0.260, y: topRect.minY + size * 0.472),
        controlPoint1: NSPoint(x: size * 0.185, y: topRect.minY + size * 0.565),
        controlPoint2: NSPoint(x: size * 0.250, y: topRect.minY + size * 0.535)
    )
    hair.lineWidth = size * 0.006
    ink.setStroke()
    hair.stroke()
    for index in 0..<11 {
        let x = size * (0.168 + CGFloat(index) * 0.009)
        let curl = NSBezierPath()
        curl.move(to: NSPoint(x: x, y: topRect.minY + size * 0.505))
        curl.curve(
            to: NSPoint(x: x + size * 0.018, y: topRect.minY + size * 0.450),
            controlPoint1: NSPoint(x: x + size * 0.030, y: topRect.minY + size * 0.515),
            controlPoint2: NSPoint(x: x - size * 0.012, y: topRect.minY + size * 0.470)
        )
        curl.lineWidth = size * 0.0018
        paleInk.setStroke()
        curl.stroke()
    }

    let body = NSBezierPath()
    body.move(to: NSPoint(x: size * 0.170, y: topRect.minY + size * 0.405))
    body.curve(
        to: NSPoint(x: size * 0.485, y: topRect.minY + size * 0.285),
        controlPoint1: NSPoint(x: size * 0.230, y: topRect.minY + size * 0.340),
        controlPoint2: NSPoint(x: size * 0.380, y: topRect.minY + size * 0.372)
    )
    body.curve(
        to: NSPoint(x: size * 0.335, y: topRect.minY + size * 0.105),
        controlPoint1: NSPoint(x: size * 0.450, y: topRect.minY + size * 0.200),
        controlPoint2: NSPoint(x: size * 0.410, y: topRect.minY + size * 0.135)
    )
    body.curve(
        to: NSPoint(x: size * 0.120, y: topRect.minY + size * 0.170),
        controlPoint1: NSPoint(x: size * 0.235, y: topRect.minY + size * 0.080),
        controlPoint2: NSPoint(x: size * 0.160, y: topRect.minY + size * 0.120)
    )
    body.curve(
        to: NSPoint(x: size * 0.170, y: topRect.minY + size * 0.405),
        controlPoint1: NSPoint(x: size * 0.070, y: topRect.minY + size * 0.260),
        controlPoint2: NSPoint(x: size * 0.120, y: topRect.minY + size * 0.360)
    )
    body.close()
    body.lineWidth = size * 0.005
    figureFill.setFill()
    figureStroke.setStroke()
    body.fill()
    body.stroke()

    for index in 0..<22 {
        let t = CGFloat(index) / 21
        let start = NSPoint(x: size * (0.145 + t * 0.295), y: topRect.minY + size * (0.185 + sin(t * .pi) * 0.090))
        let end = NSPoint(x: start.x + size * 0.080, y: start.y + size * (0.185 - t * 0.050))
        drawLine([start, end], color: NSColor(white: 0.10, alpha: 0.15), width: size * 0.0014)
    }
    drawEngravedStroke(
        from: NSPoint(x: size * 0.145, y: topRect.minY + size * 0.160),
        to: NSPoint(x: size * 0.410, y: topRect.minY + size * 0.320),
        count: 18,
        color: NSColor(white: 0.10, alpha: 0.10),
        width: size * 0.0011
    )

    let rearArm = NSBezierPath()
    rearArm.move(to: NSPoint(x: size * 0.255, y: topRect.minY + size * 0.360))
    rearArm.curve(
        to: NSPoint(x: size * 0.468, y: topRect.minY + size * 0.468),
        controlPoint1: NSPoint(x: size * 0.315, y: topRect.minY + size * 0.435),
        controlPoint2: NSPoint(x: size * 0.400, y: topRect.minY + size * 0.450)
    )
    rearArm.lineWidth = size * 0.010
    figureStroke.setStroke()
    rearArm.stroke()

    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: size * 0.470, yBy: topRect.minY + size * 0.410)
    transform.rotate(byDegrees: -24)
    transform.concat()
    let urn = NSBezierPath()
    urn.move(to: NSPoint(x: -size * 0.105, y: -size * 0.085))
    urn.curve(
        to: NSPoint(x: size * 0.110, y: -size * 0.055),
        controlPoint1: NSPoint(x: -size * 0.045, y: -size * 0.135),
        controlPoint2: NSPoint(x: size * 0.085, y: -size * 0.130)
    )
    urn.curve(
        to: NSPoint(x: size * 0.095, y: size * 0.125),
        controlPoint1: NSPoint(x: size * 0.150, y: size * 0.015),
        controlPoint2: NSPoint(x: size * 0.130, y: size * 0.085)
    )
    urn.curve(
        to: NSPoint(x: -size * 0.095, y: size * 0.105),
        controlPoint1: NSPoint(x: size * 0.030, y: size * 0.170),
        controlPoint2: NSPoint(x: -size * 0.050, y: size * 0.160)
    )
    urn.curve(
        to: NSPoint(x: -size * 0.105, y: -size * 0.085),
        controlPoint1: NSPoint(x: -size * 0.135, y: size * 0.050),
        controlPoint2: NSPoint(x: -size * 0.150, y: -size * 0.030)
    )
    urn.close()
    urn.lineWidth = size * 0.006
    NSColor(white: 0.97, alpha: 0.64).setFill()
    urn.fill()
    ink.setStroke()
    urn.stroke()
    for offset in stride(from: -0.075, through: 0.075, by: 0.025) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: size * CGFloat(offset), y: -size * 0.075))
        line.curve(
            to: NSPoint(x: size * CGFloat(offset * 0.55), y: size * 0.120),
            controlPoint1: NSPoint(x: size * CGFloat(offset * 1.55), y: size * 0.015),
            controlPoint2: NSPoint(x: size * CGFloat(offset * 1.00), y: size * 0.080)
        )
        line.lineWidth = size * 0.0018
        paleInk.setStroke()
        line.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    for i in 0..<7 {
        drawWave(
            y: topRect.minY + size * (0.205 + CGFloat(i) * 0.037),
            amplitude: size * 0.012,
            period: size * 0.16,
            x0: size * 0.425,
            x1: size * 0.96,
            color: i % 2 == 0 ? waterBlue : paleInk,
            width: size * 0.0024
        )
    }

    for i in 0..<34 {
        let y = topRect.minY + size * (0.145 + CGFloat(i) * 0.012)
        drawWave(
            y: y,
            amplitude: size * 0.004,
            period: size * 0.11,
            x0: size * 0.38,
            x1: size * 0.98,
            color: NSColor(white: 0.08, alpha: 0.12),
            width: size * 0.0008
        )
    }

    let fineStroke = NSBezierPath()
    fineStroke.move(to: NSPoint(x: size * 0.09, y: topRect.minY + size * 0.47))
    fineStroke.curve(
        to: NSPoint(x: size * 0.44, y: topRect.minY + size * 0.42),
        controlPoint1: NSPoint(x: size * 0.15, y: topRect.minY + size * 0.61),
        controlPoint2: NSPoint(x: size * 0.35, y: topRect.minY + size * 0.55)
    )
    fineStroke.curve(
        to: NSPoint(x: size * 0.58, y: topRect.minY + size * 0.30),
        controlPoint1: NSPoint(x: size * 0.47, y: topRect.minY + size * 0.37),
        controlPoint2: NSPoint(x: size * 0.51, y: topRect.minY + size * 0.32)
    )
    fineStroke.lineWidth = size * 0.004
    ink.setStroke()
    fineStroke.stroke()

    let captionAttributes: [NSAttributedString.Key: Any] = [
        .font: font(named: "TimesNewRomanPS-ItalicMT", size: size * 0.033),
        .foregroundColor: NSColor(white: 0.16, alpha: 0.38)
    ]
    ("Aquarius" as NSString).draw(
        in: NSRect(x: size * 0.11, y: topRect.minY + size * 0.035, width: size * 0.24, height: size * 0.05),
        withAttributes: captionAttributes
    )
    ("Fig. XI" as NSString).draw(
        in: NSRect(x: size * 0.58, y: topRect.minY + size * 0.50, width: size * 0.20, height: size * 0.05),
        withAttributes: captionAttributes
    )
}

private func drawBlueLabel(size: CGFloat, labelRect: NSRect, blue: NSColor) {
    blue.setFill()
    labelRect.fill()
    drawPaperTexture(in: labelRect, seed: 11235813, density: 13_000, alpha: 0.12)

    let shine = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.08),
        NSColor.white.withAlphaComponent(0.0),
        NSColor.black.withAlphaComponent(0.07)
    ])
    shine?.draw(in: labelRect, angle: 90)

    let separator = NSBezierPath()
    separator.move(to: NSPoint(x: 0, y: labelRect.maxY))
    separator.line(to: NSPoint(x: size, y: labelRect.maxY))
    separator.lineWidth = max(1, size * 0.002)
    NSColor(white: 1, alpha: 0.45).setStroke()
    separator.stroke()
}

private func drawText(size: CGFloat, labelRect: NSRect, blue: NSColor) {
    let betaParagraph = NSMutableParagraphStyle()
    betaParagraph.alignment = .right
    betaParagraph.lineSpacing = -size * 0.004

    let betaAttributes: [NSAttributedString.Key: Any] = [
        .font: font(named: "SFProDisplay-Bold", size: size * 0.080, fallbackWeight: .bold),
        .foregroundColor: blue,
        .paragraphStyle: betaParagraph,
        .kern: size * 0.002
    ]
    ("Beta\nRelease" as NSString).draw(
        in: NSRect(x: size * 0.56, y: labelRect.maxY + size * 0.088, width: size * 0.38, height: size * 0.23),
        withAttributes: betaAttributes
    )

    let nameParagraph = NSMutableParagraphStyle()
    nameParagraph.alignment = .left
    nameParagraph.lineBreakMode = .byClipping

    var nameSize = size * 0.192
    var attributes: [NSAttributedString.Key: Any] = [:]
    var measured = NSSize(width: 0, height: 0)
    while nameSize > size * 0.09 {
        attributes = [
            .font: font(named: "AvenirNextCondensed-Heavy", size: nameSize, fallbackWeight: .heavy),
            .foregroundColor: NSColor.white,
            .paragraphStyle: nameParagraph,
            .kern: size * 0.006
        ]
        measured = ("Aquarius" as NSString).size(withAttributes: attributes)
        if measured.width < size * 0.86 && measured.height < labelRect.height * 0.72 {
            break
        }
        nameSize -= size * 0.005
    }

    ("Aquarius" as NSString).draw(
        in: NSRect(
            x: size * 0.086,
            y: labelRect.midY - measured.height * 0.58,
            width: size * 0.88,
            height: measured.height * 1.20
        ),
        withAttributes: attributes
    )
}

private func makeMasterIcon(size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let s = CGFloat(size)
    let clip = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: s * 0.19, yRadius: s * 0.19)
    clip.setClip()

    let blue = NSColor(calibratedRed: 0.0, green: 0.39, blue: 0.95, alpha: 1.0)
    let labelHeight = s * 0.348
    let labelRect = NSRect(x: 0, y: 0, width: s, height: labelHeight)
    let topRect = NSRect(x: 0, y: labelHeight, width: s, height: s - labelHeight)

    drawEngravingField(size: s, topRect: topRect, blue: blue)
    drawBlueLabel(size: s, labelRect: labelRect, blue: blue)
    drawText(size: s, labelRect: labelRect, blue: blue)

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

private func resize(_ source: NSBitmapImageRep, to size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: size, height: size)

    let image = NSImage(size: source.size)
    image.addRepresentation(source)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

private func save(_ bitmap: NSBitmapImageRep, named fileName: String) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: outputDirectory.appendingPathComponent(fileName), options: .atomic)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let master = makeMasterIcon(size: 1024)
var generated: [Int: NSBitmapImageRep] = [1024: master]
var current = master
for size in [512, 256, 128, 64, 32, 16] {
    current = resize(current, to: size)
    generated[size] = current
}

let outputs: [(String, Int)] = [
    ("Aquarius-AppIcon-16.png", 16),
    ("Aquarius-AppIcon-16@2x.png", 32),
    ("Aquarius-AppIcon-32.png", 32),
    ("Aquarius-AppIcon-32@2x.png", 64),
    ("Aquarius-AppIcon-128.png", 128),
    ("Aquarius-AppIcon-128@2x.png", 256),
    ("Aquarius-AppIcon-256.png", 256),
    ("Aquarius-AppIcon-256@2x.png", 512),
    ("Aquarius-AppIcon-512.png", 512),
    ("Aquarius-AppIcon-512@2x.png", 1024)
]

for (fileName, size) in outputs {
    guard let bitmap = generated[size] else { continue }
    try save(bitmap, named: fileName)
}

print("Generated Aquarius AppIcon PNGs in \(outputDirectory.path)")
