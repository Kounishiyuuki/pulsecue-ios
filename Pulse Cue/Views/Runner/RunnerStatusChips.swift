//
//  RunnerStatusChips.swift
//  Pulse Cue
//
//  今 / 残り / 次 — where you are in the workout, in three words.
//
//  Read mid-set, at arm's length, by someone out of breath. That is why they
//  are three short chips rather than a sentence, and why 今 is the filled one:
//  the other two are context for it.
//
//  Presentation only. Every value is derived from `RunnerViewModel` state
//  passed in; nothing here advances a set or touches a Session.
//

import SwiftUI

struct RunnerStatusChips: View {
    let phase: RunnerPhase
    let isRunning: Bool
    let currentStep: Step?
    let nextStep: Step?
    let currentSetIndex: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) { chips }
        } else {
            HStack(spacing: 10) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        chip(
            label: "今",
            value: nowValue,
            accessibilityText: "現在の状態、\(nowValue)",
            isActive: true
        )
        chip(label: "残り", value: remainingValue, accessibilityText: remainingAccessibility)
        chip(label: "次", value: nextValue, accessibilityText: nextAccessibility)
    }

    // MARK: - Values

    private var nowValue: String {
        switch phase {
        case .rest: return "休憩"
        case .exercise: return isRunning ? "実行中" : "準備"
        case .done: return "未開始"
        }
    }

    private var remainingValue: String {
        guard let currentStep else { return "—" }
        // During .rest the just-completed set has not yet incremented
        // currentSetIndex. Treat it as one set already done so the chip
        // counts down as the user expects.
        let setsDone = phase == .rest ? currentSetIndex + 1 : currentSetIndex
        return "\(max(0, currentStep.sets - setsDone))"
    }

    private var nextValue: String {
        if let nextStep { return nextStep.title }
        if isRunning { return "最後" }
        return "—"
    }

    private var remainingAccessibility: String {
        guard currentStep != nil else { return "残りセット、未設定" }
        return "残り \(remainingValue) セット"
    }

    private var nextAccessibility: String {
        if nextStep != nil { return "次の種目、\(nextValue)" }
        return isRunning ? "次の種目、なし" : "次の種目、未設定"
    }

    // MARK: - Chip

    private func chip(
        label: String,
        value: String,
        accessibilityText: String,
        isActive: Bool = false
    ) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(isActive ? Color.white : .secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive ? Color.white : .primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(background(isActive: isActive))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.84), AppTheme.iceLight.opacity(0.26), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isActive ? 0.9 : 0.7
                )
        )
        // One chip, one sentence: read separately, the label and the value are
        // two fragments that mean nothing apart.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func background(isActive: Bool) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.accentFilled)
        } else {
            PulseGlassPlate(level: .subtle, focused: true, cornerRadius: 12)
        }
    }
}

// MARK: - Rest timer dial
//
// Here only because a new file would need a project.pbxproj change; it is
// shared by the Runner, Free Workout and Home, and belongs in its own file.

/// The rest timer's face: a dark dial with sixty clock ticks (every fifth
/// one longer), an ice-blue arc for the share of the rest still to run, and
/// the time left in the middle.
///
/// Presentation only. Each caller makes it one accessibility element with
/// its own label and value. The caller passes the fraction and the text; nothing
/// here reads a clock, so the dial redraws only when its caller does — once a
/// second at most — and never the screen around it.
struct RestTimerDial: View {
    /// Share of the rest still to run, 0...1 (`RestCountdown.fractionRemaining`).
    let fraction: Double
    let timeText: String
    var caption: String?
    var diameter: CGFloat
    /// The compact form (a pill or a bar) has no ticks and no text.
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { fraction.isFinite ? min(1, max(0, fraction)) : 0 }
    private var ringWidth: CGFloat { compact ? max(3, diameter * 0.11) : max(6, diameter * 0.045) }
    /// Ring sits inside the ticks on the full dial.
    private var ringInset: CGFloat { compact ? ringWidth / 2 : diameter * 0.13 }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [AppTheme.restIceDeep.opacity(compact ? 0.22 : 0.16), Color.black.opacity(0.92)],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter / 2
                    )
                )
            if !compact {
                Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                ticks
            }
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: ringWidth)
                .padding(ringInset)
            Circle()
                .trim(from: 0, to: clamped)
                // One color: a gradient along the arc leaves a hard seam at
                // twelve o'clock when the arc is nearly full.
                .stroke(AppTheme.restIce, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: AppTheme.restIce.opacity(compact ? 0.35 : 0.5), radius: ringWidth * 0.9)
                .padding(ringInset)
            if !compact {
                VStack(spacing: 4) {
                    if let caption {
                        Text(caption)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Text(timeText)
                        .font(.system(size: diameter * 0.2, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                }
                .padding(.horizontal, diameter * 0.2)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : .linear(duration: 1), value: clamped)
    }

    /// Sixty ticks, lit ice-blue for the part of the rest still to run, the
    /// way a clock's seconds would be.
    private var ticks: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let lit = Int((clamped * 60).rounded(.up))
            for index in 0..<60 {
                let major = index % 5 == 0
                let length = radius * (major ? 0.085 : 0.045)
                let outer = radius * 0.965
                let angle = Double(index) / 60 * 2 * .pi - .pi / 2
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                var path = Path()
                path.move(to: CGPoint(x: center.x + direction.x * outer, y: center.y + direction.y * outer))
                path.addLine(to: CGPoint(x: center.x + direction.x * (outer - length), y: center.y + direction.y * (outer - length)))
                let color = index < lit
                    ? AppTheme.restIce.opacity(major ? 0.95 : 0.6)
                    : Color.white.opacity(major ? 0.32 : 0.14)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: major ? 2.4 : 1.1, lineCap: .round))
            }
        }
    }
}
