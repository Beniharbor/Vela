import AppKit

/// The Vela sails from Resources/Icon.svg, redrawn as a monochrome template
/// image for the menu bar. Template rendering lets macOS tint it white/black
/// to match the menu bar, like the built-in status icons.
enum MenuBarIcon {
    static let sails: NSImage = {
        // Geometry lifted from Icon.svg (512pt viewBox, y-down).
        // Main sail: one cubic curve from the masthead down to the clew.
        let main = NSBezierPath()
        main.move(to: NSPoint(x: 253.37, y: 52.6))
        main.curve(to: NSPoint(x: 416.44, y: 344.99),
                   controlPoint1: NSPoint(x: 345.1, y: 133),
                   controlPoint2: NSPoint(x: 436.3, y: 225.6))
        main.line(to: NSPoint(x: 252.93, y: 344.99))
        main.close()

        let jib = NSBezierPath()
        jib.move(to: NSPoint(x: 234.1, y: 117.04))
        jib.line(to: NSPoint(x: 117.04, y: 344.99))
        jib.line(to: NSPoint(x: 234.1, y: 344.99))
        jib.close()

        let glyph = NSBezierPath()
        glyph.append(main)
        glyph.append(jib)

        // Fit the sails' bounding box into the standard 18×18pt status-item
        // canvas, with a hair of padding so the glyph weight matches SF Symbols.
        let canvas: CGFloat = 18
        let inset: CGFloat = 1
        let bbox = glyph.bounds
        let scale = min((canvas - 2 * inset) / bbox.width,
                        (canvas - 2 * inset) / bbox.height)
        glyph.transform(using: AffineTransform(scale: scale))
        glyph.transform(using: AffineTransform(translationByX: (canvas - bbox.width * scale) / 2 - bbox.minX * scale,
                                               byY: (canvas - bbox.height * scale) / 2 - bbox.minY * scale))

        // flipped: true keeps the SVG's y-down coordinates as-is.
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: true) { _ in
            NSColor.black.setFill()
            glyph.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
