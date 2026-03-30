import SwiftUI

struct BudgetItemRowView: View {
    let item: BudgetItem

    private var scheduleDetail: String? {
        switch item.frequency {
        case .weekly:
            // "Thursdays"
            if let ref = item.referenceDate {
                let weekday = Calendar.current.component(.weekday, from: ref)
                return Calendar.current.weekdaySymbols[weekday - 1] + "s"
            }
            return nil
        case .fortnightly:
            // "Thursdays" (same weekday, just every 2 weeks)
            if let ref = item.referenceDate {
                let weekday = Calendar.current.component(.weekday, from: ref)
                return Calendar.current.weekdaySymbols[weekday - 1] + "s"
            }
            return nil
        case .monthly:
            // "15th"
            if let day = item.dayOfMonth {
                return dayOrdinal(day)
            }
            return nil
        case .quarterly, .biYearly:
            // "15 Mar" — day + month of next occurrence
            if let ref = item.referenceDate {
                let formatter = DateFormatter()
                formatter.dateFormat = "d MMM"
                return formatter.string(from: ref)
            }
            if let day = item.dayOfMonth { return dayOrdinal(day) }
            return nil
        case .yearly:
            // "15 Mar"
            if let ref = item.referenceDate {
                let formatter = DateFormatter()
                formatter.dateFormat = "d MMM"
                return formatter.string(from: ref)
            }
            if let day = item.dayOfMonth { return dayOrdinal(day) }
            return nil
        case .irregular:
            // "Next: 15 Mar"
            if let ref = item.referenceDate {
                let formatter = DateFormatter()
                formatter.dateFormat = "d MMM"
                return "Next: " + formatter.string(from: ref)
            }
            return nil
        }
    }

    private func dayOrdinal(_ day: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: day)) ?? "\(day)"
    }

    var body: some View {
        HStack {
            Image(systemName: item.category.systemImage)
                .foregroundStyle(ScribeTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.name)
                        .font(.body)
                    if let endDate = item.endDate {
                        Text("Closed \(endDate, format: .dateTime.day().month())")
                            .font(.caption2)
                            .foregroundStyle(ScribeTheme.error)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    } else if !item.isActive {
                        Text("Paused")
                            .font(.caption2)
                            .foregroundStyle(ScribeTheme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Text(item.frequency.displayName)
                    if let schedule = scheduleDetail {
                        Text("· \(schedule)")
                    }
                }
                .font(.caption)
                .foregroundStyle(ScribeTheme.secondaryText)
            }

            Spacer()

            AmountText(
                amount: item.amount,
                currencyCode: item.currencyCode,
                type: item.type
            )
            .font(.body.monospacedDigit())
        }
        .opacity(item.isActive && item.endDate == nil ? 1.0 : 0.6)
    }
}
