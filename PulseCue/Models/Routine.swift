import Foundation
import SwiftData

@Model
final class Routine {
    var id: UUID
    var name: String
    var createdAt: Date
    var isPinned: Bool
    @Relationship(deleteRule: .cascade) var steps: [Step]
    
    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), isPinned: Bool = false, steps: [Step] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.steps = steps
    }
}
