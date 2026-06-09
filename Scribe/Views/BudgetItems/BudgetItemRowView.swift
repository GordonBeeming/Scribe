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

    private var avatarTint: Color {
        item.type == .income ? ScribeTheme.success : ScribeTheme.primary
    }

    var body: some View {
        HStack(spacing: ScribeDesign.Spacing.m) {
            ZStack {
                Circle()
                    .fill(avatarTint.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: item.category.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(avatarTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ScribeDesign.Spacing.s) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(ScribeTheme.primaryText)
                        .lineLimit(1)
                    if let endDate = item.endDate {
                        statusBadge("Closed \(endDate.formatted(.dateTime.day().month()))", color: ScribeTheme.error)
                    } else if !item.isActive {
                        statusBadge("Paused", color: ScribeTheme.secondaryText)
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
                .lineLimit(1)
            }

            Spacer(minLength: ScribeDesign.Spacing.s)

            MoneyText(
                amount: item.amount,
                currencyCode: item.currencyCode,
                type: item.type,
                emphasis: .money
            )
        }
        .opacity(item.isActive && item.endDate == nil ? 1.0 : 0.55)
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
    }
}
