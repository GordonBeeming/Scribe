import Foundation
import SwiftData
import os

private let settingsLogger = Logger(subsystem: "com.gordonbeeming.scribe", category: "SettingsViewModel")

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

    var rollingWeeklyNet: Bool {
        get {
            access(keyPath: \.rollingWeeklyNet)
            return Self.defaults?.bool(forKey: "rollingWeeklyNet") ?? false
        }
        set {
            withMutation(keyPath: \.rollingWeeklyNet) {
                Self.defaults?.set(newValue, forKey: "rollingWeeklyNet")
                updatePreferences { $0.rollingWeeklyNet = newValue }
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

    private static let didSeedDefaultsKey = "didSeedDefaultDashboardSections"

    /// Seed the two default dashboard sections (Summary / Upcoming) for new users.
    /// Runs at most once per device — guarded by an app-group UserDefaults flag so
    /// intentional deletions don't get silently resurrected on next launch.
    func ensureDefaultDashboardSectionsExist() {
        guard let modelContext else { return }
        let defaults = Self.defaults
        if defaults?.bool(forKey: Self.didSeedDefaultsKey) == true { return }

        let existing: [DashboardSection]
        do {
            existing = try modelContext.fetch(FetchDescriptor<DashboardSection>())
        } catch {
            // A transient fetch failure (store contention, migration window) must NOT
            // be treated as "no sections" — that would seed duplicates next to the
            // user's real data. Skip this launch and leave the flag unset so we retry.
            settingsLogger.error("Skipping default-section seed: fetch failed (\(error.localizedDescription))")
            return
        }
        if !existing.isEmpty {
            defaults?.set(true, forKey: Self.didSeedDefaultsKey)
            return
        }

        let summary = DashboardSection(
            id: DashboardSection.defaultSummaryID,
            sectionType: .monthlySummary,
            anchor: .fixedDayOfMonth(day: 1),
            sortOrder: 0,
            label: "Summary"
        )
        let upcoming = DashboardSection(
            id: DashboardSection.defaultUpcomingID,
            sectionType: .detailedWeekly,
            anchor: .fixedDay(weekday: 2),
            sortOrder: 1,
            label: "Upcoming"
        )
        modelContext.insert(summary)
        modelContext.insert(upcoming)
        do {
            try modelContext.save()
        } catch {
            // Save failed — don't flip the seed flag, otherwise the user is locked
            // out of defaults forever. Retry on the next launch.
            settingsLogger.error("Failed to save default sections: \(error.localizedDescription)")
            return
        }
        SyncCoordinator.shared.pushChange(for: summary.id)
        SyncCoordinator.shared.pushChange(for: upcoming.id)
        defaults?.set(true, forKey: Self.didSeedDefaultsKey)
    }

    static func currentDefaultRange() -> DefaultRange {
        let raw = UserDefaults(suiteName: "group.com.gordonbeeming.scribe")?.string(forKey: "defaultRange") ?? DefaultRange.days14.rawValue
        return DefaultRange(rawValue: raw) ?? .days14
    }

    static func currentRollingWeeklyNet() -> Bool {
        UserDefaults(suiteName: "group.com.gordonbeeming.scribe")?.bool(forKey: "rollingWeeklyNet") ?? false
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
