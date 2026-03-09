import Foundation
import SwiftData

@Model
final class AmountOverride {
    var id: UUID
    var effectiveDate: Date
    var amount: Decimal
    var overrideDayOfMonth: Int?
    var overrideReferenceDate: Date?
    var notes: String?
    var ckRecordData: Data?
    var budgetItem: BudgetItem?

    init(
        effectiveDate: Date,
        amount: Decimal,
        overrideDayOfMonth: Int? = nil,
        overrideReferenceDate: Date? = nil,
        notes: String? = nil,
        budgetItem: BudgetItem? = nil
    ) {
        self.id = UUID()
        self.effectiveDate = effectiveDate
        self.amount = amount
        self.overrideDayOfMonth = overrideDayOfMonth
        self.overrideReferenceDate = overrideReferenceDate
        self.notes = notes
        self.budgetItem = budgetItem
    }
}
