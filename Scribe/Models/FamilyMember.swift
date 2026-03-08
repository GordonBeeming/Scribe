import Foundation
import SwiftData

@Model
final class FamilyMember {
    var id: UUID
    var name: String
    var sortOrder: Int

    @Relationship(inverse: \BudgetItem.familyMembers)
    var budgetItems: [BudgetItem]

    init(name: String, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.sortOrder = sortOrder
        self.budgetItems = []
    }
}
