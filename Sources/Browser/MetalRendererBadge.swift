import AppKit

/// A small vector mark, drawn at the display's native resolution.
@MainActor enum MetalRendererBadge {
    static func image(size: CGFloat = 22) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.scaleX(by: rect.width / 24, yBy: rect.height / 24)
            transform.concat()
            let shell = NSBezierPath()
            shell.move(to: NSPoint(x: 12, y: 23))
            for point in [NSPoint(x: 22, y: 17), NSPoint(x: 22, y: 7),
                          NSPoint(x: 12, y: 1), NSPoint(x: 2, y: 7), NSPoint(x: 2, y: 17)] {
                shell.line(to: point)
            }
            shell.close()
            NSGradient(colors: [NSColor(calibratedRed: 0.18, green: 0.29, blue: 0.37, alpha: 1),
                                NSColor(calibratedRed: 0.03, green: 0.09, blue: 0.14, alpha: 1)])?.draw(in: shell, angle: 90)
            NSColor(calibratedRed: 0.24, green: 0.82, blue: 0.90, alpha: 1).setStroke()
            shell.lineWidth = 1
            shell.stroke()
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 6, y: 7))
            for point in [NSPoint(x: 6, y: 17), NSPoint(x: 12, y: 11),
                          NSPoint(x: 18, y: 17), NSPoint(x: 18, y: 7)] { mark.line(to: point) }
            NSColor(calibratedWhite: 0.94, alpha: 1).setStroke()
            mark.lineWidth = 2.7
            mark.lineJoinStyle = .round
            mark.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.accessibilityDescription = "Metal acceleration"
        return image
    }
}
