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

    /// Extract the CKRecordZone.ID from cached ckRecordData. Returns nil if data is absent or invalid.
    private func zoneIDFromRecordData(_ ckRecordData: Data?) -> CKRecordZone.ID? {
        guard let data = ckRecordData,
              let record = RecordConversion.decodeLastKnownRecord(from: data) else {
            return nil
        }
        return record.recordID.zoneID
    }

    /// Determine whether a model (by UUID) belongs to a shared zone.
    /// Checks the record's own ckRecordData first, then falls back to its parent BudgetItem's ckRecordData
    /// (for Occurrences and AmountOverrides that were created locally for a shared budget item).
    /// Returns the shared zone ID if shared, nil if owned or unknown.
    private func sharedZoneIDForRecord(id: UUID, in context: ModelContext) -> CKRecordZone.ID? {
        // Check Occurrence
        if let occurrence = try? context.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == id })).first {
            if let z = zoneIDFromRecordData(occurrence.ckRecordData), z.ownerName != CKCurrentUserDefaultName {
                return z
            }
            // New local occurrence for a shared budget item
            if let parentData = occurrence.budgetItem?.ckRecordData,
               let z = zoneIDFromRecordData(parentData), z.ownerName != CKCurrentUserDefaultName {
                return z
            }
            return nil
        }
        // Check AmountOverride
        if let override_ = try? context.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == id })).first {
            if let z = zoneIDFromRecordData(override_.ckRecordData), z.ownerName != CKCurrentUserDefaultName {
                return z
            }
            if let parentData = override_.budgetItem?.ckRecordData,
               let z = zoneIDFromRecordData(parentData), z.ownerName != CKCurrentUserDefaultName {
                return z
            }
            return nil
        }
        // Check BudgetItem
        if let item = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == id })).first {
            if let z = zoneIDFromRecordData(item.ckRecordData), z.ownerName != CKCurrentUserDefaultName {
                return z
            }
            return nil
        }
        // Check FamilyMember
        if let member = try? context.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == id })).first {
            if let z = zoneIDFromRecordData(member.ckRecordData), z.ownerName != CKCurrentUserDefaultName {
                return z
            }
            return nil
        }
        // Check DashboardSection
        if let section = try? context.fetch(FetchDescriptor<DashboardSection>(predicate: #Predicate { $0.id == id })).first {
            if let z = zoneIDFromRecordData(section.ckRecordData), z.ownerName != CKCurrentUserDefaultName {
                return z
            }
            return nil
        }
        // Check UserPreferences
        if let preferences = try? context.fetch(FetchDescriptor<UserPreferences>(predicate: #Predicate { $0.id == id })).first {
            if let z = zoneIDFromRecordData(preferences.ckRecordData), z.ownerName != CKCurrentUserDefaultName {
                return z
            }
            return nil
        }
        return nil
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

    func pushSharedChanges(for recordIDs: [CKRecord.ID]) {
        let changes = recordIDs.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0) }
        sharedSyncEngine?.state.add(pendingRecordZoneChanges: changes)
    }

    func pushDeletion(for recordIDs: [CKRecord.ID]) {
        let changes = recordIDs.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord($0) }
        syncEngine?.state.add(pendingRecordZoneChanges: changes)
    }

    func pushSharedDeletion(for recordIDs: [CKRecord.ID]) {
        let changes = recordIDs.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord($0) }
        sharedSyncEngine?.state.add(pendingRecordZoneChanges: changes)
    }

    /// Push a single model object by its UUID, routing to the correct engine (private or shared).
    func pushChange(for id: UUID) {
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        if let sharedZone = sharedZoneIDForRecord(id: id, in: context) {
            let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: sharedZone)
            logger.info("Routing push for \(id.uuidString) to shared engine (zone owner: \(sharedZone.ownerName))")
            pushSharedChanges(for: [recordID])
        } else {
            let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
            pushChanges(for: [recordID])
        }
    }

    /// Push a model change when the caller already has the ckRecordData (avoids redundant DB fetch).
    /// Pass the record's own ckRecordData, plus the parent's ckRecordData for child records (Occurrence, AmountOverride).
    func pushChange(for id: UUID, ckRecordData: Data?, parentCKRecordData: Data? = nil) {
        if let sharedZone = sharedZoneFromCKData(ckRecordData, parentCKRecordData: parentCKRecordData) {
            let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: sharedZone)
            logger.info("Routing push for \(id.uuidString) to shared engine (zone owner: \(sharedZone.ownerName))")
            pushSharedChanges(for: [recordID])
        } else {
            let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
            pushChanges(for: [recordID])
        }
    }

    /// Push deletion for a single model object by its UUID, routing to the correct engine.
    func pushDeletion(for id: UUID) {
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        if let sharedZone = sharedZoneIDForRecord(id: id, in: context) {
            let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: sharedZone)
            logger.info("Routing deletion for \(id.uuidString) to shared engine (zone owner: \(sharedZone.ownerName))")
            pushSharedDeletion(for: [recordID])
        } else {
            let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
            pushDeletion(for: [recordID])
        }
    }

    /// Determine shared zone from already-available ckRecordData, avoiding a DB fetch.
    private func sharedZoneFromCKData(_ ckRecordData: Data?, parentCKRecordData: Data? = nil) -> CKRecordZone.ID? {
        if let z = zoneIDFromRecordData(ckRecordData), z.ownerName != CKCurrentUserDefaultName {
            return z
        }
        if let parentData = parentCKRecordData,
           let z = zoneIDFromRecordData(parentData), z.ownerName != CKCurrentUserDefaultName {
            return z
        }
        return nil
    }

    /// Push all local data to CloudKit and fetch shared changes. Called on .signIn and available manually.
    /// Returns the total number of records queued for push.
    @discardableResult
    func pushAllLocalData() -> Int {
        guard let modelContainer else {
            logger.warning("Cannot push all data: no model container")
            return 0
        }

        let bgContext = ModelContext(modelContainer)
        var ownedRecordIDs: [CKRecord.ID] = []
        var sharedRecordIDs: [CKRecord.ID] = []

        /// Classify a record as owned or shared based on its ckRecordData (or parent's for child records).
        func classify(id: UUID, ckRecordData: Data?, parentCKRecordData: Data? = nil) {
            if let sharedZone = zoneIDFromRecordData(ckRecordData),
               sharedZone.ownerName != CKCurrentUserDefaultName {
                sharedRecordIDs.append(CKRecord.ID(recordName: id.uuidString, zoneID: sharedZone))
            } else if let parentData = parentCKRecordData,
                      let sharedZone = zoneIDFromRecordData(parentData),
                      sharedZone.ownerName != CKCurrentUserDefaultName {
                sharedRecordIDs.append(CKRecord.ID(recordName: id.uuidString, zoneID: sharedZone))
            } else {
                ownedRecordIDs.append(CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
            }
        }

        if let items = try? bgContext.fetch(FetchDescriptor<BudgetItem>()) {
            for item in items { classify(id: item.id, ckRecordData: item.ckRecordData) }
        }
        if let overrides = try? bgContext.fetch(FetchDescriptor<AmountOverride>()) {
            for override_ in overrides {
                classify(id: override_.id, ckRecordData: override_.ckRecordData, parentCKRecordData: override_.budgetItem?.ckRecordData)
            }
        }
        if let occurrences = try? bgContext.fetch(FetchDescriptor<Occurrence>()) {
            for occurrence in occurrences {
                classify(id: occurrence.id, ckRecordData: occurrence.ckRecordData, parentCKRecordData: occurrence.budgetItem?.ckRecordData)
            }
        }
        if let members = try? bgContext.fetch(FetchDescriptor<FamilyMember>()) {
            for member in members { classify(id: member.id, ckRecordData: member.ckRecordData) }
        }
        if let sections = try? bgContext.fetch(FetchDescriptor<DashboardSection>()) {
            for section in sections { classify(id: section.id, ckRecordData: section.ckRecordData) }
        }
        if let preferences = try? bgContext.fetch(FetchDescriptor<UserPreferences>()) {
            for pref in preferences { classify(id: pref.id, ckRecordData: pref.ckRecordData) }
        }

        let totalCount = ownedRecordIDs.count + sharedRecordIDs.count

        if !ownedRecordIDs.isEmpty {
            // Ensure zone is saved first
            syncEngine?.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: zoneID))
            ])
            pushChanges(for: ownedRecordIDs)
            logger.info("Queued \(ownedRecordIDs.count) owned records for push via private engine")
        }

        if !sharedRecordIDs.isEmpty {
            pushSharedChanges(for: sharedRecordIDs)
            logger.info("Queued \(sharedRecordIDs.count) shared records for push via shared engine")
        }

        // Also fetch latest shared data
        fetchSharedChanges()

        return totalCount
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
            Task { @MainActor in
                self.handleSentRecordZoneChanges(sentChanges, fromSharedEngine: isShared)
            }

        case .willFetchChanges:
            Task { @MainActor in syncStatus = .syncing }

        case .didFetchChanges:
            Task { @MainActor in syncStatus = .synced }

        case .willSendChanges:
            Task { @MainActor in syncStatus = .syncing }

        case .didSendChanges:
            Task { @MainActor in syncStatus = .synced }

        @unknown default:
            logger.warning("[\(engineLabel)] Unknown CKSyncEngine event")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine engine: CKSyncEngine
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        let isShared = isSharedEngine(engine)
        let engineLabel = isShared ? "shared" : "private"

        let scope = context.options.scope
        let pendingChanges = engine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pendingChanges.isEmpty, let modelContainer else { return nil }

        let bgContext = ModelContext(modelContainer)
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        /// Re-route a misrouted record to the correct engine instead of silently dropping it.
        func rerouteToCorrectEngine(_ recordID: CKRecord.ID, uuid: UUID, ckRecordData: Data?, parentCKRecordData: Data? = nil) {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            if let sharedZone = sharedZoneFromCKData(ckRecordData, parentCKRecordData: parentCKRecordData) {
                let correctedID = CKRecord.ID(recordName: uuid.uuidString, zoneID: sharedZone)
                logger.info("[\(engineLabel)] Re-routing \(recordID.recordName) to shared engine")
                sharedSyncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(correctedID)])
            } else {
                let correctedID = CKRecord.ID(recordName: uuid.uuidString, zoneID: zoneID)
                logger.info("[\(engineLabel)] Re-routing \(recordID.recordName) to private engine")
                syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(correctedID)])
            }
        }

        for change in pendingChanges {
            switch change {
            case .saveRecord(let recordID):
                guard let uuid = UUID(uuidString: recordID.recordName) else {
                    engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    continue
                }

                // Determine the target zone ID for this record.
                // For the shared engine, use the zone from the pending record ID (set by pushChange routing).
                // For the private engine, use our own zone.
                let targetZoneID = isShared ? recordID.zoneID : zoneID

                if let item = try? bgContext.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == uuid })).first {
                    let fromShared = isFromSharedZone(item.ckRecordData)
                    guard fromShared == isShared else {
                        rerouteToCorrectEngine(recordID, uuid: uuid, ckRecordData: item.ckRecordData)
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: item, zoneID: targetZoneID))
                } else if let override_ = try? bgContext.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == uuid })).first {
                    let fromShared = isFromSharedZone(override_.ckRecordData)
                        || isFromSharedZone(override_.budgetItem?.ckRecordData)
                    guard fromShared == isShared else {
                        rerouteToCorrectEngine(recordID, uuid: uuid, ckRecordData: override_.ckRecordData, parentCKRecordData: override_.budgetItem?.ckRecordData)
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: override_, zoneID: targetZoneID))
                } else if let occurrence = try? bgContext.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == uuid })).first {
                    let fromShared = isFromSharedZone(occurrence.ckRecordData)
                        || isFromSharedZone(occurrence.budgetItem?.ckRecordData)
                    guard fromShared == isShared else {
                        rerouteToCorrectEngine(recordID, uuid: uuid, ckRecordData: occurrence.ckRecordData, parentCKRecordData: occurrence.budgetItem?.ckRecordData)
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: occurrence, zoneID: targetZoneID))
                } else if let member = try? bgContext.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == uuid })).first {
                    let fromShared = isFromSharedZone(member.ckRecordData)
                    guard fromShared == isShared else {
                        rerouteToCorrectEngine(recordID, uuid: uuid, ckRecordData: member.ckRecordData)
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: member, zoneID: targetZoneID))
                } else if let section = try? bgContext.fetch(FetchDescriptor<DashboardSection>(predicate: #Predicate { $0.id == uuid })).first {
                    let fromShared = isFromSharedZone(section.ckRecordData)
                    guard fromShared == isShared else {
                        rerouteToCorrectEngine(recordID, uuid: uuid, ckRecordData: section.ckRecordData)
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: section, zoneID: targetZoneID))
                } else if let preferences = try? bgContext.fetch(FetchDescriptor<UserPreferences>(predicate: #Predicate { $0.id == uuid })).first {
                    let fromShared = isFromSharedZone(preferences.ckRecordData)
                    guard fromShared == isShared else {
                        rerouteToCorrectEngine(recordID, uuid: uuid, ckRecordData: preferences.ckRecordData)
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: preferences, zoneID: targetZoneID))
                } else {
                    // Object deleted locally before send — remove from pending
                    logger.info("[\(engineLabel)] Record \(recordID.recordName) not found locally, removing from pending")
                    engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }
            case .deleteRecord(let recordID):
                recordIDsToDelete.append(recordID)
            @unknown default:
                break
            }
        }

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }
        logger.info("[\(engineLabel)] Sending batch: \(recordsToSave.count) saves, \(recordIDsToDelete.count) deletes")
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

        // Sort modifications so parent records (BudgetItem, FamilyMember) are processed before
        // children (Occurrence, AmountOverride) that reference them via budgetItemRef.
        // Without this, child records inserted before their parent have nil budgetItem relationships.
        let parentTypes: Set<String> = [
            RecordConversion.budgetItemRecordType,
            RecordConversion.familyMemberRecordType,
            RecordConversion.dashboardSectionRecordType,
            RecordConversion.userPreferencesRecordType
        ]
        let sortedModifications = changes.modifications.sorted { a, b in
            let aIsParent = parentTypes.contains(a.record.recordType)
            let bIsParent = parentTypes.contains(b.record.recordType)
            if aIsParent != bIsParent { return aIsParent }
            return false
        }

        for modification in sortedModifications {
            let record = modification.record
            let isFromOtherOwner = record.recordID.zoneID.ownerName != CKCurrentUserDefaultName

            if record.recordType == RecordConversion.dashboardSectionRecordType {
                logger.info("[\(engineLabel)] Sync: applying DashboardSection modification \(record.recordID.recordName) (owner: \(record.recordID.zoneID.ownerName))")
            }

            // Guard: prevent duplicate processing of records delivered by both engines.
            // Private engine: skip records from other owners' zones (handled by shared engine)
            // Shared engine: skip records from our OWN zone (already handled by private engine)
            if !fromSharedEngine && isFromOtherOwner {
                logger.info("[\(engineLabel)] Skipping record \(record.recordID.recordName) from other owner's zone")
                continue
            }
            if fromSharedEngine && !isFromOtherOwner {
                logger.info("[\(engineLabel)] Skipping own record \(record.recordID.recordName) from shared engine (private engine handles these)")
                continue
            }

            applyFetchedRecord(record, to: context)
        }

        // Second pass: repair child records whose parent wasn't available during first pass.
        // Uses the original CKRecord objects (which contain budgetItemRef custom fields)
        // because ckRecordData only stores system fields and cannot be used for relationship repair.
        repairOrphanedRelationships(from: sortedModifications.map(\.record), in: context)

        for deletion in changes.deletions {
            let deletionIsFromOtherOwner = deletion.recordID.zoneID.ownerName != CKCurrentUserDefaultName
            if !fromSharedEngine && deletionIsFromOtherOwner {
                logger.info("[\(engineLabel)] Skipping deletion \(deletion.recordID.recordName) from other owner's zone")
                continue
            }
            if fromSharedEngine && !deletionIsFromOtherOwner {
                logger.info("[\(engineLabel)] Skipping own deletion \(deletion.recordID.recordName) from shared engine")
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
                    defaultCurrency: record["defaultCurrency"] as? String ?? "AUD",
                    rollingWeeklyNet: (record["rollingWeeklyNet"] as? Int ?? 0) == 1
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
        case RecordConversion.userPreferencesRecordType:
            let predicate = #Predicate<UserPreferences> { $0.id == uuid }
            if let item = try? context.fetch(FetchDescriptor<UserPreferences>(predicate: predicate)).first {
                context.delete(item)
            }
        default:
            break
        }
    }

    // MARK: - Orphaned Relationship Repair

    /// Repair Occurrences and AmountOverrides that have nil budgetItem.
    /// Uses the original CKRecord objects from the current batch (which contain budgetItemRef)
    /// because ckRecordData only stores system fields and does NOT include custom fields.
    @MainActor
    private func repairOrphanedRelationships(from records: [CKRecord], in context: ModelContext) {
        // Build a lookup of record UUID → parent UUID from the raw CKRecords
        let childTypes: Set<String> = [
            RecordConversion.occurrenceRecordType,
            RecordConversion.amountOverrideRecordType
        ]
        var parentMap: [UUID: UUID] = [:]
        for record in records where childTypes.contains(record.recordType) {
            guard let uuid = UUID(uuidString: record.recordID.recordName),
                  let ref = record["budgetItemRef"] as? CKRecord.Reference,
                  let parentUUID = UUID(uuidString: ref.recordID.recordName) else { continue }
            parentMap[uuid] = parentUUID
        }

        guard !parentMap.isEmpty else { return }

        // Repair orphaned Occurrences
        let orphanedOccurrences = (try? context.fetch(
            FetchDescriptor<Occurrence>(predicate: #Predicate { $0.budgetItem == nil })
        )) ?? []

        for occurrence in orphanedOccurrences {
            guard let parentUUID = parentMap[occurrence.id] else { continue }
            let pred = #Predicate<BudgetItem> { $0.id == parentUUID }
            if let parent = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: pred)).first {
                occurrence.budgetItem = parent
                logger.info("Repaired orphaned occurrence \(occurrence.id.uuidString) → budgetItem \(parentUUID.uuidString)")
            }
        }

        // Repair orphaned AmountOverrides
        let orphanedOverrides = (try? context.fetch(
            FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.budgetItem == nil })
        )) ?? []

        for override_ in orphanedOverrides {
            guard let parentUUID = parentMap[override_.id] else { continue }
            let pred = #Predicate<BudgetItem> { $0.id == parentUUID }
            if let parent = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: pred)).first {
                override_.budgetItem = parent
                logger.info("Repaired orphaned amountOverride \(override_.id.uuidString) → budgetItem \(parentUUID.uuidString)")
            }
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
    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges, fromSharedEngine: Bool = false) {
        guard let context = modelContainer?.mainContext else { return }
        let engineLabel = fromSharedEngine ? "shared" : "private"
        let targetEngine = fromSharedEngine ? sharedSyncEngine : syncEngine

        // Batch all updates into a single save to avoid per-record main-thread saves
        for savedRecord in changes.savedRecords {
            updateCKRecordData(from: savedRecord, in: context)
            logger.info("[\(engineLabel)] Saved record \(savedRecord.recordID.recordName)")
        }

        // Handle failures
        for failure in changes.failedRecordSaves {
            let recordID = failure.record.recordID
            let error = failure.error

            switch error.code {
            case .serverRecordChanged:
                // Conflict — server has a newer version. Use server record as base and re-queue.
                if let serverRecord = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                    logger.info("[\(engineLabel)] Conflict for \(recordID.recordName) — merging with server record")
                    updateCKRecordData(from: serverRecord, in: context)
                    targetEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }

            case .zoneNotFound:
                if fromSharedEngine {
                    // Shared zone was revoked/deleted by the owner — drop the pending change
                    // to avoid an infinite retry loop (participants can't create zones).
                    logger.warning("[\(engineLabel)] Shared zone not found for \(recordID.recordName) — share may have been revoked. Dropping pending change.")
                    targetEngine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    Task { @MainActor in
                        syncStatus = .error("Shared zone unavailable")
                    }
                } else {
                    // Private zone doesn't exist yet — create it and re-queue the record
                    logger.info("[\(engineLabel)] Zone not found — creating zone and re-queuing \(recordID.recordName)")
                    syncEngine?.state.add(pendingDatabaseChanges: [
                        .saveZone(CKRecordZone(zoneID: zoneID))
                    ])
                    targetEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }

            case .unknownItem:
                // Record doesn't exist on server — clear lastKnownRecord and retry
                logger.info("[\(engineLabel)] Unknown item \(recordID.recordName) — clearing cached record and retrying")
                clearCKRecordData(for: recordID, in: context)
                targetEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .requestRateLimited, .operationCancelled:
                // Transient errors — engine retries automatically
                logger.info("[\(engineLabel)] Transient error for \(recordID.recordName): \(error.localizedDescription)")

            default:
                logger.error("[\(engineLabel)] Failed to save record \(recordID.recordName): \(error.localizedDescription)")
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
        } else if let preferences = try? context.fetch(FetchDescriptor<UserPreferences>(predicate: #Predicate { $0.id == uuid })).first {
            preferences.ckRecordData = nil
        }
    }
}
