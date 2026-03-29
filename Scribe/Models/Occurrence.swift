import Foundation
import SwiftData
import CryptoKit

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
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var ckRecordData: Data?
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
        if let budgetItem {
            self.id = Occurrence.deterministicID(budgetItemID: budgetItem.id, dueDate: dueDate)
        } else {
            self.id = UUID()
        }
        self.dueDate = dueDate
        self.expectedAmount = expectedAmount
        self.actualAmount = actualAmount
        self.statusRaw = status.rawValue
        self.confirmedAt = confirmedAt
        self.notes = notes
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.budgetItem = budgetItem
    }

    /// Generate a deterministic UUID from a budget item ID and due date.
    /// Ensures all devices produce the same Occurrence ID for the same item+date,
    /// preventing duplicate Occurrences when multiple devices auto-confirm or manually confirm.
    static func deterministicID(budgetItemID: UUID, dueDate: Date) -> UUID {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: dueDate)
        let input = "\(budgetItemID.uuidString)_\(Int(startOfDay.timeIntervalSince1970))"
        let hash = SHA256.hash(data: Data(input.utf8))
        let bytes = Array(hash)
        // Build UUID from first 16 bytes of SHA-256, setting version 5 and variant bits
        var uuidBytes = Array(bytes.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50 // version 5
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80 // variant 1
        let uuid = uuidBytes.withUnsafeBufferPointer { buffer -> UUID in
            buffer.baseAddress!.withMemoryRebound(to: uuid_t.self, capacity: 1) { UUID(uuid: $0.pointee) }
        }
        return uuid
    }
}
