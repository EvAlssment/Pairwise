#!/usr/bin/env swift
// Regenerate the committed 1x/2x Finder artwork:
// swift scripts/dmg/render-background.swift [output.tiff]
import AppKit

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("background.tiff")
let size = NSSize(width: 660, height: 520)
let purple = NSColor(srgbRed: 0.36, green: 0.29, blue: 0.79, alpha: 1)

func render(scale: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 660 * scale, pixelsHigh: 520 * scale,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    // NSGraphicsContext already applies the bitmap's point-to-pixel scale.
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    NSColor(srgbRed: 0.985, green: 0.982, blue: 1, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

    func text(_ string: String, y: CGFloat, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (string as NSString).draw(in: NSRect(x: 24, y: y, width: 612, height: 44), withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
        NSGraphicsContext.restoreGraphicsState()
    }

    text("Install PairDesk", y: 44, font: .systemFont(ofSize: 30, weight: .semibold),
         color: NSColor(srgbRed: 0.15, green: 0.12, blue: 0.25, alpha: 1))
    text("Drag PairDesk into Applications to get started.", y: 91,
         font: .systemFont(ofSize: 15), color: NSColor(srgbRed: 0.37, green: 0.35, blue: 0.43, alpha: 1))

    // Icon centers match settings.py. Leave their native labels unobstructed.
    context.setStrokeColor(purple.cgColor)
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 205, y: 307))
    context.addCurve(to: CGPoint(x: 455, y: 307), control1: CGPoint(x: 270, y: 369), control2: CGPoint(x: 390, y: 369))
    context.strokePath()
    context.move(to: CGPoint(x: 436, y: 310))
    context.addLine(to: CGPoint(x: 455, y: 307))
    context.addLine(to: CGPoint(x: 452, y: 326))
    context.strokePath()

    text("Eject this disk, then open PairDesk from Applications.", y: 377,
         font: .systemFont(ofSize: 14, weight: .medium), color: purple)
    text("Updating? Quit PairDesk first and choose Replace.", y: 404,
         font: .systemFont(ofSize: 12), color: NSColor(srgbRed: 0.42, green: 0.40, blue: 0.48, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let representations = [render(scale: 1), render(scale: 2)]
let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: representations, using: .lzw, factor: 0)!
try data.write(to: output)
print("Wrote \(output.path)")
