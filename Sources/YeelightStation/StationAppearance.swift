import AppKit
import SwiftUI

/// Shared semantic surfaces follow the window's appearance, including previews.
enum StationAppearance {
    static let accent = adaptive(
        light: NSColor(srgbRed: 0.38, green: 0.27, blue: 0.76, alpha: 1),
        dark: NSColor(srgbRed: 0.65, green: 0.60, blue: 1, alpha: 1))
    static let windowBackground = adaptive(
        light: .windowBackgroundColor,
        dark: NSColor(srgbRed: 0.065, green: 0.069, blue: 0.09, alpha: 1))
    static let cardBackground = adaptive(light: .black.withAlphaComponent(0.035), dark: .white.withAlphaComponent(0.035))
    static let subtleBackground = adaptive(light: .black.withAlphaComponent(0.025), dark: .white.withAlphaComponent(0.025))
    static let cardBorder = Color.primary.opacity(0.075)
    static let fieldBackground = Color(nsColor: .controlBackgroundColor)
    static let popoverBackground = adaptive(
        light: .controlBackgroundColor,
        dark: NSColor(srgbRed: 0.105, green: 0.108, blue: 0.14, alpha: 1))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
