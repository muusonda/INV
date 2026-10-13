import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Provide an iconset directory.")
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)

let icons: [(String, Int)] = [
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

func renderIcon(size: Int, destination: URL) throws {
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
    ) else {
        throw NSError(
            domain: "INVIcon",
            code: 1
        )
    }

    bitmap.size = NSSize(
        width: size,
        height: size
    )

    guard let context = NSGraphicsContext(
        bitmapImageRep: bitmap
    ) else {
        throw NSError(
            domain: "INVIcon",
            code: 2
        )
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let side = CGFloat(size)
    let bounds = NSRect(
        x: 0,
        y: 0,
        width: side,
        height: side
    )

    NSColor.clear.setFill()
    bounds.fill()

    let background = NSColor(
        calibratedRed: 0.965,
        green: 0.953,
        blue: 0.914,
        alpha: 1
    )

    background.setFill()

    NSBezierPath(
        roundedRect: bounds,
        xRadius: side * 0.215,
        yRadius: side * 0.215
    ).fill()

    let font =
        NSFont(
            name: "HelveticaNeue-Bold",
            size: side * 0.305
        )
        ?? NSFont.systemFont(
            ofSize: side * 0.305,
            weight: .bold
        )

    let text = NSAttributedString(
        string: "INV",
        attributes: [
            .font: font,
            .foregroundColor: NSColor(
                calibratedWhite: 0.07,
                alpha: 1
            ),
            .kern: side * 0.004
        ]
    )

    let textSize = text.size()

    text.draw(
        at: NSPoint(
            x: (side - textSize.width) / 2,
            y: (side - textSize.height) / 2 - side * 0.015
        )
    )

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(
        using: .png,
        properties: [:]
    ) else {
        throw NSError(
            domain: "INVIcon",
            code: 3
        )
    }

    try png.write(to: destination)
}

for icon in icons {
    try renderIcon(
        size: icon.1,
        destination: outputDirectory
            .appendingPathComponent(icon.0)
    )
}

print("Typographic INV icon created.")
