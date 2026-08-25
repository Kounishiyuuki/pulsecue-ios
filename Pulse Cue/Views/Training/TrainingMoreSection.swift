//
//  TrainingMoreSection.swift
//  Pulse Cue
//
//  The training features you reach for occasionally.
//
//  All of these lived under マイページ → 設定, which filed registering a gym
//  and browsing form guides as app *configuration*. They are neither settings
//  nor daily actions: you set a gym up once, look at a form guide when an
//  exercise is unfamiliar, and check progress every few weeks. That is a third
//  frequency, and it deserves a place of its own inside the module it serves
//  rather than a place inside a screen about notifications and account.
//
//  Every destination is the existing one, unchanged. This is where they are
//  listed, not what they do.
//
//  Deliberately plain rows: they must be findable without competing with
//  today's action two sections above. Anything here that grew a filled button
//  would be back at the top of the visual hierarchy.
//

import SwiftUI

struct TrainingMoreSection: View {
    var body: some View {
        VStack(spacing: 10) {
            row(
                title: "マイジム",
                subtitle: "ジムと使えるマシンを管理",
                icon: "building.2"
            ) { MyGymHomeView() }

            row(
                title: "種目ライブラリ",
                subtitle: "種目を探してフォームガイドを見る",
                icon: "book.pages"
            ) { ExerciseLibraryView() }

            row(
                title: "進捗",
                subtitle: "重量とボリュームの推移",
                icon: "chart.line.uptrend.xyaxis"
            ) { WorkoutProgressView() }

            row(
                title: "週間プラン",
                subtitle: "1週間のトレーニング候補を確認",
                icon: "calendar"
            ) { WeeklyTrainingPlanCandidateReviewView() }

            row(
                title: "AI プラン相談",
                subtitle: "目的に合わせたメニューを相談",
                icon: "sparkles"
            ) { MockAITrainingPlanChatView() }
        }
    }

    private func row<Destination: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.cardBackground.opacity(0.5))
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        // One element naming the destination; the description is a hint, not
        // a second thing to read out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(.isButton)
    }
}
