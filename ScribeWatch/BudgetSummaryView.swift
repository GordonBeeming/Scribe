import SwiftUI
import SwiftData

struct BudgetSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<BudgetItem> { $0.isActive }, sort: \BudgetItem.sortOrder)
    private var budgetItems: [BudgetItem]

    @State private var daysAhead = 7

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let summary = computeSummary()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next \(daysAhead) Days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            let net = summary.totalIncome - summary.totalExpenses
                            Text(CurrencyFormatter.format(net, currencyCode: "AUD", signStyle: .automatic))
                                .font(.title3.monospacedDigit().bold())
                                .foregroundStyle(net >= 0 ? .green : .red)
                        }
                        HStack(spacing: 12) {
                            Label(CurrencyFormatter.format(summary.totalIncome, currencyCode: "AUD", signStyle: .none),
                                  systemImage: "arrow.down.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Label(CurrencyFormatter.format(summary.totalExpenses, currencyCode: "AUD", signStyle: .none),
                                  systemImage: "arrow.up.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section("Upcoming") {
                    let upcoming = computeUpcomingItems()
                    if upcoming.isEmpty {
                        Text("No upcoming items")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(upcoming.prefix(10), id: \.id) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Text(item.dueDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(CurrencyFormatter.format(item.amount, currencyCode: item.currencyCode,
                                    signStyle: item.isIncome ? .alwaysPositive : .alwaysNegative))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(item.isIncome ? .green : .red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scribe")
            #if DEBUG
            .toolbar {
                if budgetItems.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Load Demo Data") {
                            DataManagementService.clearAllData(in: modelContext)
                            DemoDataGenerator.generate(in: modelContext)
                        }
                    }
                }
            }
            #endif
        }
    }

    private struct Summary {
        let totalIncome: Decimal
        let totalExpenses: Decimal
    }

    private struct UpcomingItem: Identifiable {
        let id = UUID()
        let name: String
        let amount: Decimal
        let currencyCode: String
        let isIncome: Bool
        let dueDate: Date
    }

    private func computeSummary() -> Summary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let endDate = calendar.date(byAdding: .day, value: daysAhead, to: today) else {
            return Summary(totalIncome: 0, totalExpenses: 0)
        }

        var totalIncome: Decimal = 0
        var totalExpenses: Decimal = 0

        for item in budgetItems {
            let dates = DateCalculator.occurrenceDates(for: item, in: today...endDate)
            for date in dates {
                let amount = item.effectiveAmount(on: date)
                if item.type == .income {
                    totalIncome += amount
                } else {
                    totalExpenses += amount
                }
            }
        }

        return Summary(totalIncome: totalIncome, totalExpenses: totalExpenses)
    }

    private func computeUpcomingItems() -> [UpcomingItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let endDate = calendar.date(byAdding: .day, value: daysAhead, to: today) else { return [] }

        var items: [UpcomingItem] = []
        for item in budgetItems {
            let dates = DateCalculator.occurrenceDates(for: item, in: today...endDate)
            for date in dates {
                items.append(UpcomingItem(
                    name: item.name,
                    amount: item.effectiveAmount(on: date),
                    currencyCode: item.currencyCode,
                    isIncome: item.type == .income,
                    dueDate: date
                ))
            }
        }
        items.sort { $0.dueDate < $1.dueDate }
        return items
    }
}
