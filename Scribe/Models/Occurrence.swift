import Foundation
import SwiftData

enum OccurrenceStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case confirmed
    case skipped
    case overdue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .confirmed: "Confirmed"
        case .skipped: "Skipped"
        case .overdue: "Overdue"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: "circle"
        case .confirmed: "checkmark.circle.fill"
        case .skipped: "arrow.uturn.right.circle"
        case .overdue: "exclamationmark.circle"
        }
    }
}

@Model
final class Occurrence {
    var id: UUID
    var dueDate: Date
    var expectedAmount: Decimal
    var actualAmount: Decimal?
    var statusRaw: String
    var confirmedAt: Date?
    var notes: String?
    var budgetItem: BudgetItem?

    var status: OccurrenceStatus {
        get { OccurrenceStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(
        dueDate: Date,
        expectedAmount: Decimal,
        actualAmount: Decimal? = nil,
        status: OccurrenceStatus = .pending,
        confirmedAt: Date? = nil,
        notes: String? = nil,
        budgetItem: BudgetItem? = nil
    ) {
        self.id = UUID()
        self.dueDate = dueDate
        self.expectedAmount = expectedAmount
        self.actualAmount = actualAmount
        self.statusRaw = status.rawValue
        self.confirmedAt = confirmedAt
        self.notes = notes
        self.budgetItem = budgetItem
    }
}
