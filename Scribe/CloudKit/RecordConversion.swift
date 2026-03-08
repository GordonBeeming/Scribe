import Foundation
import CloudKit

/// Converts between CKRecord and SwiftData model objects.
enum RecordConversion {
    static let budgetItemRecordType = "BudgetItem"
    static let amountOverrideRecordType = "AmountOverride"
    static let occurrenceRecordType = "Occurrence"
    static let familyMemberRecordType = "FamilyMember"

    // MARK: - BudgetItem -> CKRecord

    static func record(from item: BudgetItem, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: budgetItemRecordType, recordID: recordID)
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
    }

    // MARK: - AmountOverride -> CKRecord

    static func record(from override_: AmountOverride, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: override_.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: amountOverrideRecordType, recordID: recordID)
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
        let recordID = CKRecord.ID(recordName: occurrence.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: occurrenceRecordType, recordID: recordID)
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
        let recordID = CKRecord.ID(recordName: member.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: familyMemberRecordType, recordID: recordID)
        record["name"] = member.name as CKRecordValue
        record["sortOrder"] = member.sortOrder as CKRecordValue
        return record
    }
}
