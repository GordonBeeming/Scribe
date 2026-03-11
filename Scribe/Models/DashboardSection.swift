import Foundation
import SwiftData

enum DashboardSectionType: String, Codable, CaseIterable, Identifiable {
    case monthlySummary
    case detailedWeekly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .monthlySummary: "Monthly Summary"
        case .detailedWeekly: "Detailed Weekly"
        }
    }
}

enum DashboardSectionAnchor: Codable, Equatable {
    case fixedDay(weekday: Int)
    case fixedDayOfMonth(day: Int)
    case linkedIncome(budgetItemID: UUID)

    var displayName: String {
        switch self {
        case .fixedDay(let weekday):
            let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return "Every \(weekday > 0 && weekday < 8 ? names[weekday] : "?")"
        case .fixedDayOfMonth(let day):
            return "Day \(day) of month"
        case .linkedIncome:
            return "Linked to income"
        }
    }
}

@Model
final class DashboardSection {
    var id: UUID
    var sectionTypeRaw: String
    var anchorRaw: String
    var isEnabled: Bool
    var sortOrder: Int
    var label: String
    var ckRecordData: Data?
    var createdAt: Date
    var modifiedAt: Date

    var sectionType: DashboardSectionType {
        get { DashboardSectionType(rawValue: sectionTypeRaw) ?? .detailedWeekly }
        set { sectionTypeRaw = newValue.rawValue }
    }

    var anchor: DashboardSectionAnchor {
        get {
            guard let data = anchorRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(DashboardSectionAnchor.self, from: data) else {
                return .fixedDay(weekday: 2)
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let string = String(data: data, encoding: .utf8) {
                anchorRaw = string
            }
        }
    }

    init(
        sectionType: DashboardSectionType,
        anchor: DashboardSectionAnchor,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        label: String
    ) {
        self.id = UUID()
        self.sectionTypeRaw = sectionType.rawValue
        if let data = try? JSONEncoder().encode(anchor),
           let string = String(data: data, encoding: .utf8) {
            self.anchorRaw = string
        } else {
            self.anchorRaw = "{}"
        }
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.label = label
        self.ckRecordData = nil
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}
