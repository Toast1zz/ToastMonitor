import AppKit

/// The exact vector path from artifacts/menu-bar-icon.svg, drawn natively so
/// both SwiftPM runs and packaged apps have the same resolution-independent icon.
enum MenuBarIcon {
    static func makeImage() -> NSImage {
        // SVG coordinates grow downwards. Keep its 24-point viewBox and inset
        // while fitting the image into the standard menu bar at 18 points.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            let transform = NSAffineTransform()
            transform.translateX(by: rect.minX, yBy: rect.minY)
            transform.scaleX(by: rect.width / 24, yBy: rect.height / 24)
            transform.concat()

            // Preserve the SVG's nonzero fill rule and opposite subpath
            // directions: the letter is transparent, not painted white.
            let path = NSBezierPath()
            path.windingRule = .nonZero
            path.move(to: NSPoint(x: 1, y: 12))
            path.curve(to: NSPoint(x: 12, y: 1),
                       controlPoint1: NSPoint(x: 1, y: 5.925),
                       controlPoint2: NSPoint(x: 5.925, y: 1))
            path.curve(to: NSPoint(x: 23, y: 12),
                       controlPoint1: NSPoint(x: 18.075, y: 1),
                       controlPoint2: NSPoint(x: 23, y: 5.925))
            path.curve(to: NSPoint(x: 12, y: 23),
                       controlPoint1: NSPoint(x: 23, y: 18.075),
                       controlPoint2: NSPoint(x: 18.075, y: 23))
            path.curve(to: NSPoint(x: 1, y: 12),
                       controlPoint1: NSPoint(x: 5.925, y: 23),
                       controlPoint2: NSPoint(x: 1, y: 18.075))
            path.close()
            path.move(to: NSPoint(x: 12.401, y: 9.42))
            path.line(to: NSPoint(x: 12.401, y: 7.376))
            path.curve(to: NSPoint(x: 11.09, y: 6),
                       controlPoint1: NSPoint(x: 12.401, y: 6.478),
                       controlPoint2: NSPoint(x: 11.814, y: 6))
            path.curve(to: NSPoint(x: 9.779, y: 7.376),
                       controlPoint1: NSPoint(x: 10.366, y: 6),
                       controlPoint2: NSPoint(x: 9.779, y: 6.478))
            path.line(to: NSPoint(x: 9.779, y: 9.42))
            path.line(to: NSPoint(x: 8.37, y: 9.42))
            path.curve(to: NSPoint(x: 7, y: 10.567),
                       controlPoint1: NSPoint(x: 7.548, y: 9.42),
                       controlPoint2: NSPoint(x: 7, y: 9.841))
            path.curve(to: NSPoint(x: 8.448, y: 11.713),
                       controlPoint1: NSPoint(x: 7, y: 11.274),
                       controlPoint2: NSPoint(x: 7.489, y: 11.713))
            path.curve(to: NSPoint(x: 9.779, y: 11.618),
                       controlPoint1: NSPoint(x: 8.859, y: 11.713),
                       controlPoint2: NSPoint(x: 9.427, y: 11.656))
            path.line(to: NSPoint(x: 9.779, y: 14.408))
            path.curve(to: NSPoint(x: 13.321, y: 18),
                       controlPoint1: NSPoint(x: 9.779, y: 16.777),
                       controlPoint2: NSPoint(x: 10.816, y: 18))
            path.curve(to: NSPoint(x: 17, y: 16.07),
                       controlPoint1: NSPoint(x: 14.495, y: 18),
                       controlPoint2: NSPoint(x: 17, y: 17.656))
            path.curve(to: NSPoint(x: 15.904, y: 15.019),
                       controlPoint1: NSPoint(x: 17, y: 15.439),
                       controlPoint2: NSPoint(x: 16.511, y: 15.019))
            path.curve(to: NSPoint(x: 14.632, y: 15.459),
                       controlPoint1: NSPoint(x: 15.376, y: 15.019),
                       controlPoint2: NSPoint(x: 15.063, y: 15.248))
            path.curve(to: NSPoint(x: 13.614, y: 15.783),
                       controlPoint1: NSPoint(x: 14.339, y: 15.611),
                       controlPoint2: NSPoint(x: 13.947, y: 15.783))
            path.curve(to: NSPoint(x: 12.401, y: 14.369),
                       controlPoint1: NSPoint(x: 12.832, y: 15.783),
                       controlPoint2: NSPoint(x: 12.401, y: 15.325))
            path.line(to: NSPoint(x: 12.401, y: 11.599))
            path.curve(to: NSPoint(x: 15.2, y: 11.713),
                       controlPoint1: NSPoint(x: 13.027, y: 11.637),
                       controlPoint2: NSPoint(x: 14.71, y: 11.713))
            path.curve(to: NSPoint(x: 16.648, y: 10.567),
                       controlPoint1: NSPoint(x: 16.159, y: 11.713),
                       controlPoint2: NSPoint(x: 16.648, y: 11.274))
            path.curve(to: NSPoint(x: 15.278, y: 9.42),
                       controlPoint1: NSPoint(x: 16.648, y: 9.841),
                       controlPoint2: NSPoint(x: 16.1, y: 9.42))
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        // Black supplies the alpha mask only; AppKit chooses the displayed
        // color for the menu bar's appearance, highlight and inactive state.
        image.isTemplate = true
        return image
    }
}
