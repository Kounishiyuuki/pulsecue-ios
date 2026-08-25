//
//  NutritionDailySummaryCard.swift
//  Pulse Cue
//
//  Today's intake, ordered by what a person actually decides with.
//
//  The card this replaces led with consumed calories and then gave protein,
//  carbs and fat three identical panels — but the number that decides the
//  next meal is **remaining**, and it was not on the screen at all. You could
//  read 1,840 and the target 2,400 and do the subtraction yourself, which is
//  work the app was already able to do.
//
//  So: remaining is the largest thing here, protein sits under it because it
//  is the macro people track against a target, and carbs and fat move behind
//  a disclosure. They are not less true, they are less often acted on — and
//  giving all three macros equal weight meant none of them read as more
//  important than the others.
//
//  Every figure comes from `DailyNutritionSummary`, the contract Home shares.
//  Nothing is recomputed here: this file decides what is shown and how
//  loudly, never what is true.
//

import SwiftUI

struct NutritionDailySummaryCard: View {
    let summary: DailyNutritionSummary
    /// Carbs and fat, already totalled by the caller. Passed in rather than
    /// derived here because their targets are still the screen's inline
    /// heuristics — moving them into a shared policy is a separate change.
    let carbGrams: Int
    let carbTargetGrams: Int
    let fatGrams: Int
    let fatTargetGrams: Int

    let proteinGradient: LinearGradient
    let carbGradient: LinearGradient
    let fatGradient: LinearGradient

    @Binding var showsMacroDetail: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            supportingLine
            leadingLine
            if NutritionSurface.isFirstLevel(.protein) {
                proteinPanel
            }
            macroDetail
        }
        .pulseCard(padding: 20)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("今日の栄養")
                .font(.title3.weight(.bold))
            Spacer(minLength: 8)
            // Secondary by design: the target is the subject, where it came
            // from is a footnote.
            switch summary.targetSource {
            case .profileDerived:
                PulseStatusBadge("計算目標", kind: .info)
            case .manualOverride:
                PulseStatusBadge("設定目標", kind: .info)
            case .unset:
                EmptyView()
            }
        }
    }

    private var leads: NutritionSurface.LeadingFigure {
        NutritionSurface.leadingFigure(for: summary)
    }

    /// The largest thing on the card: what the next meal is decided against.
    @ViewBuilder
    private var leadingLine: some View {
        switch leads {
        case .remaining:
            remainingLine
        case .consumed:
            // No target, so no remaining. The consumed figure moves up rather
            // than leaving a blank where the decision should be.
            emphasised(
                caption: "摂取",
                value: "\(Self.format(summary.consumedKcal ?? 0)) kcal",
                tint: AppTheme.accent,
                accessibility: intakeAccessibilityLabel
            )
        }
    }

    /// The quieter half of the pair, shown above the leading figure.
    @ViewBuilder
    private var supportingLine: some View {
        switch leads {
        case .remaining:
            intakeLine
        case .consumed:
            Text("目標カロリーは未設定です")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emphasised(
        caption: String,
        value: String,
        tint: Color,
        accessibility: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var intakeLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.format(summary.consumedKcal ?? 0))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(summary.targetKcal.map { "/ \(Self.format($0)) kcal" } ?? "kcal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(intakeAccessibilityLabel)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The largest thing on the card, because it is the one being acted on.
    @ViewBuilder
    private var remainingLine: some View {
        if let remaining = summary.remainingKcal {
            let isOver = remaining < 0
            emphasised(
                caption: isOver ? "目標超過" : "残り",
                value: "\(Self.format(abs(remaining))) kcal",
                tint: isOver ? AppTheme.warning : AppTheme.accent,
                accessibility: isOver
                    ? "目標より \(abs(remaining)) キロカロリー超過"
                    : "残り \(remaining) キロカロリー"
            )
        }
    }

    private var proteinPanel: some View {
        macroPanel(
            label: "たんぱく質",
            grams: summary.proteinGrams,
            target: summary.proteinTargetGrams,
            gradient: proteinGradient
        )
    }

    /// Carbs and fat, one tap away.
    private var macroDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                setDetail(!showsMacroDetail)
            } label: {
                HStack(spacing: 6) {
                    Text(showsMacroDetail ? "内訳を閉じる" : "炭水化物・脂質を見る")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: showsMacroDetail ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppTheme.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsMacroDetail ? "内訳を閉じる" : "炭水化物と脂質を見る")

            if showsMacroDetail {
                macroPanel(
                    label: "炭水化物",
                    grams: carbGrams,
                    target: carbTargetGrams,
                    gradient: carbGradient
                )
                macroPanel(
                    label: "脂質",
                    grams: fatGrams,
                    target: fatTargetGrams,
                    gradient: fatGradient
                )
            }
        }
    }

    private func macroPanel(
        label: String,
        grams: Int,
        target: Int,
        gradient: LinearGradient
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(grams)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Text("/ \(target) g")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressBar(progress: Double(grams) / Double(max(1, target)), gradient: gradient)
                .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(grams) グラム、目標 \(target) グラム")
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setDetail(_ open: Bool) {
        if reduceMotion {
            showsMacroDetail = open
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { showsMacroDetail = open }
        }
    }

    private var intakeAccessibilityLabel: String {
        let consumed = summary.consumedKcal ?? 0
        guard let target = summary.targetKcal else {
            return "摂取 \(consumed) キロカロリー"
        }
        return "摂取 \(consumed) キロカロリー、目標 \(target) キロカロリー"
    }

    nonisolated private static func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
