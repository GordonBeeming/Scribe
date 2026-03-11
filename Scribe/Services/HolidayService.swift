import Foundation

struct PublicHoliday: Codable, Sendable {
    let date: String
    let localName: String
    let name: String
    let countryCode: String
}

struct AvailableCountry: Codable, Sendable, Identifiable {
    let countryCode: String
    let name: String
    var id: String { countryCode }
}

actor HolidayService {
    static let shared = HolidayService()

    private let cacheTTL: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    private let defaults = UserDefaults(suiteName: "group.com.gordonbeeming.scribe")

    private var inMemoryCache: [String: Set<String>] = [:] // "ZA_2026" -> set of "2026-03-21"

    func isPublicHoliday(_ date: Date, countryCode: String) async -> Bool {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let dateString = formatDate(date)

        let cacheKey = "\(countryCode)_\(year)"
        if let cached = inMemoryCache[cacheKey] {
            return cached.contains(dateString)
        }

        // Try disk cache
        if let dates = loadFromDisk(countryCode: countryCode, year: year) {
            inMemoryCache[cacheKey] = dates
            return dates.contains(dateString)
        }

        // Fetch from API
        let dates = await fetchHolidays(year: year, countryCode: countryCode)
        inMemoryCache[cacheKey] = dates
        saveToDisk(dates: dates, countryCode: countryCode, year: year)
        return dates.contains(dateString)
    }

    func holidayDates(for countryCode: String, year: Int) async -> Set<Date> {
        let cacheKey = "\(countryCode)_\(year)"

        let dateStrings: Set<String>
        if let cached = inMemoryCache[cacheKey] {
            dateStrings = cached
        } else if let diskCached = loadFromDisk(countryCode: countryCode, year: year) {
            inMemoryCache[cacheKey] = diskCached
            dateStrings = diskCached
        } else {
            let fetched = await fetchHolidays(year: year, countryCode: countryCode)
            inMemoryCache[cacheKey] = fetched
            saveToDisk(dates: fetched, countryCode: countryCode, year: year)
            dateStrings = fetched
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current

        var result: Set<Date> = []
        for str in dateStrings {
            if let date = formatter.date(from: str) {
                result.insert(Calendar.current.startOfDay(for: date))
            }
        }
        return result
    }

    private var cachedCountries: [AvailableCountry]?

    func availableCountries() async -> [AvailableCountry] {
        if let cached = cachedCountries {
            return cached
        }

        // Try disk cache
        let key = "available_countries"
        let tsKey = "available_countries_ts"
        if let data = defaults?.data(forKey: key),
           let timestamp = defaults?.object(forKey: tsKey) as? Date,
           Date().timeIntervalSince(timestamp) < cacheTTL,
           let countries = try? JSONDecoder().decode([AvailableCountry].self, from: data) {
            cachedCountries = countries
            return countries
        }

        // Fetch from API
        guard let url = URL(string: "https://date.nager.at/api/v3/AvailableCountries") else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return [] }
            let countries = try JSONDecoder().decode([AvailableCountry].self, from: data)
            cachedCountries = countries
            defaults?.set(data, forKey: key)
            defaults?.set(Date(), forKey: tsKey)
            return countries
        } catch {
            return []
        }
    }

    func preload(countryCodes: [String]) async {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        for code in countryCodes {
            for year in [currentYear, currentYear + 1] {
                _ = await holidayDates(for: code, year: year)
            }
        }
    }

    // MARK: - Private

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private func fetchHolidays(year: Int, countryCode: String) async -> Set<String> {
        guard let url = URL(string: "https://date.nager.at/api/v3/PublicHolidays/\(year)/\(countryCode)") else {
            return []
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            let holidays = try JSONDecoder().decode([PublicHoliday].self, from: data)
            return Set(holidays.map(\.date))
        } catch {
            return []
        }
    }

    private func loadFromDisk(countryCode: String, year: Int) -> Set<String>? {
        let key = "holidays_\(countryCode)_\(year)"
        let timestampKey = "holidays_ts_\(countryCode)_\(year)"

        guard let data = defaults?.data(forKey: key),
              let timestamp = defaults?.object(forKey: timestampKey) as? Date,
              Date().timeIntervalSince(timestamp) < cacheTTL else {
            return nil
        }

        return try? JSONDecoder().decode(Set<String>.self, from: data)
    }

    private func saveToDisk(dates: Set<String>, countryCode: String, year: Int) {
        let key = "holidays_\(countryCode)_\(year)"
        let timestampKey = "holidays_ts_\(countryCode)_\(year)"

        if let data = try? JSONEncoder().encode(dates) {
            defaults?.set(data, forKey: key)
            defaults?.set(Date(), forKey: timestampKey)
        }
    }
}
