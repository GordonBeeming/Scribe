import SwiftUI

struct NextDatePickerSheet: View {
    let itemName: String
    /// Called with the chosen next date, or `nil` if this was a one-time payment with no future occurrence.
    let onSave: (Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nextDate = Date()
    @State private var isOneTime = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("When is the next \(itemName)?")
                        .foregroundStyle(ScribeTheme.secondaryText)
                }
                .scribeSection()

                Section {
                    Toggle("One-time payment (won't occur again)", isOn: $isOneTime)
                }
                .scribeSection()

                if !isOneTime {
                    Section("Next Date") {
                        DatePicker(
                            "Date",
                            selection: $nextDate,
                            in: Date()...,
                            displayedComponents: [.date]
                        )
                    }
                    .scribeSection()
                }
            }
            .scribeScreen()
            .navigationTitle("Schedule Next")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(isOneTime ? nil : nextDate)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
