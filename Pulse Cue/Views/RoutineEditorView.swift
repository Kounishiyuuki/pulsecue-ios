//
//  RoutineEditorView.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import SwiftData

struct RoutineEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var routine: Routine
    @Query private var steps: [Step]

    init(routine: Routine) {
        self._routine = Bindable(wrappedValue: routine)
        let routineId = routine.id
        self._steps = Query(
            filter: #Predicate<Step> { $0.routineId == routineId },
            sort: [SortDescriptor(\Step.order, order: .forward)]
        )
    }

    var body: some View {
        List {
            Section("ルーティン") {
                TextField("ルーティン名", text: $routine.name)
                    .onChange(of: routine.name) { _, newValue in
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            routine.name = "無題"
                        }
                        routine.updatedAt = Date()
                    }
            }

            Section("種目") {
                ForEach(steps, id: \.id) { step in
                    StepRowView(step: step)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteStep(step)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                            Button {
                                duplicateStep(step)
                            } label: {
                                Label("複製", systemImage: "doc.on.doc")
                            }
                            .tint(.blue)
                        }
                }
                .onMove(perform: moveSteps)
                .onDelete(perform: deleteSteps)

                Button {
                    addStep()
                } label: {
                    Label("種目を追加", systemImage: "plus")
                }
            }
        }
        .navigationTitle("ルーティン編集")
        .toolbar {
            EditButton()
        }
    }

    private func addStep() {
        let newStep = Step(
            routineId: routine.id,
            order: steps.count,
            title: "新しい種目",
            sets: 3,
            repsTarget: 10,
            restSeconds: 60
        )
        modelContext.insert(newStep)
        routine.updatedAt = Date()
    }

    private func deleteStep(_ step: Step) {
        modelContext.delete(step)
        reindexSteps()
        routine.updatedAt = Date()
    }

    private func deleteSteps(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(steps[index])
        }
        reindexSteps()
        routine.updatedAt = Date()
    }

    private func duplicateStep(_ step: Step) {
        let copy = Step(
            routineId: routine.id,
            order: step.order + 1,
            title: step.title,
            sets: step.sets,
            repsTarget: step.repsTarget,
            restSeconds: step.restSeconds,
            note: step.note,
            isWarmup: step.isWarmup
        )
        modelContext.insert(copy)
        reindexSteps()
        routine.updatedAt = Date()
    }

    private func moveSteps(from source: IndexSet, to destination: Int) {
        var updated = steps
        updated.move(fromOffsets: source, toOffset: destination)
        for (index, step) in updated.enumerated() {
            step.order = index
        }
        routine.updatedAt = Date()
    }

    private func reindexSteps() {
        let sorted = steps.sorted { $0.order < $1.order }
        for (index, step) in sorted.enumerated() {
            step.order = index
        }
    }
}

private struct StepRowView: View {
    @Bindable var step: Step

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("種目名", text: $step.title)
                    .font(.headline)
                Spacer()
                Toggle(isOn: $step.isWarmup) {
                    Text("ウォームアップ")
                        .font(.footnote)
                }
                .labelsHidden()
            }

            HStack {
                Stepper(value: $step.sets, in: 1...20) {
                    Text("セット: \(step.sets)")
                }
            }

            HStack {
                Stepper(value: $step.repsTarget, in: 1...50) {
                    Text("回数: \(step.repsTarget)")
                }
            }

            HStack {
                Stepper(value: $step.restSeconds, in: 0...600, step: 5) {
                    Text("休憩: \(step.restSeconds) 秒")
                }
            }

            TextField("メモ", text: $step.note, axis: .vertical)
                .font(.footnote)
                .lineLimit(2...4)
        }
        .padding(.vertical, 8)
        .onChange(of: step.sets) { _, newValue in
            step.sets = Step.clampSets(newValue)
        }
        .onChange(of: step.restSeconds) { _, newValue in
            step.restSeconds = Step.clampRest(newValue)
        }
        .onChange(of: step.title) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                step.title = "無題"
            }
        }
    }
}
