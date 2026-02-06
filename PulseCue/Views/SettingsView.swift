import SwiftUI

struct SettingsView: View {
    @ObservedObject private var audioService = AudioService.shared
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Audio") {
                    Toggle("Beep Sound", isOn: $audioService.isBeepEnabled)
                }
                
                Section("About") {
                    LabeledContent("Version", value: "1.0")
                    LabeledContent("Build", value: "1")
                }
                
                Section("Future Features") {
                    NavigationLink("Sign in with Apple") {
                        Text("Coming Soon")
                    }
                    NavigationLink("HealthKit Integration") {
                        Text("Coming Soon")
                    }
                    NavigationLink("AI Coach & Meal Kcal") {
                        Text("Coming Soon")
                    }
                    NavigationLink("Widgets & Live Activities") {
                        Text("Coming Soon")
                    }
                    NavigationLink("Analytics") {
                        Text("Coming Soon")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
