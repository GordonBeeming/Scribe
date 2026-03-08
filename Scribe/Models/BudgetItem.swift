import Foundation
import SwiftData

enum ItemType: String, Codable, CaseIterable, Identifiable {
    case income
    case expense

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .income: "Income"
        case .expense: "Expense"
        }
    }
}

enum Frequency: String, Codable, CaseIterable, Identifiable {
    case weekly
    case fortnightly
    case monthly
    case quarterly
    case yearly
    case biYearly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .fortnightly: "Fortnightly"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .yearly: "Yearly"
        case .biYearly: "Bi-Yearly"
        }
    }

    var usesReferenceDate: Bool {
        switch self {
        case .monthly: false
        default: true
        }
    }
}

enum ItemCategory: String, Codable, CaseIterable, Identifiable {
    case income
    case savings
    case housing
    case utilities
    case health
    case kids
    case subscriptions
    case insurance
    case transport
    case donations
    case transfers
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .income: "Income"
        case .savings: "Savings"
        case .housing: "Housing"
        case .utilities: "Utilities"
        case .health: "Health"
        case .kids: "Kids"
        case .subscriptions: "Subscriptions"
        case .insurance: "Insurance"
        case .transport: "Transport"
        case .donations: "Donations"
        case .transfers: "Transfers"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .income: "dollarsign.circle"
        case .savings: "banknote"
        case .housing: "house"
        case .utilities: "bolt"
        case .health: "heart"
        case .kids: "figure.2.and.child.holdinghands"
        case .subscriptions: "repeat"
        case .insurance: "shield"
        case .transport: "car"
        case .donations: "gift"
        case .transfers: "arrow.left.arrow.right"
        case .other: "ellipsis.circle"
        }
    }
}

@Model
final class BudgetItem {
    var id: UUID
    var name: String
    var itemType: String
    var amount: Decimal
    var currencyCode: String
    var frequencyRaw: String
    var dayOfMonth: Int?
    var referenceDate: Date?
    var categoryRaw: String
    var isActive: Bool
    var notes: String?
    var sortOrder: Int
    var showLast: Bool
    var createdAt: Date
    var modifiedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \AmountOverride.budgetItem)
    var amountOverrides: [AmountOverride]

    @Relationship(deleteRule: .cascade, inverse: \Occurrence.budgetItem)
    var occurrences: [Occurrence]

    var familyMembers: [FamilyMember]

    var type: ItemType {
        get { ItemType(rawValue: itemType) ?? .expense }
        set { itemType = newValue.rawValue }
    }

    var frequency: Frequency {
        get { Frequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }

    var category: ItemCategory {
        get { ItemCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    init(
        name: String,
        type: ItemType,
        amount: Decimal,
        currencyCode: String = "AUD",
        frequency: Frequency,
        dayOfMonth: Int? = nil,
        referenceDate: Date? = nil,
        category: ItemCategory,
        isActive: Bool = true,
        notes: String? = nil,
        sortOrder: Int = 0,
        showLast: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.itemType = type.rawValue
        self.amount = amount
        self.currencyCode = currencyCode
        self.frequencyRaw = frequency.rawValue
        self.dayOfMonth = dayOfMonth
        self.referenceDate = referenceDate
        self.categoryRaw = category.rawValue
        self.isActive = isActive
        self.notes = notes
        self.sortOrder = sortOrder
        self.showLast = showLast
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.amountOverrides = []
        self.occurrences = []
        self.familyMembers = []
    }

    func effectiveAmount(on date: Date) -> Decimal {
        let calendar = Calendar.current
        let applicableOverrides = amountOverrides
            .filter { calendar.startOfDay(for: $0.effectiveDate) <= calendar.startOfDay(for: date) }
            .sorted { $0.effectiveDate > $1.effectiveDate }

        return applicableOverrides.first?.amount ?? amount
    }

    func effectiveDayOfMonth(on date: Date) -> Int? {
        let calendar = Calendar.current
        let applicableOverrides = amountOverrides
            .filter { $0.overrideDayOfMonth != nil && calendar.startOfDay(for: $0.effectiveDate) <= calendar.startOfDay(for: date) }
            .sorted { $0.effectiveDate > $1.effectiveDate }

        return applicableOverrides.first?.overrideDayOfMonth ?? dayOfMonth
    }

    func effectiveReferenceDate(on date: Date) -> Date? {
        let calendar = Calendar.current
        let applicableOverrides = amountOverrides
            .filter { $0.overrideReferenceDate != nil && calendar.startOfDay(for: $0.effectiveDate) <= calendar.startOfDay(for: date) }
            .sorted { $0.effectiveDate > $1.effectiveDate }

        return applicableOverrides.first?.overrideReferenceDate ?? referenceDate
    }

    /// All schedule-affecting overrides sorted by effective date.
    var scheduleOverrides: [AmountOverride] {
        amountOverrides
            .filter { $0.overrideDayOfMonth != nil || $0.overrideReferenceDate != nil }
            .sorted { $0.effectiveDate < $1.effectiveDate }
    }
}
