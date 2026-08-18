#!/usr/bin/env swift
import AppKit
import Darwin

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("DynamicIsland-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func capsule(_ rect: CGRect) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: rect.height / 2,
        cornerHeight: rect.height / 2,
        transform: nil
    )
}

func bitmap(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
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
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.clip()
    let bodyGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.17, green: 0.18, blue: 0.22, alpha: 1),
            CGColor(red: 0.035, green: 0.04, blue: 0.055, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        bodyGradient,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )

    // The hardware pill is a product cue, distinct from the upstream eye motif.
    context.setFillColor(CGColor(gray: 0.005, alpha: 1))
    context.addPath(capsule(CGRect(x: 347, y: 838, width: 330, height: 86)))
    context.fillPath()

    // Concentric signal capsules carry Dynamic Island's own cyan/violet mark.
    let outer = CGRect(x: 282, y: 380, width: 460, height: 180)
    context.saveGState()
    context.addPath(capsule(outer))
    context.clip()
    let signalGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.27, green: 0.84, blue: 1, alpha: 1),
            CGColor(red: 0.55, green: 0.36, blue: 1, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        signalGradient,
        start: CGPoint(x: outer.minX, y: outer.midY),
        end: CGPoint(x: outer.maxX, y: outer.midY),
        options: []
    )
    context.restoreGState()

    context.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1))
    context.addPath(capsule(CGRect(x: 352, y: 416, width: 320, height: 108)))
    context.fillPath()
    context.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 1, alpha: 1))
    context.addPath(capsule(CGRect(x: 427, y: 448, width: 170, height: 44)))
    context.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (size, name) in variants {
    let data = bitmap(size: size).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(name).png"), options: .atomic)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
