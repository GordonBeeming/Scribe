import Foundation
import SwiftData

@Model
final class UserPreferences {
    var id: UUID
    var defaultRangeRaw: String
    var lookbackDays: Int
    var defaultCurrency: String
    var createdAt: Date
    var modifiedAt: Date
    var ckRecordData: Data?

    /// Well-known UUID so all devices share the same CKRecord
    static let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init(
        defaultRangeRaw: String = "14days",
        lookbackDays: Int = 5,
        defaultCurrency: String = "AUD"
    ) {
        self.id = Self.sharedID
        self.defaultRangeRaw = defaultRangeRaw
        self.lookbackDays = lookbackDays
        self.defaultCurrency = defaultCurrency
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    /// Sync current values to UserDefaults for widget access
    func syncToUserDefaults() {
        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        defaults?.set(defaultRangeRaw, forKey: "defaultRange")
        defaults?.set(lookbackDays, forKey: "lookbackDays")
        defaults?.set(defaultCurrency, forKey: "defaultCurrency")
    }
}
