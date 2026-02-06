import SwiftUI
import SwiftData

@main
struct PulseCueApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Routine.self, Step.self, DayLog.self])
    }
}
