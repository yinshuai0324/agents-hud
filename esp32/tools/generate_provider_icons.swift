#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let iconSize = 80
private let cornerRadius: CGFloat = 16

private struct Icon {
    let name: String
    let rgba: [UInt8]
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func loadImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("cannot decode \(path)")
    }
    return image
}

private func normalize(_ source: CGImage, outputURL: URL) -> [UInt8] {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    var rgba = [UInt8](repeating: 0, count: iconSize * iconSize * 4)
    var rendered: CGImage?

    rgba.withUnsafeMutableBytes { storage in
        guard let context = CGContext(
            data: storage.baseAddress,
            width: iconSize,
            height: iconSize,
            bitsPerComponent: 8,
            bytesPerRow: iconSize * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            fail("cannot create RGBA bitmap context")
        }

        let canvas = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        context.clear(canvas)
        context.addPath(CGPath(
            roundedRect: canvas,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        ))
        context.clip()
        context.interpolationQuality = .high

        let scale = max(
            CGFloat(iconSize) / CGFloat(source.width),
            CGFloat(iconSize) / CGFloat(source.height)
        )
        let drawWidth = CGFloat(source.width) * scale
        let drawHeight = CGFloat(source.height) * scale
        let drawRect = CGRect(
            x: (CGFloat(iconSize) - drawWidth) / 2,
            y: (CGFloat(iconSize) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
        context.draw(source, in: drawRect)
        rendered = context.makeImage()
    }

    guard let rendered else { fail("cannot finalize normalized icon") }
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fail("cannot create \(outputURL.path)")
    }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("cannot write \(outputURL.path)")
    }
    return rgba
}

private func rgb565a8(_ rgba: [UInt8]) -> [UInt8] {
    var output = [UInt8]()
    output.reserveCapacity(iconSize * iconSize * 3)

    for offset in stride(from: 0, to: rgba.count, by: 4) {
        let alpha = Int(rgba[offset + 3])
        var red = Int(rgba[offset])
        var green = Int(rgba[offset + 1])
        var blue = Int(rgba[offset + 2])

        // CoreGraphics renders premultiplied RGBA. LVGL RGB565A8 expects
        // straight color followed by a separate alpha plane.
        if alpha > 0 && alpha < 255 {
            red = min(255, (red * 255 + alpha / 2) / alpha)
            green = min(255, (green * 255 + alpha / 2) / alpha)
            blue = min(255, (blue * 255 + alpha / 2) / alpha)
        } else if alpha == 0 {
            red = 0
            green = 0
            blue = 0
        }

        let pixel = UInt16((red >> 3) << 11 | (green >> 2) << 5 | (blue >> 3))
        output.append(UInt8(pixel & 0xff))
        output.append(UInt8(pixel >> 8))
    }
    for offset in stride(from: 3, to: rgba.count, by: 4) {
        output.append(rgba[offset])
    }
    return output
}

private func cArray(name: String, bytes: [UInt8]) -> String {
    var result = "static const uint8_t provider_\(name)_data[PROVIDER_ICON_DATA_SIZE] = {\n"
    for start in stride(from: 0, to: bytes.count, by: 16) {
        let end = min(start + 16, bytes.count)
        let row = bytes[start..<end].map { String(format: "0x%02X", $0) }.joined(separator: ", ")
        result += "    \(row),\n"
    }
    result += "};\n\n"
    return result
}

guard CommandLine.arguments.count == 6 else {
    fail("usage: generate_provider_icons.swift CODEX CLAUDE GEMINI OUTPUT_DIR HEADER")
}

let fileManager = FileManager.default
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
do {
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fail("cannot create output directory: \(error)")
}

let sources = [
    ("codex", CommandLine.arguments[1]),
    ("claude", CommandLine.arguments[2]),
    ("gemini", CommandLine.arguments[3]),
]
private let icons = sources.map { name, path -> Icon in
    let outputURL = outputDirectory.appendingPathComponent("\(name).png")
    return Icon(name: name, rgba: normalize(loadImage(path), outputURL: outputURL))
}

var header = """
// Generated by tools/generate_provider_icons.swift. Do not edit by hand.
#pragma once

#include <stdint.h>

#define PROVIDER_ICON_WIDTH 80
#define PROVIDER_ICON_HEIGHT 80
#define PROVIDER_ICON_DATA_SIZE (PROVIDER_ICON_WIDTH * PROVIDER_ICON_HEIGHT * 3)

"""
for icon in icons {
    header += cArray(name: icon.name, bytes: rgb565a8(icon.rgba))
}
if header.hasSuffix("\n\n") {
    header.removeLast()
}

do {
    try Data(header.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[5]), options: .atomic)
} catch {
    fail("cannot write header: \(error)")
}

print("generated \(icons.count) provider icons at \(iconSize)x\(iconSize)")
