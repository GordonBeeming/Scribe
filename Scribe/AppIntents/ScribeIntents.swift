import AppIntents
import SwiftData
import Foundation

// MARK: - Add Budget Item

struct AddBudgetItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Budget Item"
    static let description = IntentDescription("Add a recurring income or expense to Scribe.")

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Type")
    var type: BudgetItemTypeAppEnum

    @Parameter(title: "Frequency", default: .monthly)
    var frequency: BudgetFrequencyAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$type) \"\(\.$name)\" of \(\.$amount), \(\.$frequency)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = SharedModelContainer.shared.mainContext
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let model = frequency.model

        let item = BudgetItem(
            name: name,
            type: type.model,
            amount: Decimal(amount),
            frequency: model,
            // Monthly schedules off a day-of-month; everything else off a reference date.
            dayOfMonth: model == .monthly ? calendar.component(.day, from: today) : nil,
            referenceDate: model == .monthly ? nil : today,
            category: type == .income ? .income : .other
        )
        context.insert(item)

        // Seed amount history with a baseline override at creation, matching the form.
        let baseline = AmountOverride(effectiveDate: item.createdAt, amount: item.amount, budgetItem: item)
        context.insert(baseline)

        do {
            try context.save()
        } catch {
            throw IntentError.saveFailed
        }
        SyncCoordinator.shared.pushChange(for: item.id)
        SyncCoordinator.shared.pushChange(for: baseline.id)

        let formatted = CurrencyFormatter.format(item.amount, currencyCode: item.currencyCode)
        return .result(dialog: IntentDialog(stringLiteral: "Added \(name) (\(formatted)) to Scribe."))
    }
}

// MARK: - Mark Paid (confirm next occurrence)

struct MarkPaidIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Payment Paid"
    static let description = IntentDescription("Confirm the next upcoming payment for a Scribe item.")

    @Parameter(title: "Item")
    var item: BudgetItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark the next \(\.$item) payment as paid")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = SharedModelContainer.shared.mainContext
        let allItems = try context.fetch(FetchDescriptor<BudgetItem>())
        guard let model = allItems.first(where: { $0.id == item.id }) else {
            return .result(dialog: "I couldn't find that item in Scribe.")
        }

        let occurrences = try context.fetch(FetchDescriptor<Occurrence>())
        let viewModel = DashboardViewModel()
        let upcoming = viewModel.upcomingItems(budgetItems: [model], occurrences: occurrences, lookbackDays: 7)
        guard let next = upcoming.first(where: { !$0.isConfirmed && !$0.isSkipped }) else {
            return .result(dialog: IntentDialog(stringLiteral: "\(model.name) has nothing due to confirm."))
        }

        let id = OccurrenceMatching.confirm(
            budgetItem: model,
            dueDate: next.dueDate,
            amount: next.amount,
            existingOccurrence: next.occurrence,
            in: context
        )
        SyncCoordinator.shared.pushChange(for: id)

        let verb = model.type == .income ? "received" : "paid"
        return .result(dialog: IntentDialog(stringLiteral: "Marked \(model.name) as \(verb)."))
    }
}

// MARK: - Budget Summary

struct BudgetSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Budget Summary"
    static let description = IntentDescription("See your income, expenses, and net for the next 14 days.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let context = SharedModelContainer.shared.mainContext
        let items = try context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.isActive }))
        let occurrences = try context.fetch(FetchDescriptor<Occurrence>())

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 13, to: today) ?? today

        let viewModel = DashboardViewModel()
        let summary = viewModel.periodSummary(budgetItems: items, occurrences: occurrences, start: today, end: end)
        let net = summary.income - summary.expenses

        let incomeText = CurrencyFormatter.format(summary.income, currencyCode: "AUD")
        let expenseText = CurrencyFormatter.format(summary.expenses, currencyCode: "AUD")
        let netText = CurrencyFormatter.format(net, currencyCode: "AUD", signStyle: .automatic)
        let dialog = "Over the next 14 days: \(incomeText) in, \(expenseText) out, net \(netText)."

        return .result(
            dialog: IntentDialog(stringLiteral: dialog),
            view: BudgetSummarySnippet(income: summary.income, expenses: summary.expenses, net: net)
        )
    }
}

// MARK: - Upcoming Expenses

struct UpcomingExpensesIntent: AppIntent {
    static let title: LocalizedStringResource = "Upcoming Expenses"
    static let description = IntentDescription("See which expenses are due soon in Scribe.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let context = SharedModelContainer.shared.mainContext
        let items = try context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.isActive }))
        let occurrences = try context.fetch(FetchDescriptor<Occurrence>())

        let viewModel = DashboardViewModel()
        let upcoming = viewModel.upcomingItems(budgetItems: items, occurrences: occurrences)
        let dueExpenses = upcoming
            .filter { $0.budgetItem.type == .expense && !$0.isConfirmed && !$0.isSkipped }
            .prefix(5)

        let rows = dueExpenses.map {
            UpcomingExpensesSnippet.Row(
                id: $0.id,
                name: $0.budgetItem.name,
                dueDate: $0.dueDate,
                amount: $0.amount,
                currencyCode: $0.budgetItem.currencyCode
            )
        }

        let total = dueExpenses.reduce(Decimal(0)) { $0 + $1.amount }
        let dialog: String
        if dueExpenses.isEmpty {
            dialog = "You have nothing due soon in Scribe."
        } else {
            let totalText = CurrencyFormatter.format(total, currencyCode: "AUD")
            dialog = "You have \(dueExpenses.count) expense\(dueExpenses.count == 1 ? "" : "s") due soon totalling \(totalText)."
        }

        return .result(
            dialog: IntentDialog(stringLiteral: dialog),
            view: UpcomingExpensesSnippet(rows: rows)
        )
    }
}

// MARK: - Errors

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case saveFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .saveFailed: "Couldn't save to Scribe. Please try again."
        }
    }
}
