import Foundation
import CloudKit

/// Converts between CKRecord and SwiftData model objects.
enum RecordConversion {
    static let budgetItemRecordType = "BudgetItem"
    static let amountOverrideRecordType = "AmountOverride"
    static let occurrenceRecordType = "Occurrence"
    static let familyMemberRecordType = "FamilyMember"
    static let dashboardSectionRecordType = "DashboardSection"
    static let quickAdjustmentRecordType = "QuickAdjustment"

    // MARK: - CKRecord System Fields

    /// Encode a CKRecord's system fields (change tag, etc.) to Data for local storage.
    static func encodeSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// Restore a CKRecord from previously archived system fields.
    /// Returns nil if data is invalid, in which case a fresh record should be created.
    static func decodeLastKnownRecord(from data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }

    /// Get or create a CKRecord for a model object. Reuses the last known record
    /// (preserving system fields) if available, otherwise creates a fresh one.
    private static func recordForModel(
        recordType: String,
        id: UUID,
        ckRecordData: Data?,
        zoneID: CKRecordZone.ID
    ) -> CKRecord {
        if let data = ckRecordData, let existing = decodeLastKnownRecord(from: data) {
            return existing
        }
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    // MARK: - BudgetItem -> CKRecord

    static func record(from item: BudgetItem, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = recordForModel(
            recordType: budgetItemRecordType,
            id: item.id,
            ckRecordData: item.ckRecordData,
            zoneID: zoneID
        )
        record["name"] = item.name as CKRecordValue
        record["itemType"] = item.itemType as CKRecordValue
        record["amount"] = NSDecimalNumber(decimal: item.amount) as CKRecordValue
        record["currencyCode"] = item.currencyCode as CKRecordValue
        record["frequencyRaw"] = item.frequencyRaw as CKRecordValue
        if let dayOfMonth = item.dayOfMonth {
            record["dayOfMonth"] = dayOfMonth as CKRecordValue
        }
        if let referenceDate = item.referenceDate {
            record["referenceDate"] = referenceDate as CKRecordValue
        }
        record["categoryRaw"] = item.categoryRaw as CKRecordValue
        record["isActive"] = (item.isActive ? 1 : 0) as CKRecordValue
        if let notes = item.notes {
            record["notes"] = notes as CKRecordValue
        }
        record["sortOrder"] = item.sortOrder as CKRecordValue
        record["showLast"] = (item.showLast ? 1 : 0) as CKRecordValue
        record["createdAt"] = item.createdAt as CKRecordValue
        record["modifiedAt"] = item.modifiedAt as CKRecordValue

        // Store family member IDs as a string list
        let memberIDs = item.familyMembers.map { $0.id.uuidString }
        if !memberIDs.isEmpty {
            record["familyMemberIDs"] = memberIDs as CKRecordValue
        }

        if let budgetReflectionRaw = item.budgetReflectionRaw {
            record["budgetReflectionRaw"] = budgetReflectionRaw as CKRecordValue
        }
        if let payDayAdjustmentDays = item.payDayAdjustmentDays {
            record["payDayAdjustmentDays"] = payDayAdjustmentDays as CKRecordValue
        }
        if let publicHolidayCountryCode = item.publicHolidayCountryCode {
            record["publicHolidayCountryCode"] = publicHolidayCountryCode as CKRecordValue
        }

        return record
    }

    static func applyRecord(_ record: CKRecord, to item: BudgetItem) {
        item.name = record["name"] as? String ?? item.name
        item.itemType = record["itemType"] as? String ?? item.itemType
        if let amount = record["amount"] as? NSNumber {
            item.amount = amount.decimalValue
        }
        item.currencyCode = record["currencyCode"] as? String ?? item.currencyCode
        item.frequencyRaw = record["frequencyRaw"] as? String ?? item.frequencyRaw
        item.dayOfMonth = record["dayOfMonth"] as? Int
        item.referenceDate = record["referenceDate"] as? Date
        item.categoryRaw = record["categoryRaw"] as? String ?? item.categoryRaw
        item.isActive = (record["isActive"] as? Int ?? 1) == 1
        item.notes = record["notes"] as? String
        item.sortOrder = record["sortOrder"] as? Int ?? 0
        item.showLast = (record["showLast"] as? Int ?? 0) == 1
        item.modifiedAt = record["modifiedAt"] as? Date ?? Date()
        item.budgetReflectionRaw = record["budgetReflectionRaw"] as? String
        item.payDayAdjustmentDays = record["payDayAdjustmentDays"] as? String
        item.publicHolidayCountryCode = record["publicHolidayCountryCode"] as? String
        item.ckRecordData = encodeSystemFields(of: record)
    }

    // MARK: - AmountOverride -> CKRecord

    static func record(from override_: AmountOverride, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = recordForModel(
            recordType: amountOverrideRecordType,
            id: override_.id,
            ckRecordData: override_.ckRecordData,
            zoneID: zoneID
        )
        record["effectiveDate"] = override_.effectiveDate as CKRecordValue
        record["amount"] = NSDecimalNumber(decimal: override_.amount) as CKRecordValue
        if let dayOfMonth = override_.overrideDayOfMonth {
            record["overrideDayOfMonth"] = dayOfMonth as CKRecordValue
        }
        if let referenceDate = override_.overrideReferenceDate {
            record["overrideReferenceDate"] = referenceDate as CKRecordValue
        }
        if let notes = override_.notes {
            record["notes"] = notes as CKRecordValue
        }
        if let budgetItem = override_.budgetItem {
            let parentRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: budgetItem.id.uuidString, zoneID: zoneID),
                action: .deleteSelf
            )
            record["budgetItemRef"] = parentRef as CKRecordValue
        }
        return record
    }

    // MARK: - Occurrence -> CKRecord

    static func record(from occurrence: Occurrence, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = recordForModel(
            recordType: occurrenceRecordType,
            id: occurrence.id,
            ckRecordData: occurrence.ckRecordData,
            zoneID: zoneID
        )
        record["dueDate"] = occurrence.dueDate as CKRecordValue
        record["expectedAmount"] = NSDecimalNumber(decimal: occurrence.expectedAmount) as CKRecordValue
        if let actualAmount = occurrence.actualAmount {
            record["actualAmount"] = NSDecimalNumber(decimal: actualAmount) as CKRecordValue
        }
        record["statusRaw"] = occurrence.statusRaw as CKRecordValue
        if let confirmedAt = occurrence.confirmedAt {
            record["confirmedAt"] = confirmedAt as CKRecordValue
        }
        if let notes = occurrence.notes {
            record["notes"] = notes as CKRecordValue
        }
        if let budgetItem = occurrence.budgetItem {
            let parentRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: budgetItem.id.uuidString, zoneID: zoneID),
                action: .deleteSelf
            )
            record["budgetItemRef"] = parentRef as CKRecordValue
        }
        return record
    }

    // MARK: - FamilyMember -> CKRecord

    static func record(from member: FamilyMember, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = recordForModel(
            recordType: familyMemberRecordType,
            id: member.id,
            ckRecordData: member.ckRecordData,
            zoneID: zoneID
        )
        record["name"] = member.name as CKRecordValue
        record["sortOrder"] = member.sortOrder as CKRecordValue
        return record
    }

    // MARK: - DashboardSection -> CKRecord

    static func record(from section: DashboardSection, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = recordForModel(
            recordType: dashboardSectionRecordType,
            id: section.id,
            ckRecordData: section.ckRecordData,
            zoneID: zoneID
        )
        record["sectionTypeRaw"] = section.sectionTypeRaw as CKRecordValue
        record["anchorRaw"] = section.anchorRaw as CKRecordValue
        record["isEnabled"] = (section.isEnabled ? 1 : 0) as CKRecordValue
        record["sortOrder"] = section.sortOrder as CKRecordValue
        record["label"] = section.label as CKRecordValue
        record["createdAt"] = section.createdAt as CKRecordValue
        record["modifiedAt"] = section.modifiedAt as CKRecordValue
        return record
    }

    static func applyRecord(_ record: CKRecord, to section: DashboardSection) {
        section.sectionTypeRaw = record["sectionTypeRaw"] as? String ?? section.sectionTypeRaw
        section.anchorRaw = record["anchorRaw"] as? String ?? section.anchorRaw
        section.isEnabled = (record["isEnabled"] as? Int ?? 1) == 1
        section.sortOrder = record["sortOrder"] as? Int ?? section.sortOrder
        section.label = record["label"] as? String ?? section.label
        section.modifiedAt = record["modifiedAt"] as? Date ?? Date()
        section.ckRecordData = encodeSystemFields(of: record)
    }

    // MARK: - QuickAdjustment -> CKRecord

    static func record(from adjustment: QuickAdjustment, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = recordForModel(
            recordType: quickAdjustmentRecordType,
            id: adjustment.id,
            ckRecordData: adjustment.ckRecordData,
            zoneID: zoneID
        )
        record["adjustmentTypeRaw"] = adjustment.adjustmentTypeRaw as CKRecordValue
        record["date"] = adjustment.date as CKRecordValue
        record["amount"] = NSDecimalNumber(decimal: adjustment.amount) as CKRecordValue
        record["name"] = adjustment.name as CKRecordValue
        record["currencyCode"] = adjustment.currencyCode as CKRecordValue
        if let notes = adjustment.notes {
            record["notes"] = notes as CKRecordValue
        }
        record["createdAt"] = adjustment.createdAt as CKRecordValue
        record["modifiedAt"] = adjustment.modifiedAt as CKRecordValue
        return record
    }

    static func applyRecord(_ record: CKRecord, to adjustment: QuickAdjustment) {
        adjustment.adjustmentTypeRaw = record["adjustmentTypeRaw"] as? String ?? adjustment.adjustmentTypeRaw
        adjustment.date = record["date"] as? Date ?? adjustment.date
        if let amount = record["amount"] as? NSNumber {
            adjustment.amount = amount.decimalValue
        }
        adjustment.name = record["name"] as? String ?? adjustment.name
        adjustment.currencyCode = record["currencyCode"] as? String ?? adjustment.currencyCode
        adjustment.notes = record["notes"] as? String
        adjustment.modifiedAt = record["modifiedAt"] as? Date ?? Date()
        adjustment.ckRecordData = encodeSystemFields(of: record)
    }
}
