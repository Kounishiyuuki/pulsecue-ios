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

    static let cornerRadius: CGFloat = 22

    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.27, green: 0.62, blue: 0.95),
            Color(red: 0.49, green: 0.51, blue: 0.97),
            Color(red: 0.66, green: 0.45, blue: 0.95),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let accentSolid = Color(red: 0.49, green: 0.51, blue: 0.97)

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
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(MyGymStyle.accentGradient) : AnyShapeStyle(Color.gray.opacity(0.4)))
                    .shadow(
                        color: isEnabled
                            ? Color(red: 0.27, green: 0.5, blue: 0.95).opacity(0.30)
                            : .clear,
                        radius: 12, x: 0, y: 6
                    )
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}
