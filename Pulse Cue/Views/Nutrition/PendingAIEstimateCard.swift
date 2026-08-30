//
//  PendingAIEstimateCard.swift
//  Pulse Cue
//
//  One pending AI estimate, awaiting the user's decision.
//
//  The card exists because an estimate is not a record. Everything about it
//  says so — the 「~」 before the figure, the 推定 badge, the fact that 確定 is
//  a deliberate second action — and none of that is decoration: until the user
//  confirms, this meal contributes nothing to the day's consumed calories.
//  `DailyNutritionSummary` enforces that; this card is where the user is told.
//
//  Confirming does not happen here. The owner runs it through
//  `applyConfirmedMealEstimate` / `NutritionLedger`, which is the only path by
//  which an AI-sourced figure may reach `DayLog` — see
//  `Docs/ai-privacy-and-safety.md`. A card that wrote for itself would be a
//  second such path.
//

import SwiftUI

struct PendingAIEstimateCard: View {
    let meal: MealEntry
    /// The day's macro targets, so the bars read against the same figures the
    /// summary card above uses.
    let targets: MacroTargets.Daily
    let proteinGradient: LinearGradient
    let carbGradient: LinearGradient
    let fatGradient: LinearGradient

    let onEdit: () -> Void
    let onConfirm: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroFoodImage(slot: meal.slot)

            VStack(alignment: .leading, spacing: 6) {
                Text(meal.slot.enLabel)
                    .font(.caption2.weight(.bold))
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
                Text(meal.name)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("~ \(NumberFormat.int(meal.kcal))")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                    Text("kcal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    estimateBadge
                }
            }

            VStack(spacing: 8) {
                macroRow(label: "PRO", value: meal.proteinGrams ?? 0,
                         target: targets.proteinGrams, gradient: proteinGradient)
                macroRow(label: "CARB", value: meal.carbGrams ?? 0,
                         target: targets.carbGrams, gradient: carbGradient)
                macroRow(label: "FAT", value: meal.fatGrams ?? 0,
                         target: targets.fatGrams, gradient: fatGradient)
            }

            HStack(spacing: 10) {
                Button(action: onEdit) {
                    Label("編集", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 0.6)
                )
                .accessibilityLabel("AI 推定を編集")

                Button(action: onConfirm) {
                    Label("確定", systemImage: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.accentFilled)
                        .shadow(
                            color: Color(red: 0.27, green: 0.5, blue: 0.95).opacity(0.4),
                            radius: 12, y: 6
                        )
                )
                .accessibilityLabel("AI 推定を確定")
            }
            .padding(.top, 4)

            Button(action: onDiscard) {
                Text("この推定を破棄")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("この AI 推定を破棄")
        }
        .padding(20)
        .frostedCard()
        .overlay(
            RoundedRectangle(cornerRadius: FrostedCardSurface.cornerRadius, style: .continuous)
                .strokeBorder(AppTheme.accent.opacity(0.35), lineWidth: 1.2)
        )
    }

    private func heroFoodImage(slot: MealSlot) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        Color(red: 0.95, green: 0.92, blue: 0.84),
                        Color(red: 0.86, green: 0.82, blue: 0.74)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Image(systemName: foodSymbol(for: slot))
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(
                    LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.5), lineWidth: 0.6)
        )
        .accessibilityHidden(true)
    }

    private func foodSymbol(for slot: MealSlot) -> String {
        switch slot {
        case .breakfast: return "fork.knife"
        case .lunch: return "fork.knife.circle"
        case .dinner: return "takeoutbag.and.cup.and.straw.fill"
        case .snack: return "cup.and.saucer.fill"
        }
    }

    private var estimateBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
            Text("推定")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(AppTheme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(.regularMaterial)
        )
        .overlay(
            Capsule().strokeBorder(AppTheme.accent.opacity(0.5), lineWidth: 0.6)
        )
    }

    private func macroRow(
        label: String,
        value: Int,
        target: Int,
        gradient: LinearGradient
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            ProgressBar(progress: Double(value) / Double(max(1, target)), gradient: gradient)
                .frame(height: 6)
            Text("\(value)g")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
