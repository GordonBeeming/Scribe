import Foundation

struct CurrencyFormatter {
    private nonisolated(unsafe) static var formatters: [String: NumberFormatter] = [:]

    static func format(_ amount: Decimal, currencyCode: String) -> String {
        if let cached = formatters[currencyCode] {
            return cached.string(from: amount as NSDecimalNumber) ?? "\(amount)"
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatters[currencyCode] = formatter

        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    static func format(_ amount: Decimal, currencyCode: String, signStyle: SignStyle) -> String {
        let formatted = format(abs(amount), currencyCode: currencyCode)
        switch signStyle {
        case .automatic:
            return amount >= 0 ? "+\(formatted)" : "-\(formatted)"
        case .alwaysPositive:
            return "+\(formatted)"
        case .alwaysNegative:
            return "-\(formatted)"
        case .none:
            return formatted
        }
    }

    enum SignStyle {
        case automatic
        case alwaysPositive
        case alwaysNegative
        case none
    }

    private static func abs(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }

    static let supportedCurrencies: [(code: String, name: String)] = [
        ("AUD", "Australian Dollar"),
        ("USD", "US Dollar"),
        ("ZAR", "South African Rand"),
        ("GBP", "British Pound"),
        ("EUR", "Euro"),
        ("NZD", "New Zealand Dollar"),
        ("CAD", "Canadian Dollar"),
        ("JPY", "Japanese Yen"),
    ]
}
