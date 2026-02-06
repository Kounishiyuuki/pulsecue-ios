import SwiftUI
import SwiftData

struct RoutineListView: View {
    let pinnedRoutines: [Routine]
    let unpinnedRoutines: [Routine]
    @ObservedObject var viewModel: RoutineViewModel
    @StateObject private var runnerVM = RunnerViewModel()
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        List {
            if !pinnedRoutines.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedRoutines) { routine in
                        RoutineRow(routine: routine, viewModel: viewModel, runnerVM: runnerVM)
                    }
                }
            }
            
            Section("Routines") {
                ForEach(unpinnedRoutines) { routine in
                    RoutineRow(routine: routine, viewModel: viewModel, runnerVM: runnerVM)
                }
            }
        }
    }
}

struct RoutineRow: View {
    let routine: Routine
    @ObservedObject var viewModel: RoutineViewModel
    @ObservedObject var runnerVM: RunnerViewModel
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        NavigationLink {
            RoutineEditView(routine: routine, viewModel: viewModel)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(routine.name)
                        .font(.headline)
                    
                    Text("\(routine.steps.count) steps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if routine.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.accentColor)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                viewModel.togglePin(routine)
            } label: {
                Label(routine.isPinned ? "Unpin" : "Pin", systemImage: routine.isPinned ? "pin.slash" : "pin")
            }
            .tint(.blue)
            
            Button {
                _ = viewModel.duplicateRoutine(routine)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                runnerVM.startRoutine(routine)
            } label: {
                Label("Start Workout", systemImage: "play.fill")
            }
            
            Button {
                viewModel.togglePin(routine)
            } label: {
                Label(routine.isPinned ? "Unpin" : "Pin", systemImage: routine.isPinned ? "pin.slash" : "pin")
            }
            
            Button {
                _ = viewModel.duplicateRoutine(routine)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete \(routine.name)?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                viewModel.deleteRoutine(routine)
            }
        }
    }
}

#Preview {
    NavigationStack {
        RoutineListView(
            pinnedRoutines: [],
            unpinnedRoutines: [],
            viewModel: RoutineViewModel()
        )
    }
}
