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
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 14

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
