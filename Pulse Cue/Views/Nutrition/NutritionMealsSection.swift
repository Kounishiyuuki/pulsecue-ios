//
//  NutritionMealsSection.swift
//  Pulse Cue
//
//  今日の食事 — the day's meal rows.
//
//  Presentation only. It is handed the day's meals already partitioned and
//  reports taps back; it does not fetch, does not decide which meals belong to
//  today, and does not write. That split matters here more than most places:
//  the rules about which meals count and who owns the day's intake live in
//  `DailyNutritionSummary` and `NutritionLedger`, and a list view that started
//  filtering by status for itself is exactly how a screen ends up disagreeing
//  with its own total.
//
//  Note what is *not* filtered here: pending manual drafts are shown alongside
//  confirmed meals, because the user needs to see the draft they left behind.
//  They still contribute nothing to consumed calories — that is the summary
//  card's business, and the 「確認待ち」 badge is what says so on this row.
//

import SwiftUI

struct NutritionMealsSection: View {
    let confirmedMeals: [MealEntry]
    let pendingManualMeals: [MealEntry]
    let proteinGradient: LinearGradient

    let onAdd: (MealSlot) -> Void
    let onEdit: (MealEntry) -> Void
    let onDelete: (MealEntry) -> Void
    let onSaveAsFavorite: (MealEntry) -> Void
    /// Whether the pin action is offered at all. False for AI-sourced or
    /// unconfirmed meals, and for ones already pinned — the owner knows the
    /// template store, this only draws the menu item.
    let canSaveAsFavorite: (MealEntry) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PulseSectionHeader("今日の食事")
                .padding(.top, 4)

            ForEach(MealSlot.allCases) { slot in
                let confirmedForSlot = confirmedMeals.filter { $0.slot == slot }
                let pendingManualForSlot = pendingManualMeals.filter { $0.slot == slot }
                if confirmedForSlot.isEmpty && pendingManualForSlot.isEmpty {
                    emptySlotRow(slot)
                } else {
                    ForEach(confirmedForSlot, id: \.id) { meal in
                        mealLogCard(meal)
                    }
                    ForEach(pendingManualForSlot, id: \.id) { meal in
                        mealLogCard(meal)
                    }
                }
            }
        }
    }

    /// One line per empty slot. Same destination as the full-size card it
    /// replaced: on a day with nothing logged, four large identical
    /// invitations filled the screen with one offer repeated.
    private func emptySlotRow(_ slot: MealSlot) -> some View {
        Button {
            onAdd(slot)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                Text(slot.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.cardBackground.opacity(0.45))
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(slot.label)を記録")
    }

    private func mealLogCard(_ meal: MealEntry) -> some View {
        Button {
            onEdit(meal)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                slotThumb(meal.slot)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(meal.slot.enLabel)
                            .font(.caption2.weight(.bold))
                            .tracking(1.0)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        statusBadge(meal.status)
                    }
                    Text(meal.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text("\(NumberFormat.int(meal.kcal)) kcal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                        if let protein = meal.proteinGrams, protein > 0 {
                            proteinChip(grams: protein)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frostedCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(meal))
        .contextMenu {
            if canSaveAsFavorite(meal) {
                Button {
                    onSaveAsFavorite(meal)
                } label: {
                    Label("よく使う食事に保存", systemImage: "star")
                }
            }
            Button("削除", role: .destructive) {
                onDelete(meal)
            }
        }
    }

    private func proteinChip(grams: Int) -> some View {
        HStack(spacing: 2) {
            Text("P")
                .font(.caption2.weight(.bold))
            Text("\(grams)g")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(proteinGradient)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color.primary.opacity(0.05))
        )
    }

    private func accessibilityLabel(_ meal: MealEntry) -> String {
        var parts = ["\(meal.slot.label) \(meal.name) \(meal.kcal) kcal"]
        if let protein = meal.proteinGrams, protein > 0 {
            parts.append("タンパク質 \(protein) g")
        }
        parts.append(meal.status.label)
        return parts.joined(separator: " ")
    }

    private func slotThumb(_ slot: MealSlot) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.accent.opacity(0.15))
                .frame(width: 48, height: 48)
            Image(systemName: slot.systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.accent)
        }
    }

    private func statusBadge(_ status: MealStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(status.label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(status == .confirmed ? Color.green : Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((status == .confirmed ? Color.green : Color.orange).opacity(0.12))
        )
    }
}
