import Foundation
import CloudKit
import SwiftData
import os

/// Bridges SwiftData <-> CKSyncEngine.
/// Listens for local SwiftData changes, pushes to CloudKit.
/// Receives CloudKit changes, writes to SwiftData.
final class SyncCoordinator: @unchecked Sendable {
    static let shared = SyncCoordinator()

    private let logger = Logger(subsystem: "com.gordonbeeming.scribe", category: "SyncCoordinator")
    private var syncEngine: CKSyncEngine?
    private var modelContainer: ModelContainer?

    /// Last known server change tokens per zone, persisted in UserDefaults
    private let tokenKey = "syncEngineState"

    @MainActor
    var syncStatus: SyncStatus = .idle

    enum SyncStatus: Sendable {
        case idle
        case syncing
        case synced
        case error(String)
    }

    private init() {}

    @MainActor
    func start(with container: ModelContainer) {
        self.modelContainer = container

        Task {
            do {
                let status = try await CloudKitManager.shared.checkAccountStatus()
                guard status == .available else {
                    logger.warning("iCloud account not available, sync disabled")
                    await MainActor.run { syncStatus = .error("iCloud not available") }
                    return
                }

                try await CloudKitManager.shared.createZoneIfNeeded()
                try await CloudKitManager.shared.createSubscriptionIfNeeded()

                let configuration = CKSyncEngine.Configuration(
                    database: CloudKitManager.shared.privateDatabase,
                    stateSerialization: loadSyncEngineState(),
                    delegate: self
                )
                let engine = CKSyncEngine(configuration)
                self.syncEngine = engine
                await MainActor.run { syncStatus = .synced }
                logger.info("CKSyncEngine started successfully")
            } catch {
                logger.error("Failed to start sync: \(error.localizedDescription)")
                await MainActor.run { syncStatus = .error(error.localizedDescription) }
            }
        }
    }

    func stop() {
        syncEngine = nil
    }

    // MARK: - Push local changes

    func pushChanges(for recordIDs: [CKRecord.ID]) {
        let changes = recordIDs.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0) }
        syncEngine?.state.add(pendingRecordZoneChanges: changes)
    }

    func pushDeletion(for recordIDs: [CKRecord.ID]) {
        let changes = recordIDs.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord($0) }
        syncEngine?.state.add(pendingRecordZoneChanges: changes)
    }

    // MARK: - State persistence

    private func loadSyncEngineState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?.data(forKey: tokenKey) else {
            return nil
        }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveSyncEngineState(_ state: CKSyncEngine.State.Serialization) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?.set(data, forKey: tokenKey)
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncCoordinator: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let stateUpdate):
            saveSyncEngineState(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            handleAccountChange(accountChange)

        case .fetchedDatabaseChanges:
            break

        case .fetchedRecordZoneChanges(let fetchedChanges):
            Task { @MainActor in
                self.handleFetchedRecordZoneChanges(fetchedChanges)
            }

        case .sentDatabaseChanges:
            break

        case .sentRecordZoneChanges(let sentChanges):
            handleSentRecordZoneChanges(sentChanges)

        case .willFetchChanges:
            Task { @MainActor in syncStatus = .syncing }

        case .didFetchChanges:
            Task { @MainActor in syncStatus = .synced }

        case .willSendChanges:
            Task { @MainActor in syncStatus = .syncing }

        case .didSendChanges:
            Task { @MainActor in syncStatus = .synced }

        @unknown default:
            logger.warning("Unknown CKSyncEngine event")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges
        guard !pendingChanges.isEmpty, let modelContainer else { return nil }

        let zoneID = CloudKitManager.shared.zoneID

        // Build records in a background context before creating the batch
        let bgContext = ModelContext(modelContainer)
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        for change in pendingChanges {
            switch change {
            case .saveRecord(let recordID):
                guard let uuid = UUID(uuidString: recordID.recordName) else { continue }
                if let item = try? bgContext.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == uuid })).first {
                    recordsToSave.append(RecordConversion.record(from: item, zoneID: zoneID))
                } else if let override_ = try? bgContext.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == uuid })).first {
                    recordsToSave.append(RecordConversion.record(from: override_, zoneID: zoneID))
                } else if let occurrence = try? bgContext.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == uuid })).first {
                    recordsToSave.append(RecordConversion.record(from: occurrence, zoneID: zoneID))
                } else if let member = try? bgContext.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == uuid })).first {
                    recordsToSave.append(RecordConversion.record(from: member, zoneID: zoneID))
                }
            case .deleteRecord(let recordID):
                recordIDsToDelete.append(recordID)
            @unknown default:
                break
            }
        }

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete, atomicByZone: false)
    }

    // MARK: - Event handlers

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            logger.info("iCloud account signed in")
        case .signOut:
            logger.info("iCloud account signed out")
            Task { @MainActor in syncStatus = .error("Signed out of iCloud") }
        case .switchAccounts:
            logger.info("iCloud account switched")
        @unknown default:
            break
        }
    }

    @MainActor
    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        guard let context = modelContainer?.mainContext else { return }
        let zoneID = CloudKitManager.shared.zoneID

        for modification in changes.modifications {
            let record = modification.record
            applyFetchedRecord(record, to: context, zoneID: zoneID)
        }

        for deletion in changes.deletions {
            applyDeletion(deletion.recordID, recordType: deletion.recordType, in: context)
        }

        try? context.save()
    }

    @MainActor
    private func applyFetchedRecord(_ record: CKRecord, to context: ModelContext, zoneID: CKRecordZone.ID) {
        guard let uuid = UUID(uuidString: record.recordID.recordName) else { return }

        switch record.recordType {
        case RecordConversion.budgetItemRecordType:
            let predicate = #Predicate<BudgetItem> { $0.id == uuid }
            let descriptor = FetchDescriptor<BudgetItem>(predicate: predicate)
            if let existing = try? context.fetch(descriptor).first {
                let remoteModified = record["modifiedAt"] as? Date ?? Date.distantPast
                if remoteModified >= existing.modifiedAt {
                    RecordConversion.applyRecord(record, to: existing)
                }
            } else {
                let item = BudgetItem(
                    name: record["name"] as? String ?? "Unknown",
                    type: ItemType(rawValue: record["itemType"] as? String ?? "expense") ?? .expense,
                    amount: (record["amount"] as? NSNumber)?.decimalValue ?? 0,
                    currencyCode: record["currencyCode"] as? String ?? "AUD",
                    frequency: Frequency(rawValue: record["frequencyRaw"] as? String ?? "monthly") ?? .monthly,
                    dayOfMonth: record["dayOfMonth"] as? Int,
                    referenceDate: record["referenceDate"] as? Date,
                    category: ItemCategory(rawValue: record["categoryRaw"] as? String ?? "other") ?? .other,
                    isActive: (record["isActive"] as? Int ?? 1) == 1,
                    notes: record["notes"] as? String,
                    sortOrder: record["sortOrder"] as? Int ?? 0,
                    showLast: (record["showLast"] as? Int ?? 0) == 1
                )
                item.id = uuid
                item.createdAt = record["createdAt"] as? Date ?? Date()
                item.modifiedAt = record["modifiedAt"] as? Date ?? Date()
                context.insert(item)
            }

        case RecordConversion.occurrenceRecordType:
            let predicate = #Predicate<Occurrence> { $0.id == uuid }
            let descriptor = FetchDescriptor<Occurrence>(predicate: predicate)
            if let existing = try? context.fetch(descriptor).first {
                let remoteStatus = OccurrenceStatus(rawValue: record["statusRaw"] as? String ?? "pending") ?? .pending
                if remoteStatus == .confirmed || existing.status == .pending {
                    existing.statusRaw = record["statusRaw"] as? String ?? existing.statusRaw
                    existing.confirmedAt = record["confirmedAt"] as? Date ?? existing.confirmedAt
                    if let actualAmount = record["actualAmount"] as? NSNumber {
                        existing.actualAmount = actualAmount.decimalValue
                    }
                }
            } else {
                let occurrence = Occurrence(
                    dueDate: record["dueDate"] as? Date ?? Date(),
                    expectedAmount: (record["expectedAmount"] as? NSNumber)?.decimalValue ?? 0,
                    actualAmount: (record["actualAmount"] as? NSNumber)?.decimalValue,
                    status: OccurrenceStatus(rawValue: record["statusRaw"] as? String ?? "pending") ?? .pending,
                    confirmedAt: record["confirmedAt"] as? Date,
                    notes: record["notes"] as? String
                )
                occurrence.id = uuid
                if let ref = record["budgetItemRef"] as? CKRecord.Reference,
                   let parentUUID = UUID(uuidString: ref.recordID.recordName) {
                    let parentPred = #Predicate<BudgetItem> { $0.id == parentUUID }
                    let parentDesc = FetchDescriptor<BudgetItem>(predicate: parentPred)
                    occurrence.budgetItem = try? context.fetch(parentDesc).first
                }
                context.insert(occurrence)
            }

        case RecordConversion.familyMemberRecordType:
            let predicate = #Predicate<FamilyMember> { $0.id == uuid }
            let descriptor = FetchDescriptor<FamilyMember>(predicate: predicate)
            if let existing = try? context.fetch(descriptor).first {
                existing.name = record["name"] as? String ?? existing.name
                existing.sortOrder = record["sortOrder"] as? Int ?? existing.sortOrder
            } else {
                let member = FamilyMember(
                    name: record["name"] as? String ?? "Unknown",
                    sortOrder: record["sortOrder"] as? Int ?? 0
                )
                member.id = uuid
                context.insert(member)
            }

        default:
            break
        }
    }

    @MainActor
    private func applyDeletion(_ recordID: CKRecord.ID, recordType: CKRecord.RecordType, in context: ModelContext) {
        guard let uuid = UUID(uuidString: recordID.recordName) else { return }

        switch recordType {
        case RecordConversion.budgetItemRecordType:
            let predicate = #Predicate<BudgetItem> { $0.id == uuid }
            if let item = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: predicate)).first {
                context.delete(item)
            }
        case RecordConversion.occurrenceRecordType:
            let predicate = #Predicate<Occurrence> { $0.id == uuid }
            if let item = try? context.fetch(FetchDescriptor<Occurrence>(predicate: predicate)).first {
                context.delete(item)
            }
        case RecordConversion.familyMemberRecordType:
            let predicate = #Predicate<FamilyMember> { $0.id == uuid }
            if let item = try? context.fetch(FetchDescriptor<FamilyMember>(predicate: predicate)).first {
                context.delete(item)
            }
        default:
            break
        }
    }

    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        for failure in changes.failedRecordSaves {
            logger.error("Failed to save record \(failure.record.recordID.recordName): \(failure.error.localizedDescription)")
        }
    }

}
