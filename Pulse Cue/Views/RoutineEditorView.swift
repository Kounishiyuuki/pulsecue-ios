//
//  RoutineEditorView.swift
//  Pulse Cue
//
//  Start-ready routine detail and editor.
//

import SwiftUI
import SwiftData

struct RoutineEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @Bindable var routine: Routine
    @Query private var steps: [Step]

    private let onStart: ((Routine) -> Void)?
    @State private var restStore = RoutineRestPreferenceStore()
    @State private var editMode: EditMode = .inactive

    init(routine: Routine, onStart: ((Routine) -> Void)? = nil) {
        self._routine = Bindable(wrappedValue: routine)
        self.onStart = onStart
        let routineId = routine.id
        self._steps = Query(
            filter: #Predicate<Step> { $0.routineId == routineId },
            sort: [SortDescriptor(\Step.order, order: .forward)]
        )
    }

    var body: some View {
        ZStack {
            PulseAtmosphericBackground().ignoresSafeArea()
            List {
                overviewSection
                restSection
                exercisesSection
            }
            .environment(\.editMode, $editMode)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("ルーティン詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "完了" : "並び替え") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let onStart {
                startBar(onStart: onStart)
            }
        }
        .onAppear(perform: materializeEffectiveRest)
        .onChange(of: settings.defaultRestSeconds) { _, _ in
            materializeEffectiveRest()
        }
        .onDisappear(perform: commitName)
    }

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("ルーティン名")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("ルーティン名を入力", text: $routine.name)
                    .font(.title3.weight(.bold))
                    .textInputAutocapitalization(.sentences)
                    .onChange(of: routine.name) { _, _ in markRoutineUpdated() }
            }
            .padding(.vertical, 6)
            .listRowBackground(rowBackground)
        } header: {
            PulseSectionHeader("基本情報", icon: "list.bullet.rectangle")
        } footer: {
            Text("カードから直接開始することも、この画面で内容を調整してから開始することもできます。")
        }
    }

    private var restSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("標準の休憩", systemImage: "timer")
                        .font(.headline)
                    Spacer()
                    Text(restText(routineDefaultRest))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(AppTheme.accent)
                }
                Stepper(value: routineRestBinding, in: 0...600, step: 5) {
                    Text("ルーティン全体に適用")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("ルーティン標準休憩")
                .accessibilityValue(restText(routineDefaultRest))

                Button {
                    useAppDefaultRest()
                } label: {
                    Label("アプリ標準を使用（\(restText(settings.defaultRestSeconds))）", systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.accent)
            }
            .padding(.vertical, 6)
            .listRowBackground(rowBackground)
        } header: {
            PulseSectionHeader("休憩設定", icon: "clock.arrow.circlepath")
        } footer: {
            Text("アプリ初期値は\(restText(settings.defaultRestSeconds))です。種目ごとに個別の休憩へ変更できます。")
        }
    }

    private var exercisesSection: some View {
        Section {
            if steps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "dumbbell")
                        .font(.title2)
                        .foregroundStyle(AppTheme.accent)
                    Text("種目がまだありません")
                        .font(.headline)
                    Text("種目を追加して、セット・回数・休憩を設定してください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .listRowBackground(rowBackground)
            }

            ForEach(steps, id: \.id) { step in
                RoutineStepEditorCard(
                    step: step,
                    routineDefaultRest: routineDefaultRest,
                    overrideRest: restStore.stepOverride(for: step.id),
                    onRestModeChanged: { override in
                        applyRestOverride(override, to: step)
                    },
                    onChanged: markRoutineUpdated
                )
                .listRowBackground(rowBackground)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { deleteStep(step) } label: {
                        Label("削除", systemImage: "trash")
                    }
                    Button { duplicateStep(step) } label: {
                        Label("複製", systemImage: "doc.on.doc")
                    }
                    .tint(.blue)
                }
            }
            .onMove(perform: moveSteps)
            .onDelete(perform: deleteSteps)

            Button(action: addStep) {
                Label("種目を追加", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(AppTheme.accent)
            .listRowBackground(rowBackground)
        } header: {
            PulseSectionHeader("種目と順番", icon: "dumbbell")
        } footer: {
            Text("右上の「並び替え」で順番を変更し、左スワイプで複製・削除できます。")
        }
    }

    private func startBar(onStart: @escaping (Routine) -> Void) -> some View {
        Button {
            prepareRestPreferences()
            materializeEffectiveRest()
            commitName()
            try? modelContext.save()
            onStart(routine)
        } label: {
            Label("この内容で開始", systemImage: "play.fill")
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(.white)
                .background(
                    PulseGlassPlate(level: .functional, focused: true, cornerRadius: 18)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(AppTheme.accentFilled.opacity(steps.isEmpty ? 0.28 : 0.82))
                        }
                )
        }
        .buttonStyle(.plain)
        .disabled(steps.isEmpty)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var rowBackground: Color { AppTheme.surfaceCard }

    private var routineDefaultRest: Int {
        restStore.routineDefault(for: routine.id, appDefault: settings.defaultRestSeconds)
    }

    private var routineRestBinding: Binding<Int> {
        Binding(
            get: { routineDefaultRest },
            set: { newValue in
                let clamped = Step.clampRest(newValue)
                restStore.setRoutineDefault(clamped, for: routine.id)
                for step in steps where restStore.stepOverride(for: step.id) == nil {
                    step.restSeconds = clamped
                }
                markRoutineUpdated()
            }
        )
    }

    private func applyRestOverride(_ override: Int?, to step: Step) {
        if let override {
            let clamped = Step.clampRest(override)
            restStore.setStepOverride(clamped, for: step.id, routineID: routine.id)
            step.restSeconds = clamped
        } else {
            restStore.clearStepOverride(for: step.id)
            step.restSeconds = routineDefaultRest
        }
        markRoutineUpdated()
    }

    private func addStep() {
        let newStep = Step(
            routineId: routine.id,
            order: steps.count,
            title: "新しい種目",
            sets: 3,
            repsTarget: 10,
            restSeconds: routineDefaultRest
        )
        modelContext.insert(newStep)
        markRoutineUpdated()
    }

    private func deleteStep(_ step: Step) {
        restStore.removeMetadata(forSteps: [step.id])
        modelContext.delete(step)
        reindexSteps(excluding: [step.id])
        markRoutineUpdated()
    }

    private func deleteSteps(at offsets: IndexSet) {
        let removed = offsets.map { steps[$0] }
        restStore.removeMetadata(forSteps: removed.map(\.id))
        removed.forEach(modelContext.delete)
        reindexSteps(excluding: Set(removed.map(\.id)))
        markRoutineUpdated()
    }

    private func duplicateStep(_ step: Step) {
        for existing in steps where existing.order > step.order {
            existing.order += 1
        }
        let copy = step.duplicated(routineId: routine.id, order: step.order + 1)
        modelContext.insert(copy)
        if let override = restStore.stepOverride(for: step.id) {
            restStore.setStepOverride(override, for: copy.id, routineID: routine.id)
        }
        markRoutineUpdated()
    }

    private func moveSteps(from source: IndexSet, to destination: Int) {
        var updated = steps
        updated.move(fromOffsets: source, toOffset: destination)
        for (index, step) in updated.enumerated() { step.order = index }
        markRoutineUpdated()
    }

    private func reindexSteps(excluding excludedIDs: Set<UUID> = []) {
        let sorted = steps.filter { !excludedIDs.contains($0.id) }.sorted { $0.order < $1.order }
        for (index, step) in sorted.enumerated() { step.order = index }
    }

    private func commitName() {
        let trimmed = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "無題" : trimmed
        guard routine.name != normalized else { return }
        routine.name = normalized
        markRoutineUpdated()
    }

    private func markRoutineUpdated() {
        routine.updatedAt = Date()
    }

    private func materializeEffectiveRest() {
        prepareRestPreferences()
        let routineRest = routineDefaultRest
        for step in steps {
            step.restSeconds = restStore.stepOverride(for: step.id) ?? routineRest
        }
    }

    private func prepareRestPreferences() {
        restStore.prepareRoutine(
            routine.id,
            existingStepRests: steps.sorted { $0.order < $1.order }.map { (id: $0.id, seconds: $0.restSeconds) },
            appDefault: settings.defaultRestSeconds
        )
    }

    private func useAppDefaultRest() {
        prepareRestPreferences()
        restStore.clearRoutineDefault(for: routine.id)
        for step in steps where restStore.stepOverride(for: step.id) == nil {
            step.restSeconds = settings.defaultRestSeconds
        }
        markRoutineUpdated()
    }

    private func restText(_ seconds: Int) -> String {
        seconds == 0 ? "なし" : "\(seconds)秒"
    }
}

private struct RoutineStepEditorCard: View {
    @Bindable var step: Step
    let routineDefaultRest: Int
    let overrideRest: Int?
    let onRestModeChanged: (Int?) -> Void
    let onChanged: () -> Void

    private var usesIndividualRest: Bool { overrideRest != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField("種目名", text: titleBinding)
                    .font(.headline.weight(.bold))
                if step.isWarmup {
                    Text("準備")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AppTheme.accent.opacity(0.12)))
                }
            }

            Toggle("ウォームアップ種目", isOn: warmupBinding)
                .font(.subheadline.weight(.semibold))
                .tint(AppTheme.accent)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { prescriptionControls }
                VStack(spacing: 10) { prescriptionControls }
            }

            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        restModeButton(title: "標準 \(restText(routineDefaultRest))", selected: !usesIndividualRest, useIndividual: false)
                        restModeButton(title: "個別に設定", selected: usesIndividualRest, useIndividual: true)
                    }
                    VStack(spacing: 8) {
                        restModeButton(title: "標準 \(restText(routineDefaultRest))", selected: !usesIndividualRest, useIndividual: false)
                        restModeButton(title: "個別に設定", selected: usesIndividualRest, useIndividual: true)
                    }
                }

                if usesIndividualRest {
                    Stepper(value: individualRestBinding, in: 0...600, step: 5) {
                        HStack {
                            Text("個別の休憩")
                            Spacer()
                            Text(restText(step.restSeconds))
                                .font(.body.monospacedDigit().weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                } else {
                    Label("ルーティン標準を使用", systemImage: "arrow.triangle.branch")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("メモ（フォームや重量の目安など）", text: noteBinding, axis: .vertical)
                .font(.subheadline)
                .lineLimit(2...5)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var prescriptionControls: some View {
        compactStepper(title: "セット", value: setsBinding, range: 1...20)
        compactStepper(title: "回数", value: repsBinding, range: 1...50)
    }

    private func compactStepper(title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text("\(value.wrappedValue)").font(.headline.monospacedDigit())
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private func restModeButton(title: String, selected: Bool, useIndividual: Bool) -> some View {
        Button {
            onRestModeChanged(useIndividual ? step.restSeconds : nil)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? Color.black : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(selected ? AppTheme.accent : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var titleBinding: Binding<String> {
        Binding(get: { step.title }, set: { step.rename(to: $0); onChanged() })
    }
    private var setsBinding: Binding<Int> {
        Binding(get: { step.sets }, set: { step.sets = Step.clampSets($0); onChanged() })
    }
    private var repsBinding: Binding<Int> {
        Binding(get: { step.repsTarget }, set: { step.repsTarget = max(1, $0); onChanged() })
    }
    private var noteBinding: Binding<String> {
        Binding(get: { step.note }, set: { step.note = $0; onChanged() })
    }
    private var warmupBinding: Binding<Bool> {
        Binding(get: { step.isWarmup }, set: { step.isWarmup = $0; onChanged() })
    }
    private var individualRestBinding: Binding<Int> {
        Binding(
            get: { step.restSeconds },
            set: { onRestModeChanged(Step.clampRest($0)) }
        )
    }

    private func restText(_ seconds: Int) -> String {
        seconds == 0 ? "なし" : "\(seconds)秒"
    }
}
