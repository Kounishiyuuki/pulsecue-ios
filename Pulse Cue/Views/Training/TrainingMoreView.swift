//
//  TrainingMoreView.swift
//  Pulse Cue
//
//  その他の機能 — the occasional training destinations, on a screen of their
//  own.
//
//  They used to be listed at the bottom of the Training root, below the
//  routine library. That reads fine with two routines and badly with twenty:
//  the library is unbounded, so the distance to My Gym or the machine
//  catalogue grew with the user's own history. Someone who used the app more
//  had a harder time reaching them, which is the wrong way round.
//
//  The rows themselves are unchanged — `TrainingMoreSection` still owns them,
//  and `TrainingSurface.moreDestinations` still decides which exist. Only
//  where they are shown moved.
//

import SwiftData
import SwiftUI

struct TrainingMoreView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.deepSpace.opacity(0.95), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                TrainingMoreSection()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
        }
        .navigationTitle("その他の機能")
        .navigationBarTitleDisplayMode(.large)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Free Workout
//
// Kept in this file only because a new file would need a project.pbxproj
// change; these belong in their own FreeWorkout*.swift files.

/// Start a Free Workout, or resume / discard one already in progress. Shown
/// on Home and Training; all state lives in `FreeWorkoutLauncher`.
struct FreeWorkoutEntryCard: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var dataScope: WorkoutDataScopeResolver
    @StateObject private var launcher = FreeWorkoutLauncher()
    @State private var pendingDiscard: FreeWorkoutRecovery.Candidate?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if launcher.candidates.isEmpty {
                startButton
            } else {
                ForEach(launcher.candidates) { candidate in
                    activeCard(candidate)
                }
            }
        }
        .onAppear { launcher.configure(context: modelContext, scope: dataScope.scope) }
        .onChange(of: dataScope.scope) { _, scope in launcher.configure(context: modelContext, scope: scope) }
        .fullScreenCover(item: $launcher.presented) { model in
            FreeWorkoutView(model: model, onClose: launcher.workoutScreenClosed)
        }
        .confirmationDialog(
            "このフリーワークアウトを破棄しますか？",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            titleVisibility: .visible,
            presenting: pendingDiscard
        ) { candidate in
            Button("破棄", role: .destructive) { launcher.discard(candidate) }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("記録したセットも含め、このトレーニングは保存されません。")
        }
        .alert(
            noticeTitle,
            isPresented: Binding(get: { launcher.notice != nil }, set: { if !$0 { launcher.notice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    private var noticeTitle: String {
        switch launcher.notice {
        case .scopeUndetermined: return "アカウントを確認中のため、まだ開始できません"
        case .nothingSaved: return "記録されたセットがないため保存されませんでした"
        case nil: return ""
        }
    }

    private var startButton: some View {
        Button {
            launcher.start()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.pencil")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("フリーワークアウトを開始")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("ルーティンなしで、その場で種目とセットを記録")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(launcher.isBusy)
        .pulseGlass(level: .subtle, padding: 16)
        .accessibilityElement(children: .combine)
    }

    private func activeCard(_ candidate: FreeWorkoutRecovery.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("進行中のフリーワークアウト")
                .font(.headline)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("\(startedText(candidate.startedAt))開始・\(DateUtils.formatDuration(seconds: Int(context.date.timeIntervalSince(candidate.startedAt))))経過")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("\(candidate.stepCount)種目・\(candidate.loggedResultCount)セット記録済み")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !candidate.isResumable {
                Text("この記録は再開できません")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
            }
            HStack(spacing: 12) {
                Button {
                    launcher.resume(candidate)
                } label: {
                    Text("再開").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accentFilled)
                .disabled(!candidate.isResumable || launcher.isBusy)

                Button(role: .destructive) {
                    pendingDiscard = candidate
                } label: {
                    Text("破棄").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(launcher.isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pulseGlass(level: .subtle, padding: 16)
    }

    private func startedText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "H:mm" : "M/d H:mm"
        return formatter.string(from: date)
    }
}

/// The workout itself: every exercise and every set on one screen, edited
/// in any order — not the Runner's one-set-at-a-time flow.
struct FreeWorkoutView: View {
    @ObservedObject var model: FreeWorkoutViewModel
    let onClose: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Accessibility sizes stack what sits side by side at normal sizes, the
    /// pattern `SessionDetailView` uses, so nothing is squeezed or shrunk.
    private var stacks: Bool { dynamicTypeSize.isAccessibilitySize }

    @State private var showPicker = false
    @State private var showFinish = false
    @State private var showUnsavedDuration = false
    @State private var isReordering = false
    @State private var weightEntry: FreeWorkoutViewModel.RowKey?
    @State private var repsEntry: FreeWorkoutViewModel.RowKey?
    @State private var entryText = ""

    var body: some View {
        NavigationStack {
            Group {
                if let summary = model.completion {
                    WorkoutCompletionView(summary: summary, onDone: onClose)
                } else {
                    workoutList
                }
            }
            .toolbar { toolbar }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("保存されていない時間の変更があります", isPresented: $showUnsavedDuration, titleVisibility: .visible) {
            Button("編集に戻る") {
                if let key = model.unsavedDurationEdits.first, model.selected != key { model.select(key) }
            }
            // Finishes as 「終了して保存」 does; only the unsaved edits are dropped.
            Button("変更を破棄して終了", role: .destructive) {
                model.finish()
                if model.finishOutcome == .discarded { onClose() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("記録済みのセットの時間が正しく入力されていません。終了すると、変更は破棄され元の時間が残ります。記録していないセットは保存されません。")
        }
        .confirmationDialog("トレーニングを終了しますか？", isPresented: $showFinish, titleVisibility: .visible) {
            Button("終了して保存") {
                model.finish()
                if model.finishOutcome == .discarded { onClose() }
            }
            Button("記録せずに破棄", role: .destructive) {
                model.discard()
                onClose()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("記録していないセットは保存されません。")
        }
        .alert("重量（kg）", isPresented: entryBinding($weightEntry)) {
            TextField("例: 60", text: $entryText).keyboardType(.decimalPad)
            Button("設定") {
                if let key = weightEntry, let kg = SetWeight.parse(entryText) { model.setWeight(kg, for: key) }
            }
            Button("未入力に戻す", role: .destructive) {
                if let key = weightEntry { model.setWeight(nil, for: key) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("0〜\(SetWeight.number(SetWeight.maximumKg)) kg")
        }
        .alert("回数", isPresented: entryBinding($repsEntry)) {
            TextField("例: 10", text: $entryText).keyboardType(.numberPad)
            Button("設定") {
                if let key = repsEntry, let reps = Int(entryText.trimmingCharacters(in: .whitespaces)), reps >= 0 {
                    model.setReps(reps, for: key)
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.completion == nil {
            ToolbarItem(placement: .topBarLeading) {
                Button("閉じる") { onClose() }
                    .accessibilityHint("記録は進行中のまま残ります")
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("フリーワークアウト").font(.headline)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(model.elapsedText(now: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("経過時間 \(model.elapsedText(now: context.date))")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("終了") {
                    if model.unsavedDurationEdits.isEmpty { showFinish = true } else { showUnsavedDuration = true }
                }
                    .fontWeight(.semibold)
            }
        }
    }

    private var workoutList: some View {
        List {
            if model.cards.isEmpty {
                // Not ContentUnavailableView: in a list row it truncated its
                // title at accessibility sizes.
                VStack(spacing: 10) {
                    Image(systemName: "dumbbell")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("種目を追加して始めましょう")
                        .font(.title3.weight(.bold))
                    Text("「種目を追加」から、今日やる種目を選べます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            ForEach(model.cards) { card in
                if isReordering {
                    Text(card.title)
                        .font(.body.weight(.semibold))
                        .frame(minHeight: 44)
                } else {
                    exerciseCard(card)
                        .listRowSeparator(.hidden)
                }
            }
            .onMove(perform: isReordering ? { model.moveExercises(fromOffsets: $0, toOffset: $1) } : nil)
            .listRowBackground(Color.clear)

            if model.cards.count > 1 {
                Button(isReordering ? "並び替えを完了" : "種目を並び替え") { isReordering.toggle() }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(PulseAtmosphericBackground().ignoresSafeArea())
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        // Pushed rather than a sheet: a sheet nested in this full-screen
        // cover was observed to build its content and never appear.
        .navigationDestination(isPresented: $showPicker) {
            FreeWorkoutExercisePicker(
                onSelectExercise: { model.addExercise($0) },
                onSelectCustom: { model.addExercise(exerciseId: nil, title: $0) }
            )
        }
        // Pinned to the bottom, within thumb reach however long the list is.
        .safeAreaInset(edge: .bottom) {
            if !isReordering {
                Button {
                    showPicker = true
                } label: {
                    Label("種目を追加", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accentFilled)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Exercise card

    private func exerciseCard(_ card: FreeWorkoutViewModel.ExerciseCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(card.title)
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Button(role: .destructive) {
                        model.removeExercise(card.id)
                    } label: {
                        Label(card.canRemove ? "種目を削除" : "記録済みの種目は削除できません", systemImage: "trash")
                    }
                    .disabled(!card.canRemove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("\(card.title)のメニュー")
            }
            if let previous = card.previousText {
                Text("前回: \(previous)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !stacks {
            HStack {
                Text("セット").frame(width: 44, alignment: .leading)
                if card.acceptsWeight { Text("kg").frame(maxWidth: .infinity) }
                if card.tracksReps { Text("回").frame(maxWidth: .infinity) } else { Text("時間").frame(maxWidth: .infinity) }
                if card.tracksReps { Text("RIR").frame(width: SetRIRPicker.width) }
                Color.clear.frame(width: 44)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            }

            ForEach(card.rows) { row in
                setRow(row, card: card)
                if model.selected == row.key {
                    editor(row, card: card)
                }
            }

            Button {
                model.addSet(to: card.id)
            } label: {
                Label("セットを追加", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .disabled(!card.canAddSet)
        }
        .pulseGlass(level: .subtle, padding: 16)
        .buttonStyle(.plain)
    }

    private func setRow(_ row: FreeWorkoutViewModel.SetRow, card: FreeWorkoutViewModel.ExerciseCard) -> some View {
        Group {
            if stacks {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("セット \(row.number)").font(.body.weight(.semibold))
                        if let values = compactValues(row, card: card) {
                            Text(values)
                                .font(.body.monospacedDigit())
                        }
                        if model.acceptsRepsInReserve(row.key) {
                            SetRIRPicker(value: row.repsInReserve) { model.setRepsInReserve($0, for: row.key) }
                        }
                    }
                    Spacer(minLength: 4)
                    completionButton(row, card: card)
                }
            } else {
                wideSetRow(row, card: card)
            }
        }
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(model.selected == row.key ? AppTheme.accentSoft : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(row.key) }
        .contextMenu {
            Button("スキップ") { model.skip(row.key) }
            Button("セットを削除", role: .destructive) { model.removeSet(row.key) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowLabel(row, card: card))
        .accessibilityAction(named: "編集") { model.select(row.key) }
        .accessibilityAction(named: "スキップ") { model.skip(row.key) }
        .accessibilityAction(named: "セットを削除") { model.removeSet(row.key) }
        .accessibilityActions {
            // The row reads as one element, so the picker inside it is
            // reached through these actions instead.
            if model.acceptsRepsInReserve(row.key) {
                ForEach(SetRIRPicker.options, id: \.self) { value in
                    Button(SetRIRPicker.spokenText(value)) { model.setRepsInReserve(value, for: row.key) }
                }
            }
        }
    }

    private func compactValues(_ row: FreeWorkoutViewModel.SetRow, card: FreeWorkoutViewModel.ExerciseCard) -> String? {
        let reps: String? = card.tracksReps ? "\(row.reps) 回" : row.duration.displayText
        guard card.acceptsWeight else { return reps }
        let weight = row.weightKg.map { "\(SetWeight.number($0)) kg" } ?? "– kg"
        return reps.map { "\(weight) × \($0)" } ?? weight
    }

    private func completionButton(_ row: FreeWorkoutViewModel.SetRow, card: FreeWorkoutViewModel.ExerciseCard) -> some View {
        Button {
            // A timed row without a valid duration opens its editor, where
            // the reason is shown, instead of doing nothing.
            if row.state == .done || row.durationIssue(tracksReps: card.tracksReps) != nil {
                if model.selected != row.key { model.select(row.key) }
            } else {
                model.complete(row.key)
            }
        } label: {
            Image(systemName: icon(for: row.state))
                .font(.title2)
                .foregroundStyle(row.state == .done ? AppTheme.success : .secondary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(row.state == .done ? "セット\(row.number)は完了済み" : "セット\(row.number)を完了")
    }

    private func wideSetRow(_ row: FreeWorkoutViewModel.SetRow, card: FreeWorkoutViewModel.ExerciseCard) -> some View {
        HStack {
            Text("\(row.number)")
                .font(.body.weight(.semibold).monospacedDigit())
                .frame(width: 44, alignment: .leading)
            if card.acceptsWeight {
                Text(row.weightKg.map(SetWeight.number) ?? "–")
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: .infinity)
            }
            if card.tracksReps {
                Text("\(row.reps)")
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: .infinity)
            } else {
                Text(row.duration.issue == .empty ? "–" : row.duration.displayText)
                    .font(.body.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            if card.tracksReps {
                if model.acceptsRepsInReserve(row.key) {
                    SetRIRPicker(value: row.repsInReserve) { model.setRepsInReserve($0, for: row.key) }
                        .frame(width: SetRIRPicker.width)
                } else {
                    Color.clear.frame(width: SetRIRPicker.width, height: 1)
                }
            }
            completionButton(row, card: card)
        }
        .frame(minHeight: 44)
    }

    private func editor(_ row: FreeWorkoutViewModel.SetRow, card: FreeWorkoutViewModel.ExerciseCard) -> some View {
        VStack(spacing: 10) {
            if card.acceptsWeight {
                stepper(
                    value: row.weightKg.map { "\(SetWeight.number($0)) kg" } ?? "重量なし",
                    minus: ("−2.5", "2.5キログラム減らす", { model.adjustWeight(by: -2.5, for: row.key) }),
                    plus: ("+2.5", "2.5キログラム増やす", { model.adjustWeight(by: 2.5, for: row.key) }),
                    valueLabel: "重量 \(row.weightKg.map(SetWeight.number) ?? "未入力")キログラム",
                    onTapValue: {
                        entryText = row.weightKg.map(SetWeight.number) ?? ""
                        weightEntry = row.key
                    }
                )
            }
            if card.tracksReps {
                stepper(
                    value: "\(row.reps) 回",
                    minus: ("−1", "1回減らす", { model.adjustReps(by: -1, for: row.key) }),
                    plus: ("+1", "1回増やす", { model.adjustReps(by: 1, for: row.key) }),
                    valueLabel: "回数 \(row.reps)回",
                    onTapValue: {
                        entryText = "\(row.reps)"
                        repsEntry = row.key
                    }
                )
            }
            if !card.tracksReps {
                SetDurationEditor(entry: row.duration) { model.setDuration($0, for: row.key) }
            }
            let actions = stacks
                ? AnyLayout(VStackLayout(spacing: 8))
                : AnyLayout(HStackLayout(spacing: 10))
            actions {
                if row.state != .done {
                    Button {
                        model.complete(row.key)
                    } label: {
                        Label("完了", systemImage: "checkmark")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accentFilled)
                    .disabled(row.durationIssue(tracksReps: card.tracksReps) != nil)
                    .accessibilityLabel("セット\(row.number)を完了")
                }
                if row.state == .draft {
                    Button {
                        model.skip(row.key)
                    } label: {
                        Text("スキップ").frame(maxWidth: stacks ? .infinity : nil, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    model.removeSet(row.key)
                } label: {
                    Group {
                        if stacks { Label("セットを削除", systemImage: "trash") } else { Image(systemName: "trash") }
                    }
                    .frame(maxWidth: stacks ? .infinity : nil, minHeight: 44)
                    .frame(minWidth: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("セット\(row.number)を削除")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func stepper(
        value: String,
        minus: (String, String, () -> Void),
        plus: (String, String, () -> Void),
        valueLabel: String,
        onTapValue: @escaping () -> Void
    ) -> some View {
        let valueButton = Button(action: onTapValue) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(stacks ? nil : 1)
                .minimumScaleFactor(stacks ? 1 : 0.6)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(valueLabel)
        .accessibilityHint("タップして入力")
        return Group {
            if stacks {
                VStack(spacing: 8) {
                    valueButton
                    HStack(spacing: 10) {
                        stepButton(minus.0, label: minus.1, action: minus.2)
                        stepButton(plus.0, label: plus.1, action: plus.2)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    stepButton(minus.0, label: minus.1, action: minus.2)
                    valueButton
                    stepButton(plus.0, label: plus.1, action: plus.2)
                }
            }
        }
    }

    private func stepButton(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12)
                .frame(maxWidth: stacks ? .infinity : nil, minHeight: 44)
                .frame(minWidth: 64)
                .foregroundStyle(AppTheme.accent)
                .background(Capsule().fill(Color.white.opacity(0.055)))
                .overlay(Capsule().strokeBorder(AppTheme.separator.opacity(0.45), lineWidth: 1))
        }
        .accessibilityLabel(label)
    }

    private func icon(for state: FreeWorkoutViewModel.SetRow.State) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .skipped: return "forward.circle"
        case .draft: return "circle"
        }
    }

    private func rowLabel(_ row: FreeWorkoutViewModel.SetRow, card: FreeWorkoutViewModel.ExerciseCard) -> String {
        var parts = ["セット \(row.number)"]
        if card.acceptsWeight { parts.append(row.weightKg.map { "\(SetWeight.number($0))キログラム" } ?? "重量未入力") }
        if card.tracksReps {
            parts.append("\(row.reps)回")
        } else {
            parts.append(row.duration.issue == .empty ? "時間未入力" : row.duration.displayText)
        }
        if model.acceptsRepsInReserve(row.key) { parts.append(SetRIRPicker.spokenText(row.repsInReserve)) }
        switch row.state {
        case .done: parts.append("完了")
        case .skipped: parts.append("スキップ")
        case .draft: parts.append("未記録")
        }
        return parts.joined(separator: "、")
    }

    private func entryBinding(_ key: Binding<FreeWorkoutViewModel.RowKey?>) -> Binding<Bool> {
        Binding(get: { key.wrappedValue != nil }, set: { if !$0 { key.wrappedValue = nil } })
    }
}

/// Reps-in-reserve chip for a done rep-counted set, shared by the Runner and
/// Free Workout: one tap opens the values, one more picks. Secondary to the
/// set's weight and reps, so it stays small and neutral. The values are the
/// domain's (`RepsInReserve.range`); nothing is validated here.
struct SetRIRPicker: View {
    let value: Int?
    let onChange: (Int?) -> Void

    static let width: CGFloat = 76
    /// 未入力, then 0...4.
    static let options: [Int?] = [nil] + RepsInReserve.range.map { Optional($0) }

    static func text(_ value: Int?) -> String {
        guard let value else { return "RIR –" }
        return value == RepsInReserve.range.upperBound ? "RIR \(value)+" : "RIR \(value)"
    }

    static func spokenText(_ value: Int?) -> String {
        guard let value else { return "RIR 未入力" }
        return value == RepsInReserve.range.upperBound ? "RIR \(value)以上" : "RIR \(value)"
    }

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.self) { option in
                Button {
                    if option != value { onChange(option) }
                } label: {
                    if option == value {
                        Label(Self.menuText(option), systemImage: "checkmark")
                    } else {
                        Text(Self.menuText(option))
                    }
                }
                .accessibilityLabel(Self.spokenText(option))
            }
        } label: {
            Text(Self.text(value))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .frame(minWidth: 64, minHeight: 44)
                .background(Capsule().fill(Color.white.opacity(0.055)))
                .overlay(Capsule().strokeBorder(AppTheme.separator.opacity(0.45), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.spokenText(value))
        .accessibilityHint("タップしてあと何回できたか（RIR）を選択")
    }

    private static func menuText(_ value: Int?) -> String {
        guard let value else { return "未入力" }
        return value == RepsInReserve.range.upperBound ? "\(value)+（4回以上）" : "\(value)"
    }
}

/// Minutes-and-seconds editor for a timed set, shared by the Runner and Free
/// Workout: −1分 / value / +1分, the value tappable for exact entry. The
/// entry is passed back as typed; when it cannot be completed the reason is
/// shown under it, so a disabled Complete is never unexplained.
struct SetDurationEditor: View {
    let entry: DurationEntry
    let onChange: (DurationEntry) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isEntering = false
    @State private var minutesText = ""
    @State private var secondsText = ""

    var body: some View {
        let stacks = dynamicTypeSize.isAccessibilitySize
        VStack(spacing: 6) {
            if stacks {
                VStack(spacing: 8) {
                    valueButton(stacks: true)
                    HStack(spacing: 10) {
                        stepButton(-1, stacks: true)
                        stepButton(1, stacks: true)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    stepButton(-1, stacks: false)
                    valueButton(stacks: false)
                    stepButton(1, stacks: false)
                }
            }
            if let issue = entry.issue {
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(issue == .empty ? AnyShapeStyle(.secondary) : AnyShapeStyle(AppTheme.warning))
                    .multilineTextAlignment(.center)
            }
        }
        .alert("時間", isPresented: $isEntering) {
            TextField("分", text: $minutesText).keyboardType(.numberPad)
            TextField("秒（0〜59）", text: $secondsText).keyboardType(.numberPad)
            Button("設定") { onChange(DurationEntry(minutes: minutesText, seconds: secondsText)) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このセットを行った時間です。秒は0〜59で入力します。")
        }
    }

    private func valueButton(stacks: Bool) -> some View {
        Button {
            minutesText = entry.minutes
            secondsText = entry.seconds
            isEntering = true
        } label: {
            Text(entry.displayText)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(stacks ? nil : 1)
                .minimumScaleFactor(stacks ? 1 : 0.6)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.issue == .empty ? "時間 未入力" : "時間 \(entry.displayText)")
        .accessibilityHint("タップして分と秒を入力")
    }

    private func stepButton(_ delta: Int, stacks: Bool) -> some View {
        Button {
            onChange(entry.adjustingMinutes(by: delta))
        } label: {
            Text(delta < 0 ? "−1分" : "+1分")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12)
                .frame(maxWidth: stacks ? .infinity : nil, minHeight: 44)
                .frame(minWidth: 64)
                .foregroundStyle(AppTheme.accent)
                .background(Capsule().fill(Color.white.opacity(0.055)))
                .overlay(Capsule().strokeBorder(AppTheme.separator.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "1分減らす" : "1分増やす")
    }
}

/// "＋ 種目を追加": every catalogue exercise plus this user's custom
/// machines, searchable. `ExerciseLibraryView` is a read-only Form Guide
/// index (guided exercises only), so it is not reused as is; its search rule
/// is.
struct FreeWorkoutExercisePicker: View {
    let onSelectExercise: (Exercise) -> Void
    let onSelectCustom: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CustomMachine.displayName) private var customMachines: [CustomMachine]
    @State private var searchText = ""

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var exercises: [Exercise] {
        guard !query.isEmpty else { return ExerciseLibrary.all }
        return ExerciseLibrary.all.filter { exercise in
            exercise.displayName.localizedCaseInsensitiveContains(query)
                || exercise.aliases.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || exercise.bodyParts.contains(where: { $0.displayName.localizedCaseInsensitiveContains(query) })
        }
    }

    private var customs: [CustomMachine] {
        customMachines.filter { $0.isAvailable && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
            List {
                // A plain field, not `.searchable`: in this pushed screen an
                // active search bar outlived the pop and hid the workout's
                // toolbar.
                TextField("種目名・部位で検索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .accessibilityLabel("種目を検索")
                if !customs.isEmpty {
                    Section("カスタム") {
                        ForEach(customs) { machine in
                            row(machine.displayName, detail: "カスタム") {
                                onSelectCustom(machine.displayName)
                            }
                        }
                    }
                }
                Section("種目") {
                    ForEach(exercises) { exercise in
                        row(exercise.displayName, detail: exercise.bodyParts.map(\.displayName).joined(separator: "・")) {
                            onSelectExercise(exercise)
                        }
                    }
                }
            }
            .overlay {
                if exercises.isEmpty && customs.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("種目を追加")
            .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityHint("この種目を追加")
    }
}
