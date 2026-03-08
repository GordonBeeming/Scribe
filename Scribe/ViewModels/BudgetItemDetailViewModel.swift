import Foundation
import SwiftData

@Observable
final class BudgetItemDetailViewModel {
    // Form fields
    var name: String = ""
    var itemType: ItemType = .expense
    var amount: Decimal = 0
    var currencyCode: String = "AUD"
    var frequency: Frequency = .monthly
    var dayOfMonth: Int? = 1
    var referenceDate: Date? = Date()
    var category: ItemCategory = .other
    var isActive: Bool = true
    var notes: String = ""
    var showLast: Bool = false
    var selectedFamilyMemberIDs: Set<UUID> = []

    // Amount override
    var newOverrideAmount: Decimal = 0
    var newOverrideDate: Date = Date()
    var newOverrideDayOfMonth: Int?
    var newOverrideNotes: String = ""

    var isEditing: Bool = false

    func loadFromItem(_ item: BudgetItem) {
        name = item.name
        itemType = item.type
        amount = item.amount
        currencyCode = item.currencyCode
        frequency = item.frequency
        dayOfMonth = item.dayOfMonth
        referenceDate = item.referenceDate
        category = item.category
        isActive = item.isActive
        notes = item.notes ?? ""
        showLast = item.showLast
        selectedFamilyMemberIDs = Set(item.familyMembers.map(\.id))
        isEditing = true
    }

    func applyToItem(_ item: BudgetItem) {
        item.name = name
        item.type = itemType
        item.amount = amount
        item.currencyCode = currencyCode
        item.frequency = frequency
        item.dayOfMonth = frequency == .monthly ? dayOfMonth : nil
        item.referenceDate = frequency.usesReferenceDate ? referenceDate : nil
        item.category = category
        item.isActive = isActive
        item.notes = notes.isEmpty ? nil : notes
        item.showLast = showLast
        item.modifiedAt = Date()
    }

    func applyFamilyMembers(to item: BudgetItem, allMembers: [FamilyMember]) {
        item.familyMembers = allMembers.filter { selectedFamilyMemberIDs.contains($0.id) }
    }

    func createItem() -> BudgetItem {
        BudgetItem(
            name: name,
            type: itemType,
            amount: amount,
            currencyCode: currencyCode,
            frequency: frequency,
            dayOfMonth: frequency == .monthly ? dayOfMonth : nil,
            referenceDate: frequency.usesReferenceDate ? referenceDate : nil,
            category: category,
            isActive: isActive,
            notes: notes.isEmpty ? nil : notes,
            showLast: showLast
        )
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0
    }
}
