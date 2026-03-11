import Foundation
import SwiftData
import CloudKit

enum ImportMode {
    case merge
    case replace
}

@MainActor
enum DataManagementService {

    static func hasExistingData(in context: ModelContext) -> Bool {
        let count = (try? context.fetchCount(FetchDescriptor<BudgetItem>())) ?? 0
        return count > 0
    }

    // MARK: - Clear

    static func clearAllData(in context: ModelContext) {
        let zoneID = CloudKitManager.shared.zoneID
        var deletionIDs: [CKRecord.ID] = []

        if let items = try? context.fetch(FetchDescriptor<BudgetItem>()) {
            deletionIDs.append(contentsOf: items.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
            for item in items { context.delete(item) }
        }

        if let overrides = try? context.fetch(FetchDescriptor<AmountOverride>()) {
            deletionIDs.append(contentsOf: overrides.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
            for o in overrides { context.delete(o) }
        }

        if let occurrences = try? context.fetch(FetchDescriptor<Occurrence>()) {
            deletionIDs.append(contentsOf: occurrences.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
            for o in occurrences { context.delete(o) }
        }

        if let members = try? context.fetch(FetchDescriptor<FamilyMember>()) {
            deletionIDs.append(contentsOf: members.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
            for m in members { context.delete(m) }
        }

        if let sections = try? context.fetch(FetchDescriptor<DashboardSection>()) {
            deletionIDs.append(contentsOf: sections.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
            for s in sections { context.delete(s) }
        }

        if let adjustments = try? context.fetch(FetchDescriptor<QuickAdjustment>()) {
            deletionIDs.append(contentsOf: adjustments.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
            for a in adjustments { context.delete(a) }
        }

        try? context.save()

        if !deletionIDs.isEmpty {
            SyncCoordinator.shared.pushDeletion(for: deletionIDs)
        }
    }

    // MARK: - Export

    static func exportData(from context: ModelContext) throws -> Data {
        let items = (try? context.fetch(FetchDescriptor<BudgetItem>())) ?? []
        let overrides = (try? context.fetch(FetchDescriptor<AmountOverride>())) ?? []
        let occurrences = (try? context.fetch(FetchDescriptor<Occurrence>())) ?? []
        let members = (try? context.fetch(FetchDescriptor<FamilyMember>())) ?? []
        let sections = (try? context.fetch(FetchDescriptor<DashboardSection>())) ?? []
        let adjustments = (try? context.fetch(FetchDescriptor<QuickAdjustment>())) ?? []

        let export = ScribeExport(
            exportDate: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            familyMembers: members.map { CodableFamilyMember(from: $0) },
            budgetItems: items.map { CodableBudgetItem(from: $0) },
            amountOverrides: overrides.map { CodableAmountOverride(from: $0) },
            occurrences: occurrences.map { CodableOccurrence(from: $0) },
            dashboardSections: sections.map { CodableDashboardSection(from: $0) },
            quickAdjustments: adjustments.map { CodableQuickAdjustment(from: $0) }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }

    // MARK: - Import

    static func importData(_ data: Data, into context: ModelContext, mode: ImportMode) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ScribeExport.self, from: data)

        if mode == .replace {
            clearAllData(in: context)
        }

        let zoneID = CloudKitManager.shared.zoneID
        var recordIDs: [CKRecord.ID] = []

        // Insert family members first
        var memberMap: [UUID: FamilyMember] = [:]
        for codableMember in export.familyMembers {
            if mode == .merge, let existing = existingFamilyMember(id: codableMember.id, in: context) {
                existing.name = codableMember.name
                existing.sortOrder = codableMember.sortOrder
                memberMap[codableMember.id] = existing
            } else {
                let member = codableMember.toModel()
                context.insert(member)
                memberMap[codableMember.id] = member
            }
            recordIDs.append(CKRecord.ID(recordName: codableMember.id.uuidString, zoneID: zoneID))
        }

        // Insert budget items
        var itemMap: [UUID: BudgetItem] = [:]
        for codableItem in export.budgetItems {
            if mode == .merge, let existing = existingBudgetItem(id: codableItem.id, in: context) {
                if codableItem.modifiedAt > existing.modifiedAt {
                    updateBudgetItem(existing, from: codableItem)
                    existing.familyMembers = codableItem.familyMemberIDs.compactMap { memberMap[$0] }
                }
                itemMap[codableItem.id] = existing
            } else {
                let item = codableItem.toModel()
                context.insert(item)
                item.familyMembers = codableItem.familyMemberIDs.compactMap { memberMap[$0] }
                itemMap[codableItem.id] = item
            }
            recordIDs.append(CKRecord.ID(recordName: codableItem.id.uuidString, zoneID: zoneID))
        }

        // Insert amount overrides
        for codableOverride in export.amountOverrides {
            if mode == .merge, let existing = existingAmountOverride(id: codableOverride.id, in: context) {
                existing.effectiveDate = codableOverride.effectiveDate
                existing.amount = codableOverride.amount
                existing.overrideDayOfMonth = codableOverride.overrideDayOfMonth
                existing.overrideReferenceDate = codableOverride.overrideReferenceDate
                existing.notes = codableOverride.notes
                if let parentID = codableOverride.budgetItemID {
                    existing.budgetItem = itemMap[parentID]
                }
            } else {
                let override_ = codableOverride.toModel()
                context.insert(override_)
                if let parentID = codableOverride.budgetItemID {
                    override_.budgetItem = itemMap[parentID]
                }
            }
            recordIDs.append(CKRecord.ID(recordName: codableOverride.id.uuidString, zoneID: zoneID))
        }

        // Insert occurrences
        for codableOcc in export.occurrences {
            if mode == .merge, let existing = existingOccurrence(id: codableOcc.id, in: context) {
                existing.dueDate = codableOcc.dueDate
                existing.expectedAmount = codableOcc.expectedAmount
                existing.actualAmount = codableOcc.actualAmount
                existing.statusRaw = codableOcc.statusRaw
                existing.confirmedAt = codableOcc.confirmedAt
                existing.notes = codableOcc.notes
                if let parentID = codableOcc.budgetItemID {
                    existing.budgetItem = itemMap[parentID]
                }
            } else {
                let occurrence = codableOcc.toModel()
                context.insert(occurrence)
                if let parentID = codableOcc.budgetItemID {
                    occurrence.budgetItem = itemMap[parentID]
                }
            }
            recordIDs.append(CKRecord.ID(recordName: codableOcc.id.uuidString, zoneID: zoneID))
        }

        // Insert dashboard sections
        if let codableSections = export.dashboardSections {
            for codableSection in codableSections {
                if mode == .merge, let existing = existingDashboardSection(id: codableSection.id, in: context) {
                    if codableSection.modifiedAt > existing.modifiedAt {
                        existing.sectionTypeRaw = codableSection.sectionTypeRaw
                        existing.anchorRaw = codableSection.anchorRaw
                        existing.isEnabled = codableSection.isEnabled
                        existing.sortOrder = codableSection.sortOrder
                        existing.label = codableSection.label
                        existing.modifiedAt = codableSection.modifiedAt
                    }
                } else {
                    let section = codableSection.toModel()
                    context.insert(section)
                }
                recordIDs.append(CKRecord.ID(recordName: codableSection.id.uuidString, zoneID: zoneID))
            }
        }

        // Insert quick adjustments
        if let codableAdjustments = export.quickAdjustments {
            for codableAdjustment in codableAdjustments {
                if mode == .merge, let existing = existingQuickAdjustment(id: codableAdjustment.id, in: context) {
                    if codableAdjustment.modifiedAt > existing.modifiedAt {
                        existing.adjustmentTypeRaw = codableAdjustment.adjustmentTypeRaw
                        existing.date = codableAdjustment.date
                        existing.amount = codableAdjustment.amount
                        existing.name = codableAdjustment.name
                        existing.currencyCode = codableAdjustment.currencyCode
                        existing.notes = codableAdjustment.notes
                        existing.modifiedAt = codableAdjustment.modifiedAt
                    }
                } else {
                    let adjustment = codableAdjustment.toModel()
                    context.insert(adjustment)
                }
                recordIDs.append(CKRecord.ID(recordName: codableAdjustment.id.uuidString, zoneID: zoneID))
            }
        }

        try? context.save()

        if !recordIDs.isEmpty {
            SyncCoordinator.shared.pushChanges(for: recordIDs)
        }
    }

    // MARK: - Helpers

    private static func existingBudgetItem(id: UUID, in context: ModelContext) -> BudgetItem? {
        try? context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == id })).first
    }

    private static func existingFamilyMember(id: UUID, in context: ModelContext) -> FamilyMember? {
        try? context.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == id })).first
    }

    private static func existingAmountOverride(id: UUID, in context: ModelContext) -> AmountOverride? {
        try? context.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == id })).first
    }

    private static func existingOccurrence(id: UUID, in context: ModelContext) -> Occurrence? {
        try? context.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == id })).first
    }

    private static func existingDashboardSection(id: UUID, in context: ModelContext) -> DashboardSection? {
        try? context.fetch(FetchDescriptor<DashboardSection>(predicate: #Predicate { $0.id == id })).first
    }

    private static func existingQuickAdjustment(id: UUID, in context: ModelContext) -> QuickAdjustment? {
        try? context.fetch(FetchDescriptor<QuickAdjustment>(predicate: #Predicate { $0.id == id })).first
    }

    private static func updateBudgetItem(_ item: BudgetItem, from codable: CodableBudgetItem) {
        item.name = codable.name
        item.itemType = codable.itemType
        item.amount = codable.amount
        item.currencyCode = codable.currencyCode
        item.frequencyRaw = codable.frequencyRaw
        item.dayOfMonth = codable.dayOfMonth
        item.referenceDate = codable.referenceDate
        item.categoryRaw = codable.categoryRaw
        item.isActive = codable.isActive
        item.notes = codable.notes
        item.sortOrder = codable.sortOrder
        item.showLast = codable.showLast
        item.budgetReflectionRaw = codable.budgetReflectionRaw
        item.payDayAdjustmentDays = codable.payDayAdjustmentDays
        item.publicHolidayCountryCode = codable.publicHolidayCountryCode
        item.modifiedAt = codable.modifiedAt
    }
}
