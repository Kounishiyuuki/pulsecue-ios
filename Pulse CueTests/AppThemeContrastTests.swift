//
//  AppThemeContrastTests.swift
//  Pulse CueTests
//
//  Regression guard for the shared filled-accent token used by primary
//  buttons AND selected-state surfaces (chips, tiles, checkboxes, badges).
//  White text/icons sit on `AppTheme.accentFilled`, so both the light- and
//  dark-mode *resolved* colours must clear WCAG AA for normal text (4.5:1).
//
//  Non-circular by construction: the test resolves the ACTUAL UIColor the
//  app ships for each interface style and computes the WCAG contrast with the
//  standard formula — it never asserts a value produced by the code under
//  test.
//

import Testing
import UIKit
import SwiftUI
@testable import Pulse_Cue

@MainActor
struct AppThemeContrastTests {

    /// WCAG relative luminance of a resolved (opaque) colour.
    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Contrast ratio of the given colour against pure white foreground.
    private func contrastWithWhite(_ color: UIColor) -> Double {
        (1.0 + 0.05) / (luminance(color) + 0.05)
    }

    private func resolved(_ color: Color, _ style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    @Test func accentFilledLightModeClearsAA() {
        let ratio = contrastWithWhite(resolved(AppTheme.accentFilled, .light))
        #expect(ratio >= 4.5)
    }

    @Test func accentFilledDarkModeClearsAA() {
        let ratio = contrastWithWhite(resolved(AppTheme.accentFilled, .dark))
        #expect(ratio >= 4.5)
    }

    /// The plain `accent` tint is intentionally *not* contrast-safe for white
    /// text in dark mode — this pins the reason `accentFilled` must exist, so
    /// a future refactor can't silently collapse the two tokens.
    @Test func plainAccentIsInsufficientForWhiteInDark() {
        let ratio = contrastWithWhite(resolved(AppTheme.accent, .dark))
        #expect(ratio < 4.5)
    }
}
