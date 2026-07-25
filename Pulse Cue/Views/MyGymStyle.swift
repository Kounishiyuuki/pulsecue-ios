//
//  MyGymStyle.swift
//  Pulse Cue
//
//  Shared visual primitives for the My Gym + gym candidate search +
//  generated plan preview screens. Mirrors the glass-card aesthetic
//  established by `SettingsView`'s private helpers but exposed as
//  reusable modifiers so PR #20 / #21 / #22 screens can stay
//  cohesive without each view re-implementing the recipe.
//
//  Layout-only. No model, repository, or networking dependencies.
//

import SwiftUI

enum MyGymStyle {

    static let cornerRadius: CGFloat = 20

    /// Unified with `AppTheme.accent` — the restrained single blue accent.
    /// Kept as a (single-hue) `LinearGradient` only so existing
    /// `foregroundStyle(accentGradient)` call sites compile unchanged; the
    /// loud blue→purple gradient is intentionally gone for visual calm.
    static let accentGradient = LinearGradient(
        colors: [AppTheme.accent, AppTheme.accent],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let accentSolid = AppTheme.accent

    /// Subtle radial background used behind hero screens (MyGymHome,
    /// TargetBodyPart, GeneratedPlanPreview). Adapts to color scheme.
    @ViewBuilder
    static func backgroundLayer(for colorScheme: ColorScheme) -> some View {
        if colorScheme == .dark {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.08, blue: 0.13),
                    Color(red: 0.10, green: 0.12, blue: 0.20),
                    Color(red: 0.07, green: 0.10, blue: 0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.96, blue: 1.00),
                    Color(red: 0.92, green: 0.94, blue: 1.00),
                    Color(red: 0.96, green: 0.93, blue: 1.00),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    static func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(accentGradient)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
            Spacer()
        }
    }
}

// MARK: - Card modifier

extension View {
    /// Wraps content in the standard frosted card used across the
    /// My Gym surface. Internal padding + corner radius are fixed so
    /// every screen looks the same.
    func myGymCard(padding: CGFloat = 18) -> some View {
        modifier(MyGymCardModifier(padding: padding))
    }
}

private struct MyGymCardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(cardBackground)
            .overlay(cardStroke)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: MyGymStyle.cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: MyGymStyle.cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.7), .white.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}

// MARK: - Primary CTA button style

struct MyGymPrimaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(Color(.systemGray4)))
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}
