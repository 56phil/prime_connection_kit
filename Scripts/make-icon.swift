#!/usr/bin/env swift
// Draws the application icon and packages it as AppIcon.icns.
//
// The rest of the app carries no binary assets — content-type icons come from SF
// Symbols — so the application icon is generated from vector geometry rather than
// committed as a blob. That keeps it editable, reviewable, and reproducible at any
// size, and means the sizes macOS asks for are each rendered natively instead of
// being downsampled from one large bitmap.
//
// Geometry follows Apple's macOS icon template: a 1024×1024 canvas with the icon
// body inset to 824×824 and corners of continuous curvature, known as a squircle.
// The system draws the drop shadow, so none is baked in — baking one would double
// it up in the Dock.
//
// Usage:
//   swift Scripts/make-icon.swift [--out build] [--preview <file.png>]

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Shape

/// A superellipse, the shape macOS uses for app icons.
///
/// A rounded rectangle with circular corners has a visible seam where the corner
/// meets the straight edge, because curvature jumps from a fixed value to zero.
/// Apple's shape ramps it smoothly instead. A superellipse with an exponent around
/// five reproduces that: curvature falls off gradually, so the corner reads as
/// continuous. The closer exponent, the tighter and squarer the corner.
func squircle(center: CGPoint, radius: CGFloat, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 1024
    let power = 2 / exponent
    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        // |x|^n + |y|^n = 1, written parametrically.
        let x = center.x + radius * (cosine < 0 ? -1 : 1) * pow(abs(cosine), power)
        let y = center.y + radius * (sine < 0 ? -1 : 1) * pow(abs(sine), power)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Palette

/// The icon's colours, kept together so the design can be adjusted in one place.
enum Palette {
    /// Top of the background gradient: an HP blue, bright enough to read in a Dock.
    static let backgroundTop = CGColor(red: 0.30, green: 0.43, blue: 0.96, alpha: 1)
    /// Bottom of the background gradient: the same hue, deepened for weight.
    static let backgroundBottom = CGColor(red: 0.09, green: 0.15, blue: 0.47, alpha: 1)

    /// The calculator's case.
    static let body = CGColor(red: 0.99, green: 0.99, blue: 1.0, alpha: 1)
    /// The calculator's display, darker than the case so it reads as a screen.
    static let screen = CGColor(red: 0.10, green: 0.16, blue: 0.36, alpha: 1)
    /// Text on the display.
    static let screenText = CGColor(red: 0.72, green: 0.84, blue: 1.0, alpha: 1)

    /// Ordinary keys, tinted so the case is not lost in the background.
    static let key = CGColor(red: 0.35, green: 0.48, blue: 0.90, alpha: 0.55)
    /// The top row of keys, colour-coded on a real HP Prime.
    static let keyAccent = CGColor(red: 0.97, green: 0.45, blue: 0.20, alpha: 0.95)
}

/// How much detail the glyph carries, which depends on the size it will be seen at.
enum Detail {
    /// Full keypad, as drawn at 128 pixels and above.
    case full
    /// Display and a colour band instead of a keypad.
    case simple
    /// A bare screen and colour band: at 16 pixels even a single line of display
    /// text antialiases into mottling across the whole screen.
    case minimal

    init(pixels: Int) {
        switch pixels {
        case ..<24: self = .minimal
        case ..<64: self = .simple
        default: self = .full
        }
    }
}

// MARK: - Drawing

/// Draws the icon into a context whose coordinate system is 1024 units square.
func drawIcon(in context: CGContext, detail: Detail = .full) {
    let canvas: CGFloat = 1024
    let center = CGPoint(x: canvas / 2, y: canvas / 2)

    // The icon body sits inside the canvas, leaving the margin macOS expects.
    let bodyRadius: CGFloat = 412

    context.saveGState()
    context.addPath(squircle(center: center, radius: bodyRadius))
    context.clip()

    // Background: a vertical gradient, which gives the flat shape some depth.
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.backgroundTop, Palette.backgroundBottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: canvas),
        options: []
    )

    // A soft highlight across the top edge, as if lit from above.
    if let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.saveGState()
        context.addPath(squircle(center: CGPoint(x: center.x, y: center.y - 150), radius: bodyRadius))
        context.clip()
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: 0, y: 60),
            end: CGPoint(x: 0, y: 520),
            options: []
        )
        context.restoreGState()
    }

    drawCalculator(in: context, center: center, detail: detail)
    context.restoreGState()
}

/// Draws the calculator glyph, centred on `center`.
///
/// The proportions follow a real HP Prime: a tall case, a display across the top
/// third, and a colour-coded keypad filling the rest.
///
/// - Parameter detailed: whether to draw the full keypad. At small sizes a
///   sixteen-key grid collapses into grey mush, so the small variants drop it and
///   give the space to the display, which still reads as a calculator silhouette.
func drawCalculator(in context: CGContext, center: CGPoint, detail: Detail = .full) {
    let detailed = detail == .full
    // The small variants are drawn larger. A 16-pixel icon has to spend its few
    // pixels on the glyph rather than on margin, or the shape is lost.
    let caseWidth: CGFloat = detailed ? 356 : 440
    let caseHeight: CGFloat = detailed ? 532 : 528
    let caseRadius: CGFloat = detailed ? 46 : 58

    let caseRect = CGRect(
        x: center.x - caseWidth / 2,
        y: center.y - caseHeight / 2,
        width: caseWidth,
        height: caseHeight
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -6),
        blur: 26,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22)
    )
    context.setFillColor(Palette.body)
    context.addPath(roundedRect(caseRect, radius: caseRadius))
    context.fillPath()
    context.restoreGState()

    let inset: CGFloat = detailed ? 38 : 30
    let screenRect = CGRect(
        x: caseRect.minX + inset,
        y: caseRect.minY + inset,
        width: caseWidth - inset * 2,
        height: detailed ? 140 : 236
    )
    context.setFillColor(Palette.screen)
    context.addPath(roundedRect(screenRect, radius: 18))
    context.fillPath()

    // Content on the display. Uneven lengths read as text; the simplified variant
    // uses a single thick line, because two thin ones merge into a smudge at 16px.
    if detail == .full {
        context.setFillColor(Palette.screenText)
        for (index, width) in [CGFloat(176), 118, 196].enumerated() {
            let bar = CGRect(
                x: screenRect.minX + 26,
                y: screenRect.minY + 32 + CGFloat(index) * 38,
                width: width,
                height: 15
            )
            context.addPath(roundedRect(bar, radius: 7.5))
            context.fillPath()
        }
    } else if detail == .simple {
        context.setFillColor(Palette.screenText)
        let bar = CGRect(
            x: screenRect.minX + 36,
            y: screenRect.minY + 56,
            width: 216,
            height: 48
        )
        context.addPath(roundedRect(bar, radius: 24))
        context.fillPath()
    }

    guard detailed else {
        // One chunky colour-coded block stands in for the keypad: enough to read
        // as keys, which a sixteen-key grid at this size cannot.
        let bar = CGRect(
            x: screenRect.minX,
            y: screenRect.maxY + 44,
            width: screenRect.width,
            height: 120
        )
        context.setFillColor(Palette.keyAccent)
        context.addPath(roundedRect(bar, radius: 26))
        context.fillPath()
        return
    }

    // Keypad: four columns, four rows, with the top row colour-coded as it is on
    // the calculator this app talks to.
    let columns = 4
    let rows = 4
    let keySize: CGFloat = 52
    let gap: CGFloat = 20
    let keypadWidth = CGFloat(columns) * keySize + CGFloat(columns - 1) * gap
    let keypadX = center.x - keypadWidth / 2
    let keypadY = caseRect.maxY - inset - (CGFloat(rows) * keySize + CGFloat(rows - 1) * gap)

    for row in 0..<rows {
        context.setFillColor(row == 0 ? Palette.keyAccent : Palette.key)
        for column in 0..<columns {
            let key = CGRect(
                x: keypadX + CGFloat(column) * (keySize + gap),
                y: keypadY + CGFloat(row) * (keySize + gap),
                width: keySize,
                height: keySize
            )
            context.addPath(roundedRect(key, radius: 14))
            context.fillPath()
        }
    }
}

/// Renders the icon at one pixel size.
func render(pixels: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Work in a fixed 1024-unit space so the geometry does not depend on the
    // output size; flip the y-axis so coordinates read top-down.
    context.interpolationQuality = .high
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    // Below this the keypad is only a few pixels of each key, which reads as
    // noise rather than as keys.
    drawIcon(in: context, detail: Detail(pixels: pixels))

    return context.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "could not create a PNG destination at \(url.path)",
        ])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "could not write \(url.path)",
        ])
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let outputRoot = URL(fileURLWithPath: value(after: "--out") ?? "build", isDirectory: true)
let fileManager = FileManager.default

// The entries macOS expects in an .iconset, as (file name, pixel size).
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

do {
    try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)

    let iconset = outputRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try? fileManager.removeItem(at: iconset)
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

    for (name, pixels) in variants {
        guard let image = render(pixels: pixels) else {
            throw NSError(domain: "make-icon", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "could not render \(pixels)px",
            ])
        }
        try writePNG(image, to: iconset.appendingPathComponent(name))
    }

    // iconutil is part of macOS, so the bundle stays free of third-party tools.
    let iconsetProcess = Process()
    iconsetProcess.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    let icns = outputRoot.appendingPathComponent("AppIcon.icns")
    iconsetProcess.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try iconsetProcess.run()
    iconsetProcess.waitUntilExit()
    guard iconsetProcess.terminationStatus == 0 else {
        throw NSError(domain: "make-icon", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "iconutil failed with status \(iconsetProcess.terminationStatus)",
        ])
    }

    let size = ((try? fileManager.attributesOfItem(atPath: icns.path))?[.size] as? Int) ?? 0
    print("Wrote \(icns.path) (\(size) bytes)")

    // A single render at one size, for comparing the installed icon against the
    // artwork without the contact sheet's background in the way.
    if let single = value(after: "--png") {
        let pixels = Int(value(after: "--png-size") ?? "128") ?? 128
        guard let image = render(pixels: pixels) else {
            throw NSError(domain: "make-icon", code: 7)
        }
        try writePNG(image, to: URL(fileURLWithPath: single))
        print("Wrote \(single)")
    }

    // A magnified sheet for the small sizes. At 16 and 32 pixels the icon cannot
    // be judged from a contact sheet, so each is rendered again and scaled up with
    // no smoothing, which shows exactly the pixels macOS will have to work with.
    if let magnifyPath = value(after: "--magnify") {
        let sizes = [16, 32]
        let scale = 16
        let padding = 16
        let cell = sizes.max()! * scale
        let totalWidth = sizes.count * (cell + padding) + padding
        let height = cell + padding * 2
        guard let sheet = CGContext(
            data: nil,
            width: totalWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "make-icon", code: 6) }
        sheet.interpolationQuality = .none
        sheet.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.57, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: totalWidth, height: height))
        var x = padding
        for size in sizes {
            if let image = render(pixels: size) {
                sheet.draw(image, in: CGRect(x: x, y: padding, width: cell, height: cell))
            }
            x += cell + padding
        }
        if let sheetImage = sheet.makeImage() {
            try writePNG(sheetImage, to: URL(fileURLWithPath: magnifyPath))
            print("Wrote \(magnifyPath)")
        }
    }

    // An optional preview sheet, for reviewing the icon at the sizes it is
    // actually seen at rather than only at 1024.
    if let previewPath = value(after: "--preview") {
        let sizes = [16, 32, 64, 128, 256, 512]
        let padding = 24
        let totalWidth = sizes.reduce(0) { $0 + $1 + padding } + padding
        let height = (sizes.max() ?? 512) + padding * 2
        guard let sheet = CGContext(
            data: nil,
            width: totalWidth,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "make-icon", code: 5) }

        // Checkerboard-ish mid grey, so both the shape and its edges are visible.
        sheet.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.57, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: totalWidth, height: height))

        var x = padding
        for size in sizes {
            if let image = render(pixels: size) {
                sheet.draw(image, in: CGRect(
                    x: x, y: padding, width: size, height: size
                ))
            }
            x += size + padding
        }
        if let sheetImage = sheet.makeImage() {
            try writePNG(sheetImage, to: URL(fileURLWithPath: previewPath))
            print("Wrote \(previewPath)")
        }
    }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
