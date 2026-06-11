//
//  PulseUITests.swift
//  Pulse CueTests
//
//  Lightweight checks for the shared "Apple Health Light" UI foundation.
//  These verify the small bits of logic in the primitives (status-badge kind
//  mapping) and that the components construct — not their pixels.
//

import SwiftUI
import Testing
@testable import Pulse_Cue

@Suite
@MainActor
struct PulseUITests {

    @Test
    func statusBadgeKindsMapToDistinctIconsAndTints() {
        let kinds: [PulseStatusBadge.Kind] = [.info, .success, .warning]
        let icons = kinds.map(\.systemImage)
        // Each kind has its own, non-empty SF Symbol.
        #expect(Set(icons).count == kinds.count)
        #expect(icons.allSatisfy { !$0.isEmpty })
        // Warning and success use different tints from info.
        #expect(PulseStatusBadge.Kind.success.tint != PulseStatusBadge.Kind.info.tint)
        #expect(PulseStatusBadge.Kind.warning.tint != PulseStatusBadge.Kind.info.tint)
    }

    @Test
    func componentsConstruct() {
        // Smoke check: the primitives build and are usable from outside the
        // module (catches access-level regressions).
        _ = PulseCard { Text("x") }
        _ = PulseSectionHeader("Title", icon: "heart")
        _ = PulseSectionHeader("No icon")
        _ = PulseStatusBadge("ok", kind: .success)
        _ = PulseStatusBadge("info")
    }

    @Test
    func buttonStylesAreApplicable() {
        _ = Button("Primary") {}.buttonStyle(PulsePrimaryButtonStyle())
        _ = Button("Secondary") {}.buttonStyle(PulseSecondaryButtonStyle())
        _ = Button("Tertiary") {}.buttonStyle(PulseTertiaryButtonStyle())
    }

    // MARK: - Disabled visual state respects both manual flag and .disabled(...)

    @Test
    func effectiveEnabledIsManualAndEnvironment() {
        // Enabled only when BOTH the manual flag and the `.disabled(...)`
        // environment are enabled — disabled if either is false.
        #expect(PulseButtonBody.isEffectivelyEnabled(manual: true, environment: true) == true)
        #expect(PulseButtonBody.isEffectivelyEnabled(manual: false, environment: true) == false)
        #expect(PulseButtonBody.isEffectivelyEnabled(manual: true, environment: false) == false)
        #expect(PulseButtonBody.isEffectivelyEnabled(manual: false, environment: false) == false)
    }

    @Test
    func manualDisabledFlagStillForcesDisabled() {
        // The kept manual API: isEnabled:false disables regardless of env.
        #expect(PulseButtonBody.isEffectivelyEnabled(manual: false, environment: true) == false)
    }

    @Test
    func environmentDisabledIsRespectedEvenWhenManualEnabled() {
        // The fix: SwiftUI `.disabled(true)` (environment == false) disables
        // even when the style's manual flag stays the default `true`.
        #expect(PulseButtonBody.isEffectivelyEnabled(manual: true, environment: false) == false)
    }

    @Test
    func disabledButtonStylesStillConstruct() {
        // The styles remain applicable together with `.disabled(...)`.
        _ = Button("Primary") {}.buttonStyle(PulsePrimaryButtonStyle()).disabled(true)
        _ = Button("Secondary") {}.buttonStyle(PulseSecondaryButtonStyle(isEnabled: false))
        _ = Button("Tertiary") {}.buttonStyle(PulseTertiaryButtonStyle()).disabled(true)
    }

    @Test
    func spacingScaleIsMonotonic() {
        #expect(AppTheme.Spacing.xs < AppTheme.Spacing.s)
        #expect(AppTheme.Spacing.s < AppTheme.Spacing.m)
        #expect(AppTheme.Spacing.m < AppTheme.Spacing.l)
        #expect(AppTheme.Spacing.l < AppTheme.Spacing.xl)
    }
}
