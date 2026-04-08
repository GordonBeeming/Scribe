import Foundation
import SwiftData

/// Keeps `BudgetItem.amount` in sync with the most recent applicable
/// `AmountOverride` (an override whose `effectiveDate` is on or before today).
///
/// `BudgetItem.amount` is treated as the "current effective amount" — when an
/// override's effective date arrives, the item's headline amount should follow.
/// The full history (including the original amount seeded at create time) lives
/// in `amountOverrides`.
enum BudgetItemAmountRefresher {

    /// Refresh every `BudgetItem` in the given context. Returns the IDs of items
    /// whose `amount` actually changed AND were successfully persisted, so the
    /// caller can push sync updates only for records that actually made it to
    /// disk.
    @discardableResult
    static func refreshAll(in context: ModelContext, on date: Date = Date()) -> [UUID] {
        let descriptor = FetchDescriptor<BudgetItem>()
        guard let items = try? context.fetch(descriptor) else { return [] }

        var changedIDs: [UUID] = []
        for item in items {
            if refresh(item, on: date) {
                changedIDs.append(item.id)
            }
        }

        guard !changedIDs.isEmpty else { return [] }
        do {
            try context.save()
            return changedIDs
        } catch {
            print("BudgetItemAmountRefresher.refreshAll: save failed: \(error)")
            return []
        }
    }

    /// Refresh a single item. Returns `true` if `item.amount` changed.
    @discardableResult
    static func refresh(_ item: BudgetItem, on date: Date = Date()) -> Bool {
        let effective = item.effectiveAmount(on: date)
        guard effective != item.amount else { return false }
        item.amount = effective
        item.modifiedAt = Date()
        return true
    }

    /// Ensures every existing item has an `AmountOverride` covering its
    /// historical baseline (effective from `createdAt`). Safe to run repeatedly:
    /// items that already have an override at or before `createdAt` are skipped.
    ///
    /// Run once per launch as a backfill for items created before amount history
    /// was tracked from day one.
    static func backfillBaselineOverrides(in context: ModelContext) {
        let descriptor = FetchDescriptor<BudgetItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        let calendar = Calendar.current
        var inserted: [UUID] = []

        for item in items {
            let createdDay = calendar.startOfDay(for: item.createdAt)
            let hasBaseline = item.amountOverrides.contains { override_ in
                calendar.startOfDay(for: override_.effectiveDate) <= createdDay
            }
            if hasBaseline { continue }

            // We can't reliably reconstruct the original pre-override amount
            // from current data, so use the item's current amount as the best
            // available baseline for the backfilled override.
            let baselineAmount = item.amount

            let baseline = AmountOverride(
                effectiveDate: item.createdAt,
                amount: baselineAmount,
                notes: nil,
                budgetItem: item
            )
            context.insert(baseline)
            inserted.append(baseline.id)
        }

        guard !inserted.isEmpty else { return }
        do {
            try context.save()
            for id in inserted {
                SyncCoordinator.shared.pushChange(for: id)
            }
        } catch {
            print("BudgetItemAmountRefresher.backfillBaselineOverrides: save failed: \(error)")
        }
    }
}
