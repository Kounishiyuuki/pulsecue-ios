import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var healthVM: HealthViewModel
    @StateObject private var runnerVM: RunnerViewModel
    @State private var todayLog: DayLog?
    
    init() {
        _healthVM = StateObject(wrappedValue: HealthViewModel())
        _runnerVM = StateObject(wrappedValue: RunnerViewModel())
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Health Summary Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Today's Health")
                            .font(.headline)
                        
                        if let log = todayLog {
                            HStack(spacing: 20) {
                                VStack(alignment: .leading) {
                                    Text("Intake")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(Int(log.caloriesIntake)) kcal")
                                        .font(.title3)
                                        .bold()
                                }
                                
                                VStack(alignment: .leading) {
                                    Text("Exercise")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(Int(log.caloriesExercise)) kcal")
                                        .font(.title3)
                                        .bold()
                                }
                                
                                VStack(alignment: .leading) {
                                    Text("Balance")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(Int(log.balance)) kcal")
                                        .font(.title3)
                                        .bold()
                                        .foregroundStyle(log.balance >= 0 ? .green : .red)
                                }
                            }
                            
                            HStack(spacing: 20) {
                                VStack(alignment: .leading) {
                                    Text("Sleep")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(log.sleepHours, specifier: "%.1f")h")
                                        .font(.title3)
                                        .bold()
                                }
                                
                                if let weight = log.weightKg {
                                    VStack(alignment: .leading) {
                                        Text("Weight")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("\(weight, specifier: "%.1f")kg")
                                            .font(.title3)
                                            .bold()
                                    }
                                }
                            }
                        } else {
                            Text("No data logged today")
                                .foregroundStyle(.secondary)
                        }
                        
                        NavigationLink {
                            DayLogView()
                        } label: {
                            Text("Update Log")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 2)
                    
                    // Active Workout Card
                    if runnerVM.state != .idle {
                        RunnerView()
                    } else {
                        VStack(spacing: 12) {
                            Text("No active workout")
                                .font(.headline)
                            
                            NavigationLink {
                                WorkoutView()
                            } label: {
                                Text("Start Workout")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.accentColor)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(radius: 2)
                    }
                }
                .padding()
            }
            .navigationTitle("Today")
            .onAppear {
                healthVM.modelContext = modelContext
                runnerVM.restoreState(modelContext: modelContext)
                todayLog = healthVM.getTodayLog()
            }
        }
    }
}

#Preview {
    TodayView()
        .modelContainer(for: [Routine.self, DayLog.self])
}
