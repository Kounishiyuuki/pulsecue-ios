//
//  TrainingMoreSection.swift
//  Pulse Cue
//
//  The training features you reach for occasionally.
//
//  Setting a gym up happens once, a form guide gets opened when an exercise is
//  unfamiliar, and progress gets checked every few weeks. That is a third
//  frequency — neither a setting nor a daily action — and it deserves a place
//  inside the module it serves rather than one inside a screen about
//  notifications and the account.
//
//  Which destinations belong here is not decided in this file. The list comes
//  from `TrainingSurface.moreDestinations`, so promoting something out of
//  「その他」 is a change to the ranking rather than a card someone moves.
//  This file decides only what each row says and where it goes.
//
//  Deliberately plain rows: they must be findable without competing with
//  today's action two sections above. Anything here that grew a filled button
//  would be back at the top of the visual hierarchy.
//

import SwiftUI

struct TrainingMoreSection: View {
    var body: some View {
        VStack(spacing: 10) {
            ForEach(TrainingSurface.moreDestinations, id: \.self) { destination in
                row(for: destination)
            }
        }
    }

    /// One row per ranked destination. The `switch` is exhaustive, so a
    /// destination added to `TrainingSurface` cannot reach `.more` without
    /// someone deciding what its row says and where it goes.
    @ViewBuilder
    private func row(for destination: TrainingSurface.Destination) -> some View {
        switch destination {
        case .gym:
            row(
                title: "マイジム",
                subtitle: "ジムと使えるマシンを管理",
                icon: "building.2"
            ) { MyGymHomeView() }

        // Two different things, deliberately listed separately: the library is
        // exercises and their form guides, the catalogue is the machines
        // themselves. The Settings card that held both under one 「ライブラリ」
        // heading is what made it easy to carry one over and lose the other.
        case .exerciseLibrary:
            row(
                title: "種目ライブラリ",
                subtitle: "種目を探してフォームガイドを見る",
                icon: "book.pages"
            ) { ExerciseLibraryView() }

        case .machineCatalog:
            row(
                title: "マシンカタログ",
                subtitle: "ローカル一覧から検索・部位で絞り込み",
                icon: "square.grid.2x2"
            ) { MachineCatalogListView() }

        case .progress:
            row(
                title: "進捗",
                subtitle: "重量とボリュームの推移",
                icon: "chart.line.uptrend.xyaxis"
            ) { WorkoutProgressView() }

        case .weeklyPlan:
            row(
                title: "週間プラン",
                subtitle: "1週間のトレーニング候補を確認",
                icon: "calendar"
            ) { WeeklyTrainingPlanCandidateReviewView() }

        case .aiPlanning:
            row(
                title: "AI プラン相談",
                subtitle: "目的に合わせたメニューを相談",
                icon: "sparkles"
            ) { MockAITrainingPlanChatView() }

        // Not listed here: these are the screen itself, not entries on it.
        case .today, .plan, .history:
            EmptyView()
        }
    }

    private func row<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder destination: @escaping () -> Content
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
