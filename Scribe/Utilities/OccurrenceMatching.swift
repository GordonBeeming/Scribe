import Foundation
import SwiftData

/// Centralized occurrence matching and mutation logic.
/// Keeps all occurrence find/confirm/skip/adjust in one place so Dashboard,
/// Period, and any future views share identical behavior.
///
/// Mutation methods return the affected occurrence ID so callers can push
/// sync changes. SyncCoordinator is NOT referenced here — this file is
/// compiled into widget and watch targets that don't include CloudKit.
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

    /// Confirm an occurrence, creating one if needed. Returns the ID to sync.
    @MainActor
    @discardableResult
    static func confirm(
        budgetItem: BudgetItem,
        dueDate: Date,
        amount: Decimal,
        existingOccurrence: Occurrence?,
        in context: ModelContext
    ) -> UUID {
        if let existing = existingOccurrence {
            existing.status = .confirmed
            existing.confirmedAt = Date()
            existing.modifiedAt = Date()
            try? context.save()
            return existing.id
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
            return occurrence.id
        }
    }

    /// Undo a confirmed occurrence back to pending. Returns the ID to sync.
    @MainActor
    @discardableResult
    static func undoConfirm(
        occurrence: Occurrence,
        in context: ModelContext
    ) -> UUID {
        occurrence.status = .pending
        occurrence.confirmedAt = nil
        occurrence.actualAmount = nil
        occurrence.modifiedAt = Date()
        try? context.save()
        return occurrence.id
    }

    /// Skip or unskip an occurrence. Returns the ID to sync.
    @MainActor
    @discardableResult
    static func toggleSkip(
        budgetItem: BudgetItem,
        dueDate: Date,
        amount: Decimal,
        existingOccurrence: Occurrence?,
        in context: ModelContext
    ) -> UUID {
        if let existing = existingOccurrence, existing.status == .skipped {
            existing.status = .pending
            existing.modifiedAt = Date()
            try? context.save()
            return existing.id
        } else if let existing = existingOccurrence {
            existing.status = .skipped
            existing.modifiedAt = Date()
            try? context.save()
            return existing.id
        } else {
            let occurrence = Occurrence(
                dueDate: dueDate,
                expectedAmount: amount,
                status: .skipped,
                budgetItem: budgetItem
            )
            context.insert(occurrence)
            try? context.save()
            return occurrence.id
        }
    }

    /// Adjust the actual amount on a confirmed occurrence. Returns the ID to sync.
    @MainActor
    @discardableResult
    static func adjustAmount(
        occurrence: Occurrence,
        newAmount: Decimal,
        in context: ModelContext
    ) -> UUID {
        occurrence.actualAmount = newAmount
        occurrence.modifiedAt = Date()
        try? context.save()
        return occurrence.id
    }
}
