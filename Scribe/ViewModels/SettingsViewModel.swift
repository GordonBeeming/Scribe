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

enum LookbackDays: Int, CaseIterable, Identifiable {
    case days0 = 0
    case days1 = 1
    case days2 = 2
    case days3 = 3
    case days5 = 5
    case days7 = 7

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .days0: "None"
        case .days1: "1 day"
        case .days2: "2 days"
        case .days3: "3 days"
        case .days5: "5 days"
        case .days7: "7 days"
        }
    }
}

@Observable
final class SettingsViewModel {
    nonisolated(unsafe) private static let defaults = UserDefaults(suiteName: "group.com.gordonbeeming.scribe")

    var lookbackDays: LookbackDays {
        get {
            access(keyPath: \.lookbackDays)
            guard Self.defaults?.object(forKey: "lookbackDays") != nil else { return .days5 }
            let raw = Self.defaults?.integer(forKey: "lookbackDays") ?? 5
            return LookbackDays(rawValue: raw) ?? .days5
        }
        set {
            withMutation(keyPath: \.lookbackDays) {
                Self.defaults?.set(newValue.rawValue, forKey: "lookbackDays")
            }
        }
    }

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

    static func currentLookbackDays() -> Int {
        let raw = UserDefaults(suiteName: "group.com.gordonbeeming.scribe")?.integer(forKey: "lookbackDays")
        // UserDefaults returns 0 for missing keys, so check if key exists
        if UserDefaults(suiteName: "group.com.gordonbeeming.scribe")?.object(forKey: "lookbackDays") == nil {
            return 5
        }
        return raw ?? 5
    }
}
