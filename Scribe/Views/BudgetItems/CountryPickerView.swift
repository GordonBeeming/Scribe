import SwiftUI

struct CountryPickerView: View {
    @State private var localSelection: String?
    var onSelect: (String?) -> Void
    @State private var countries: [AvailableCountry] = []
    @State private var searchText = ""
    @State private var isLoading = true

    init(selectedCode: String?, onSelect: @escaping (String?) -> Void) {
        self._localSelection = State(initialValue: selectedCode)
        self.onSelect = onSelect
    }

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
                localSelection = nil
                onSelect(nil)
            } label: {
                HStack {
                    Text("None")
                    Spacer()
                    if localSelection == nil {
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
                        localSelection = country.countryCode
                        onSelect(country.countryCode)
                    } label: {
                        HStack {
                            Text("\(country.name) (\(country.countryCode))")
                            Spacer()
                            if localSelection == country.countryCode {
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
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search countries")
        .task {
            let fetched = await HolidayService.shared.availableCountries()
            countries = fetched.sorted { $0.name < $1.name }
            isLoading = false
        }
    }
}
