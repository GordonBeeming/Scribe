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
    /// whose `amount` actually changed so the caller can push sync updates.
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

        if !changedIDs.isEmpty {
            try? context.save()
        }
        return changedIDs
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

            // Use the earliest known amount as the baseline. If there are no
            // overrides at all, that's just the item's current amount. If there
            // are later overrides, the baseline is whatever the item's amount
            // was before any of them — which is `item.amount` until the first
            // override's effectiveDate has passed.
            let baselineAmount: Decimal
            if let earliest = item.amountOverrides.sorted(by: { $0.effectiveDate < $1.effectiveDate }).first,
               calendar.startOfDay(for: earliest.effectiveDate) <= calendar.startOfDay(for: Date()) {
                // The earliest override has already taken effect, so the
                // current `item.amount` may have already moved on. We can't
                // recover the original from data, so use the current amount as
                // the best available baseline.
                baselineAmount = item.amount
            } else {
                baselineAmount = item.amount
            }

            let baseline = AmountOverride(
                effectiveDate: item.createdAt,
                amount: baselineAmount,
                notes: nil,
                budgetItem: item
            )
            context.insert(baseline)
            inserted.append(baseline.id)
        }

        if !inserted.isEmpty {
            try? context.save()
            for id in inserted {
                SyncCoordinator.shared.pushChange(for: id)
            }
        }
    }
}
