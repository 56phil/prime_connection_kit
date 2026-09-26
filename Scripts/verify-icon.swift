#!/usr/bin/env swift
// Verifies that macOS resolves the installed application icon.
//
// The Dock does not read the icon file itself: it asks Launch Services for the
// bundle's icon, which is the lookup performed here. That makes this a real check
// of what will be shown, not merely of what was written to disk — an `.icns` with
// the wrong name, or a missing `CFBundleIconFile` entry, still leaves a file on
// disk while the system shows the generic placeholder.
//
// The comparison is calibrated against a bundle that deliberately has no icon, so
// it does not depend on a hardcoded colour or on how this particular macOS version
// decorates icons. What matters is that the bundle's icon differs from the
// placeholder in the same way at every size.
//
// Usage: swift Scripts/verify-icon.swift <app-bundle> [--save <system-icon.png>]

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("verify-icon: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: verify-icon.swift <app-bundle> [--save <png>]")
}
let appURL = URL(fileURLWithPath: arguments[1])
let saveURL: URL? = arguments.firstIndex(of: "--save").flatMap {
    $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil
}

guard let bundle = Bundle(url: appURL) else {
    fail("\(appURL.path) is not a bundle")
}

// MARK: - Checks that do not depend on the running system

let info = bundle.infoDictionary ?? [:]
let iconName = info["CFBundleIconFile"] as? String
print("bundle id:        \(bundle.bundleIdentifier ?? "(none)")")
print("CFBundleIconFile: \(iconName ?? "(not set)")")

guard let iconName, !iconName.isEmpty else {
    fail("CFBundleIconFile is not set, so the Dock has no icon to show")
}

// `.icns` is implied when the name carries no extension.
let resourceName = iconName.hasSuffix(".icns") ? iconName : "\(iconName).icns"
guard let iconURL = bundle.url(forResource: resourceName, withExtension: nil) else {
    fail("\(resourceName) is not in the bundle's resources")
}

// Read the icns and enumerate the sizes it actually contains, rather than trusting
// the generator to have written them all.
guard let source = CGImageSourceCreateWithURL(iconURL as CFURL, nil) else {
    fail("\(iconURL.lastPathComponent) is not a readable image")
}
let count = CGImageSourceGetCount(source)
var sizes: [String] = []
for index in 0..<count {
    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
    sizes.append("\(image.width)×\(image.height)")
}
print("icon file:        \(iconURL.lastPathComponent) "
      + "(\(((try? FileManager.default.attributesOfItem(atPath: iconURL.path))?[.size] as? Int) ?? 0) bytes)")
print("representations:  \(count) — \(sizes.joined(separator: ", "))")

// The sizes macOS asks for. Missing one makes that context fall back to the
// generic icon rather than scaling a neighbour.
let required = ["16×16", "32×32", "64×64", "128×128", "256×256", "512×512", "1024×1024"]
let missing = required.filter { !sizes.contains($0) }
guard missing.isEmpty else {
    fail("the icon is missing \(missing.joined(separator: ", "))")
}
print("all required sizes present")

// MARK: - What the system will actually show

/// Renders an image to premultiplied RGBA bytes at a fixed size.
func pixels(_ image: CGImage) -> [UInt8]? {
    let side = 64
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let data = context.data else { return nil }
    return Array(UnsafeBufferPointer(
        start: data.bindMemory(to: UInt8.self, capacity: side * side * 4),
        count: side * side * 4
    ))
}

/// Averages the colour of the drawn pixels.
///
/// An icon is a squircle, so its corners are transparent. Counting them would pull
/// every average towards black and hide the difference being looked for.
func signature(_ bytes: [UInt8]) -> (r: Double, g: Double, b: Double) {
    var r = 0.0, g = 0.0, b = 0.0
    var counted = 0
    for index in stride(from: 0, to: bytes.count, by: 4) {
        guard bytes[index + 3] > 200 else { continue }
        r += Double(bytes[index]) / 255
        g += Double(bytes[index + 1]) / 255
        b += Double(bytes[index + 2]) / 255
        counted += 1
    }
    guard counted > 0 else { return (0, 0, 0) }
    return (r / Double(counted), g / Double(counted), b / Double(counted))
}

func resolveIcon(for url: URL) -> (r: Double, g: Double, b: Double)? {
    let image = NSWorkspace.shared.icon(forFile: url.path)
    image.size = NSSize(width: 64, height: 64)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let cgImage = bitmap.cgImage,
          let bytes = pixels(cgImage)
    else { return nil }
    return signature(bytes)
}

// Calibrate against a bundle with no icon at all, built alongside this one so the
// comparison is between two bundles the same system is decorating the same way.
let placeholderRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("verify-icon-placeholder-\(getpid())", isDirectory: true)
let placeholderApp = placeholderRoot.appendingPathComponent("NoIcon.app", isDirectory: true)
let placeholderInfo = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NoIcon</string>
<key>CFBundleIdentifier</key><string>com.primeconnectionkit.verify.noicon</string>
<key>CFBundleName</key><string>NoIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
"""
defer { try? FileManager.default.removeItem(at: placeholderRoot) }
do {
    try FileManager.default.createDirectory(
        at: placeholderApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true
    )
    try Data(placeholderInfo.utf8).write(to: placeholderApp.appendingPathComponent("Contents/Info.plist"))
    try Data("#!/bin/sh\n".utf8).write(to: placeholderApp.appendingPathComponent("Contents/MacOS/NoIcon"))
} catch {
    fail("could not build the calibration bundle: \(error.localizedDescription)")
}

guard let placeholder = resolveIcon(for: placeholderApp) else {
    fail("the system returned no icon for the calibration bundle")
}
guard let installed = resolveIcon(for: appURL) else {
    fail("the system returned no icon for \(appURL.lastPathComponent)")
}

/// Sum of the per-channel differences, which is enough to tell artwork from a
/// placeholder without asserting what either looks like.
func distance(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
    abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
}

let difference = distance(installed, placeholder)
print(String(format: "calibration:      placeholder r %.3f g %.3f b %.3f",
             placeholder.r, placeholder.g, placeholder.b))
print(String(format: "installed icon:   r %.3f g %.3f b %.3f",
             installed.r, installed.g, installed.b))
print(String(format: "difference:       %.3f", difference))

// The placeholder is a pale grey document shape. Any icon with real artwork differs
// from it by far more than rounding; a bundle whose icon was not picked up does not
// differ at all.
guard difference > 0.05 else {
    fail("the system shows the same icon as a bundle with no icon, so the "
         + "artwork is not being applied")
}

if let saveURL,
   let image = NSWorkspace.shared.icon(forFile: appURL.path).tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
   let png = image.representation(using: .png, properties: [:]) {
    try? png.write(to: saveURL)
    print("wrote a copy of the system's icon to \(saveURL.path)")
}

print("\nThe system is showing the bundle's own icon.")
