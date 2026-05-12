import SwiftUI
import SwiftData

@main
struct PulseCueApp: App {
    init() {
        // Request notification permissions on app launch
        Task {
            await NotificationService.shared.requestAuthorization()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Routine.self, Step.self, DayLog.self])
    }
}
