//
//  WorkoutView.swift
//  Pulse Cue
//
//  Routine selection surface with separate detail, edit, and start paths.
//

import SwiftUI
import SwiftData

struct WorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject var runnerViewModel: RunnerViewModel

    @Query(sort: [SortDescriptor(\Routine.updatedAt, order: .reverse)]) private var routines: [Routine]
    @Query private var allSteps: [Step]

    @State private var searchText = ""
    @State private var editorRoutine: Routine?
    @State private var routinePendingStartAfterEditorDismissal: Routine?
    @State private var routinePendingDeletion: Routine?
    @State private var orderStore = RoutineOrderStore()
    @State private var restStore = RoutineRestPreferenceStore()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.deepSpace.opacity(0.95), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 14) {
                    titleBlock
                    searchBar
                    routineContent
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                createButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .navigationTitle("ルーティンを選択")
        .navigationBarTitleDisplayMode(.inline)
        // History lives under Training rather than in the tab bar. Past
        // workouts are something you look at while deciding what to do next,
        // so it belongs beside routine selection — and a toolbar item keeps it
        // one tap away without changing the surface below it.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    HistoryView()
                } label: {
                    Label("履歴", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityLabel("履歴")
            }
        }
        .sheet(item: $editorRoutine, onDismiss: startPendingRoutine) { routine in
            NavigationStack {
                RoutineEditorView(routine: routine, onStart: requestStartFromEditor)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { editorRoutine = nil }
                        }
                    }
            }
        }
        .alert(
            "ルーティンを削除しますか？",
            isPresented: Binding(
                get: { routinePendingDeletion != nil },
                set: { if !$0 { routinePendingDeletion = nil } }
            ),
            presenting: routinePendingDeletion
        ) { routine in
            Button("削除", role: .destructive) { deleteRoutine(routine) }
            Button("キャンセル", role: .cancel) {}
        } message: { routine in
            Text("「\(routine.name)」と種目内容を削除します。この操作は取り消せません。")
        }
        .preferredColorScheme(.dark)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日のルーティン")
                    .font(.system(.largeTitle, design: .rounded, weight: .black))
                Spacer()
                if !savedRoutines.isEmpty {
                    Text("\(filteredRoutines.count)件")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(AppTheme.accent.opacity(0.12)))
                }
            }
            Text("そのまま開始するか、カードを開いて内容を調整できます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("ルーティン名を検索", text: $searchText)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索をクリア")
            }
        }
        .padding(.leading, 14)
        .frame(minHeight: 50)
        .background(PulseGlassPlate(level: .functional, cornerRadius: 18))
    }

    @ViewBuilder
    private var routineContent: some View {
        if savedRoutines.isEmpty {
            stateCard(
                icon: "figure.strengthtraining.traditional",
                title: "最初のルーティンを作成",
                message: "種目、セット、回数、休憩をまとめて、すぐ始められる準備をしましょう。",
                actionTitle: "ルーティンを作成",
                action: createRoutine
            )
        } else if filteredRoutines.isEmpty {
            stateCard(
                icon: "magnifyingglass",
                title: "一致するルーティンがありません",
                message: "検索語を変えるか、検索をクリアしてください。",
                actionTitle: "検索をクリア",
                action: { searchText = "" }
            )
        } else {
            if !pinnedRoutines.isEmpty {
                sectionHeader("ピン留め", icon: "pin.fill", count: pinnedRoutines.count)
                ForEach(pinnedRoutines) { routine in routineCard(routine) }
            }
            if !regularRoutines.isEmpty {
                sectionHeader(pinnedRoutines.isEmpty ? "ルーティン" : "その他", icon: "list.bullet.rectangle", count: regularRoutines.count)
                ForEach(regularRoutines) { routine in routineCard(routine) }
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(AppTheme.accent)
            Text(title).font(.headline.weight(.bold))
            Spacer()
            Text("\(count)件").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func routineCard(_ routine: Routine) -> some View {
        let steps = stepsByRoutine[routine.id] ?? []
        return VStack(alignment: .leading, spacing: 14) {
            NavigationLink {
                RoutineEditorView(routine: routine, onStart: startRoutine)
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(routine.name)
                                .font(.title3.weight(.bold))
                                .multilineTextAlignment(.leading)
                            Text("内容を確認・編集")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                        Spacer(minLength: 8)
                        if routine.isPinned {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 30, height: 30)
                        }
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .frame(width: 24, height: 30)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { cardMetadata(routine: routine, steps: steps) }
                        VStack(alignment: .leading, spacing: 8) { cardMetadata(routine: routine, steps: steps) }
                    }
                    tagRow(for: steps)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().overlay(Color.white.opacity(0.08))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { cardActions(routine, hasSteps: !steps.isEmpty) }
                VStack(spacing: 10) { cardActions(routine, hasSteps: !steps.isEmpty) }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.surfaceCard.opacity(0.96))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(routine.isPinned ? AppTheme.accent.opacity(0.28) : Color.white.opacity(0.06), lineWidth: 1)
                }
        )
    }

    @ViewBuilder
    private func cardMetadata(routine: Routine, steps: [Step]) -> some View {
        metadata(icon: "dumbbell.fill", text: "\(steps.count)種目")
        metadata(icon: "clock.fill", text: estimatedDuration(steps))
        metadata(icon: "arrow.triangle.2.circlepath", text: "更新 \(DateUtils.formatDate(routine.updatedAt))")
    }

    @ViewBuilder
    private func cardActions(_ routine: Routine, hasSteps: Bool) -> some View {
        Button { startRoutine(routine) } label: {
            Label("このまま開始", systemImage: "play.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 14).fill(AppTheme.accentFilled.opacity(hasSteps ? 1 : 0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!hasSteps)

        Menu {
            Button { editorRoutine = routine } label: { Label("編集", systemImage: "pencil") }
            Button { duplicateRoutine(routine) } label: { Label("複製", systemImage: "doc.on.doc") }
            Button { togglePinned(routine) } label: {
                Label(routine.isPinned ? "ピン留めを解除" : "ピン留め", systemImage: routine.isPinned ? "pin.slash" : "pin")
            }
            Button { moveRoutine(routine, direction: -1) } label: {
                Label("上へ移動", systemImage: "arrow.up")
            }
            .disabled(!canMove(routine, direction: -1))
            Button { moveRoutine(routine, direction: 1) } label: {
                Label("下へ移動", systemImage: "arrow.down")
            }
            .disabled(!canMove(routine, direction: 1))
            Divider()
            Button(role: .destructive) { routinePendingDeletion = routine } label: { Label("削除", systemImage: "trash") }
        } label: {
            Label("その他", systemImage: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 92, minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private func metadata(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func tagRow(for steps: [Step]) -> some View {
        let tags = bodyPartTags(for: steps)
        if !tags.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    ForEach(tags, id: \.self) { tag in tagChip(tag) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tags, id: \.self) { tag in tagChip(tag) }
                }
            }
        }
    }

    private func tagChip(_ tag: String) -> some View {
        Text(tag)
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(AppTheme.accent.opacity(0.11)))
    }

    private func stateCard(icon: String, title: String, message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(AppTheme.accent)
            Text(title).font(.headline.weight(.bold))
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: action) {
                Text(actionTitle).font(.subheadline.weight(.bold)).frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accentFilled)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 20).fill(AppTheme.surfaceCard))
    }

    private var createButton: some View {
        Button(action: createRoutine) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "plus")
                        .frame(width: 54)
                } else {
                    Label("新規作成", systemImage: "plus")
                        .padding(.horizontal, 18)
                }
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .frame(minHeight: 54)
            .background {
                ZStack {
                    PulseGlassPlate(level: .functional, focused: true, cornerRadius: 27)
                    Capsule().fill(AppTheme.accentFilled.opacity(0.82))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新しいルーティンを作成")
    }

    /// The routine library: only routines the user explicitly saved.
    /// Workout-generated routines (Quick Plan "この内容で開始") stay out of the
    /// list while remaining valid Runner / History targets.
    private var savedRoutines: [Routine] { routines.filter { $0.origin == .userSaved } }

    private var filteredRoutines: [Routine] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return savedRoutines }
        return savedRoutines.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var pinnedRoutines: [Routine] { orderStore.ordered(routines: filteredRoutines.filter(\.isPinned), pinned: true) }
    private var regularRoutines: [Routine] { orderStore.ordered(routines: filteredRoutines.filter { !$0.isPinned }, pinned: false) }
    private var stepsByRoutine: [UUID: [Step]] { Dictionary(grouping: allSteps, by: \.routineId) }

    private func bodyPartTags(for steps: [Step]) -> [String] {
        var seen = Set<BodyPart>()
        var result: [String] = []
        for step in steps {
            guard let exercise = step.resolvedExercise else { continue }
            for part in exercise.bodyParts where seen.insert(part).inserted {
                result.append(part.displayName)
                if result.count == 3 { return result }
            }
        }
        return result
    }

    private func estimatedDuration(_ steps: [Step]) -> String {
        WorkoutDurationEstimator.approximateText(forSteps: steps)
    }

    private func startRoutine(_ routine: Routine) {
        // Shared with Quick Plan via `WorkoutStarter` so there is one start
        // path (same 3-layer rest handling, same Runner init).
        WorkoutStarter.start(
            routine: routine,
            steps: stepsByRoutine[routine.id] ?? [],
            modelContext: modelContext,
            restStore: restStore,
            appDefaultRestSeconds: settings.defaultRestSeconds,
            runner: runnerViewModel
        )
    }

    private func requestStartFromEditor(_ routine: Routine) {
        routinePendingStartAfterEditorDismissal = routine
        editorRoutine = nil
    }

    private func startPendingRoutine() {
        guard let routine = routinePendingStartAfterEditorDismissal else { return }
        routinePendingStartAfterEditorDismissal = nil
        startRoutine(routine)
    }

    private func createRoutine() {
        let routine = Routine(name: "新しいルーティン")
        modelContext.insert(routine)
        editorRoutine = routine
    }

    private func togglePinned(_ routine: Routine) {
        routine.isPinned.toggle()
        routine.updatedAt = Date()
        orderStore.setPinned(routine.id, pinned: routine.isPinned)
        try? modelContext.save()
    }

    private func duplicateRoutine(_ routine: Routine) {
        let sourceSteps = (stepsByRoutine[routine.id] ?? []).sorted(by: { $0.order < $1.order })
        prepareRestPreferences(for: routine, steps: sourceSteps)
        let copy = Routine(name: routine.name + "（コピー）", isPinned: routine.isPinned)
        modelContext.insert(copy)
        var mapping: [UUID: UUID] = [:]
        for step in sourceSteps {
            let newStep = step.duplicated(routineId: copy.id, order: step.order)
            mapping[step.id] = newStep.id
            modelContext.insert(newStep)
        }
        restStore.copyMetadata(from: routine.id, to: copy.id, stepIDMapping: mapping)
        orderStore.setPinned(copy.id, pinned: copy.isPinned)
        try? modelContext.save()
    }

    private func prepareRestPreferences(for routine: Routine, steps: [Step]) {
        restStore.prepareRoutine(
            routine.id,
            existingStepRests: steps.sorted { $0.order < $1.order }.map { (id: $0.id, seconds: $0.restSeconds) },
            appDefault: settings.defaultRestSeconds
        )
    }

    private func orderedGroup(for routine: Routine) -> [Routine] {
        orderStore.ordered(routines: savedRoutines.filter { $0.isPinned == routine.isPinned }, pinned: routine.isPinned)
    }

    private func canMove(_ routine: Routine, direction: Int) -> Bool {
        let group = orderedGroup(for: routine)
        guard let index = group.firstIndex(where: { $0.id == routine.id }) else { return false }
        return group.indices.contains(index + direction)
    }

    private func moveRoutine(_ routine: Routine, direction: Int) {
        let group = orderedGroup(for: routine)
        guard let index = group.firstIndex(where: { $0.id == routine.id }), canMove(routine, direction: direction) else { return }
        let destination = direction < 0 ? index - 1 : index + 2
        orderStore.move(routines: group, fromOffsets: IndexSet(integer: index), toOffset: destination, pinned: routine.isPinned)
    }

    private func deleteRoutine(_ routine: Routine) {
        let steps = stepsByRoutine[routine.id] ?? []
        restStore.removeMetadata(forRoutine: routine.id, stepIDs: steps.map(\.id))
        steps.forEach { modelContext.delete($0) }
        modelContext.delete(routine)
        routinePendingDeletion = nil
        try? modelContext.save()
    }
}
