import Foundation
import SwiftData

struct ScribeExport: Codable {
    let exportDate: Date
    let appVersion: String
    let familyMembers: [CodableFamilyMember]
    let budgetItems: [CodableBudgetItem]
    let amountOverrides: [CodableAmountOverride]
    let occurrences: [CodableOccurrence]
    let dashboardSections: [CodableDashboardSection]?
    let quickAdjustments: [CodableQuickAdjustment]?
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
    let budgetReflectionRaw: String?
    let payDayAdjustmentDays: String?
    let publicHolidayCountryCode: String?

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
        self.budgetReflectionRaw = item.budgetReflectionRaw
        self.payDayAdjustmentDays = item.payDayAdjustmentDays
        self.publicHolidayCountryCode = item.publicHolidayCountryCode
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
        item.budgetReflectionRaw = budgetReflectionRaw
        item.payDayAdjustmentDays = payDayAdjustmentDays
        item.publicHolidayCountryCode = publicHolidayCountryCode
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

struct CodableDashboardSection: Codable {
    let id: UUID
    let sectionTypeRaw: String
    let anchorRaw: String
    let isEnabled: Bool
    let sortOrder: Int
    let label: String
    let createdAt: Date
    let modifiedAt: Date

    init(from section: DashboardSection) {
        self.id = section.id
        self.sectionTypeRaw = section.sectionTypeRaw
        self.anchorRaw = section.anchorRaw
        self.isEnabled = section.isEnabled
        self.sortOrder = section.sortOrder
        self.label = section.label
        self.createdAt = section.createdAt
        self.modifiedAt = section.modifiedAt
    }

    @MainActor
    func toModel() -> DashboardSection {
        let section = DashboardSection(
            sectionType: DashboardSectionType(rawValue: sectionTypeRaw) ?? .detailedWeekly,
            anchor: {
                if let data = anchorRaw.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(DashboardSectionAnchor.self, from: data) {
                    return decoded
                }
                return .fixedDay(weekday: 2)
            }(),
            isEnabled: isEnabled,
            sortOrder: sortOrder,
            label: label
        )
        section.id = id
        section.createdAt = createdAt
        section.modifiedAt = modifiedAt
        return section
    }
}

struct CodableQuickAdjustment: Codable {
    let id: UUID
    let adjustmentTypeRaw: String
    let date: Date
    let amount: Decimal
    let name: String
    let currencyCode: String
    let notes: String?
    let createdAt: Date
    let modifiedAt: Date

    init(from adjustment: QuickAdjustment) {
        self.id = adjustment.id
        self.adjustmentTypeRaw = adjustment.adjustmentTypeRaw
        self.date = adjustment.date
        self.amount = adjustment.amount
        self.name = adjustment.name
        self.currencyCode = adjustment.currencyCode
        self.notes = adjustment.notes
        self.createdAt = adjustment.createdAt
        self.modifiedAt = adjustment.modifiedAt
    }

    @MainActor
    func toModel() -> QuickAdjustment {
        let adjustment = QuickAdjustment(
            type: QuickAdjustmentType(rawValue: adjustmentTypeRaw) ?? .expense,
            date: date,
            amount: amount,
            name: name,
            currencyCode: currencyCode,
            notes: notes
        )
        adjustment.id = id
        adjustment.createdAt = createdAt
        adjustment.modifiedAt = modifiedAt
        return adjustment
    }
}
