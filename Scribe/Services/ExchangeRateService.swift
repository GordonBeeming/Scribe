import Foundation

/// Provides exchange rates relative to a base currency.
/// Uses open.er-api.com (free, no key). Caches for 7 days.
actor ExchangeRateService {
    static let shared = ExchangeRateService()

    private let cacheTTL: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let defaults = UserDefaults(suiteName: "group.com.gordonbeeming.scribe")

    private var inMemoryRates: [String: Double]? // currency code -> rate (relative to USD)
    private var lastFetched: Date?

    /// Convert an amount from one currency to another.
    /// Returns nil if rates aren't available or currencies aren't supported.
    func convert(_ amount: Decimal, from sourceCurrency: String, to targetCurrency: String) async -> Decimal? {
        guard sourceCurrency != targetCurrency else { return amount }

        guard let rates = await getRates() else { return nil }

        // Both rates are relative to USD
        guard let sourceRate = rate(for: sourceCurrency, in: rates),
              let targetRate = rate(for: targetCurrency, in: rates) else {
            return nil
        }

        // Convert: amount in source -> USD -> target
        let amountInUSD = Double(truncating: amount as NSDecimalNumber) / sourceRate
        let amountInTarget = amountInUSD * targetRate
        return Decimal(amountInTarget)
    }

    /// Get the exchange rate from one currency to another (multiply by this to convert).
    func exchangeRate(from sourceCurrency: String, to targetCurrency: String) async -> Double? {
        guard sourceCurrency != targetCurrency else { return 1.0 }
        guard let rates = await getRates() else { return nil }

        guard let sourceRate = rate(for: sourceCurrency, in: rates),
              let targetRate = rate(for: targetCurrency, in: rates) else {
            return nil
        }

        return targetRate / sourceRate
    }

    /// Preload rates so they're cached for later use.
    func preload() async {
        _ = await getRates()
    }

    /// Return all rates (for ExchangeRateCache to consume).
    func fetchAllRates() async -> [String: Double]? {
        await getRates()
    }

    // MARK: - Private

    private func rate(for currency: String, in rates: [String: Double]) -> Double? {
        if currency == "USD" { return 1.0 }
        return rates[currency]
    }

    private func getRates() async -> [String: Double]? {
        // In-memory cache
        if let rates = inMemoryRates, let fetched = lastFetched,
           Date().timeIntervalSince(fetched) < cacheTTL {
            return rates
        }

        // Disk cache
        if let diskRates = loadFromDisk() {
            inMemoryRates = diskRates
            return diskRates
        }

        // Fetch fresh
        let rates = await fetchRates()
        if let rates {
            inMemoryRates = rates
            lastFetched = Date()
            saveToDisk(rates)
        }
        return rates
    }

    private func fetchRates() async -> [String: Double]? {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(ExchangeRateResponse.self, from: data)
            guard decoded.result == "success" else { return nil }
            return decoded.rates
        } catch {
            return nil
        }
    }

    private func loadFromDisk() -> [String: Double]? {
        let key = "exchange_rates"
        let tsKey = "exchange_rates_ts"

        guard let data = defaults?.data(forKey: key),
              let timestamp = defaults?.object(forKey: tsKey) as? Date,
              Date().timeIntervalSince(timestamp) < cacheTTL else {
            return nil
        }

        lastFetched = timestamp
        return try? JSONDecoder().decode([String: Double].self, from: data)
    }

    private func saveToDisk(_ rates: [String: Double]) {
        if let data = try? JSONEncoder().encode(rates) {
            defaults?.set(data, forKey: "exchange_rates")
            defaults?.set(Date(), forKey: "exchange_rates_ts")
        }
    }
}

private struct ExchangeRateResponse: Codable {
    let result: String
    let rates: [String: Double]
}
