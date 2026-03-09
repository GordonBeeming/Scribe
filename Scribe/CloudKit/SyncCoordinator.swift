import Foundation
import CloudKit
import SwiftData
import os

/// Bridges SwiftData <-> CKSyncEngine following Apple's reference implementation.
/// The engine automatically fetches remote changes and sends local changes.
/// On first launch (nil state), it fetches all existing server records AND
/// pushes all local records (triggered by the .accountChange .signIn event).
final class SyncCoordinator: @unchecked Sendable {
    static let shared = SyncCoordinator()

    private let logger = Logger(subsystem: "com.gordonbeeming.scribe", category: "SyncCoordinator")
    private var syncEngine: CKSyncEngine?
    private var modelContainer: ModelContainer?

    private let stateKey = "syncEngineState"
    private let zoneName = "ScribeBudgetZone"

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    @MainActor
    var syncStatus: SyncStatus = .idle

    enum SyncStatus: Sendable {
        case idle
        case syncing
        case synced
        case error(String)
    }

    private init() {}

    // MARK: - Lifecycle

    @MainActor
    func start(with container: ModelContainer) {
        self.modelContainer = container

        // Skip CloudKit in test environment
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        Task {
            do {
                let status = try await CloudKitManager.shared.checkAccountStatus()
                logger.info("iCloud account status: \(String(describing: status))")
                switch status {
                case .available:
                    break
                case .temporarilyUnavailable:
                    logger.info("iCloud temporarily unavailable, proceeding anyway")
                default:
                    logger.warning("iCloud not available (status: \(String(describing: status)))")
                    await MainActor.run { syncStatus = .error("iCloud not available") }
                    return
                }

                let configuration = CKSyncEngine.Configuration(
                    database: CloudKitManager.shared.privateDatabase,
                    stateSerialization: loadSyncEngineState(),
                    delegate: self
                )
                let engine = CKSyncEngine(configuration)
                self.syncEngine = engine

                // Ensure our zone exists via the engine's pending database changes
                engine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: zoneID))
                ])

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

    /// Push a single model object by its UUID
    func pushChange(for id: UUID) {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        pushChanges(for: [recordID])
    }

    /// Push deletion for a single model object by its UUID
    func pushDeletion(for id: UUID) {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        pushDeletion(for: [recordID])
    }

    /// Push all local data to CloudKit. Called on .signIn and available manually.
    func pushAllLocalData() {
        guard let modelContainer else {
            logger.warning("Cannot push all data: no model container")
            return
        }

        let bgContext = ModelContext(modelContainer)
        var recordIDs: [CKRecord.ID] = []

        if let items = try? bgContext.fetch(FetchDescriptor<BudgetItem>()) {
            recordIDs.append(contentsOf: items.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
        }
        if let overrides = try? bgContext.fetch(FetchDescriptor<AmountOverride>()) {
            recordIDs.append(contentsOf: overrides.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
        }
        if let occurrences = try? bgContext.fetch(FetchDescriptor<Occurrence>()) {
            recordIDs.append(contentsOf: occurrences.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
        }
        if let members = try? bgContext.fetch(FetchDescriptor<FamilyMember>()) {
            recordIDs.append(contentsOf: members.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
        }

        if !recordIDs.isEmpty {
            // Ensure zone is saved first
            syncEngine?.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: zoneID))
            ])
            pushChanges(for: recordIDs)
            logger.info("Queued \(recordIDs.count) records for push to CloudKit")
        }
    }

    // MARK: - State persistence

    private func loadSyncEngineState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?.data(forKey: stateKey) else {
            return nil
        }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveSyncEngineState(_ state: CKSyncEngine.State.Serialization) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?.set(data, forKey: stateKey)
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

        case .fetchedDatabaseChanges(let dbChanges):
            handleFetchedDatabaseChanges(dbChanges)

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
        let scope = context.options.scope
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pendingChanges.isEmpty, let modelContainer else { return nil }

        let zoneID = self.zoneID
        let bgContext = ModelContext(modelContainer)
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        for change in pendingChanges {
            switch change {
            case .saveRecord(let recordID):
                guard let uuid = UUID(uuidString: recordID.recordName) else {
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    continue
                }
                if let item = try? bgContext.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == uuid })).first {
                    recordsToSave.append(RecordConversion.record(from: item, zoneID: zoneID))
                } else if let override_ = try? bgContext.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == uuid })).first {
                    recordsToSave.append(RecordConversion.record(from: override_, zoneID: zoneID))
                } else if let occurrence = try? bgContext.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == uuid })).first {
                    recordsToSave.append(RecordConversion.record(from: occurrence, zoneID: zoneID))
                } else if let member = try? bgContext.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == uuid })).first {
                    recordsToSave.append(RecordConversion.record(from: member, zoneID: zoneID))
                } else {
                    // Object deleted locally before send — remove from pending
                    logger.info("Record \(recordID.recordName) not found locally, removing from pending")
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
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

    // MARK: - Account Changes

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            // First time connecting (or reconnecting) — push all local data
            // so it reaches the server. The engine will also fetch any server data.
            logger.info("iCloud account signed in — pushing all local data")
            syncEngine?.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: zoneID))
            ])
            pushAllLocalData()

        case .signOut:
            logger.info("iCloud account signed out")
            Task { @MainActor in syncStatus = .error("Signed out of iCloud") }

        case .switchAccounts:
            // Different account — clear local data and let the new account's data come in
            logger.info("iCloud account switched — clearing local sync state")
            UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?.removeObject(forKey: stateKey)

        @unknown default:
            break
        }
    }

    // MARK: - Fetched Database Changes (zone deletions)

    private func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in changes.deletions {
            if deletion.zoneID == zoneID {
                logger.warning("Our zone was deleted from the server — clearing local data")
                Task { @MainActor in
                    guard let context = modelContainer?.mainContext else { return }
                    DataManagementService.clearAllData(in: context)
                }
            }
        }
    }

    // MARK: - Fetched Record Zone Changes

    @MainActor
    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        guard let context = modelContainer?.mainContext else { return }

        for modification in changes.modifications {
            let record = modification.record
            applyFetchedRecord(record, to: context)
        }

        for deletion in changes.deletions {
            applyDeletion(deletion.recordID, recordType: deletion.recordType, in: context)
        }

        try? context.save()
    }

    @MainActor
    private func applyFetchedRecord(_ record: CKRecord, to context: ModelContext) {
        guard let uuid = UUID(uuidString: record.recordID.recordName) else { return }
        let ckData = RecordConversion.encodeSystemFields(of: record)

        switch record.recordType {
        case RecordConversion.budgetItemRecordType:
            let predicate = #Predicate<BudgetItem> { $0.id == uuid }
            if let existing = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: predicate)).first {
                let remoteModified = record["modifiedAt"] as? Date ?? Date.distantPast
                if remoteModified >= existing.modifiedAt {
                    RecordConversion.applyRecord(record, to: existing)
                }
                existing.ckRecordData = ckData
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
                item.ckRecordData = ckData
                context.insert(item)
            }

        case RecordConversion.occurrenceRecordType:
            let predicate = #Predicate<Occurrence> { $0.id == uuid }
            if let existing = try? context.fetch(FetchDescriptor<Occurrence>(predicate: predicate)).first {
                let remoteStatus = OccurrenceStatus(rawValue: record["statusRaw"] as? String ?? "pending") ?? .pending
                if remoteStatus == .confirmed || existing.status == .pending {
                    existing.statusRaw = record["statusRaw"] as? String ?? existing.statusRaw
                    existing.confirmedAt = record["confirmedAt"] as? Date ?? existing.confirmedAt
                    if let actualAmount = record["actualAmount"] as? NSNumber {
                        existing.actualAmount = actualAmount.decimalValue
                    }
                }
                existing.ckRecordData = ckData
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
                occurrence.ckRecordData = ckData
                if let ref = record["budgetItemRef"] as? CKRecord.Reference,
                   let parentUUID = UUID(uuidString: ref.recordID.recordName) {
                    let parentPred = #Predicate<BudgetItem> { $0.id == parentUUID }
                    occurrence.budgetItem = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: parentPred)).first
                }
                context.insert(occurrence)
            }

        case RecordConversion.amountOverrideRecordType:
            let predicate = #Predicate<AmountOverride> { $0.id == uuid }
            if let existing = try? context.fetch(FetchDescriptor<AmountOverride>(predicate: predicate)).first {
                existing.effectiveDate = record["effectiveDate"] as? Date ?? existing.effectiveDate
                if let amount = record["amount"] as? NSNumber {
                    existing.amount = amount.decimalValue
                }
                existing.overrideDayOfMonth = record["overrideDayOfMonth"] as? Int
                existing.overrideReferenceDate = record["overrideReferenceDate"] as? Date
                existing.notes = record["notes"] as? String
                existing.ckRecordData = ckData
            } else {
                let override_ = AmountOverride(
                    effectiveDate: record["effectiveDate"] as? Date ?? Date(),
                    amount: (record["amount"] as? NSNumber)?.decimalValue ?? 0,
                    overrideDayOfMonth: record["overrideDayOfMonth"] as? Int,
                    overrideReferenceDate: record["overrideReferenceDate"] as? Date,
                    notes: record["notes"] as? String
                )
                override_.id = uuid
                override_.ckRecordData = ckData
                if let ref = record["budgetItemRef"] as? CKRecord.Reference,
                   let parentUUID = UUID(uuidString: ref.recordID.recordName) {
                    let parentPred = #Predicate<BudgetItem> { $0.id == parentUUID }
                    override_.budgetItem = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: parentPred)).first
                }
                context.insert(override_)
            }

        case RecordConversion.familyMemberRecordType:
            let predicate = #Predicate<FamilyMember> { $0.id == uuid }
            if let existing = try? context.fetch(FetchDescriptor<FamilyMember>(predicate: predicate)).first {
                existing.name = record["name"] as? String ?? existing.name
                existing.sortOrder = record["sortOrder"] as? Int ?? existing.sortOrder
                existing.ckRecordData = ckData
            } else {
                let member = FamilyMember(
                    name: record["name"] as? String ?? "Unknown",
                    sortOrder: record["sortOrder"] as? Int ?? 0
                )
                member.id = uuid
                member.ckRecordData = ckData
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
        case RecordConversion.amountOverrideRecordType:
            let predicate = #Predicate<AmountOverride> { $0.id == uuid }
            if let item = try? context.fetch(FetchDescriptor<AmountOverride>(predicate: predicate)).first {
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

    // MARK: - Sent Record Zone Changes (success & error handling)

    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        // Update lastKnownRecord for successful saves
        for savedRecord in changes.savedRecords {
            updateCKRecordData(from: savedRecord)
        }

        // Handle failures
        for failure in changes.failedRecordSaves {
            let recordID = failure.record.recordID
            let error = failure.error

            switch error.code {
            case .serverRecordChanged:
                // Conflict — server has a newer version. Use server record as base and re-queue.
                if let serverRecord = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                    logger.info("Conflict for \(recordID.recordName) — merging with server record")
                    updateCKRecordData(from: serverRecord)
                    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }

            case .zoneNotFound:
                // Zone doesn't exist yet — save zone and re-queue the record
                logger.info("Zone not found — creating zone and re-queuing \(recordID.recordName)")
                syncEngine?.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: zoneID))
                ])
                syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

            case .unknownItem:
                // Record doesn't exist on server — clear lastKnownRecord and retry
                logger.info("Unknown item \(recordID.recordName) — clearing cached record and retrying")
                clearCKRecordData(for: recordID)
                syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .requestRateLimited, .operationCancelled:
                // Transient errors — engine retries automatically
                logger.info("Transient error for \(recordID.recordName): \(error.localizedDescription)")

            default:
                logger.error("Failed to save record \(recordID.recordName): \(error.localizedDescription)")
            }
        }
    }

    /// Persist CKRecord system fields after a successful save or when resolving a conflict.
    private func updateCKRecordData(from record: CKRecord) {
        guard let modelContainer,
              let uuid = UUID(uuidString: record.recordID.recordName) else { return }

        let ckData = RecordConversion.encodeSystemFields(of: record)
        let bgContext = ModelContext(modelContainer)

        if let item = try? bgContext.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == uuid })).first {
            item.ckRecordData = ckData
        } else if let override_ = try? bgContext.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == uuid })).first {
            override_.ckRecordData = ckData
        } else if let occurrence = try? bgContext.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == uuid })).first {
            occurrence.ckRecordData = ckData
        } else if let member = try? bgContext.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == uuid })).first {
            member.ckRecordData = ckData
        }

        try? bgContext.save()
    }

    /// Clear cached CKRecord system fields so next upload creates a fresh record.
    private func clearCKRecordData(for recordID: CKRecord.ID) {
        guard let modelContainer,
              let uuid = UUID(uuidString: recordID.recordName) else { return }

        let bgContext = ModelContext(modelContainer)

        if let item = try? bgContext.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == uuid })).first {
            item.ckRecordData = nil
        } else if let override_ = try? bgContext.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == uuid })).first {
            override_.ckRecordData = nil
        } else if let occurrence = try? bgContext.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == uuid })).first {
            occurrence.ckRecordData = nil
        } else if let member = try? bgContext.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == uuid })).first {
            member.ckRecordData = nil
        }

        try? bgContext.save()
    }
}
