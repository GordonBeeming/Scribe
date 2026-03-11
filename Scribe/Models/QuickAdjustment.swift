import Foundation
import SwiftData

enum QuickAdjustmentType: String, Codable, CaseIterable, Identifiable {
    case expense
    case income
    case balanceReset

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .expense: "Expense"
        case .income: "Income"
        case .balanceReset: "Balance Reset"
        }
    }

    var systemImage: String {
        switch self {
        case .expense: "arrow.down.circle"
        case .income: "arrow.up.circle"
        case .balanceReset: "arrow.triangle.2.circlepath"
        }
    }
}

@Model
final class QuickAdjustment {
    var id: UUID
    var adjustmentTypeRaw: String
    var date: Date
    var amount: Decimal
    var name: String
    var currencyCode: String
    var notes: String?
    var ckRecordData: Data?
    var createdAt: Date
    var modifiedAt: Date

    var adjustmentType: QuickAdjustmentType {
        get { QuickAdjustmentType(rawValue: adjustmentTypeRaw) ?? .expense }
        set { adjustmentTypeRaw = newValue.rawValue }
    }

    init(
        type: QuickAdjustmentType,
        date: Date,
        amount: Decimal,
        name: String,
        currencyCode: String = "AUD",
        notes: String? = nil
    ) {
        self.id = UUID()
        self.adjustmentTypeRaw = type.rawValue
        self.date = date
        self.amount = amount
        self.name = name
        self.currencyCode = currencyCode
        self.notes = notes
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}
