import Foundation

enum DefaultRange: String, CaseIterable, Identifiable {
    case days7 = "7days"
    case days14 = "14days"
    case days21 = "21days"
    case days28 = "28days"
    case oneMonth = "1month"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .days7: "7 days"
        case .days14: "14 days"
        case .days21: "21 days"
        case .days28: "28 days"
        case .oneMonth: "1 month"
        }
    }

    /// Compute the end date from a given start date.
    func endDate(from start: Date) -> Date {
        let calendar = Calendar.current
        switch self {
        case .days7:
            return calendar.date(byAdding: .day, value: 6, to: start) ?? start
        case .days14:
            return calendar.date(byAdding: .day, value: 13, to: start) ?? start
        case .days21:
            return calendar.date(byAdding: .day, value: 20, to: start) ?? start
        case .days28:
            return calendar.date(byAdding: .day, value: 27, to: start) ?? start
        case .oneMonth:
            return calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
        }
    }
}

@Observable
final class SettingsViewModel {
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: "group.com.gordonbeeming.scribe")

    var defaultRange: DefaultRange {
        get {
            access(keyPath: \.defaultRange)
            let raw = Self.defaults?.string(forKey: "defaultRange") ?? DefaultRange.days14.rawValue
            return DefaultRange(rawValue: raw) ?? .days14
        }
        set {
            withMutation(keyPath: \.defaultRange) {
                Self.defaults?.set(newValue.rawValue, forKey: "defaultRange")
            }
        }
    }

    var defaultCurrency: String {
        get {
            access(keyPath: \.defaultCurrency)
            return Self.defaults?.string(forKey: "defaultCurrency") ?? "AUD"
        }
        set {
            withMutation(keyPath: \.defaultCurrency) {
                Self.defaults?.set(newValue, forKey: "defaultCurrency")
            }
        }
    }

    static func currentDefaultRange() -> DefaultRange {
        let raw = UserDefaults(suiteName: "group.com.gordonbeeming.scribe")?.string(forKey: "defaultRange") ?? DefaultRange.days14.rawValue
        return DefaultRange(rawValue: raw) ?? .days14
    }
}
