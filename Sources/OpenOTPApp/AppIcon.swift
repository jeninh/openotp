import AppKit

enum AppIcon {

    static func image(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let radius = size * 0.225
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06),
                                xRadius: radius, yRadius: radius)

        NSColor.white.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        path.lineWidth = size * 0.006
        path.stroke()

        let ink = NSColor.black
        if let glyph = IconSet.emailCheck(size: size * 0.8, color: ink) {
            let g = glyph.size
            let glyphRect = NSRect(x: (size - g.width) / 2, y: (size - g.height) / 2, width: g.width, height: g.height)
            glyph.draw(in: glyphRect)
        }
        return image
    }
}
