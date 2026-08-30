//
//  FrostedCardSurface.swift
//  Pulse Cue
//
//  The frosted card back used by Home and Nutrition.
//
//  Both screens carried a byte-identical `glassBackground` / `glassStroke`
//  pair. That was tolerable while each was a private detail of one file, but
//  the moment either screen's cards move into components of their own the
//  choice is between passing the surface down, copying it a third and fourth
//  time, or naming it once. This names it once.
//
//  Only the two definitions that were already identical are here. `RunnerView`
//  and `AICoachView` have their own variants that are *similar* rather than
//  the same, and merging those is a visual decision, not a readability one.
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
