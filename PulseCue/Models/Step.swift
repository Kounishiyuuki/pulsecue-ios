import Foundation
import SwiftData

@Model
final class Step {
    var id: UUID
    var name: String
    var durationSeconds: Int
    var order: Int
    var routine: Routine?
    
    init(id: UUID = UUID(), name: String, durationSeconds: Int, order: Int) {
        self.id = id
        self.name = name
        self.durationSeconds = durationSeconds
        self.order = order
    }
}
