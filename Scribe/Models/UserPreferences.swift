import Foundation
import SwiftData

@Model
final class UserPreferences {
    var id: UUID
    var defaultRangeRaw: String
    var lookbackDays: Int
    var defaultCurrency: String
    /// When true, the weekly dashboard cards show a cumulative net that carries each week's
    /// leftover into the next, so monthly income spreads ("burns down") across the weeks
    /// instead of spiking in its landing week. When false (or nil), each week stands alone.
    /// Optional so adding it to the existing model is a safe SwiftData lightweight migration
    /// (a non-optional column would crash on launch for users upgrading from an older build).
    var rollingWeeklyNet: Bool? = false
    var createdAt: Date
    var modifiedAt: Date
    var ckRecordData: Data?

    /// Well-known UUID so all devices share the same CKRecord
    static let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init(
        defaultRangeRaw: String = "14days",
        lookbackDays: Int = 5,
        defaultCurrency: String = "AUD",
        rollingWeeklyNet: Bool = false
    ) {
        self.id = Self.sharedID
        self.defaultRangeRaw = defaultRangeRaw
        self.lookbackDays = lookbackDays
        self.defaultCurrency = defaultCurrency
        self.rollingWeeklyNet = rollingWeeklyNet
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    /// Sync current values to UserDefaults for widget access
    func syncToUserDefaults() {
        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        defaults?.set(defaultRangeRaw, forKey: "defaultRange")
        defaults?.set(lookbackDays, forKey: "lookbackDays")
        defaults?.set(defaultCurrency, forKey: "defaultCurrency")
        defaults?.set(rollingWeeklyNet ?? false, forKey: "rollingWeeklyNet")
    }
}
