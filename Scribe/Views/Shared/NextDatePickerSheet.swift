import SwiftUI

struct NextDatePickerSheet: View {
    let itemName: String
    let onSave: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nextDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("When is the next \(itemName)?")
                        .foregroundStyle(ScribeTheme.secondaryText)
                }

                Section("Next Date") {
                    DatePicker(
                        "Date",
                        selection: $nextDate,
                        in: Date()...,
                        displayedComponents: [.date]
                    )
                }
            }
            .navigationTitle("Schedule Next")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(nextDate)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
