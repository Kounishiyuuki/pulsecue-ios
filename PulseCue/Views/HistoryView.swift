import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = HealthViewModel()
    @State private var logs: [DayLog] = []
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(logs) { log in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(log.date, style: .date)
                            .font(.headline)
                        
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Intake")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(Int(log.caloriesIntake))")
                                    .font(.subheadline)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Exercise")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(Int(log.caloriesExercise))")
                                    .font(.subheadline)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Balance")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(Int(log.balance))")
                                    .font(.subheadline)
                                    .foregroundStyle(log.balance >= 0 ? .green : .red)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sleep")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(log.sleepHours, specifier: "%.1f")h")
                                    .font(.subheadline)
                            }
                            
                            if let weight = log.weightKg {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Weight")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(weight, specifier: "%.1f")kg")
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("History")
            .onAppear {
                viewModel.modelContext = modelContext
                logs = viewModel.getRecentLogs(days: 30)
            }
        }
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [DayLog.self])
}
