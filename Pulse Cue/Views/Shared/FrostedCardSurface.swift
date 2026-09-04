//
//  FrostedCardSurface.swift
//  Pulse Cue
//
//  The frosted card back used by Home, Nutrition and the AI Coach.
//
//  Those three drew a byte-identical fill, shadow and hairline stroke. Once a
//  screen's cards move into components of their own, the choice is between
//  passing the surface down, copying it again, or naming it once.
//
//  `RunnerView` is deliberately not here: its cards are built on
//  `PulseGlassPlate` and look different on purpose. Merging them would be a
//  visual decision, not a readability one.
//

import SwiftUI

extension View {
    /// Home / Nutrition card back: frosted fill, soft drop shadow, hairline
    /// top-left highlight. Pixel-for-pixel what both screens already drew.
    func frostedCard() -> some View {
        background(FrostedCardSurface.background)
            .overlay(FrostedCardSurface.stroke)
    }
}

enum FrostedCardSurface {
    static let cornerRadius: CGFloat = 22

    static var background: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
    }

    static var stroke: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.7), .white.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.6
            )
    }
}
