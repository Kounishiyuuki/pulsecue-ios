//
//  AppTheme.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import UIKit

enum AppTheme {
    static let background = Color(.systemGroupedBackground)
    static let cardBackground = Color(.systemBackground)
    static let cardBorder = Color(.systemGray5)
    static let shadow = Color.black.opacity(0.06)
    static let highlight = Color.orange

    // MARK: - Apple Health Light foundation
    //
    // A calmer, "Apple Health / Fitness" inspired palette: light and airy,
    // a restrained blue accent, soft translucent cards, and subtle blue-gray
    // borders. Additive — the keys above are kept for existing call sites.
    // Colors adapt to dark mode via dynamic `UIColor` so no asset catalog
    // entries are required.

    /// App background — off-white / very pale blue-gray (light), near-black
    /// (dark). Airy and low-contrast so cards float above it.
    static let surface = dynamicColor(
        light: (0.96, 0.97, 0.985, 1.0),
        dark: (0.07, 0.08, 0.10, 1.0)
    )

    /// Soft, translucent white card fill. Pair with `.regularMaterial` via
    /// `PulseCard` for the frosted look, or use directly for a flat card.
    static let surfaceCard = dynamicColor(
        light: (1.0, 1.0, 1.0, 0.85),
        dark: (1.0, 1.0, 1.0, 0.06)
    )

    /// Subtle blue-gray hairline border for cards and dividers.
    static let separator = dynamicColor(
        light: (0.60, 0.66, 0.74, 0.30),
        dark: (0.40, 0.45, 0.52, 0.45)
    )

    /// Restrained blue accent for primary actions and key highlights —
    /// deliberately less saturated than the legacy cyan/purple gradient.
    static let accent = dynamicColor(
        light: (0.16, 0.47, 0.86, 1.0),
        dark: (0.40, 0.64, 0.96, 1.0)
    )

    /// Low-emphasis accent tint for secondary fills and badges.
    static let accentSoft = accent.opacity(0.12)

    /// Solid fill for controls that carry **white** text/icons (filled
    /// primary buttons, the Home CTA). `accent` alone is tuned as a *tint on
    /// backgrounds* — its dark-mode value is bright enough that white text on
    /// it fails contrast (~2.6:1). `accentFilled` is deliberately deeper in
    /// both modes so white foreground clears WCAG AA (~4.5:1) on it:
    ///   - light (0.14,0.45,0.84) → white ≈ 4.68:1
    ///   - dark  (0.17,0.45,0.86) → white ≈ 4.59:1
    /// Single-hue by design — no gradient. Use `accent` for tints/foreground,
    /// `accentFilled` only where white sits *on top of* the color.
    static let accentFilled = dynamicColor(
        light: (0.14, 0.45, 0.84, 1.0),
        dark: (0.17, 0.45, 0.86, 1.0)
    )

    // MARK: - PulseCue Glass palette

    /// Atmospheric colors inspired by the product's calm blue identity.
    /// These are background/light roles, never replacements for semantic text.
    static let deepSpace = Color(red: 0.008, green: 0.063, blue: 0.141)
    static let deepGlass = Color(red: 0.020, green: 0.149, blue: 0.349)
    static let reflectedBlue = Color(red: 0.329, green: 0.514, blue: 0.702)
    static let edgeBlue = Color(red: 0.490, green: 0.627, blue: 0.792)
    static let iceLight = Color(red: 0.757, green: 0.910, blue: 1.000)

    static let atmosphericBase = dynamicColor(
        light: (0.955, 0.976, 0.995, 1.0),
        dark: (0.008, 0.035, 0.080, 1.0)
    )
    static let glassEdge = dynamicColor(
        light: (1.0, 1.0, 1.0, 0.78),
        dark: (0.76, 0.91, 1.0, 0.20)
    )

    /// Calm, trustworthy status colors.
    static let success = dynamicColor(
        light: (0.18, 0.60, 0.36, 1.0),
        dark: (0.36, 0.78, 0.52, 1.0)
    )
    static let warning = dynamicColor(
        light: (0.85, 0.55, 0.16, 1.0),
        dark: (0.96, 0.70, 0.34, 1.0)
    )
    static let info = accent

    /// Readable text roles (semantic system colors keep contrast correct).
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary

    /// Softer shadow than the legacy card shadow.
    static let softShadow = Color.black.opacity(0.05)

    /// Corner radii.
    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 14
    static let glassRadius: CGFloat = 22
    static let heroRadius: CGFloat = 28

    /// Consistent spacing scale.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Builds a light/dark adaptive `Color` from RGBA tuples (0...1).
    private static func dynamicColor(
        light: (r: Double, g: Double, b: Double, a: Double),
        dark: (r: Double, g: Double, b: Double, a: Double)
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
    }
}
