import SwiftUI

struct CountryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCode: String?
    @State private var countries: [AvailableCountry] = []
    @State private var searchText = ""
    @State private var isLoading = true

    private var filteredCountries: [AvailableCountry] {
        if searchText.isEmpty {
            return countries
        }
        let query = searchText.lowercased()
        return countries.filter {
            $0.name.lowercased().contains(query) ||
            $0.countryCode.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            Button {
                selectedCode = nil
                dismiss()
            } label: {
                HStack {
                    Text("None")
                    Spacer()
                    if selectedCode == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .foregroundStyle(.primary)

            if isLoading {
                ProgressView("Loading countries...")
            } else {
                ForEach(filteredCountries) { country in
                    Button {
                        selectedCode = country.countryCode
                        dismiss()
                    } label: {
                        HStack {
                            Text("\(country.name) (\(country.countryCode))")
                            Spacer()
                            if selectedCode == country.countryCode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle("Holiday Country")
        .searchable(text: $searchText, prompt: "Search countries")
        .task {
            let fetched = await HolidayService.shared.availableCountries()
            countries = fetched.sorted { $0.name < $1.name }
            isLoading = false
        }
    }
}
