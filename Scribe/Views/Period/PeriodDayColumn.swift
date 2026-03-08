import SwiftUI

struct PeriodDayColumn: View {
    let date: Date
    let dayTotal: Decimal
    let runningTotal: Decimal?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isToday ? ScribeTheme.primary : ScribeTheme.primaryText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                AmountText(amount: dayTotal, currencyCode: "AUD")
                    .font(.subheadline.monospacedDigit().weight(.medium))

                if let runningTotal {
                    Text("Running: \(CurrencyFormatter.format(runningTotal, currencyCode: "AUD", signStyle: .automatic))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(ScribeTheme.secondaryText)
                }
            }
        }
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
}
