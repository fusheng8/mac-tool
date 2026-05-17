#!/usr/bin/env swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let appIconSource = resources.appendingPathComponent("logo-source.png")
let statusIconName = "StatusIconRingGray.png"
let statusTemplateIconName = "StatusIconRingTemplate.png"
let targetResources = root
    .appendingPathComponent("Sources", isDirectory: true)
    .appendingPathComponent("MacToolApp", isDirectory: true)
    .appendingPathComponent("Resources", isDirectory: true)

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: targetResources, withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: iconset.path) {
    try FileManager.default.removeItem(at: iconset)
}
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func withGraphicsContext(size: Int, actions: (NSGraphicsContext, CGRect) -> Void) -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
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
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create graphics context")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    actions(context, CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawArc(
    center: CGPoint,
    radius: CGFloat,
    startAngle: CGFloat,
    endAngle: CGFloat,
    lineWidth: CGFloat,
    color: NSColor,
    lineCap: NSBezierPath.LineCapStyle = .round
) {
    let path = NSBezierPath()
    path.appendArc(
        withCenter: center,
        radius: radius,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: false
    )
    path.lineWidth = lineWidth
    path.lineCapStyle = lineCap
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

func drawMetalRing(center: CGPoint, radius: CGFloat, lineWidth: CGFloat, scale: CGFloat) {
    let start: CGFloat = 42
    let end: CGFloat = 318
    drawArc(
        center: center,
        radius: radius,
        startAngle: start,
        endAngle: end,
        lineWidth: lineWidth,
        color: color(0xD8DDE6)
    )
    drawArc(
        center: center,
        radius: radius,
        startAngle: 118,
        endAngle: 202,
        lineWidth: lineWidth,
        color: color(0xB8C5CE, alpha: 0.48),
        lineCap: .butt
    )
    drawArc(
        center: center,
        radius: radius,
        startAngle: 202,
        endAngle: 278,
        lineWidth: lineWidth,
        color: color(0xF7F2E4, alpha: 0.58),
        lineCap: .butt
    )
    drawArc(
        center: center,
        radius: radius,
        startAngle: 42,
        endAngle: 112,
        lineWidth: lineWidth,
        color: color(0xEEF2FF, alpha: 0.64),
        lineCap: .butt
    )

    drawArc(
        center: center,
        radius: radius + lineWidth * 0.20,
        startAngle: 50,
        endAngle: 308,
        lineWidth: max(2 * scale, lineWidth * 0.08),
        color: NSColor.white.withAlphaComponent(0.36)
    )
    drawArc(
        center: center,
        radius: radius - lineWidth * 0.32,
        startAngle: 54,
        endAngle: 304,
        lineWidth: max(2 * scale, lineWidth * 0.06),
        color: NSColor.black.withAlphaComponent(0.30)
    )

    drawArc(
        center: center,
        radius: radius,
        startAngle: 298,
        endAngle: 318,
        lineWidth: lineWidth,
        color: color(0xF59E0B)
    )
}

func fourPointSpark(center: CGPoint, verticalRadius: CGFloat, horizontalRadius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: center.x, y: center.y + verticalRadius))
    path.curve(
        to: CGPoint(x: center.x + horizontalRadius, y: center.y),
        controlPoint1: CGPoint(x: center.x + verticalRadius * 0.08, y: center.y + verticalRadius * 0.42),
        controlPoint2: CGPoint(x: center.x + horizontalRadius * 0.42, y: center.y + horizontalRadius * 0.08)
    )
    path.curve(
        to: CGPoint(x: center.x, y: center.y - verticalRadius),
        controlPoint1: CGPoint(x: center.x + horizontalRadius * 0.42, y: center.y - horizontalRadius * 0.08),
        controlPoint2: CGPoint(x: center.x + verticalRadius * 0.08, y: center.y - verticalRadius * 0.42)
    )
    path.curve(
        to: CGPoint(x: center.x - horizontalRadius, y: center.y),
        controlPoint1: CGPoint(x: center.x - verticalRadius * 0.08, y: center.y - verticalRadius * 0.42),
        controlPoint2: CGPoint(x: center.x - horizontalRadius * 0.42, y: center.y - horizontalRadius * 0.08)
    )
    path.curve(
        to: CGPoint(x: center.x, y: center.y + verticalRadius),
        controlPoint1: CGPoint(x: center.x - horizontalRadius * 0.42, y: center.y + horizontalRadius * 0.08),
        controlPoint2: CGPoint(x: center.x - verticalRadius * 0.08, y: center.y + verticalRadius * 0.42)
    )
    path.close()
    return path
}

func drawControlPath(scale: CGFloat, lineWidth: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 320 * scale, y: 478 * scale))
    path.curve(
        to: CGPoint(x: 442 * scale, y: 384 * scale),
        controlPoint1: CGPoint(x: 362 * scale, y: 456 * scale),
        controlPoint2: CGPoint(x: 392 * scale, y: 410 * scale)
    )
    path.curve(
        to: CGPoint(x: 704 * scale, y: 642 * scale),
        controlPoint1: CGPoint(x: 522 * scale, y: 458 * scale),
        controlPoint2: CGPoint(x: 612 * scale, y: 576 * scale)
    )
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

func sourceAppIconImage() -> NSImage? {
    NSImage(contentsOf: appIconSource)
}

func drawSourceAppIcon(_ sourceImage: NSImage, size: Int) -> NSBitmapImageRep {
    return withGraphicsContext(size: size) { _, rect in
        let scale = CGFloat(size) / 1024
        let iconBody = rect.insetBy(dx: 154 * scale, dy: 154 * scale)
        let iconMask = roundedRect(iconBody, radius: 104 * scale)
        let sourceVerticalOffset = 34 * scale

        NSColor.clear.setFill()
        rect.fill()

        NSGraphicsContext.saveGraphicsState()
        iconMask.addClip()
        sourceImage.draw(
            in: rect.offsetBy(dx: 0, dy: -sourceVerticalOffset),
            from: CGRect(origin: .zero, size: sourceImage.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}

func drawAppIcon(size: Int) -> NSBitmapImageRep {
    if let sourceImage = sourceAppIconImage() {
        return drawSourceAppIcon(sourceImage, size: size)
    }

    return withGraphicsContext(size: size) { _, rect in
        let scale = CGFloat(size) / 1024
        NSColor.clear.setFill()
        rect.fill()

        let outer = rect.insetBy(dx: 52 * scale, dy: 52 * scale)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 42 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -18 * scale)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let outerPath = roundedRect(outer, radius: 224 * scale)
        color(0x101722).setFill()
        outerPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let gradient = NSGradient(colors: [
            color(0x24272A),
            color(0x151719),
            color(0x0A0B0D)
        ])!
        gradient.draw(in: outerPath, angle: 38)

        let highlight = roundedRect(outer.insetBy(dx: 24 * scale, dy: 24 * scale), radius: 198 * scale)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        highlight.lineWidth = 8 * scale
        highlight.stroke()

        let symbolShadow = NSShadow()
        symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.46)
        symbolShadow.shadowBlurRadius = 34 * scale
        symbolShadow.shadowOffset = NSSize(width: 0, height: -14 * scale)

        NSGraphicsContext.saveGraphicsState()
        symbolShadow.set()
        drawMetalRing(
            center: CGPoint(x: 512 * scale, y: 522 * scale),
            radius: 222 * scale,
            lineWidth: 72 * scale,
            scale: scale
        )
        NSGraphicsContext.restoreGraphicsState()

        drawArc(
            center: CGPoint(x: 512 * scale, y: 522 * scale),
            radius: 222 * scale,
            startAngle: 42,
            endAngle: 286,
            lineWidth: 14 * scale,
            color: NSColor.white.withAlphaComponent(0.10)
        )
        drawArc(
            center: CGPoint(x: 512 * scale, y: 522 * scale),
            radius: 189 * scale,
            startAngle: 54,
            endAngle: 304,
            lineWidth: 6 * scale,
            color: NSColor.black.withAlphaComponent(0.20)
        )
    }
}

func drawStatusIcon(size: Int, tint: NSColor) -> NSBitmapImageRep {
    return withGraphicsContext(size: size) { _, rect in
        let scale = CGFloat(size) / 64
        NSColor.clear.setFill()
        rect.fill()

        let path = NSBezierPath()
        path.appendArc(
            withCenter: CGPoint(x: 32 * scale, y: 32 * scale),
            radius: 20.2 * scale,
            startAngle: 20,
            endAngle: 318,
            clockwise: false
        )
        path.lineWidth = 9.2 * scale
        path.lineCapStyle = .butt
        path.lineJoinStyle = .round
        tint.setStroke()
        path.stroke()
    }
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(url.lastPathComponent)")
    }
    try data.write(to: url, options: .atomic)
}

let iconEntries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in iconEntries {
    try writePNG(drawAppIcon(size: size), to: iconset.appendingPathComponent(name))
}

let statusIcon = drawStatusIcon(size: 64, tint: color(0x9B9B9F))
try writePNG(statusIcon, to: resources.appendingPathComponent(statusIconName))
try writePNG(statusIcon, to: targetResources.appendingPathComponent(statusIconName))

let statusTemplateIcon = drawStatusIcon(size: 64, tint: .white)
try writePNG(statusTemplateIcon, to: resources.appendingPathComponent(statusTemplateIconName))
try writePNG(statusTemplateIcon, to: targetResources.appendingPathComponent(statusTemplateIconName))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c",
    "icns",
    iconset.path,
    "-o",
    resources.appendingPathComponent("AppIcon.icns").path
]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}

print("Generated Resources/AppIcon.icns, Resources/\(statusIconName), and Resources/\(statusTemplateIconName)")
