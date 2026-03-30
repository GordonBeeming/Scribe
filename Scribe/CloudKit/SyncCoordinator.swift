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
    private var sharedSyncEngine: CKSyncEngine?
    private var modelContainer: ModelContainer?

    private let stateKey = "syncEngineState"
    private let sharedStateKey = "sharedSyncEngineState"
    private let zoneName = "ScribeBudgetZone"

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Whether the given engine is the shared database engine (read-only, for receiving shared data)
    private func isSharedEngine(_ engine: CKSyncEngine) -> Bool {
        engine === sharedSyncEngine
    }

    /// Check if a record's ckRecordData indicates it originated from a shared zone (not the user's own private zone).
    /// Returns true if the record should be skipped by the private engine.
    private func isFromSharedZone(_ ckRecordData: Data?) -> Bool {
        guard let data = ckRecordData,
              let record = RecordConversion.decodeLastKnownRecord(from: data) else {
            return false
        }
        return record.recordID.zoneID.ownerName != CKCurrentUserDefaultName
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

                // Private database engine (owns the data, reads + writes)
                let configuration = CKSyncEngine.Configuration(
                    database: CloudKitManager.shared.privateDatabase,
                    stateSerialization: loadSyncEngineState(forKey: stateKey),
                    delegate: self
                )
                let engine = CKSyncEngine(configuration)
                self.syncEngine = engine

                // Ensure our zone exists via the engine's pending database changes
                engine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: zoneID))
                ])

                // Shared database engine (read-only, receives data shared by others)
                let sharedConfig = CKSyncEngine.Configuration(
                    database: CloudKitManager.shared.sharedDatabase,
                    stateSerialization: loadSyncEngineState(forKey: sharedStateKey),
                    delegate: self
                )
                let sharedEngine = CKSyncEngine(sharedConfig)
                self.sharedSyncEngine = sharedEngine

                await MainActor.run { syncStatus = .synced }
                logger.info("CKSyncEngine started successfully (private + shared)")
            } catch {
                logger.error("Failed to start sync: \(error.localizedDescription)")
                await MainActor.run { syncStatus = .error(error.localizedDescription) }
            }
        }
    }

    func stop() {
        syncEngine = nil
        sharedSyncEngine = nil
    }

    /// Trigger an immediate fetch on the shared database engine (e.g. after accepting a share)
    func fetchSharedChanges() {
        guard let sharedSyncEngine else {
            logger.warning("Cannot fetch shared changes: shared sync engine not started")
            return
        }
        let options = CKSyncEngine.FetchChangesOptions()
        Task {
            do {
                try await sharedSyncEngine.fetchChanges(options)
                logger.info("Shared changes fetch completed")
            } catch {
                logger.error("Failed to fetch shared changes: \(error.localizedDescription)")
            }
        }
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
        if let sections = try? bgContext.fetch(FetchDescriptor<DashboardSection>()) {
            recordIDs.append(contentsOf: sections.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
        }
        if let adjustments = try? bgContext.fetch(FetchDescriptor<QuickAdjustment>()) {
            recordIDs.append(contentsOf: adjustments.map {
                CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
            })
        }
        if let preferences = try? bgContext.fetch(FetchDescriptor<UserPreferences>()) {
            recordIDs.append(contentsOf: preferences.map {
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

    private func loadSyncEngineState(forKey key: String) -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveSyncEngineState(_ state: CKSyncEngine.State.Serialization, forKey key: String) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?.set(data, forKey: key)
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncCoordinator: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine engine: CKSyncEngine) {
        let isShared = isSharedEngine(engine)
        let engineLabel = isShared ? "shared" : "private"

        switch event {
        case .stateUpdate(let stateUpdate):
            let key = isShared ? sharedStateKey : stateKey
            saveSyncEngineState(stateUpdate.stateSerialization, forKey: key)

        case .accountChange(let accountChange):
            if !isShared {
                handleAccountChange(accountChange)
            } else {
                switch accountChange.changeType {
                case .switchAccounts:
                    // Clear shared state on account switch
                    UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?.removeObject(forKey: sharedStateKey)
                default:
                    break
                }
            }

        case .fetchedDatabaseChanges(let dbChanges):
            handleFetchedDatabaseChanges(dbChanges, isShared: isShared)

        case .fetchedRecordZoneChanges(let fetchedChanges):
            logger.info("[\(engineLabel)] Fetched record zone changes: \(fetchedChanges.modifications.count) mods, \(fetchedChanges.deletions.count) dels")
            Task { @MainActor in
                self.handleFetchedRecordZoneChanges(fetchedChanges, fromSharedEngine: isShared)
            }

        case .sentDatabaseChanges:
            break

        case .sentRecordZoneChanges(let sentChanges):
            if !isShared {
                Task { @MainActor in
                    self.handleSentRecordZoneChanges(sentChanges)
                }
            }

        case .willFetchChanges:
            Task { @MainActor in syncStatus = .syncing }

        case .didFetchChanges:
            Task { @MainActor in syncStatus = .synced }

        case .willSendChanges:
            if !isShared {
                Task { @MainActor in syncStatus = .syncing }
            }

        case .didSendChanges:
            if !isShared {
                Task { @MainActor in syncStatus = .synced }
            }

        @unknown default:
            logger.warning("[\(engineLabel)] Unknown CKSyncEngine event")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine engine: CKSyncEngine
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        // Shared engine is read-only -- never push changes
        if isSharedEngine(engine) { return nil }

        let scope = context.options.scope
        let pendingChanges = engine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pendingChanges.isEmpty, let modelContainer else { return nil }

        let zoneID = self.zoneID
        let bgContext = ModelContext(modelContainer)
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        for change in pendingChanges {
            switch change {
            case .saveRecord(let recordID):
                guard let uuid = UUID(uuidString: recordID.recordName) else {
                    engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    continue
                }
                if let item = try? bgContext.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == uuid })).first {
                    guard !isFromSharedZone(item.ckRecordData) else {
                        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: item, zoneID: zoneID))
                } else if let override_ = try? bgContext.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == uuid })).first {
                    guard !isFromSharedZone(override_.ckRecordData) else {
                        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: override_, zoneID: zoneID))
                } else if let occurrence = try? bgContext.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == uuid })).first {
                    guard !isFromSharedZone(occurrence.ckRecordData) else {
                        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: occurrence, zoneID: zoneID))
                } else if let member = try? bgContext.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == uuid })).first {
                    guard !isFromSharedZone(member.ckRecordData) else {
                        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: member, zoneID: zoneID))
                } else if let section = try? bgContext.fetch(FetchDescriptor<DashboardSection>(predicate: #Predicate { $0.id == uuid })).first {
                    guard !isFromSharedZone(section.ckRecordData) else {
                        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: section, zoneID: zoneID))
                } else if let adjustment = try? bgContext.fetch(FetchDescriptor<QuickAdjustment>(predicate: #Predicate { $0.id == uuid })).first {
                    guard !isFromSharedZone(adjustment.ckRecordData) else {
                        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: adjustment, zoneID: zoneID))
                } else if let preferences = try? bgContext.fetch(FetchDescriptor<UserPreferences>(predicate: #Predicate { $0.id == uuid })).first {
                    guard !isFromSharedZone(preferences.ckRecordData) else {
                        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: preferences, zoneID: zoneID))
                } else {
                    // Object deleted locally before send — remove from pending
                    logger.info("Record \(recordID.recordName) not found locally, removing from pending")
                    engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
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
            let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
            defaults?.removeObject(forKey: stateKey)
            defaults?.removeObject(forKey: sharedStateKey)

        @unknown default:
            break
        }
    }

    // MARK: - Fetched Database Changes

    private func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges, isShared: Bool) {
        let engineLabel = isShared ? "shared" : "private"

        for modification in changes.modifications {
            logger.info("[\(engineLabel)] Zone modified: \(modification.zoneID.zoneName) (owner: \(modification.zoneID.ownerName))")
        }

        for deletion in changes.deletions {
            // Only treat this as "our" zone deletion when it matches the private engine's zoneID.
            let isOurPrivateZoneDeletion = !isShared && (deletion.zoneID == zoneID)
            if isOurPrivateZoneDeletion {
                logger.warning("[\(engineLabel)] Our private zone was deleted — clearing local data")
                Task { @MainActor in
                    guard let context = modelContainer?.mainContext else { return }
                    DataManagementService.clearAllData(in: context)
                }
            } else if isShared && deletion.zoneID.zoneName == zoneName {
                logger.info("[\(engineLabel)] Shared zone revoked: \(deletion.zoneID.zoneName) (owner: \(deletion.zoneID.ownerName))")
            }
        }
    }

    // MARK: - Fetched Record Zone Changes

    @MainActor
    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, fromSharedEngine: Bool = false) {
        guard let context = modelContainer?.mainContext else { return }

        let engineLabel = fromSharedEngine ? "shared" : "private"
        let sectionCountBefore = (try? context.fetchCount(FetchDescriptor<DashboardSection>())) ?? -1
        logger.info("[\(engineLabel)] handleFetchedRecordZoneChanges: \(changes.modifications.count) modifications, \(changes.deletions.count) deletions (DashboardSections before: \(sectionCountBefore))")

        for modification in changes.modifications {
            let record = modification.record
            let isFromOtherOwner = record.recordID.zoneID.ownerName != CKCurrentUserDefaultName

            if record.recordType == RecordConversion.dashboardSectionRecordType {
                logger.info("[\(engineLabel)] Sync: applying DashboardSection modification \(record.recordID.recordName) (owner: \(record.recordID.zoneID.ownerName))")
            }

            // Guard: if the private engine delivers a record from another owner's zone, skip it.
            // This prevents duplicate inserts when the same record is delivered by both engines.
            if !fromSharedEngine && isFromOtherOwner {
                logger.info("[\(engineLabel)] Skipping record \(record.recordID.recordName) from other owner's zone (owner: \(record.recordID.zoneID.ownerName))")
                continue
            }

            applyFetchedRecord(record, to: context)
        }

        for deletion in changes.deletions {
            // Guard: skip deletions from another owner's zone on the private engine (same as modifications)
            if !fromSharedEngine && deletion.recordID.zoneID.ownerName != CKCurrentUserDefaultName {
                logger.info("[\(engineLabel)] Skipping deletion \(deletion.recordID.recordName) from other owner's zone (owner: \(deletion.recordID.zoneID.ownerName))")
                continue
            }

            if deletion.recordType == RecordConversion.dashboardSectionRecordType {
                logger.warning("[\(engineLabel)] Sync: applying DashboardSection DELETION \(deletion.recordID.recordName)")
            }
            applyDeletion(deletion.recordID, recordType: deletion.recordType, in: context)
        }

        do {
            try context.save()
        } catch {
            logger.error("Failed to save fetched record zone changes: \(error.localizedDescription)")
        }

        let sectionCountAfter = (try? context.fetchCount(FetchDescriptor<DashboardSection>())) ?? -1
        if sectionCountBefore != sectionCountAfter {
            logger.warning("DashboardSection count changed: \(sectionCountBefore) -> \(sectionCountAfter)")
        }
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
                    // Restore familyMembers relationship
                    restoreFamilyMembers(from: record, to: existing, in: context)
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
                item.budgetReflectionRaw = record["budgetReflectionRaw"] as? String
                item.payDayAdjustmentDays = record["payDayAdjustmentDays"] as? String
                item.publicHolidayCountryCode = record["publicHolidayCountryCode"] as? String
                item.endDate = record["endDate"] as? Date
                context.insert(item)
                // Restore familyMembers relationship
                restoreFamilyMembers(from: record, to: item, in: context)
            }

        case RecordConversion.occurrenceRecordType:
            let predicate = #Predicate<Occurrence> { $0.id == uuid }
            if let existing = try? context.fetch(FetchDescriptor<Occurrence>(predicate: predicate)).first {
                let remoteModified = record["modifiedAt"] as? Date ?? Date.distantPast
                if remoteModified >= existing.modifiedAt {
                    RecordConversion.applyRecord(record, to: existing)
                }
                existing.ckRecordData = ckData
                // Restore budgetItem relationship if missing (may have been nil if parent wasn't synced yet)
                if existing.budgetItem == nil,
                   let ref = record["budgetItemRef"] as? CKRecord.Reference,
                   let parentUUID = UUID(uuidString: ref.recordID.recordName) {
                    let parentPred = #Predicate<BudgetItem> { $0.id == parentUUID }
                    existing.budgetItem = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: parentPred)).first
                }
            } else {
                // Check for a duplicate occurrence with same budgetItem + dueDate (created locally with a different UUID)
                let remoteDueDate = record["dueDate"] as? Date ?? Date()
                if let ref = record["budgetItemRef"] as? CKRecord.Reference,
                   let parentUUID = UUID(uuidString: ref.recordID.recordName) {
                    // Use the same Gregorian+UTC calendar as deterministicID for consistent day boundaries
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
                    let dueDateStart = calendar.startOfDay(for: remoteDueDate)
                    let dueDateEnd = calendar.date(byAdding: .day, value: 1, to: dueDateStart) ?? dueDateStart
                    let dupPred = #Predicate<Occurrence> {
                        $0.budgetItem?.id == parentUUID &&
                        $0.dueDate >= dueDateStart &&
                        $0.dueDate < dueDateEnd
                    }
                    if let localDuplicate = try? context.fetch(FetchDescriptor<Occurrence>(predicate: dupPred)).first {
                        // Merge: prefer the remote record (it has a CloudKit record ID), update the existing local one
                        let remoteModified = record["modifiedAt"] as? Date ?? Date.distantPast
                        let remoteStatus = OccurrenceStatus(rawValue: record["statusRaw"] as? String ?? "pending") ?? .pending
                        // Keep whichever has a more "advanced" status (confirmed > skipped > pending)
                        let shouldApplyRemote = remoteModified >= localDuplicate.modifiedAt
                            || (remoteStatus == .confirmed && localDuplicate.status != .confirmed)
                        if shouldApplyRemote {
                            RecordConversion.applyRecord(record, to: localDuplicate)
                        }
                        // Update UUID to match the remote record so future syncs find it.
                        // Preserve the original local ID so we can log and diagnose the merge correctly.
                        let originalLocalId = localDuplicate.id
                        localDuplicate.id = uuid
                        localDuplicate.ckRecordData = ckData
                        logger.info("Merged duplicate occurrence remote \(uuid.uuidString) with local \(originalLocalId.uuidString) (updated local id to match remote) for budgetItem \(parentUUID.uuidString)")
                        break
                    }
                }

                let occurrence = Occurrence(
                    dueDate: remoteDueDate,
                    expectedAmount: (record["expectedAmount"] as? NSNumber)?.decimalValue ?? 0,
                    actualAmount: (record["actualAmount"] as? NSNumber)?.decimalValue,
                    status: OccurrenceStatus(rawValue: record["statusRaw"] as? String ?? "pending") ?? .pending,
                    confirmedAt: record["confirmedAt"] as? Date,
                    notes: record["notes"] as? String
                )
                occurrence.id = uuid
                occurrence.createdAt = record["createdAt"] as? Date ?? Date()
                occurrence.modifiedAt = record["modifiedAt"] as? Date ?? Date()
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
                let remoteModified = record["modifiedAt"] as? Date ?? Date.distantPast
                if remoteModified >= existing.modifiedAt {
                    RecordConversion.applyRecord(record, to: existing)
                }
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
                override_.createdAt = record["createdAt"] as? Date ?? Date()
                override_.modifiedAt = record["modifiedAt"] as? Date ?? Date()
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
                let remoteModified = record["modifiedAt"] as? Date ?? Date.distantPast
                if remoteModified >= existing.modifiedAt {
                    RecordConversion.applyRecord(record, to: existing)
                }
                existing.ckRecordData = ckData
            } else {
                let member = FamilyMember(
                    name: record["name"] as? String ?? "Unknown",
                    sortOrder: record["sortOrder"] as? Int ?? 0
                )
                member.id = uuid
                member.createdAt = record["createdAt"] as? Date ?? Date()
                member.modifiedAt = record["modifiedAt"] as? Date ?? Date()
                member.ckRecordData = ckData
                context.insert(member)
            }

        case RecordConversion.dashboardSectionRecordType:
            let predicate = #Predicate<DashboardSection> { $0.id == uuid }
            if let existing = try? context.fetch(FetchDescriptor<DashboardSection>(predicate: predicate)).first {
                let remoteModified = record["modifiedAt"] as? Date ?? Date.distantPast
                if remoteModified >= existing.modifiedAt {
                    RecordConversion.applyRecord(record, to: existing)
                }
                existing.ckRecordData = ckData
            } else {
                let section = DashboardSection(
                    sectionType: DashboardSectionType(rawValue: record["sectionTypeRaw"] as? String ?? "detailedWeekly") ?? .detailedWeekly,
                    anchor: {
                        if let anchorRaw = record["anchorRaw"] as? String,
                           let data = anchorRaw.data(using: .utf8),
                           let decoded = try? JSONDecoder().decode(DashboardSectionAnchor.self, from: data) {
                            return decoded
                        }
                        return .fixedDay(weekday: 2)
                    }(),
                    isEnabled: (record["isEnabled"] as? Int ?? 1) == 1,
                    sortOrder: record["sortOrder"] as? Int ?? 0,
                    label: record["label"] as? String ?? "Section"
                )
                section.id = uuid
                section.createdAt = record["createdAt"] as? Date ?? Date()
                section.modifiedAt = record["modifiedAt"] as? Date ?? Date()
                section.ckRecordData = ckData
                context.insert(section)
            }

        case RecordConversion.quickAdjustmentRecordType:
            let predicate = #Predicate<QuickAdjustment> { $0.id == uuid }
            if let existing = try? context.fetch(FetchDescriptor<QuickAdjustment>(predicate: predicate)).first {
                let remoteModified = record["modifiedAt"] as? Date ?? Date.distantPast
                if remoteModified >= existing.modifiedAt {
                    RecordConversion.applyRecord(record, to: existing)
                }
                existing.ckRecordData = ckData
            } else {
                let adjustment = QuickAdjustment(
                    type: QuickAdjustmentType(rawValue: record["adjustmentTypeRaw"] as? String ?? "expense") ?? .expense,
                    date: record["date"] as? Date ?? Date(),
                    amount: (record["amount"] as? NSNumber)?.decimalValue ?? 0,
                    name: record["name"] as? String ?? "Unknown",
                    currencyCode: record["currencyCode"] as? String ?? "AUD",
                    notes: record["notes"] as? String
                )
                adjustment.id = uuid
                adjustment.createdAt = record["createdAt"] as? Date ?? Date()
                adjustment.modifiedAt = record["modifiedAt"] as? Date ?? Date()
                adjustment.ckRecordData = ckData
                context.insert(adjustment)
            }

        case RecordConversion.userPreferencesRecordType:
            let predicate = #Predicate<UserPreferences> { $0.id == uuid }
            if let existing = try? context.fetch(FetchDescriptor<UserPreferences>(predicate: predicate)).first {
                let remoteModified = record["modifiedAt"] as? Date ?? Date.distantPast
                if remoteModified >= existing.modifiedAt {
                    RecordConversion.applyRecord(record, to: existing)
                }
                existing.ckRecordData = ckData
            } else {
                let preferences = UserPreferences(
                    defaultRangeRaw: record["defaultRangeRaw"] as? String ?? "14days",
                    lookbackDays: record["lookbackDays"] as? Int ?? 5,
                    defaultCurrency: record["defaultCurrency"] as? String ?? "AUD"
                )
                preferences.id = uuid
                preferences.createdAt = record["createdAt"] as? Date ?? Date()
                preferences.modifiedAt = record["modifiedAt"] as? Date ?? Date()
                preferences.ckRecordData = ckData
                preferences.syncToUserDefaults()
                context.insert(preferences)
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
        case RecordConversion.dashboardSectionRecordType:
            let predicate = #Predicate<DashboardSection> { $0.id == uuid }
            if let item = try? context.fetch(FetchDescriptor<DashboardSection>(predicate: predicate)).first {
                context.delete(item)
            }
        case RecordConversion.quickAdjustmentRecordType:
            let predicate = #Predicate<QuickAdjustment> { $0.id == uuid }
            if let item = try? context.fetch(FetchDescriptor<QuickAdjustment>(predicate: predicate)).first {
                context.delete(item)
            }
        case RecordConversion.userPreferencesRecordType:
            let predicate = #Predicate<UserPreferences> { $0.id == uuid }
            if let item = try? context.fetch(FetchDescriptor<UserPreferences>(predicate: predicate)).first {
                context.delete(item)
            }
        default:
            break
        }
    }

    // MARK: - Family Member Relationship Restoration

    @MainActor
    private func restoreFamilyMembers(from record: CKRecord, to item: BudgetItem, in context: ModelContext) {
        if let memberIDStrings = record["familyMemberIDs"] as? [String] {
            let memberUUIDs = memberIDStrings.compactMap { UUID(uuidString: $0) }
            item.familyMembers = memberUUIDs.compactMap { memberUUID in
                let pred = #Predicate<FamilyMember> { $0.id == memberUUID }
                return try? context.fetch(FetchDescriptor<FamilyMember>(predicate: pred)).first
            }
        } else {
            item.familyMembers = []
        }
    }

    // MARK: - Sent Record Zone Changes (success & error handling)

    @MainActor
    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        guard let context = modelContainer?.mainContext else { return }

        // Batch all updates into a single save to avoid per-record main-thread saves
        for savedRecord in changes.savedRecords {
            updateCKRecordData(from: savedRecord, in: context)
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
                    updateCKRecordData(from: serverRecord, in: context)
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
                clearCKRecordData(for: recordID, in: context)
                syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .requestRateLimited, .operationCancelled:
                // Transient errors — engine retries automatically
                logger.info("Transient error for \(recordID.recordName): \(error.localizedDescription)")

            default:
                logger.error("Failed to save record \(recordID.recordName): \(error.localizedDescription)")
            }
        }

        // Single save for all batched updates
        do {
            try context.save()
        } catch {
            logger.error("Failed to save sent record zone changes: \(error.localizedDescription)")
        }
    }

    /// Apply CKRecord system fields to the matching local model (no save — caller batches saves).
    @MainActor
    private func updateCKRecordData(from record: CKRecord, in context: ModelContext) {
        guard let uuid = UUID(uuidString: record.recordID.recordName) else { return }

        let ckData = RecordConversion.encodeSystemFields(of: record)

        if let item = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == uuid })).first {
            item.ckRecordData = ckData
        } else if let override_ = try? context.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == uuid })).first {
            override_.ckRecordData = ckData
        } else if let occurrence = try? context.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == uuid })).first {
            occurrence.ckRecordData = ckData
        } else if let member = try? context.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == uuid })).first {
            member.ckRecordData = ckData
        } else if let section = try? context.fetch(FetchDescriptor<DashboardSection>(predicate: #Predicate { $0.id == uuid })).first {
            section.ckRecordData = ckData
        } else if let adjustment = try? context.fetch(FetchDescriptor<QuickAdjustment>(predicate: #Predicate { $0.id == uuid })).first {
            adjustment.ckRecordData = ckData
        } else if let preferences = try? context.fetch(FetchDescriptor<UserPreferences>(predicate: #Predicate { $0.id == uuid })).first {
            preferences.ckRecordData = ckData
        }
    }

    /// Clear cached CKRecord system fields so next upload creates a fresh record (no save — caller batches saves).
    @MainActor
    private func clearCKRecordData(for recordID: CKRecord.ID, in context: ModelContext) {
        guard let uuid = UUID(uuidString: recordID.recordName) else { return }

        if let item = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == uuid })).first {
            item.ckRecordData = nil
        } else if let override_ = try? context.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == uuid })).first {
            override_.ckRecordData = nil
        } else if let occurrence = try? context.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == uuid })).first {
            occurrence.ckRecordData = nil
        } else if let member = try? context.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == uuid })).first {
            member.ckRecordData = nil
        } else if let section = try? context.fetch(FetchDescriptor<DashboardSection>(predicate: #Predicate { $0.id == uuid })).first {
            section.ckRecordData = nil
        } else if let adjustment = try? context.fetch(FetchDescriptor<QuickAdjustment>(predicate: #Predicate { $0.id == uuid })).first {
            adjustment.ckRecordData = nil
        } else if let preferences = try? context.fetch(FetchDescriptor<UserPreferences>(predicate: #Predicate { $0.id == uuid })).first {
            preferences.ckRecordData = nil
        }
    }
}
