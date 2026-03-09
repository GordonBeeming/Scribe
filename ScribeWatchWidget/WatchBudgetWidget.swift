import WidgetKit
import SwiftUI
import SwiftData

struct WatchBudgetWidget: Widget {
    let kind: String = "WatchBudgetWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchBudgetProvider()) { entry in
            WatchBudgetWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Budget Summary")
        .description("See your upcoming budget at a glance.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}

// MARK: - Entry

struct WatchBudgetEntry: TimelineEntry {
    let date: Date
    let itemCount: Int
    let net: Decimal
    let nextItemName: String?
    let nextItemAmount: Decimal?
    let nextItemIsIncome: Bool
}

// MARK: - Provider

struct WatchBudgetProvider: TimelineProvider {
    private static let appGroupID = "group.com.gordonbeeming.scribe"

    private var sharedStoreURL: URL {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return containerURL.appendingPathComponent("Scribe.store")
    }

    func placeholder(in context: Context) -> WatchBudgetEntry {
        WatchBudgetEntry(date: Date(), itemCount: 5, net: 1200, nextItemName: "Rent", nextItemAmount: 2400, nextItemIsIncome: false)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (WatchBudgetEntry) -> Void) {
        Task { @MainActor in
            completion(generateEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<WatchBudgetEntry>) -> Void) {
        Task { @MainActor in
            let entry = generateEntry()
            let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }

    @MainActor
    private func generateEntry() -> WatchBudgetEntry {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let endDate = calendar.date(byAdding: .day, value: 7, to: today) else {
            return WatchBudgetEntry(date: Date(), itemCount: 0, net: 0, nextItemName: nil, nextItemAmount: nil, nextItemIsIncome: false)
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
            let items = try context.fetch(FetchDescriptor<BudgetItem>(predicate: predicate))

            var totalIncome: Decimal = 0
            var totalExpenses: Decimal = 0
            var itemCount = 0

            struct Upcoming {
                let name: String
                let amount: Decimal
                let isIncome: Bool
                let dueDate: Date
            }
            var upcoming: [Upcoming] = []

            for item in items {
                let dates = DateCalculator.occurrenceDates(for: item, in: today...endDate)
                for date in dates {
                    let amount = item.effectiveAmount(on: date)
                    itemCount += 1
                    if item.type == .income {
                        totalIncome += amount
                    } else {
                        totalExpenses += amount
                    }
                    upcoming.append(Upcoming(name: item.name, amount: amount, isIncome: item.type == .income, dueDate: date))
                }
            }

            upcoming.sort { $0.dueDate < $1.dueDate }
            let next = upcoming.first

            return WatchBudgetEntry(
                date: Date(),
                itemCount: itemCount,
                net: totalIncome - totalExpenses,
                nextItemName: next?.name,
                nextItemAmount: next?.amount,
                nextItemIsIncome: next?.isIncome ?? false
            )
        } catch {
            return WatchBudgetEntry(date: Date(), itemCount: 0, net: 0, nextItemName: nil, nextItemAmount: nil, nextItemIsIncome: false)
        }
    }
}

// MARK: - Views

struct WatchBudgetWidgetView: View {
    let entry: WatchBudgetEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        case .accessoryInline:
            inlineView
        case .accessoryCorner:
            cornerView
        default:
            circularView
        }
    }

    private var circularView: some View {
        VStack(spacing: 1) {
            Image(systemName: "dollarsign.circle")
                .font(.caption)
            Text("\(entry.itemCount)")
                .font(.title3.bold())
            Text("items")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "dollarsign.circle")
                Text("Scribe")
                    .font(.caption.bold())
                Spacer()
                Text(CurrencyFormatter.format(entry.net, currencyCode: "AUD", signStyle: .automatic))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(entry.net >= 0 ? .green : .red)
            }
            if let name = entry.nextItemName, let amount = entry.nextItemAmount {
                HStack {
                    Text("Next: \(name)")
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                    Text(CurrencyFormatter.format(amount, currencyCode: "AUD", signStyle: entry.nextItemIsIncome ? .alwaysPositive : .alwaysNegative))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(entry.nextItemIsIncome ? .green : .red)
                }
            } else {
                Text("No upcoming items")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inlineView: some View {
        let netFormatted = CurrencyFormatter.format(entry.net, currencyCode: "AUD", signStyle: .automatic)
        return Text("\(entry.itemCount) items \(netFormatted)")
    }

    private var cornerView: some View {
        VStack {
            Text(CurrencyFormatter.format(entry.net, currencyCode: "AUD", signStyle: .automatic))
                .font(.caption.monospacedDigit())
                .foregroundStyle(entry.net >= 0 ? .green : .red)
        }
        .widgetLabel {
            Text("Budget")
        }
    }
}
