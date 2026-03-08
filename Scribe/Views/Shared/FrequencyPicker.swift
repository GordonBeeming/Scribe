import SwiftUI

struct FrequencyPicker: View {
    @Binding var frequency: Frequency
    @Binding var dayOfMonth: Int?
    @Binding var referenceDate: Date?

    var body: some View {
        Picker("Frequency", selection: $frequency) {
            ForEach(Frequency.allCases) { freq in
                Text(freq.displayName).tag(freq)
            }
        }

        if frequency == .monthly {
            Picker("Day of Month", selection: Binding(
                get: { dayOfMonth ?? 1 },
                set: { dayOfMonth = $0 }
            )) {
                ForEach(1...31, id: \.self) { day in
                    Text("\(day)").tag(day)
                }
            }
        } else {
            DatePicker(
                "Reference Date",
                selection: Binding(
                    get: { referenceDate ?? Date() },
                    set: { referenceDate = $0 }
                ),
                displayedComponents: .date
            )
        }
    }
}
