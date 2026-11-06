#!/usr/bin/env swift
// Renders Resources/AppIcon.icns from Resources/AppIconSource.png (Žuća on yellow).
// The source may have an opaque background around its rounded square; that square is found,
// scaled onto the macOS icon grid (824pt body, 100pt margin on 1024) and clipped to transparent corners.
// Usage: swift scripts/make-icon.swift [source.png] [output.icns]
import AppKit

let arguments = CommandLine.arguments.dropFirst()
let sourcePath = arguments.first ?? "Resources/AppIconSource.png"
let outputPath = arguments.dropFirst().first ?? "Resources/AppIcon.icns"

main()

func main() {
    do {
        guard let source = NSImage(contentsOfFile: sourcePath),
              let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw failure("Could not read \(sourcePath)")
        }
        let body = try bodyRect(in: cgSource)
        guard let cropped = cgSource.cropping(to: body) else { throw failure("Could not crop the icon body") }

        let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Poscar.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            try writePNG(cropped, pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
            try writePNG(cropped, pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }
        try runIconutil(iconset: iconset, output: outputPath)
        print("Wrote \(outputPath)")
    } catch {
        FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

/// The rounded square: left, right and top edges are where its yellow background starts; the shape is
/// square, so the bottom follows from the width. Outlines and shadows around it are left out.
func bodyRect(in image: CGImage) throws -> CGRect {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw failure("Could not read pixels") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    func isBackground(_ x: Int, _ y: Int) -> Bool {
        let offset = (y * width + x) * 4
        let (r, g, b) = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        return r > 200 && g > 160 && b < 90
    }

    var minX = width, minY = height, maxX = 0
    for y in 0..<height {
        for x in 0..<width where isBackground(x, y) {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
        }
    }
    guard maxX > minX else { throw failure("No yellow background found in \(sourcePath)") }
    let side = CGFloat(maxX - minX + 1)
    // A hair inside, so anti-aliased edge pixels don't show.
    return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: side, height: side).insetBy(dx: side * 0.012, dy: side * 0.012)
}

func writePNG(_ body: CGImage, pixels: Int, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw failure("Could not create a bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185).addClip()
    context.cgContext.draw(body, in: rect)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("Could not encode PNG") }
    try png.write(to: url)
}

func runIconutil(iconset: URL, output: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw failure("iconutil failed") }
}

func failure(_ message: String) -> NSError {
    NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
