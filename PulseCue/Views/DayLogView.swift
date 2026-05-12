import SwiftUI
import SwiftData

struct DayLogView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = HealthViewModel()
    
    @State private var log: DayLog?
    @State private var caloriesIntake: String = ""
    @State private var caloriesExercise: String = ""
    @State private var sleepHours: String = ""
    @State private var weightKg: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Calories") {
                    HStack {
                        Text("Intake")
                        Spacer()
                        TextField("0", text: $caloriesIntake)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("kcal")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("Exercise")
                        Spacer()
                        TextField("0", text: $caloriesExercise)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("kcal")
                            .foregroundStyle(.secondary)
                    }
                    
                    if let intake = Double(caloriesIntake), let exercise = Double(caloriesExercise) {
                        HStack {
                            Text("Balance")
                            Spacer()
                            Text("\(Int(intake - exercise)) kcal")
                                .foregroundStyle(intake - exercise >= 0 ? .green : .red)
                                .bold()
                        }
                    }
                }
                
                Section("Sleep") {
                    HStack {
                        Text("Hours")
                        Spacer()
                        TextField("0", text: $sleepHours)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("hours")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Weight") {
                    HStack {
                        Text("Weight")
                        Spacer()
                        TextField("Optional", text: $weightKg)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("kg")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Today's Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveLog()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                viewModel.modelContext = modelContext
                log = viewModel.getOrCreateTodayLog()
                
                if let log = log {
                    caloriesIntake = log.caloriesIntake > 0 ? String(Int(log.caloriesIntake)) : ""
                    caloriesExercise = log.caloriesExercise > 0 ? String(Int(log.caloriesExercise)) : ""
                    sleepHours = log.sleepHours > 0 ? String(format: "%.1f", log.sleepHours) : ""
                    if let weight = log.weightKg {
                        weightKg = String(format: "%.1f", weight)
                    }
                }
            }
        }
    }
    
    private func saveLog() {
        guard let log = log else { return }
        
        viewModel.updateLog(
            log,
            caloriesIntake: Double(caloriesIntake),
            caloriesExercise: Double(caloriesExercise),
            sleepHours: Double(sleepHours),
            weightKg: weightKg.isEmpty ? nil : Double(weightKg)
        )
    }
}

#Preview {
    DayLogView()
        .modelContainer(for: [DayLog.self])
}
