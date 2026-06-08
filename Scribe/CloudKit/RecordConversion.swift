import Foundation
import CloudKit

/// Converts between CKRecord and SwiftData model objects.
enum RecordConversion {
    static let budgetItemRecordType = "BudgetItem"
    static let amountOverrideRecordType = "AmountOverride"
    static let occurrenceRecordType = "Occurrence"
    static let familyMemberRecordType = "FamilyMember"
    static let dashboardSectionRecordType = "DashboardSection"
    static let userPreferencesRecordType = "UserPreferences"

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
        } else {
            record["dayOfMonth"] = nil
        }
        if let referenceDate = item.referenceDate {
            record["referenceDate"] = referenceDate as CKRecordValue
        } else {
            record["referenceDate"] = nil
        }
        record["categoryRaw"] = item.categoryRaw as CKRecordValue
        record["isActive"] = (item.isActive ? 1 : 0) as CKRecordValue
        if let notes = item.notes {
            record["notes"] = notes as CKRecordValue
        } else {
            record["notes"] = nil
        }
        record["sortOrder"] = item.sortOrder as CKRecordValue
        record["showLast"] = (item.showLast ? 1 : 0) as CKRecordValue
        record["createdAt"] = item.createdAt as CKRecordValue
        record["modifiedAt"] = item.modifiedAt as CKRecordValue

        // Store family member IDs as a string list
        let memberIDs = item.familyMembers.map { $0.id.uuidString }
        if !memberIDs.isEmpty {
            record["familyMemberIDs"] = memberIDs as CKRecordValue
        } else {
            record["familyMemberIDs"] = nil
        }

        if let budgetReflectionRaw = item.budgetReflectionRaw {
            record["budgetReflectionRaw"] = budgetReflectionRaw as CKRecordValue
        } else {
            record["budgetReflectionRaw"] = nil
        }
        if let payDayAdjustmentDays = item.payDayAdjustmentDays {
            record["payDayAdjustmentDays"] = payDayAdjustmentDays as CKRecordValue
        } else {
            record["payDayAdjustmentDays"] = nil
        }
        if let publicHolidayCountryCode = item.publicHolidayCountryCode {
            record["publicHolidayCountryCode"] = publicHolidayCountryCode as CKRecordValue
        } else {
            record["publicHolidayCountryCode"] = nil
        }
        if let endDate = item.endDate {
            record["endDate"] = endDate as CKRecordValue
        } else {
            record["endDate"] = nil
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
        item.endDate = record["endDate"] as? Date
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
        } else {
            record["overrideDayOfMonth"] = nil
        }
        if let referenceDate = override_.overrideReferenceDate {
            record["overrideReferenceDate"] = referenceDate as CKRecordValue
        } else {
            record["overrideReferenceDate"] = nil
        }
        if let notes = override_.notes {
            record["notes"] = notes as CKRecordValue
        } else {
            record["notes"] = nil
        }
        record["createdAt"] = override_.createdAt as CKRecordValue
        record["modifiedAt"] = override_.modifiedAt as CKRecordValue
        if let budgetItem = override_.budgetItem {
            let parentRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: budgetItem.id.uuidString, zoneID: zoneID),
                action: .deleteSelf
            )
            record["budgetItemRef"] = parentRef as CKRecordValue
        }
        return record
    }

    static func applyRecord(_ record: CKRecord, to override_: AmountOverride) {
        override_.effectiveDate = record["effectiveDate"] as? Date ?? override_.effectiveDate
        if let amount = record["amount"] as? NSNumber {
            override_.amount = amount.decimalValue
        }
        override_.overrideDayOfMonth = record["overrideDayOfMonth"] as? Int
        override_.overrideReferenceDate = record["overrideReferenceDate"] as? Date
        override_.notes = record["notes"] as? String
        override_.modifiedAt = record["modifiedAt"] as? Date ?? Date()
        override_.ckRecordData = encodeSystemFields(of: record)
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
        } else {
            record["actualAmount"] = nil
        }
        record["statusRaw"] = occurrence.statusRaw as CKRecordValue
        if let confirmedAt = occurrence.confirmedAt {
            record["confirmedAt"] = confirmedAt as CKRecordValue
        } else {
            record["confirmedAt"] = nil
        }
        if let notes = occurrence.notes {
            record["notes"] = notes as CKRecordValue
        } else {
            record["notes"] = nil
        }
        record["createdAt"] = occurrence.createdAt as CKRecordValue
        record["modifiedAt"] = occurrence.modifiedAt as CKRecordValue
        if let budgetItem = occurrence.budgetItem {
            let parentRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: budgetItem.id.uuidString, zoneID: zoneID),
                action: .deleteSelf
            )
            record["budgetItemRef"] = parentRef as CKRecordValue
        }
        return record
    }

    static func applyRecord(_ record: CKRecord, to occurrence: Occurrence) {
        occurrence.dueDate = record["dueDate"] as? Date ?? occurrence.dueDate
        if let expectedAmount = record["expectedAmount"] as? NSNumber {
            occurrence.expectedAmount = expectedAmount.decimalValue
        }
        if let actualAmount = record["actualAmount"] as? NSNumber {
            occurrence.actualAmount = actualAmount.decimalValue
        } else {
            occurrence.actualAmount = nil
        }
        occurrence.statusRaw = record["statusRaw"] as? String ?? occurrence.statusRaw
        occurrence.confirmedAt = record["confirmedAt"] as? Date
        occurrence.notes = record["notes"] as? String
        occurrence.modifiedAt = record["modifiedAt"] as? Date ?? Date()
        occurrence.ckRecordData = encodeSystemFields(of: record)
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
        record["createdAt"] = member.createdAt as CKRecordValue
        record["modifiedAt"] = member.modifiedAt as CKRecordValue
        return record
    }

    static func applyRecord(_ record: CKRecord, to member: FamilyMember) {
        member.name = record["name"] as? String ?? member.name
        member.sortOrder = record["sortOrder"] as? Int ?? member.sortOrder
        member.modifiedAt = record["modifiedAt"] as? Date ?? Date()
        member.ckRecordData = encodeSystemFields(of: record)
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

    // MARK: - UserPreferences -> CKRecord

    static func record(from preferences: UserPreferences, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = recordForModel(
            recordType: userPreferencesRecordType,
            id: preferences.id,
            ckRecordData: preferences.ckRecordData,
            zoneID: zoneID
        )
        record["defaultRangeRaw"] = preferences.defaultRangeRaw as CKRecordValue
        record["lookbackDays"] = preferences.lookbackDays as CKRecordValue
        record["defaultCurrency"] = preferences.defaultCurrency as CKRecordValue
        record["rollingWeeklyNet"] = ((preferences.rollingWeeklyNet ?? false) ? 1 : 0) as CKRecordValue
        record["createdAt"] = preferences.createdAt as CKRecordValue
        record["modifiedAt"] = preferences.modifiedAt as CKRecordValue
        return record
    }

    static func applyRecord(_ record: CKRecord, to preferences: UserPreferences) {
        preferences.defaultRangeRaw = record["defaultRangeRaw"] as? String ?? preferences.defaultRangeRaw
        preferences.lookbackDays = record["lookbackDays"] as? Int ?? preferences.lookbackDays
        preferences.defaultCurrency = record["defaultCurrency"] as? String ?? preferences.defaultCurrency
        // Stored as Int (1/0); absent on records written before this field existed → keep current value.
        if let rolling = record["rollingWeeklyNet"] as? Int {
            preferences.rollingWeeklyNet = rolling == 1
        }
        preferences.modifiedAt = record["modifiedAt"] as? Date ?? Date()
        preferences.ckRecordData = encodeSystemFields(of: record)
        preferences.syncToUserDefaults()
    }
}
