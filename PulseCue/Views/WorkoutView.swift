import SwiftUI
import SwiftData

struct WorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = RoutineViewModel()
    @Query(sort: \Routine.isPinned, order: .reverse) private var allRoutines: [Routine]
    
    var filteredRoutines: [Routine] {
        if viewModel.searchText.isEmpty {
            return allRoutines
        }
        return allRoutines.filter { $0.name.localizedCaseInsensitiveContains(viewModel.searchText) }
    }
    
    var pinnedRoutines: [Routine] {
        filteredRoutines.filter { $0.isPinned }
    }
    
    var unpinnedRoutines: [Routine] {
        filteredRoutines.filter { !$0.isPinned }
    }
    
    var body: some View {
        NavigationStack {
            RoutineListView(
                pinnedRoutines: pinnedRoutines,
                unpinnedRoutines: unpinnedRoutines,
                viewModel: viewModel
            )
            .navigationTitle("Workout")
            .searchable(text: $viewModel.searchText, prompt: "Search routines")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RoutineEditView(routine: nil, viewModel: viewModel)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                viewModel.modelContext = modelContext
            }
        }
    }
}

#Preview {
    WorkoutView()
        .modelContainer(for: [Routine.self])
}
