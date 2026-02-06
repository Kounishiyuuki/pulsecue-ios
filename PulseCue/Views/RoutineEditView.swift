import SwiftUI
import SwiftData

struct RoutineEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: RoutineViewModel
    
    let routine: Routine?
    @State private var name: String
    @State private var steps: [Step]
    @State private var showingAddStep = false
    @State private var editingStep: Step?
    
    init(routine: Routine?, viewModel: RoutineViewModel) {
        self.routine = routine
        self.viewModel = viewModel
        _name = State(initialValue: routine?.name ?? "")
        _steps = State(initialValue: routine?.steps.sorted(by: { $0.order < $1.order }) ?? [])
    }
    
    var body: some View {
        Form {
            Section("Routine Details") {
                TextField("Routine Name", text: $name)
            }
            
            Section("Steps") {
                ForEach(steps) { step in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(step.name)
                                .font(.headline)
                            Text("\(step.durationSeconds)s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Button {
                            editingStep = step
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                }
                .onMove { from, to in
                    steps.move(fromOffsets: from, toOffset: to)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let step = steps[index]
                        viewModel.deleteStep(step)
                    }
                    steps.remove(atOffsets: indexSet)
                }
                
                Button {
                    showingAddStep = true
                } label: {
                    Label("Add Step", systemImage: "plus")
                }
            }
        }
        .navigationTitle(routine == nil ? "New Routine" : "Edit Routine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    saveRoutine()
                    dismiss()
                }
                .disabled(name.isEmpty)
            }
            
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        .sheet(isPresented: $showingAddStep) {
            StepEditView(step: nil, routine: routine) { newStep in
                if let routine = routine {
                    viewModel.addStep(to: routine, name: newStep.name, durationSeconds: newStep.durationSeconds)
                    steps = routine.steps.sorted(by: { $0.order < $1.order })
                } else {
                    steps.append(newStep)
                }
            }
        }
        .sheet(item: $editingStep) { step in
            StepEditView(step: step, routine: routine) { updatedStep in
                viewModel.updateStep(step, name: updatedStep.name, durationSeconds: updatedStep.durationSeconds)
                if let index = steps.firstIndex(where: { $0.id == step.id }) {
                    steps[index] = step
                }
            }
        }
    }
    
    private func saveRoutine() {
        if let routine = routine {
            viewModel.updateRoutine(routine, name: name)
            
            // Update step orders
            for (index, step) in steps.enumerated() {
                step.order = index
            }
            viewModel.reorderSteps(in: routine, from: IndexSet(), to: 0)
        } else {
            let newRoutine = viewModel.createRoutine(name: name)
            for (index, step) in steps.enumerated() {
                viewModel.addStep(to: newRoutine, name: step.name, durationSeconds: step.durationSeconds)
            }
        }
    }
}

struct StepEditView: View {
    @Environment(\.dismiss) private var dismiss
    let step: Step?
    let routine: Routine?
    let onSave: (Step) -> Void
    
    @State private var name: String
    @State private var durationSeconds: Int
    
    init(step: Step?, routine: Routine?, onSave: @escaping (Step) -> Void) {
        self.step = step
        self.routine = routine
        self.onSave = onSave
        _name = State(initialValue: step?.name ?? "")
        _durationSeconds = State(initialValue: step?.durationSeconds ?? 30)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Step Details") {
                    TextField("Step Name", text: $name)
                    
                    Stepper("Duration: \(durationSeconds)s", value: $durationSeconds, in: 1...3600, step: 5)
                }
            }
            .navigationTitle(step == nil ? "New Step" : "Edit Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let newStep = step ?? Step(name: name, durationSeconds: durationSeconds, order: 0)
                        newStep.name = name
                        newStep.durationSeconds = durationSeconds
                        onSave(newStep)
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RoutineEditView(routine: nil, viewModel: RoutineViewModel())
    }
}
