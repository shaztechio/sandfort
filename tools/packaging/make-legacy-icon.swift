// Copyright 2026 Shazron Abdullah and Sandfort contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Builds a conventionally shaped macOS app icon from full-bleed square artwork.
//
// The original artwork is a full-bleed square at every size, with no mask and no
// margin (issue #68). macOS 13 through 15 draw an icns as-is, so Sandfort
// appeared as a hard square against rounded neighbours.
//
// This tool produces the shape those systems expect: the artwork scaled to
// 824/1024 of the canvas, clipped to a continuous-curvature rounded rectangle,
// centred with a 100/1024 margin, over a soft drop shadow.
//
// macOS 26 is unaffected. It normalises whatever an icns contains to the same
// shape, so full-bleed artwork and artwork already inside that shape converge on
// the same rendering. Verified by handing NSWorkspace two bundles that differ
// only in their icns — and in their bundle identifier, because IconServices
// caches on it and reusing one identifier produced a stale, misleading render.
//
// usage: make-legacy-icon.swift SOURCE OUTPUT.iconset
//   where SOURCE is square PNG artwork or an icns to take the largest PNG from
//   then: iconutil -c icns OUTPUT.iconset -o Sandfort.icns

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// Apple's pre-26 icon grid, expressed against a 1024-point canvas. The body is
// 824 wide, which leaves exactly 100 on every side, and the corner radius is
// 22.5% of the body. Everything below scales these by size/1024 so each
// rendition draws its own path rather than downsampling one large bitmap.
private enum Grid {
    static let canvas: CGFloat = 1024
    static let body: CGFloat = 824
    static let cornerRadius: CGFloat = 185.4

    // The shadow is an approximation of the template's, not a published
    // constant. It stays well inside the 100-point margin at every size.
    static let shadowBlur: CGFloat = 20
    static let shadowOffsetY: CGFloat = 10
    static let shadowAlpha: CGFloat = 0.28
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-legacy-icon: \(message)\n".utf8))
    exit(1)
}

private let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

/// Loads square artwork from either a PNG or the largest PNG element of an icns.
private func loadArtwork(at url: URL) throws -> CGImage {
    let data = try Data(contentsOf: url)
    if data.count > 8, Array(data[0..<8]) == pngMagic {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { fail("could not decode \(url.lastPathComponent)") }
        return image
    }
    return try largestPNG(inICNS: url, data: data)
}

/// Returns the largest PNG element stored in an `.icns` container.
///
/// This reads the container directly rather than shelling out to `iconutil
/// -c iconset`, which garbles the small elements into noise and mislabels the
/// 64x64 `icp6` as `icon_48x48.png`. Both are extraction artifacts, but they
/// cost an afternoon once already, so nothing here depends on that tool.
private func largestPNG(inICNS url: URL, data: Data) throws -> CGImage {
    guard data.count > 8, Array(data[0..<4]) == Array("icns".utf8) else {
        fail("\(url.lastPathComponent) is neither a PNG nor an icns container")
    }

    func be32(_ offset: Int) -> Int {
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
            | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    }

    var best: CGImage?
    var offset = 8

    while offset + 8 <= data.count {
        let length = be32(offset + 4)
        guard length >= 8, offset + length <= data.count else { break }
        let body = data.subdata(in: (offset + 8)..<(offset + length))
        offset += length

        guard body.count > 8, Array(body[0..<8]) == pngMagic else { continue }
        guard let source = CGImageSourceCreateWithData(body as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { continue }
        if image.width > (best?.width ?? 0) { best = image }
    }

    guard let image = best else { fail("no PNG element found in \(url.lastPathComponent)") }
    return image
}

/// The continuous-curvature rounded rectangle macOS uses, not a circular-corner
/// one. SwiftUI already knows the curve, so we borrow its path rather than
/// approximating a superellipse by hand.
private func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

private func render(_ artwork: CGImage, at size: Int) -> CGImage {
    let scale = CGFloat(size) / Grid.canvas
    let side = Grid.body * scale
    let margin = (CGFloat(size) - side) / 2
    let rect = CGRect(x: margin, y: margin, width: side, height: side)
    let path = squirclePath(in: rect, radius: Grid.cornerRadius * scale)

    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create a \(size)x\(size) context") }

    context.interpolationQuality = .high

    // Fill the shape once with the shadow enabled. The artwork is opaque, so
    // this fill is entirely covered a moment later and only its shadow survives.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -Grid.shadowOffsetY * scale),
        blur: Grid.shadowBlur * scale,
        color: NSColor.black.withAlphaComponent(Grid.shadowAlpha).cgColor
    )
    context.addPath(path)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    context.draw(artwork, in: rect)
    context.restoreGState()

    guard let image = context.makeImage() else { fail("could not render \(size)x\(size)") }
    return image
}

private func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fail("could not encode \(url.lastPathComponent)")
    }
    try png.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data(
        "usage: make-legacy-icon.swift SOURCE OUTPUT.iconset\n".utf8
    ))
    exit(2)
}

let source = URL(fileURLWithPath: arguments[1])
let destination = URL(fileURLWithPath: arguments[2])

let artwork = try loadArtwork(at: source)
guard artwork.width == artwork.height else {
    fail("source artwork is \(artwork.width)x\(artwork.height); a square is required")
}

try? FileManager.default.removeItem(at: destination)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

// The names iconutil expects. Each entry renders natively at its own pixel
// size so a 16-point icon gets a path drawn at 16 points, not a downsampled 1024.
let renditions: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for rendition in renditions {
    let image = render(artwork, at: rendition.pixels)
    try write(image, to: destination.appendingPathComponent("\(rendition.name).png"))
}

print("wrote \(renditions.count) renditions to \(destination.path)")
print("next: iconutil -c icns \(destination.path) -o Sandfort-legacy.icns")
