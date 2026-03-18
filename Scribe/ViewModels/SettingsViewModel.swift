import Foundation
import SwiftData

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

    private var modelContext: ModelContext?

    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

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
                updatePreferences { $0.lookbackDays = newValue.rawValue }
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
                updatePreferences { $0.defaultRangeRaw = newValue.rawValue }
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
                updatePreferences { $0.defaultCurrency = newValue }
            }
        }
    }

    /// Read/create the shared UserPreferences and apply a mutation, then push to CloudKit.
    private func updatePreferences(_ mutation: (UserPreferences) -> Void) {
        guard let modelContext else { return }
        let preferences = getOrCreatePreferences(in: modelContext)
        mutation(preferences)
        preferences.modifiedAt = Date()
        try? modelContext.save()
        SyncCoordinator.shared.pushChange(for: UserPreferences.sharedID)
    }

    /// Get existing UserPreferences or create one seeded from current UserDefaults.
    private func getOrCreatePreferences(in context: ModelContext) -> UserPreferences {
        let sharedID = UserPreferences.sharedID
        let predicate = #Predicate<UserPreferences> { $0.id == sharedID }
        if let existing = try? context.fetch(FetchDescriptor<UserPreferences>(predicate: predicate)).first {
            return existing
        }
        // Seed from current UserDefaults values
        let preferences = UserPreferences(
            defaultRangeRaw: defaultRange.rawValue,
            lookbackDays: lookbackDays.rawValue,
            defaultCurrency: defaultCurrency
        )
        context.insert(preferences)
        try? context.save()
        return preferences
    }

    /// Ensure UserPreferences model exists (call on app launch for migration).
    func ensurePreferencesExist() {
        guard let modelContext else { return }
        let _ = getOrCreatePreferences(in: modelContext)
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
