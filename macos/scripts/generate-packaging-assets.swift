#!/usr/bin/env swift
import AppKit
import Foundation

private enum PackagingAssetError: Error, LocalizedError {
    case invalidArguments
    case cannotCreateBitmap
    case cannotCreatePNG

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: generate-packaging-assets.swift iconset <output.iconset> | dmg-background <output.png>"
        case .cannotCreateBitmap:
            return "Could not create bitmap context."
        case .cannotCreatePNG:
            return "Could not encode PNG."
        }
    }
}

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

private func renderPNG(width: Int, height: Int, draw: (CGSize) -> Void) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)
    else {
        throw PackagingAssetError.cannotCreateBitmap
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGSize(width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw PackagingAssetError.cannotCreatePNG
    }
    return data
}

private func drawIcon(size: CGSize) {
    color(0, 0, 0, 0).setFill()
    NSRect(origin: .zero, size: size).fill()

    let inset = size.width * 0.08
    let rect = NSRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
    let radius = size.width * 0.22
    let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        color(10, 121, 112),
        color(245, 158, 11)
    ])?.draw(in: background, angle: 40)

    color(255, 255, 255, 0.18).setFill()
    NSBezierPath(ovalIn: rect.insetBy(dx: size.width * 0.14, dy: size.height * 0.14)).fill()

    let bolt = NSBezierPath()
    let w = size.width
    let h = size.height
    bolt.move(to: NSPoint(x: w * 0.56, y: h * 0.78))
    bolt.line(to: NSPoint(x: w * 0.34, y: h * 0.47))
    bolt.line(to: NSPoint(x: w * 0.50, y: h * 0.47))
    bolt.line(to: NSPoint(x: w * 0.43, y: h * 0.22))
    bolt.line(to: NSPoint(x: w * 0.68, y: h * 0.56))
    bolt.line(to: NSPoint(x: w * 0.51, y: h * 0.56))
    bolt.close()
    color(255, 255, 255).setFill()
    bolt.fill()

    color(4, 47, 46, 0.20).setStroke()
    background.lineWidth = max(1, size.width * 0.018)
    background.stroke()
}

private func writeIconSet(to outputURL: URL) throws {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: outputURL)
    try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

    let specs: [(String, Int)] = [
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

    for (name, pixels) in specs {
        let data = try renderPNG(width: pixels, height: pixels) { size in
            drawIcon(size: size)
        }
        try data.write(to: outputURL.appendingPathComponent(name), options: .atomic)
    }
}

private func drawDMGBackground(size: CGSize) {
    color(248, 250, 252).setFill()
    NSRect(origin: .zero, size: size).fill()

    color(226, 232, 240, 0.55).setStroke()
    let grid = NSBezierPath()
    stride(from: 0.5, through: size.width, by: 32).forEach { x in
        grid.move(to: NSPoint(x: x, y: 0))
        grid.line(to: NSPoint(x: x, y: size.height))
    }
    stride(from: 0.5, through: size.height, by: 32).forEach { y in
        grid.move(to: NSPoint(x: 0, y: y))
        grid.line(to: NSPoint(x: size.width, y: y))
    }
    grid.lineWidth = 1
    grid.stroke()

    let title = "Drag Vibestick to Applications"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: color(15, 23, 42)
    ]
    let titleSize = title.size(withAttributes: attributes)
    title.draw(
        at: NSPoint(x: (size.width - titleSize.width) / 2, y: size.height - 64),
        withAttributes: attributes)

    let arrowY = size.height * 0.50
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: size.width * 0.40, y: arrowY))
    arrow.line(to: NSPoint(x: size.width * 0.60, y: arrowY))
    arrow.lineWidth = 8
    arrow.lineCapStyle = .round
    color(71, 85, 105).setStroke()
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: size.width * 0.60, y: arrowY))
    head.line(to: NSPoint(x: size.width * 0.56, y: arrowY + 26))
    head.line(to: NSPoint(x: size.width * 0.56, y: arrowY - 26))
    head.close()
    color(71, 85, 105).setFill()
    head.fill()

    let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: color(71, 85, 105)
    ]
    let hint = "Open Vibestick from Applications to finish Helper and auto-start setup."
    let hintSize = hint.size(withAttributes: hintAttributes)
    hint.draw(
        at: NSPoint(x: (size.width - hintSize.width) / 2, y: 54),
        withAttributes: hintAttributes)
}

private func writeDMGBackground(to outputURL: URL) throws {
    let data = try renderPNG(width: 640, height: 420) { size in
        drawDMGBackground(size: size)
    }
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try data.write(to: outputURL, options: .atomic)
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw PackagingAssetError.invalidArguments
    }

    let command = CommandLine.arguments[1]
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    switch command {
    case "iconset":
        try writeIconSet(to: outputURL)
    case "dmg-background":
        try writeDMGBackground(to: outputURL)
    default:
        throw PackagingAssetError.invalidArguments
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
