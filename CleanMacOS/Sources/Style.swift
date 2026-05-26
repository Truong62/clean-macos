import SwiftUI
import AppKit

// Shared visual style — matches the Home screen aesthetic (frosted cards, soft pastel).

/// Soft pastel blob gradient (the Sense look), reused across screens for banners/thumbnails.
let appPastelGradient = LinearGradient(
    colors: [
        Color(red: 0.98, green: 0.80, blue: 0.86),
        Color(red: 0.99, green: 0.87, blue: 0.77),
        Color(red: 0.86, green: 0.82, blue: 0.95),
        Color(red: 0.80, green: 0.92, blue: 0.86),
    ],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

extension View {
    /// Show the pointing-hand cursor while hovering — use on clickable controls.
    func pointerCursor() -> some View {
        modifier(PointerCursor())
    }

    /// Frosted, rounded "card" surface matching the Home screen cards.
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }
}

private struct PointerCursor: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { h in
                hovering = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop() } }
    }
}
