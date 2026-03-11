import Foundation

/// Observable cache providing synchronous exchange rate access after async load.
@MainActor @Observable
final class ExchangeRateCache {
    static let shared = ExchangeRateCache()

    /// The user's base/default currency
    let baseCurrency = "AUD"

    /// Raw rates relative to USD (populated after load)
    private(set) var rates: [String: Double] = [:]
    private(set) var isLoaded = false

    /// Convert amount from a source currency to base currency synchronously.
    /// Returns nil if rates aren't loaded or currency not found.
    func convertToBase(_ amount: Decimal, from currencyCode: String) -> Decimal? {
        guard currencyCode != baseCurrency else { return nil } // same currency, no conversion needed
        guard isLoaded else { return nil }

        let sourceRate: Double
        if currencyCode == "USD" {
            sourceRate = 1.0
        } else {
            guard let r = rates[currencyCode] else { return nil }
            sourceRate = r
        }

        let baseRate: Double
        if baseCurrency == "USD" {
            baseRate = 1.0
        } else {
            guard let r = rates[baseCurrency] else { return nil }
            baseRate = r
        }

        let amountDouble = Double(truncating: amount as NSDecimalNumber)
        let converted = (amountDouble / sourceRate) * baseRate

        // Round to 2 decimal places
        let rounded = (converted * 100).rounded() / 100
        return Decimal(rounded)
    }

    /// Load rates from ExchangeRateService
    func load() async {
        let fetchedRates = await ExchangeRateService.shared.fetchAllRates()
        if let fetchedRates {
            rates = fetchedRates
            isLoaded = true
        }
    }
}
