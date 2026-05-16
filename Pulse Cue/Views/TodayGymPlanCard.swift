//
//  TodayGymPlanCard.swift
//  Pulse Cue
//
//  Today-tab quick access for gym-based workout generation. Surfaces
//  the existing My Gym flow at the right entry point without making
//  the user walk through Settings →「マイジム」first. Branches over
//  four states based on what data is already saved:
//
//    1. No gym registered          → register a gym
//    2. Gym(s) exist, none active  → pick the active gym
//    3. Active gym + machines saved → straight to body-part selection
//    4. Active gym, no machines    → prepare machine info (fallback)
//
//  Reuses `MyGymStyle` for the visual treatment so the card is
//  consistent with the rest of the My Gym surface. No new model,
//  schema, repository, generator, or networking — pure navigation.
//

import SwiftUI
import SwiftData

struct TodayGymPlanCard: View {

    @Environment(\.modelContext) private var modelContext

    /// All gyms; we derive "active" + "first registered" from this
    /// single `@Query` so the card reactively updates whenever the
    /// user changes their setup elsewhere in the app.
    @Query(sort: [SortDescriptor(\Gym.updatedAt, order: .reverse)])
    private var gyms: [Gym]

    /// Machine rows for the active gym, fetched in a single `@Query`.
    /// This is a non-trivial relationship: SwiftData filters need a
    /// concrete value, so we fetch all machines and group in Swift.
    /// Volumes are tiny (catalog max ~16 per gym), so the constant
    /// factor is fine.
    @Query private var machines: [GymMachine]

    @State private var showRegistrationSheet = false

    private var activeGym: Gym? { gyms.first(where: \.isActive) }

    private func machineCount(for gym: Gym) -> Int {
        machines.filter { $0.gymId == gym.id }.count
    }

    var body: some View {
        cardContent
            .myGymCard()
            .sheet(isPresented: $showRegistrationSheet) {
                NavigationStack {
                    GymCandidateSearchView { _ in
                        showRegistrationSheet = false
                    }
                }
            }
    }

    // MARK: - Card body

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch state {
            case .noGym:
                noGymContent
            case .noActiveGym:
                noActiveGymContent
            case .activeWithMachines(let gym, let count):
                activeWithMachinesContent(gym: gym, count: count)
            case .activeWithoutMachines(let gym):
                activeWithoutMachinesContent(gym: gym)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(MyGymStyle.accentGradient)
            Text("ジムからメニュー作成")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    // MARK: - State variants

    private var noGymContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ジムを登録すると、設備に合わせたメニューを作成できます")
                .font(.body)
                .foregroundStyle(.primary)
            Button {
                showRegistrationSheet = true
            } label: {
                Label("ジムを登録する", systemImage: "plus.circle.fill")
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
        }
    }

    private var noActiveGymContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今日使うジムを選択してください")
                .font(.body)
                .foregroundStyle(.primary)
            NavigationLink {
                MyGymHomeView()
            } label: {
                Label("ジムを選ぶ", systemImage: "building.2.fill")
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
        }
    }

    private func activeWithMachinesContent(gym: Gym, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            gymSummaryRow(gym: gym, count: count)
            NavigationLink {
                TargetBodyPartSelectionView(gym: gym)
            } label: {
                Label("部位を選んで作成", systemImage: "target")
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
        }
    }

    private func activeWithoutMachinesContent(gym: Gym) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(gym.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text("このジムのマシン情報がまだありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if gym.officialUrl != nil && !(gym.officialUrl?.isEmpty ?? true) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text("公式URLからの自動取り込みは今後対応予定です。")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            NavigationLink {
                MyGymHomeView()
            } label: {
                Label("マシン情報を準備する", systemImage: "wrench.adjustable.fill")
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
        }
    }

    // MARK: - Summary row

    private func gymSummaryRow(gym: Gym, count: Int) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MyGymStyle.accentGradient.opacity(0.18))
                Image(systemName: "building.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MyGymStyle.accentSolid)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(gym.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(count) 台のマシンを使ってメニューを組みます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - State derivation

    private enum CardState {
        case noGym
        case noActiveGym
        case activeWithMachines(Gym, count: Int)
        case activeWithoutMachines(Gym)
    }

    private var state: CardState {
        if gyms.isEmpty { return .noGym }
        guard let active = activeGym else { return .noActiveGym }
        let count = machineCount(for: active)
        return count > 0
            ? .activeWithMachines(active, count: count)
            : .activeWithoutMachines(active)
    }
}

// SwiftData opacity workaround: `MyGymStyle.accentGradient` is a
// `LinearGradient`; `.opacity` on a gradient returns the gradient
// modified by alpha. Helper here so call sites read cleanly.
private extension LinearGradient {
    func opacity(_ alpha: Double) -> some ShapeStyle {
        AnyShapeStyle(self).opacity(alpha)
    }
}
