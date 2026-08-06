//
//  AppTheme.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import UIKit

enum AppTheme {
    /// Midnight Pulse foundation. The aliases at the top are intentionally
    /// kept because older screens still use them directly.
    static let background = Color(red: 0.027, green: 0.063, blue: 0.067)
    static let cardBackground = Color(red: 0.055, green: 0.118, blue: 0.122)
    static let cardBorder = Color.white.opacity(0.08)
    static let shadow = Color.black.opacity(0.28)
    static let highlight = Color(red: 0.322, green: 0.820, blue: 0.820)

    // MARK: - Midnight Pulse foundation

    /// Deep blue-green app background. Both appearances deliberately resolve
    /// to the same dark family so presented sheets do not flash white.
    static let surface = dynamicColor(
        light: (0.027, 0.063, 0.067, 1.0),
        dark: (0.027, 0.063, 0.067, 1.0)
    )

    /// Flat elevated surface for ordinary cards.
    static let surfaceCard = dynamicColor(
        light: (0.055, 0.118, 0.122, 1.0),
        dark: (0.055, 0.118, 0.122, 1.0)
    )

    /// Quiet teal-gray hairline border for structure without glow.
    static let separator = dynamicColor(
        light: (0.35, 0.49, 0.49, 0.24),
        dark: (0.35, 0.49, 0.49, 0.24)
    )

    /// Restrained teal reserved for actions, selection and important values.
    static let accent = dynamicColor(
        light: (0.322, 0.820, 0.820, 1.0),
        dark: (0.322, 0.820, 0.820, 1.0)
    )

    /// Low-emphasis accent tint for secondary fills and badges.
    static let accentSoft = accent.opacity(0.12)

    /// Deeper teal for filled controls carrying white labels.
    static let accentFilled = dynamicColor(
        light: (0.075, 0.439, 0.451, 1.0),
        dark: (0.075, 0.439, 0.451, 1.0)
    )

    // MARK: - PulseCue Glass palette

    /// Atmospheric colors inspired by the product's calm teal identity.
    /// These are background/light roles, never replacements for semantic text.
    static let deepSpace = Color(red: 0.012, green: 0.035, blue: 0.039)
    static let deepGlass = Color(red: 0.035, green: 0.157, blue: 0.165)
    static let reflectedBlue = Color(red: 0.180, green: 0.390, blue: 0.396)
    static let edgeBlue = Color(red: 0.290, green: 0.570, blue: 0.570)
    static let iceLight = Color(red: 0.690, green: 0.900, blue: 0.890)

    static let atmosphericBase = dynamicColor(
        light: (0.027, 0.063, 0.067, 1.0),
        dark: (0.027, 0.063, 0.067, 1.0)
    )
    static let glassEdge = dynamicColor(
        light: (0.60, 0.90, 0.88, 0.16),
        dark: (0.60, 0.90, 0.88, 0.16)
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

    /// Explicit text roles remain readable even inside UIKit-backed surfaces.
    static let textPrimary = Color(red: 0.902, green: 0.941, blue: 0.929)
    static let textSecondary = Color(red: 0.596, green: 0.690, blue: 0.675)

    /// Softer shadow than the legacy card shadow.
    static let softShadow = Color.black.opacity(0.20)

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
