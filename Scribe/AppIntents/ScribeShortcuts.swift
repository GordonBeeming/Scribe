import AppIntents

/// Natural-language shortcuts for Siri, Spotlight, and the Shortcuts app.
/// Phrases must include `\(.applicationName)`.
struct ScribeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BudgetSummaryIntent(),
            phrases: [
                "What's left in my \(.applicationName) budget",
                "Show my \(.applicationName) summary",
                "How's my \(.applicationName) budget"
            ],
            shortTitle: "Budget Summary",
            systemImageName: "chart.pie.fill"
        )

        AppShortcut(
            intent: UpcomingExpensesIntent(),
            phrases: [
                "What's due in \(.applicationName)",
                "Show upcoming \(.applicationName) expenses"
            ],
            shortTitle: "Upcoming Expenses",
            systemImageName: "clock.fill"
        )

        AppShortcut(
            intent: AddBudgetItemIntent(),
            phrases: [
                "Add an expense to \(.applicationName)",
                "Add a \(.applicationName) item"
            ],
            shortTitle: "Add Item",
            systemImageName: "plus.circle.fill"
        )

        AppShortcut(
            intent: MarkPaidIntent(),
            phrases: [
                "Mark a payment paid in \(.applicationName)"
            ],
            shortTitle: "Mark Paid",
            systemImageName: "checkmark.circle.fill"
        )
    }
}
