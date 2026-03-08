import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

struct UpcomingExpensesWidget: Widget {
    let kind: String = "UpcomingExpensesWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: UpcomingExpensesIntent.self,
            provider: UpcomingExpensesProvider()
        ) { entry in
            UpcomingExpensesWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Upcoming Expenses")
        .description("See your upcoming budget items at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Intent

struct UpcomingExpensesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Upcoming Expenses"
    static let description: IntentDescription = "Configure the upcoming expenses widget."

    @Parameter(title: "Days Ahead", default: 7)
    var daysAhead: Int
}

// MARK: - Entry

struct UpcomingExpensesEntry: TimelineEntry {
    let date: Date
    let daysAhead: Int
    let items: [WidgetExpenseItem]
    let totalExpenses: Decimal
    let totalIncome: Decimal
}

struct WidgetExpenseItem: Identifiable {
    let id = UUID()
    let name: String
    let amount: Decimal
    let currencyCode: String
    let isIncome: Bool
    let dueDate: Date
}

// MARK: - Provider

struct UpcomingExpensesProvider: AppIntentTimelineProvider {
    private static let appGroupID = "group.com.gordonbeeming.scribe"

    private var sharedStoreURL: URL {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return containerURL.appendingPathComponent("Scribe.store")
    }

    func placeholder(in context: Context) -> UpcomingExpensesEntry {
        UpcomingExpensesEntry(
            date: Date(),
            daysAhead: 7,
            items: [
                WidgetExpenseItem(name: "Rent", amount: 750, currencyCode: "AUD", isIncome: false, dueDate: Date()),
                WidgetExpenseItem(name: "Salary", amount: 4150, currencyCode: "AUD", isIncome: true, dueDate: Date()),
            ],
            totalExpenses: 750,
            totalIncome: 4150
        )
    }

    func snapshot(for configuration: UpcomingExpensesIntent, in context: Context) async -> UpcomingExpensesEntry {
        await generateEntry(daysAhead: configuration.daysAhead)
    }

    func timeline(for configuration: UpcomingExpensesIntent, in context: Context) async -> Timeline<UpcomingExpensesEntry> {
        let entry = await generateEntry(daysAhead: configuration.daysAhead)
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private static let fallbackEntry = UpcomingExpensesEntry(
        date: Date(), daysAhead: 7, items: [], totalExpenses: 0, totalIncome: 0
    )

    @MainActor
    private func generateEntry(daysAhead: Int) -> UpcomingExpensesEntry {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let endDate = calendar.date(byAdding: .day, value: daysAhead, to: today) else {
            return Self.fallbackEntry
        }

        do {
            let schema = Schema([
                BudgetItem.self,
                AmountOverride.self,
                Occurrence.self,
                FamilyMember.self,
            ])
            let config = ModelConfiguration("Scribe", schema: schema, url: sharedStoreURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = container.mainContext

            let predicate = #Predicate<BudgetItem> { $0.isActive }
            let budgetItems = try context.fetch(FetchDescriptor<BudgetItem>(predicate: predicate))

            var widgetItems: [WidgetExpenseItem] = []
            var totalIncome: Decimal = 0
            var totalExpenses: Decimal = 0

            for item in budgetItems {
                let dates = DateCalculator.occurrenceDates(for: item, in: today...endDate)
                for date in dates {
                    let amount = item.effectiveAmount(on: date)
                    widgetItems.append(WidgetExpenseItem(
                        name: item.name,
                        amount: amount,
                        currencyCode: item.currencyCode,
                        isIncome: item.type == .income,
                        dueDate: date
                    ))
                    if item.type == .income {
                        totalIncome += amount
                    } else {
                        totalExpenses += amount
                    }
                }
            }

            widgetItems.sort { $0.dueDate < $1.dueDate }

            return UpcomingExpensesEntry(
                date: Date(),
                daysAhead: daysAhead,
                items: widgetItems,
                totalExpenses: totalExpenses,
                totalIncome: totalIncome
            )
        } catch {
            return Self.fallbackEntry
        }
    }
}

// MARK: - View

struct UpcomingExpensesWidgetView: View {
    let entry: UpcomingExpensesEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .systemMedium:
            mediumView
        case .systemLarge:
            largeView
        default:
            smallView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(entry.items.count)")
                .font(.system(size: 36, weight: .bold, design: .rounded))

            Text("items in \(entry.daysAhead) days")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            let net = entry.totalIncome - entry.totalExpenses
            Text(CurrencyFormatter.format(net, currencyCode: "AUD", signStyle: .automatic))
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(net >= 0 ? .green : .red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Upcoming \(entry.daysAhead) Days")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                let net = entry.totalIncome - entry.totalExpenses
                Text(CurrencyFormatter.format(net, currencyCode: "AUD", signStyle: .automatic))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(net >= 0 ? .green : .red)
            }

            if entry.items.isEmpty {
                Text("No upcoming items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(entry.items.prefix(4)) { item in
                    HStack {
                        Text(item.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text(CurrencyFormatter.format(item.amount, currencyCode: item.currencyCode, signStyle: item.isIncome ? .alwaysPositive : .alwaysNegative))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(item.isIncome ? .green : .red)
                    }
                }
            }
        }
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Upcoming \(entry.daysAhead) Days")
                    .font(.headline)
                Spacer()
                let net = entry.totalIncome - entry.totalExpenses
                Text(CurrencyFormatter.format(net, currencyCode: "AUD", signStyle: .automatic))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(net >= 0 ? .green : .red)
            }

            Divider()

            if entry.items.isEmpty {
                Spacer()
                Text("No upcoming items.\nAdd budget items in the app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(entry.items.prefix(8)) { item in
                    HStack {
                        Text(item.dueDate, format: .dateTime.weekday(.abbreviated).day())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        Text(item.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text(CurrencyFormatter.format(item.amount, currencyCode: item.currencyCode, signStyle: item.isIncome ? .alwaysPositive : .alwaysNegative))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(item.isIncome ? .green : .red)
                    }
                }
                Spacer()
            }
        }
    }
}

#Preview(as: .systemMedium) {
    UpcomingExpensesWidget()
} timeline: {
    UpcomingExpensesEntry(
        date: Date(),
        daysAhead: 7,
        items: [
            WidgetExpenseItem(name: "Rent", amount: 750, currencyCode: "AUD", isIncome: false, dueDate: Date()),
            WidgetExpenseItem(name: "Gordon Salary", amount: 8300, currencyCode: "AUD", isIncome: true, dueDate: Date()),
            WidgetExpenseItem(name: "Aussie Broadband", amount: 150, currencyCode: "AUD", isIncome: false, dueDate: Date()),
        ],
        totalExpenses: 900,
        totalIncome: 8300
    )
}
