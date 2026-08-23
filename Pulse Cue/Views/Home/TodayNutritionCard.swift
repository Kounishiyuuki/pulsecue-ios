//
//  TodayNutritionCard.swift
//  Pulse Cue
//
//  Today's intake, as a decision rather than a readout.
//
//  Nutrition used to appear on Home as a 摂取 tile in a 2×2 grid of
//  equal-looking metrics and a 食事ログ link below it — which told you what
//  you had eaten but not what to do about it. The number that actually
//  decides the next meal is **remaining**, so that is the one given weight
//  here.
//
//  Everything shown is existing app truth. Consumed kcal is
//  `DayLog.intakeCalories`, which `NutritionLedger` already keeps equal to the
//  sum of confirmed meals; the target is the same value Nutrition shows; and
//  protein comes from `ProteinTotals`, the tested helper that owns the
//  confirmed-only rule. No calorie or macro policy was invented for Home.
//
//  Pending and AI-estimated meals are excluded, because they are excluded
//  everywhere else — an estimate that has not been confirmed must not quietly
//  become part of a total the user is deciding against.
//

import SwiftUI

/// What Home needs to know about today's nutrition. Pure presentation.
struct HomeNutritionSummary: Equatable {
    /// Confirmed intake so far. `nil` when nothing has been recorded.
    let consumedKcal: Int?
    /// The day's intake target. `nil` when the profile has not been set up.
    let targetKcal: Int?
    let proteinGrams: Int
    let proteinTargetGrams: Int

    /// What is left of the target. `nil` when either side is unknown, and
    /// never negative-by-omission: going over is a real answer and is shown.
    var remainingKcal: Int? {
        guard let targetKcal else { return nil }
        return targetKcal - (consumedKcal ?? 0)
    }
}

struct TodayNutritionCard: View {
    let summary: HomeNutritionSummary
    /// Opens the Nutrition tab. Owned by `ContentView` so Home moves to the
    /// existing tab rather than pushing a second copy of the same screen.
    let onRecordMeal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            intakeLine
            remainingLine
            proteinLine

            Button(action: onRecordMeal) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text("食事を記録")
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(AppTheme.accent)
                .padding(.vertical, 13)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.accent.opacity(0.14))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("食事を記録")
        }
        .padding(16)
        .pulseCard()
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "fork.knife")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            Text("今日の栄養")
                .font(.headline)
            Spacer(minLength: 0)
        }
    }

    private var intakeLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(summary.consumedKcal.map(Self.format) ?? "0")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(summary.targetKcal.map { "/ \(Self.format($0)) kcal" } ?? "kcal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        // Read as a sentence, not as two loose numbers.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(intakeAccessibilityLabel)
        // Large accessibility sizes need the room; nothing here is truncated.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var remainingLine: some View {
        if let remaining = summary.remainingKcal {
            let isOver = remaining < 0
            Text(
                isOver
                    ? "目標より \(Self.format(abs(remaining))) kcal 超過"
                    : "残り \(Self.format(remaining)) kcal"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isOver ? AppTheme.warning : AppTheme.accent)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            // No target configured. Saying "残り —" would imply a number
            // exists; this says what is actually missing.
            Text("目標カロリーは未設定です")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var proteinLine: some View {
        HStack(spacing: 6) {
            Text("たんぱく質")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("\(summary.proteinGrams) / \(summary.proteinTargetGrams) g")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "たんぱく質 \(summary.proteinGrams) グラム、目標 \(summary.proteinTargetGrams) グラム"
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var intakeAccessibilityLabel: String {
        let consumed = summary.consumedKcal ?? 0
        guard let target = summary.targetKcal else {
            return "摂取 \(consumed) キロカロリー"
        }
        return "摂取 \(consumed) キロカロリー、目標 \(target) キロカロリー"
    }

    private static func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
