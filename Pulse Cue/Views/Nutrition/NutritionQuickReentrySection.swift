//
//  NutritionQuickReentrySection.swift
//  Pulse Cue
//
//  最近の食事 / よく使う食事 — one tap to log something eaten before.
//
//  Two cards rather than one, deliberately. 「最近」 is what happened to be
//  eaten and 「よく使う」 is what the user chose to pin; merging them would
//  mean a meal eaten once yesterday sitting among the ones deliberately kept,
//  and the list would slowly stop being trustworthy as a shortcut.
//
//  Both hide themselves when empty. A permanent empty placeholder on a screen
//  whose whole point was fewer standing invitations would undo that.
//
//  Adding is not done here — the owner inserts the row and runs the ledger, so
//  every path that creates a meal goes through the same one.
//

import SwiftUI

struct NutritionQuickReentrySection: View {
    let suggestions: [RecentMealSuggestions.Suggestion]
    let templates: [FavoriteMealTemplate]
    let proteinGradient: LinearGradient

    let onAddSuggestion: (RecentMealSuggestions.Suggestion) -> Void
    let onAddTemplate: (FavoriteMealTemplate) -> Void
    let onRemoveTemplate: (FavoriteMealTemplate) -> Void

    /// Nothing at all when there is neither history nor a pinned template —
    /// not an empty container. An empty `VStack` is still a child, and the
    /// parent would keep spacing around it, leaving a gap on exactly the
    /// screens that have least to show.
    @ViewBuilder
    var body: some View {
        if !suggestions.isEmpty || !templates.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                if !suggestions.isEmpty {
                    card(title: "最近の食事", icon: "clock.arrow.circlepath") {
                        ForEach(suggestions) { suggestion in
                            chip(
                                slotLabel: suggestion.slot.label,
                                slotIcon: suggestion.slot.systemImage,
                                name: suggestion.name,
                                kcal: suggestion.kcal,
                                proteinGrams: nil,
                                accessibilityLabel: "最近の食事 \(suggestion.name) \(suggestion.kcal) kcal、タップで今日に追加",
                                action: { onAddSuggestion(suggestion) }
                            )
                        }
                    }
                }

                if !templates.isEmpty {
                    card(title: "よく使う食事", icon: "star.fill") {
                        ForEach(templates) { template in
                            chip(
                                slotLabel: template.slot.label,
                                slotIcon: "star.fill",
                                name: template.name,
                                kcal: template.kcal,
                                proteinGrams: template.proteinGrams,
                                accessibilityLabel: "よく使う食事 \(template.name) \(template.kcal) kcal、タップで今日に追加",
                                action: { onAddTemplate(template) }
                            )
                            .contextMenu {
                                Button("削除", role: .destructive) {
                                    onRemoveTemplate(template)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func card<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .labelStyle(.titleAndIcon)
                Spacer()
                Text("タップで今日に追加")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    content()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .frostedCard()
    }

    private func chip(
        slotLabel: String,
        slotIcon: String,
        name: String,
        kcal: Int,
        proteinGrams: Int?,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: slotIcon)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                    Text(slotLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(NumberFormat.int(kcal))")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                    Text("kcal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let proteinGrams, proteinGrams > 0 {
                        Spacer(minLength: 4)
                        Text("P \(proteinGrams)g")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(proteinGradient)
                    }
                }
            }
            .padding(12)
            .frame(width: 150, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppTheme.accent.opacity(0.25), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
