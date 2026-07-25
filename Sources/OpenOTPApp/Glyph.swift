import SwiftUI
import AppKit

struct Glyph: View {
    let name: String
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        Group {
            if let img = IconSet.image(name, size: size * 2, color: .black, template: true) {
                Image(nsImage: img)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: size, height: size)
                    .foregroundStyle(color)
            } else {
                Color.clear.frame(width: size, height: size)
            }
        }
        // Glyphs are decorative — always paired with a text label or inside a
        // labeled control — so VoiceOver reads the text, not "image". Any icon-
        // only button sets its own .accessibilityLabel.
        .accessibilityHidden(true)
    }
}
