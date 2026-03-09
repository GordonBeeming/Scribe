import Foundation
import SwiftData

struct ScribeExport: Codable {
    let exportDate: Date
    let appVersion: String
    let familyMembers: [CodableFamilyMember]
    let budgetItems: [CodableBudgetItem]
    let amountOverrides: [CodableAmountOverride]
    let occurrences: [CodableOccurrence]
}

struct CodableFamilyMember: Codable {
    let id: UUID
    let name: String
    let sortOrder: Int

    init(from member: FamilyMember) {
        self.id = member.id
        self.name = member.name
        self.sortOrder = member.sortOrder
    }

    @MainActor
    func toModel() -> FamilyMember {
        let member = FamilyMember(name: name, sortOrder: sortOrder)
        member.id = id
        return member
    }
}

struct CodableBudgetItem: Codable {
    let id: UUID
    let name: String
    let itemType: String
    let amount: Decimal
    let currencyCode: String
    let frequencyRaw: String
    let dayOfMonth: Int?
    let referenceDate: Date?
    let categoryRaw: String
    let isActive: Bool
    let notes: String?
    let sortOrder: Int
    let showLast: Bool
    let createdAt: Date
    let modifiedAt: Date
    let familyMemberIDs: [UUID]

    init(from item: BudgetItem) {
        self.id = item.id
        self.name = item.name
        self.itemType = item.itemType
        self.amount = item.amount
        self.currencyCode = item.currencyCode
        self.frequencyRaw = item.frequencyRaw
        self.dayOfMonth = item.dayOfMonth
        self.referenceDate = item.referenceDate
        self.categoryRaw = item.categoryRaw
        self.isActive = item.isActive
        self.notes = item.notes
        self.sortOrder = item.sortOrder
        self.showLast = item.showLast
        self.createdAt = item.createdAt
        self.modifiedAt = item.modifiedAt
        self.familyMemberIDs = item.familyMembers.map { $0.id }
    }

    @MainActor
    func toModel() -> BudgetItem {
        let item = BudgetItem(
            name: name,
            type: ItemType(rawValue: itemType) ?? .expense,
            amount: amount,
            currencyCode: currencyCode,
            frequency: Frequency(rawValue: frequencyRaw) ?? .monthly,
            dayOfMonth: dayOfMonth,
            referenceDate: referenceDate,
            category: ItemCategory(rawValue: categoryRaw) ?? .other,
            isActive: isActive,
            notes: notes,
            sortOrder: sortOrder,
            showLast: showLast
        )
        item.id = id
        item.createdAt = createdAt
        item.modifiedAt = modifiedAt
        return item
    }
}

struct CodableAmountOverride: Codable {
    let id: UUID
    let effectiveDate: Date
    let amount: Decimal
    let overrideDayOfMonth: Int?
    let overrideReferenceDate: Date?
    let notes: String?
    let budgetItemID: UUID?

    init(from override_: AmountOverride) {
        self.id = override_.id
        self.effectiveDate = override_.effectiveDate
        self.amount = override_.amount
        self.overrideDayOfMonth = override_.overrideDayOfMonth
        self.overrideReferenceDate = override_.overrideReferenceDate
        self.notes = override_.notes
        self.budgetItemID = override_.budgetItem?.id
    }

    @MainActor
    func toModel() -> AmountOverride {
        let override_ = AmountOverride(
            effectiveDate: effectiveDate,
            amount: amount,
            overrideDayOfMonth: overrideDayOfMonth,
            overrideReferenceDate: overrideReferenceDate,
            notes: notes
        )
        override_.id = id
        return override_
    }
}

struct CodableOccurrence: Codable {
    let id: UUID
    let dueDate: Date
    let expectedAmount: Decimal
    let actualAmount: Decimal?
    let statusRaw: String
    let confirmedAt: Date?
    let notes: String?
    let budgetItemID: UUID?

    init(from occurrence: Occurrence) {
        self.id = occurrence.id
        self.dueDate = occurrence.dueDate
        self.expectedAmount = occurrence.expectedAmount
        self.actualAmount = occurrence.actualAmount
        self.statusRaw = occurrence.statusRaw
        self.confirmedAt = occurrence.confirmedAt
        self.notes = occurrence.notes
        self.budgetItemID = occurrence.budgetItem?.id
    }

    @MainActor
    func toModel() -> Occurrence {
        let occurrence = Occurrence(
            dueDate: dueDate,
            expectedAmount: expectedAmount,
            actualAmount: actualAmount,
            status: OccurrenceStatus(rawValue: statusRaw) ?? .pending,
            confirmedAt: confirmedAt,
            notes: notes
        )
        occurrence.id = id
        return occurrence
    }
}
