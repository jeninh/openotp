import SwiftUI

// Ink & Paper — a monochrome design system.
// Ink #0A0A0A · Paper #FFFFFF · one grayscale ramp · no chrome color.
// Tokens are built on Color.primary so the scheme adapts to light/dark while
// staying strictly monochrome.
enum Theme {
    static let ink = Color.primary
    static let paper = Color(nsColor: .windowBackgroundColor)
    static let secondary = Color.secondary
    static let border = Color.primary.opacity(0.12)
    static let fill = Color.primary.opacity(0.06)
    static let fillStrong = Color.primary.opacity(0.10)
    static let chipRadius: CGFloat = 7
}
