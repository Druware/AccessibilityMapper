// DMGBackground.swift
//
// Renders the drag-and-drop background for the "Accessibility Mapper" distribution DMG.
//
//   swift DMGBackground.swift <out.png> <scale>
//
// The design canvas is 660 x 520 points. All drawing below is expressed in that
// point space; the scale argument multiplies the pixel dimensions of the bitmap
// (1 -> 660x520, 2 -> 1320x1040) so a HiDPI TIFF can be assembled from both.
//
// Layout note: the positions below are quoted in Finder's top-left origin
// convention and converted to AppKit's bottom-left origin via topY().

import AppKit
import Foundation

// MARK: - Canvas contract

let canvasWidth: CGFloat = 660
let canvasHeight: CGFloat = 520

/// Converts a top-left-origin y coordinate to AppKit's bottom-left origin.
func topY(_ y: CGFloat) -> CGFloat { canvasHeight - y }

// Finder icon centers (top-left origin). Kept here for documentation; the
// packaging script positions the real icons at the same coordinates.
//
// Layout contract v3: every drawn element sits above y = 480 so the bottom 40pt
// of the canvas is pure gradient. That strip is the buffer a Finder tab bar eats
// on a Mac where AppKit's app-global tab-bar switch overrides the DMG's
// .DS_Store; without it the footer is clipped away. Do not fill it.
let appIconCenter = CGPoint(x: 165, y: 166)
let applicationsCenter = CGPoint(x: 495, y: 166)
let websiteCenter = CGPoint(x: 330, y: 336)

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("DMGBackground: \(message)\n".utf8))
    exit(1)
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: 1.0
    )
}

/// Draws `text` horizontally centered on `centerX`, with its vertical center at
/// the top-left-origin coordinate `centerYFromTop`.
func drawCentered(
    _ text: String,
    font: NSFont,
    color textColor: NSColor,
    centerX: CGFloat,
    centerYFromTop: CGFloat
) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let size = attributed.size()
    let origin = CGPoint(
        x: centerX - size.width / 2.0,
        y: topY(centerYFromTop) - size.height / 2.0
    )
    attributed.draw(in: NSRect(origin: origin, size: size))
}

// MARK: - Drawing

func drawBackground() {
    // 1. Vertical gradient, near-white at the top to a light cool grey.
    let gradient = NSGradient(starting: color(0xFBFCFD), ending: color(0xE7EBF0))
    guard let gradient else { fail("could not create the background gradient") }
    // angle 270 puts the starting colour at the top of the canvas.
    gradient.draw(in: NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight), angle: 270)

    // 2. Title.
    drawCentered(
        "Accessibility Mapper",
        font: .systemFont(ofSize: 26, weight: .semibold),
        color: color(0x1C2430),
        centerX: canvasWidth / 2,
        centerYFromTop: 40
    )

    // 3. Subtitle.
    drawCentered(
        "Drag the app onto the Applications folder to install",
        font: .systemFont(ofSize: 13, weight: .regular),
        color: color(0x5A6675),
        centerX: canvasWidth / 2,
        centerYFromTop: 74
    )

    // 4. Dashed drop target behind the /Applications icon position.
    let targetSide: CGFloat = 152
    let targetRect = NSRect(
        x: applicationsCenter.x - targetSide / 2,
        y: topY(applicationsCenter.y) - targetSide / 2,
        width: targetSide,
        height: targetSide
    )
    let target = NSBezierPath(roundedRect: targetRect, xRadius: 18, yRadius: 18)
    color(0x9AA8B8).withAlphaComponent(0.04).setFill()
    target.fill()
    target.lineWidth = 2
    target.setLineDash([8, 6], count: 2, phase: 0)
    color(0x9AA8B8).setStroke()
    target.stroke()

    // 5. Arrow from the app icon toward /Applications.
    let arrowY = topY(166)
    let arrowStartX: CGFloat = 258
    let arrowEndX: CGFloat = 402
    let headLength: CGFloat = 22
    let headHalfHeight: CGFloat = 12
    let shaftHalfThickness: CGFloat = 2.5
    let shaftEndX = arrowEndX - headLength

    color(0x7C8899).setFill()

    let shaft = NSBezierPath(
        rect: NSRect(
            x: arrowStartX,
            y: arrowY - shaftHalfThickness,
            width: shaftEndX - arrowStartX,
            height: shaftHalfThickness * 2
        )
    )
    shaft.fill()

    let head = NSBezierPath()
    head.move(to: CGPoint(x: arrowEndX, y: arrowY))
    head.line(to: CGPoint(x: shaftEndX, y: arrowY + headHalfHeight))
    head.line(to: CGPoint(x: shaftEndX, y: arrowY - headHalfHeight))
    head.close()
    head.fill()

    // 6. Footer: hairline rule plus the product URL.
    let ruleY = topY(442)
    color(0xD3DAE3).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: ruleY - 0.5, width: canvasWidth, height: 1)).fill()

    drawCentered(
        "www.twowheeljunction.com/products/accessibilitymapper",
        font: .systemFont(ofSize: 11, weight: .medium),
        color: color(0x2B6CB0),
        centerX: canvasWidth / 2,
        centerYFromTop: 458
    )
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("usage: swift DMGBackground.swift <out.png> <scale>")
}

let outputPath = arguments[1]
guard let scaleValue = Int(arguments[2]), scaleValue >= 1, scaleValue <= 4 else {
    fail("scale must be an integer between 1 and 4, got '\(arguments[2])'")
}
let scale = CGFloat(scaleValue)

guard
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasWidth * scale),
        pixelsHigh: Int(canvasHeight * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
else {
    fail("could not allocate a \(Int(canvasWidth * scale))x\(Int(canvasHeight * scale)) bitmap")
}

// Leave rep.size at its default (one point per pixel). If it were set to the
// 660x520 point canvas, NSGraphicsContext would install its own scale factor on
// top of the NSAffineTransform below and every drawing would come out at
// scale-squared.
guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fail("could not create a graphics context for the bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true

let transform = NSAffineTransform()
transform.scale(by: scale)
transform.concat()

drawBackground()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fail("could not encode the bitmap as PNG")
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fail("could not write '\(outputPath)': \(error.localizedDescription)")
}
