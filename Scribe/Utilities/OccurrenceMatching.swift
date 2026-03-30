import Foundation
import SwiftData

/// Centralized occurrence matching and confirmation logic.
/// Prevents duplicate implementations across Dashboard, Period, and other views.
enum OccurrenceMatching {

    /// Find an existing occurrence for a budget item, matching against both the scheduled
    /// date and the display date. Occurrences may have been created with either date
    /// depending on which view confirmed them.
    static func findOccurrence(
        for budgetItem: BudgetItem,
        scheduledDate: Date,
        displayDate: Date,
        in occurrences: [Occurrence]
    ) -> Occurrence? {
        let calendar = Calendar.current
        return occurrences.first {
            $0.budgetItem?.id == budgetItem.id &&
            (calendar.isDate($0.dueDate, inSameDayAs: scheduledDate) ||
             calendar.isDate($0.dueDate, inSameDayAs: displayDate))
        }
    }

    /// Confirm an occurrence, creating one if needed.
    @MainActor
    static func confirm(
        budgetItem: BudgetItem,
        dueDate: Date,
        amount: Decimal,
        existingOccurrence: Occurrence?,
        in context: ModelContext
    ) {
        if let existing = existingOccurrence {
            existing.status = .confirmed
            existing.confirmedAt = Date()
            existing.modifiedAt = Date()
            try? context.save()
            SyncCoordinator.shared.pushChange(for: existing.id)
        } else {
            let occurrence = Occurrence(
                dueDate: dueDate,
                expectedAmount: amount,
                status: .confirmed,
                confirmedAt: Date(),
                budgetItem: budgetItem
            )
            context.insert(occurrence)
            try? context.save()
            SyncCoordinator.shared.pushChange(for: occurrence.id)
        }
    }

    /// Undo a confirmed occurrence back to pending.
    @MainActor
    static func undoConfirm(
        occurrence: Occurrence,
        in context: ModelContext
    ) {
        occurrence.status = .pending
        occurrence.confirmedAt = nil
        occurrence.actualAmount = nil
        occurrence.modifiedAt = Date()
        try? context.save()
        SyncCoordinator.shared.pushChange(for: occurrence.id)
    }

    /// Skip or unskip an occurrence.
    @MainActor
    static func toggleSkip(
        budgetItem: BudgetItem,
        dueDate: Date,
        amount: Decimal,
        existingOccurrence: Occurrence?,
        in context: ModelContext
    ) {
        if let existing = existingOccurrence, existing.status == .skipped {
            existing.status = .pending
            existing.modifiedAt = Date()
            try? context.save()
            SyncCoordinator.shared.pushChange(for: existing.id)
        } else if let existing = existingOccurrence {
            existing.status = .skipped
            existing.modifiedAt = Date()
            try? context.save()
            SyncCoordinator.shared.pushChange(for: existing.id)
        } else {
            let occurrence = Occurrence(
                dueDate: dueDate,
                expectedAmount: amount,
                status: .skipped,
                budgetItem: budgetItem
            )
            context.insert(occurrence)
            try? context.save()
            SyncCoordinator.shared.pushChange(for: occurrence.id)
        }
    }

    /// Adjust the actual amount on a confirmed occurrence.
    @MainActor
    static func adjustAmount(
        occurrence: Occurrence,
        newAmount: Decimal,
        in context: ModelContext
    ) {
        occurrence.actualAmount = newAmount
        occurrence.modifiedAt = Date()
        try? context.save()
        SyncCoordinator.shared.pushChange(for: occurrence.id)
    }
}
