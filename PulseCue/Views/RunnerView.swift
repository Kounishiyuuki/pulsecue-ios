import SwiftUI
import SwiftData

struct RunnerView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = RunnerViewModel()
    
    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            if let routine = viewModel.currentRoutine {
                Text(routine.name)
                    .font(.title2)
                    .bold()
                
                // Now / Rest / Next display
                VStack(spacing: 16) {
                    // Now
                    VStack(spacing: 8) {
                        Text("NOW")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        if let current = viewModel.currentStep {
                            Text(current.name)
                                .font(.title)
                                .bold()
                                .foregroundStyle(viewModel.state == .resting ? .accentColor : .primary)
                            
                            if viewModel.state == .resting {
                                Text(formatTime(viewModel.remainingSeconds))
                                    .font(.system(size: 48, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.accentColor)
                            }
                        } else {
                            Text("Ready")
                                .font(.title)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(viewModel.state == .resting ? Color.accentColor.opacity(0.1) : Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // Rest indicator
                    if viewModel.state == .resting {
                        Text("REST")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Next
                    VStack(spacing: 8) {
                        Text("NEXT")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        if let next = viewModel.nextStep {
                            Text(next.name)
                                .font(.headline)
                        } else {
                            Text("Complete!")
                                .font(.headline)
                                .foregroundStyle(.green)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                
                // Action buttons
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            if viewModel.state == .running {
                                viewModel.startCurrentStep()
                            } else {
                                viewModel.completeCurrentStep()
                            }
                        } label: {
                            Text(viewModel.state == .running ? "Start" : "Complete")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        
                        Button {
                            viewModel.skipCurrentStep()
                        } label: {
                            Text("Skip")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    
                    HStack(spacing: 12) {
                        Button {
                            viewModel.addTenSeconds()
                        } label: {
                            Text("+10s")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(viewModel.state != .resting)
                        
                        Button {
                            viewModel.goBack()
                        } label: {
                            Text("Back")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(viewModel.currentStepIndex == 0)
                    }
                    
                    Button {
                        viewModel.stop()
                    } label: {
                        Text("Stop Workout")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
        .onAppear {
            viewModel.restoreState(modelContext: modelContext)
        }
    }
}

#Preview {
    RunnerView()
        .modelContainer(for: [Routine.self])
}
