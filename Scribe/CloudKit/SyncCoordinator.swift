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
    private let legacySharedDeletionScrubKey = "didScrubLegacySharedDeletions"
    private let legacySharedDeletionQuarantineKey = "legacySharedDeletionQuarantine"
    private let deferredChangesKey = "deferredRecordZoneChanges"
    private let lastKnownUserRecordNameKey = "lastKnownUserRecordName"

    /// The quarantine stores one entry per record ID: zone name, owner name and record name joined
    /// by a newline. CloudKit allows none of the three to contain a newline, so the split back is
    /// unambiguous for any ID we could be handed.
    private static let quarantineFieldSeparator = "\n"
    private let zoneName = "ScribeBudgetZone"

    /// Settings that belong to one iCloud account rather than to the shared budget. They use
    /// fixed UUIDs, so letting them travel through the share makes both family members fight
    /// over the same record names.
    private static let perUserRecordTypes: Set<String> = [
        RecordConversion.userPreferencesRecordType,
        RecordConversion.dashboardSectionRecordType
    ]

    /// A push queued before the engines existed. `start(with:)` builds them asynchronously
    /// after an account-status check, so without this buffer every launch-time push is added
    /// to a nil engine and silently lost.
    /// Internal rather than private so the UserDefaults round-trip can be tested without standing
    /// up a live sync engine.
    struct DeferredChange {
        enum Target: String {
            case privateDatabase = "private"
            case sharedDatabase = "shared"
        }

        let target: Target
        let change: CKSyncEngine.PendingRecordZoneChange
    }

    /// Guards the buffer, the two engine properties, *and* the handover of changes to an engine.
    /// Reading the engine and buffering have to be atomic, or a push can read a nil engine, lose
    /// the race to the drain, and sit buffered until the next launch. Handing changes over has to
    /// be inside the same hold, or `stop()` can nil the engines in between and the change lands on
    /// a discarded engine — `pushAllLocalData()` re-queues saves after a resync, but not
    /// deletions. Holding the lock across `state.add` is safe: it is an in-memory append that
    /// never calls back into us synchronously, so it cannot deadlock.
    private let deferredChangesLock = NSLock()
    private var deferredChanges: [DeferredChange] = []

    /// Engines `stop()` has retired. `fetchAllChanges()` and the deletion scrub hold engine
    /// references across a restart, so a discarded engine can still deliver events. Honouring a
    /// `.stateUpdate` from one would write its stale serialization under the live key and
    /// resurrect the very token a resync just dropped. Identity is matched rather than comparing
    /// against the live engine, because an event can fire between `CKSyncEngine(...)` and
    /// publication and must still be handled. The engines are retained as the values: an
    /// identifier is just an address, and a deallocated engine's address can be handed to a new
    /// one, whose events would then be ignored for the rest of the process. A handful per process,
    /// so it is never pruned.
    private var retiredEngines: [ObjectIdentifier: CKSyncEngine] = [:]

    /// Bumped whenever the buffer is discarded for an account switch. Work in flight from the
    /// previous account must not write anything after it.
    private var sessionEpoch = 0

    /// Deletions handed to an engine but not yet confirmed by the server. They have already left
    /// `pendingRecordZoneChanges`, so if a resync retires the engine mid-request nothing would ever
    /// retry them and the record would survive on the server. `stop()` rescues these too.
    private var inFlightDeletions: [DeferredChange] = []

    /// Record names whose private-zone copy is currently being fetched by
    /// `recoverHijackedPerUserRecords`, so a second recovery is not started for the same record.
    private var recoveringPerUserRecords: Set<String> = []

    /// Set while the legacy-deletion classification pass is running, so a second one can't start
    /// alongside it and process the same quarantine entries twice.
    private var isScrubbing = false

    /// Bumped by every `start(with:)`. An earlier account-status check can still be awaiting when a
    /// resync starts another, and whichever finishes last would otherwise publish over the other's
    /// engines, orphaning them with their pending changes still aboard.
    private var startGeneration = 0

    /// The fixed UUIDs every device seeds per-user settings with. They are the only per-user
    /// records identifiable from a record name alone.
    private static let wellKnownPerUserIDs: Set<UUID> = [
        UserPreferences.sharedID,
        DashboardSection.defaultSummaryID,
        DashboardSection.defaultUpcomingID
    ]

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Whether the given engine is the shared database engine (read-only, for receiving shared
    /// data). Asked of the engine's own database rather than compared against `sharedSyncEngine`,
    /// which is nil until `publishEngines`: an early callback would otherwise read as private and
    /// skip every shared-engine gate.
    private func isSharedEngine(_ engine: CKSyncEngine) -> Bool {
        engine.database.databaseScope == .shared
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

    /// Whether cached ckRecordData describes one of the per-user settings records.
    private func isPerUserRecord(_ ckRecordData: Data?) -> Bool {
        guard let data = ckRecordData,
              let record = RecordConversion.decodeLastKnownRecord(from: data) else {
            return false
        }
        return Self.perUserRecordTypes.contains(record.recordType)
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
        // DashboardSection and UserPreferences are per-user settings: always this account's own,
        // whatever a hijacked cache says about their zone.
        return nil
    }

    @MainActor
    var syncStatus: SyncStatus = .idle {
        didSet {
            // Only stamp on a real sync cycle completing (.syncing → .synced), not the
            // initial .synced set when the engines are merely started, which would show
            // a misleading "Last synced" before anything has actually synced.
            if case .synced = syncStatus, case .syncing = oldValue {
                lastSyncDate = Date()
            }
        }
    }

    /// Timestamp of the last successful sync, surfaced in Settings so the user can
    /// tell whether sync is actually progressing.
    @MainActor
    var lastSyncDate: Date?

    /// Number of local changes still queued for upload across both engines. A count
    /// that never drains is the signal that sync is stuck.
    @MainActor
    var pendingChangeCount: Int {
        (syncEngine?.state.pendingRecordZoneChanges.count ?? 0)
            + (sharedSyncEngine?.state.pendingRecordZoneChanges.count ?? 0)
    }

    enum SyncStatus: Sendable {
        case idle
        case syncing
        case synced
        case error(String)
    }

    /// Set by `forceFullResync()` so the re-upload runs *after* `start(with:)` has
    /// asynchronously recreated the engines — pushing before they exist is a no-op.
    @MainActor
    private var pendingResyncPush = false

    private init() {
        // The buffer outlives the process: a push made before the engines exist is only in memory
        // until it drains, and a termination in that window would lose a deletion for good, since
        // nothing walks a deleted model again on the next ordinary launch.
        deferredChanges = loadDeferredChanges()
    }

    // MARK: - Lifecycle

    @MainActor
    func start(with container: ModelContainer) {
        self.modelContainer = container

        // Skip CloudKit in test environment
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        recoverHijackedPerUserRecords(reclaimPerUserRecords())

        deferredChangesLock.lock()
        startGeneration += 1
        let generation = startGeneration
        deferredChangesLock.unlock()

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

                // The buffer and the migration state outlive the process, and a relaunch under a
                // different account never sees `.switchAccounts` — the engine only reports a switch
                // it observed. Without this the drain in publishEngines would hand the previous
                // account's record IDs to the new account's engine.
                do {
                    let userRecordName = try await CloudKitManager.shared.container.userRecordID().recordName
                    if let previous = loadLastKnownUserRecordName(), previous != userRecordName {
                        logger.info("iCloud account changed since the last launch — discarding the previous account's buffered work")
                        discardBufferedChanges()
                        discardMigrationState()
                    }
                    saveLastKnownUserRecordName(userRecordName)
                } catch {
                    logger.error("Could not confirm the iCloud account, not publishing engines: \(error.localizedDescription)")
                    return
                }

                // Private database engine (owns the data, reads + writes)
                let configuration = CKSyncEngine.Configuration(
                    database: CloudKitManager.shared.privateDatabase,
                    stateSerialization: loadSyncEngineState(forKey: stateKey),
                    delegate: self
                )
                let engine = CKSyncEngine(configuration)

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

                guard self.claimPublication(generation: generation, private: engine, shared: sharedEngine) else {
                    logger.info("Discarding engines from a superseded start")
                    return
                }
                self.publishEngines(private: engine, shared: sharedEngine)

                // Engines now exist — run a resync re-upload if one was requested.
                // forceFullResync() can't push directly because we get here async.
                await MainActor.run {
                    if pendingResyncPush {
                        pendingResyncPush = false
                        _ = pushAllLocalData()
                    }
                    syncStatus = .synced
                }
                logger.info("CKSyncEngine started successfully (private + shared)")
            } catch {
                logger.error("Failed to start sync: \(error.localizedDescription)")
                await MainActor.run { syncStatus = .error(error.localizedDescription) }
            }
        }
    }

    /// Drops both engines, rescuing whatever they still had queued into the buffer so the restart
    /// drains it into the new engines.
    ///
    /// Saves would survive anyway, because `pushAllLocalData()` re-queues every local record after
    /// a resync. Deletions would not: the model is already gone locally, so nothing walks it again
    /// and the record stays on the server for good. Re-queued saves that duplicate what
    /// `pushAllLocalData()` adds are harmless, since pending changes are a set.
    func stop() {
        deferredChangesLock.lock()
        if let syncEngine {
            deferredChanges.append(contentsOf: syncEngine.state.pendingRecordZoneChanges.map {
                DeferredChange(target: .privateDatabase, change: $0)
            })
            retiredEngines[ObjectIdentifier(syncEngine)] = syncEngine
        }
        if let sharedSyncEngine {
            deferredChanges.append(contentsOf: sharedSyncEngine.state.pendingRecordZoneChanges.map {
                DeferredChange(target: .sharedDatabase, change: $0)
            })
            retiredEngines[ObjectIdentifier(sharedSyncEngine)] = sharedSyncEngine
        }
        deferredChanges.append(contentsOf: inFlightDeletions)
        inFlightDeletions.removeAll()
        syncEngine = nil
        sharedSyncEngine = nil
        saveDeferredChanges(deferredChanges)
        deferredChangesLock.unlock()
    }

    /// Trigger an immediate fetch on the shared database engine (e.g. after accepting a share)
    func fetchSharedChanges() {
        guard let sharedSyncEngine else {
            logger.warning("Cannot fetch shared changes: shared sync engine not started")
            return
        }
        let options = CKSyncEngine.FetchChangesOptions()
        // Detached so the fetch never inherits the caller's executor. This is
        // reachable from inside a CKSyncEngine delegate callback (sign-in and
        // forceFullResync both route here via pushAllLocalData), and calling
        // fetchChanges on the engine's own serial delegate executor trips its
        // re-entrancy guard and traps (EXC_BREAKPOINT).
        Task.detached { [sharedSyncEngine, logger] in
            do {
                try await sharedSyncEngine.fetchChanges(options)
                logger.info("Shared changes fetch completed")
            } catch {
                logger.error("Failed to fetch shared changes: \(error.localizedDescription)")
            }
        }
    }

    /// Fetch immediately on every running engine. The sync engine's own fetch schedule is
    /// documented as indeterminate, so an app that only ever waits can show minutes-old data
    /// after coming to the foreground.
    func fetchAllChanges() {
        // Snapshot under the lock: stop() and publishEngines() mutate both properties under it.
        deferredChangesLock.lock()
        var engines: [(label: String, engine: CKSyncEngine)] = []
        if let syncEngine { engines.append(("private", syncEngine)) }
        if let sharedSyncEngine { engines.append(("shared", sharedSyncEngine)) }
        deferredChangesLock.unlock()

        guard !engines.isEmpty else {
            logger.debug("Cannot fetch changes: sync engines not started")
            return
        }

        // Detached so the fetch never inherits the caller's executor. Calling fetchChanges on
        // the engine's own serial delegate executor trips its re-entrancy guard and traps.
        Task.detached { [engines, logger] in
            for entry in engines {
                do {
                    try await entry.engine.fetchChanges(CKSyncEngine.FetchChangesOptions())
                    logger.info("[\(entry.label)] Foreground fetch completed")
                } catch {
                    logger.error("[\(entry.label)] Foreground fetch failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Push local changes

    /// Add pending changes to an engine, or buffer them when that engine doesn't exist yet.
    /// Everything happens inside one `deferredChangesLock` hold; see the lock's declaration.
    /// `ifSessionEpoch` makes the account check part of the same critical section as the handover,
    /// so work from a previous account cannot slip in between a check and an add.
    private func enqueue(
        _ changes: [CKSyncEngine.PendingRecordZoneChange],
        to target: DeferredChange.Target,
        ifSessionEpoch: Int? = nil
    ) {
        guard !changes.isEmpty else { return }
        let label = target == .privateDatabase ? "private" : "shared"

        deferredChangesLock.lock()
        if let ifSessionEpoch, ifSessionEpoch != sessionEpoch {
            deferredChangesLock.unlock()
            logger.info("Dropping \(changes.count) change(s) from a previous account session")
            return
        }
        guard let engine = target == .privateDatabase ? syncEngine : sharedSyncEngine else {
            deferredChanges.append(contentsOf: changes.map { DeferredChange(target: target, change: $0) })
            let buffered = deferredChanges.count
            saveDeferredChanges(deferredChanges)
            deferredChangesLock.unlock()
            logger.info("Deferred \(changes.count) change(s) for the \(label) engine until it starts (\(buffered) buffered)")
            return
        }
        engine.state.add(pendingRecordZoneChanges: changes)
        deferredChangesLock.unlock()
    }

    /// Throw away everything buffered. Only for an account switch: the buffered changes name
    /// records in the previous account's zones, so draining them into the new account's engine
    /// would push one person's data at another's store.
    private func discardBufferedChanges() {
        deferredChangesLock.lock()
        let discarded = deferredChanges.count
        deferredChanges.removeAll()
        saveDeferredChanges(deferredChanges)
        sessionEpoch += 1
        deferredChangesLock.unlock()
        if discarded > 0 {
            logger.info("Discarded \(discarded) buffered change(s) belonging to the previous account")
        }
    }

    /// Drop the one-off migration state on an account switch. The done flag and the quarantine are
    /// not account-scoped: the previous account's flag would skip the new account's scrub entirely,
    /// and a leftover quarantine entry would be classified against the wrong shared database.
    private func discardMigrationState() {
        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        defaults?.removeObject(forKey: legacySharedDeletionScrubKey)
        defaults?.removeObject(forKey: legacySharedDeletionQuarantineKey)
    }

    /// Whether this start attempt is still the current one and may publish its engines. A newer
    /// `start(with:)` wins, and the superseded attempt's engines are retired on the spot so their
    /// events are ignored rather than racing the live pair. A method rather than an inline lock
    /// because `NSLock.lock()` is unavailable from the async context this runs in.
    private func claimPublication(
        generation: Int,
        private privateEngine: CKSyncEngine,
        shared sharedEngine: CKSyncEngine
    ) -> Bool {
        deferredChangesLock.lock()
        defer { deferredChangesLock.unlock() }
        guard generation == startGeneration else {
            retiredEngines[ObjectIdentifier(privateEngine)] = privateEngine
            retiredEngines[ObjectIdentifier(sharedEngine)] = sharedEngine
            return false
        }
        return true
    }

    /// Publish both engines and hand the buffered work over, all in one lock hold so no push can
    /// slip between the two and no `stop()` can discard an engine mid-handover.
    private func publishEngines(private privateEngine: CKSyncEngine, shared sharedEngine: CKSyncEngine) {
        deferredChangesLock.lock()
        syncEngine = privateEngine
        sharedSyncEngine = sharedEngine
        let buffered = deferredChanges
        deferredChanges.removeAll()
        saveDeferredChanges(deferredChanges)

        let privateChanges = buffered.filter { $0.target == .privateDatabase }.map(\.change)
        let sharedChanges = buffered.filter { $0.target == .sharedDatabase }.map(\.change)
        if !privateChanges.isEmpty {
            privateEngine.state.add(pendingRecordZoneChanges: privateChanges)
        }
        if !sharedChanges.isEmpty {
            sharedEngine.state.add(pendingRecordZoneChanges: sharedChanges)
        }
        deferredChangesLock.unlock()

        if !buffered.isEmpty {
            logger.info("Drained deferred changes: \(privateChanges.count) private, \(sharedChanges.count) shared")
        }

        scrubLegacySharedDeletionsIfNeeded(on: sharedEngine)
    }

    /// One-time repair for deletions the old build queued on the shared engine before per-user
    /// records were kept out of the share. The cheap guard in `nextRecordZoneChangeBatch` catches
    /// the three well-known settings IDs, but a custom section's UUID is random and a pending
    /// deletion carries no record type, so the only way to classify one is to ask the server what
    /// the record is. Sending it blind would delete the owner's data.
    ///
    /// `nextRecordZoneChangeBatch` is the gate, not this pass. The engine is live from its
    /// initialiser and can ask for a batch before `publishEngines(...)` runs, so withholding has to
    /// happen where sends are actually assembled. This is the classifier: it works through whatever
    /// the gate quarantined. A candidate leaves the quarantine only once classified — dropped when
    /// the server says it is a per-user record or that the record is already gone, re-queued
    /// through `enqueue` when it is any other type. A lookup that fails for any other reason leaves
    /// it quarantined and the done flag unset, so the next publication retries it. The flag is set,
    /// and the gate stops withholding, only when the quarantine is empty.
    private func scrubLegacySharedDeletionsIfNeeded(on sharedEngine: CKSyncEngine) {
        guard !legacySharedDeletionScrubIsDone || !loadLegacySharedDeletionQuarantine().isEmpty else { return }

        // Collecting from the engine is belt-and-braces now the gate quarantines on the way out.
        // It still catches anything queued before this build ever assembled a batch.
        let pendingCandidates: [CKRecord.ID] = sharedEngine.state.pendingRecordZoneChanges.compactMap { change in
            guard case .deleteRecord(let recordID) = change,
                  recordID.zoneID.ownerName != CKCurrentUserDefaultName else { return nil }
            return recordID
        }

        if !pendingCandidates.isEmpty {
            sharedEngine.state.remove(pendingRecordZoneChanges: pendingCandidates.map { .deleteRecord($0) })
            for recordID in pendingCandidates {
                quarantineLegacySharedDeletion(recordID)
            }
        }

        runLegacySharedDeletionClassification()
    }

    /// Whether the legacy deletion pass has finished for good on this device.
    private var legacySharedDeletionScrubIsDone: Bool {
        UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?
            .bool(forKey: legacySharedDeletionScrubKey) == true
    }

    /// Flip the in-flight flag. A plain method rather than an inline lock because `NSLock.lock()`
    /// is unavailable from an async context, and the classification pass clears this from one.
    private func setScrubbing(_ value: Bool) {
        deferredChangesLock.lock()
        isScrubbing = value
        deferredChangesLock.unlock()
    }

    /// The current account session. A method for the same reason as `setScrubbing`.
    private func currentSessionEpoch() -> Int {
        deferredChangesLock.lock()
        defer { deferredChangesLock.unlock() }
        return sessionEpoch
    }

    /// Record deletions handed to an engine, so `stop()` can rescue any the server never confirmed.
    private func trackInFlightDeletions(_ recordIDs: [CKRecord.ID], target: DeferredChange.Target) {
        guard !recordIDs.isEmpty else { return }
        deferredChangesLock.lock()
        inFlightDeletions.append(contentsOf: recordIDs.map {
            DeferredChange(target: target, change: .deleteRecord($0))
        })
        deferredChangesLock.unlock()
    }

    /// Forget deletions the server has now answered for, whether it accepted them or refused them.
    /// A refusal leaves the change back on the engine, which retries it itself.
    private func clearInFlightDeletions(_ recordIDs: [CKRecord.ID]) {
        guard !recordIDs.isEmpty else { return }
        let names = Set(recordIDs.map(\.recordName))
        deferredChangesLock.lock()
        inFlightDeletions.removeAll { deferred in
            guard case .deleteRecord(let id) = deferred.change else { return false }
            return names.contains(id.recordName)
        }
        deferredChangesLock.unlock()
    }

    /// Serialises the quarantine's read-modify-write cycles. The gate runs on the engine's queue
    /// and the classification pass in a detached task, so without this a gate insert landing
    /// between a pass's load and save is dropped, the following empty check sets the done flag,
    /// and an unclassified deletion ships.
    private let quarantineLock = NSLock()

    /// Apply a change to the persisted quarantine as one atomic read-modify-write. Returns whether
    /// the quarantine is empty afterwards, so a caller deciding the done flag reads the same
    /// snapshot it just wrote.
    @discardableResult
    private func mutateQuarantine(_ body: (inout [CKRecord.ID]) -> Void) -> Bool {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        var quarantined = loadLegacySharedDeletionQuarantine()
        body(&quarantined)
        saveLegacySharedDeletionQuarantine(quarantined)
        return quarantined.isEmpty
    }

    /// Add one record ID to the persisted quarantine, if it isn't already there.
    private func quarantineLegacySharedDeletion(_ recordID: CKRecord.ID) {
        mutateQuarantine { quarantined in
            guard !quarantined.contains(recordID) else { return }
            quarantined.append(recordID)
        }
    }

    /// Ask the server what each quarantined deletion refers to and act on the answer. Only one pass
    /// runs at a time, so a gate that quarantines something while a pass is already working cannot
    /// make two passes classify the same entries.
    private func runLegacySharedDeletionClassification() {
        let candidates = loadLegacySharedDeletionQuarantine()

        deferredChangesLock.lock()
        guard !isScrubbing else {
            deferredChangesLock.unlock()
            return
        }
        guard !candidates.isEmpty else {
            deferredChangesLock.unlock()
            UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?
                .set(true, forKey: legacySharedDeletionScrubKey)
            return
        }
        isScrubbing = true
        deferredChangesLock.unlock()

        logger.info("Classifying \(candidates.count) quarantined legacy shared deletion(s)")

        // Re-adds go through enqueue rather than a captured engine: this pass is long enough for a
        // forceFullResync() to replace the engines underneath it, and a deletion put back on a
        // discarded engine is gone for good. enqueue lands it on whichever engine is current, or
        // buffers it when the restart is still in flight.
        let epoch = currentSessionEpoch()

        Task.detached { [self, logger, legacySharedDeletionScrubKey] in
            var remaining = candidates
            // Real deletions are held here rather than enqueued as they are classified. While the
            // done flag is still false the gate would quarantine each one straight back, and the
            // per-candidate write would then filter it out for being a classified candidate,
            // losing it from both queues. They go out once the flag is set, or back into the
            // quarantine for a later pass if anything is still unclassified.
            var toRestore: [CKRecord.ID] = []
            var restored = 0
            var dropped = 0

            for recordID in candidates {
                do {
                    let record = try await CloudKitManager.shared.sharedDatabase.record(for: recordID)
                    if Self.perUserRecordTypes.contains(record.recordType) {
                        dropped += 1
                        logger.info("Dropped legacy shared deletion \(recordID.recordName) (\(record.recordType)) — per-user records never travel through the share")
                    } else {
                        toRestore.append(recordID)
                        restored += 1
                    }
                    remaining.removeAll { $0 == recordID }
                } catch let error as CKError where error.code == .unknownItem {
                    dropped += 1
                    remaining.removeAll { $0 == recordID }
                    logger.info("Legacy shared deletion \(recordID.recordName) — record already gone from the server, dropping")
                } catch {
                    logger.error("Could not classify legacy shared deletion \(recordID.recordName), staying quarantined: \(error.localizedDescription)")
                }
                guard currentSessionEpoch() == epoch else {
                    logger.info("Account switched mid-classification — abandoning the pass")
                    setScrubbing(false)
                    return
                }
                // Persisted per candidate so an interrupted pass resumes from where it stopped.
                // Dropping just the one classified ID, rather than rewriting the whole list, is
                // what keeps anything the gate quarantined meanwhile.
                if !remaining.contains(recordID) {
                    mutateQuarantine { quarantined in
                        quarantined.removeAll { $0 == recordID }
                    }
                }
            }

            setScrubbing(false)

            guard currentSessionEpoch() == epoch else {
                logger.info("Account switched mid-classification — abandoning the pass")
                return
            }

            // The park and the emptiness check are one atomic step, so the done flag is decided on
            // the same snapshot that was just written. Anything still unclassified means the gate
            // is still withholding, so the confirmed deletions are parked for a later pass.
            let quarantineIsEmpty = mutateQuarantine { quarantined in
                guard !quarantined.isEmpty else { return }
                quarantined.append(contentsOf: toRestore.filter { !quarantined.contains($0) })
            }

            if quarantineIsEmpty {
                // Flag first, so the gate stops withholding before these go back on the queue.
                UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?
                    .set(true, forKey: legacySharedDeletionScrubKey)
                for recordID in toRestore {
                    enqueue([.deleteRecord(recordID)], to: .sharedDatabase, ifSessionEpoch: epoch)
                }
                logger.info("Legacy shared deletion scrub complete: \(restored) re-queued, \(dropped) dropped")
            } else {
                logger.error("Legacy shared deletion scrub incomplete: \(remaining.count) still quarantined, \(toRestore.count) confirmed deletion(s) parked, retrying on the next start (\(dropped) dropped)")
            }
        }
    }

    /// The iCloud user this device last synced as, or nil on a first run. Internal rather than
    /// private so the UserDefaults round-trip can be tested without standing up a live sync engine.
    func loadLastKnownUserRecordName() -> String? {
        UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?
            .string(forKey: lastKnownUserRecordNameKey)
    }

    /// Record the iCloud user this device is syncing as. Internal for the same reason as the loader.
    func saveLastKnownUserRecordName(_ recordName: String) {
        UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?
            .set(recordName, forKey: lastKnownUserRecordNameKey)
    }

    /// Read the persisted deferred changes. Internal rather than private so the UserDefaults
    /// round-trip can be tested without standing up a live sync engine.
    func loadDeferredChanges() -> [DeferredChange] {
        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        guard let entries = defaults?.stringArray(forKey: deferredChangesKey) else { return [] }
        return entries.compactMap { entry in
            let parts = entry.components(separatedBy: Self.quarantineFieldSeparator)
            guard parts.count == 5, let target = DeferredChange.Target(rawValue: parts[0]) else {
                return nil
            }
            let recordID = CKRecord.ID(
                recordName: parts[4],
                zoneID: CKRecordZone.ID(zoneName: parts[2], ownerName: parts[3])
            )
            let change: CKSyncEngine.PendingRecordZoneChange
            switch parts[1] {
            case "save": change = .saveRecord(recordID)
            case "delete": change = .deleteRecord(recordID)
            default: return nil
            }
            return DeferredChange(target: target, change: change)
        }
    }

    /// Replace the persisted deferred changes. Internal for the same reason as the loader.
    /// Callers that mutate `deferredChanges` already hold `deferredChangesLock`, so this must not
    /// take it: `NSLock` is not recursive.
    func saveDeferredChanges(_ changes: [DeferredChange]) {
        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        guard !changes.isEmpty else {
            defaults?.removeObject(forKey: deferredChangesKey)
            return
        }
        let entries: [String] = changes.compactMap { deferred in
            let kind: String
            let recordID: CKRecord.ID
            switch deferred.change {
            case .saveRecord(let id):
                kind = "save"
                recordID = id
            case .deleteRecord(let id):
                kind = "delete"
                recordID = id
            @unknown default:
                return nil
            }
            return [
                deferred.target.rawValue,
                kind,
                recordID.zoneID.zoneName,
                recordID.zoneID.ownerName,
                recordID.recordName
            ].joined(separator: Self.quarantineFieldSeparator)
        }
        defaults?.set(entries, forKey: deferredChangesKey)
    }

    /// Read the quarantined legacy deletions. Internal rather than private so the UserDefaults
    /// round-trip can be tested without standing up a live sync engine.
    func loadLegacySharedDeletionQuarantine() -> [CKRecord.ID] {
        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        guard let entries = defaults?.stringArray(forKey: legacySharedDeletionQuarantineKey) else {
            return []
        }
        return entries.compactMap { entry in
            let parts = entry.components(separatedBy: Self.quarantineFieldSeparator)
            guard parts.count == 3 else { return nil }
            return CKRecord.ID(
                recordName: parts[2],
                zoneID: CKRecordZone.ID(zoneName: parts[0], ownerName: parts[1])
            )
        }
    }

    /// Replace the quarantined legacy deletions. Internal for the same reason as the loader.
    func saveLegacySharedDeletionQuarantine(_ recordIDs: [CKRecord.ID]) {
        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        guard !recordIDs.isEmpty else {
            defaults?.removeObject(forKey: legacySharedDeletionQuarantineKey)
            return
        }
        let entries = recordIDs.map { recordID in
            [recordID.zoneID.zoneName, recordID.zoneID.ownerName, recordID.recordName]
                .joined(separator: Self.quarantineFieldSeparator)
        }
        defaults?.set(entries, forKey: legacySharedDeletionQuarantineKey)
    }

    func pushChanges(for recordIDs: [CKRecord.ID]) {
        enqueue(recordIDs.map { .saveRecord($0) }, to: .privateDatabase)
    }

    func pushSharedChanges(for recordIDs: [CKRecord.ID]) {
        enqueue(recordIDs.map { .saveRecord($0) }, to: .sharedDatabase)
    }

    func pushDeletion(for recordIDs: [CKRecord.ID]) {
        enqueue(recordIDs.map { .deleteRecord($0) }, to: .privateDatabase)
    }

    func pushSharedDeletion(for recordIDs: [CKRecord.ID]) {
        enqueue(recordIDs.map { .deleteRecord($0) }, to: .sharedDatabase)
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
        // Per-user settings stay in this account's own zone even when their cached record was
        // overwritten with the other family member's zone.
        if isPerUserRecord(ckRecordData) { return nil }
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
        /// Per-user settings are always owned, whatever their cached zone says.
        func classify(id: UUID, ckRecordData: Data?, parentCKRecordData: Data? = nil, isPerUser: Bool = false) {
            if isPerUser {
                ownedRecordIDs.append(CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
            } else if let sharedZone = zoneIDFromRecordData(ckRecordData),
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
            for section in sections { classify(id: section.id, ckRecordData: section.ckRecordData, isPerUser: true) }
        }
        if let preferences = try? bgContext.fetch(FetchDescriptor<UserPreferences>()) {
            for pref in preferences { classify(id: pref.id, ckRecordData: pref.ckRecordData, isPerUser: true) }
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

        deferredChangesLock.lock()
        let isRetired = retiredEngines[ObjectIdentifier(engine)] != nil
        deferredChangesLock.unlock()
        guard !isRetired else {
            logger.debug("[\(engineLabel)] Ignoring event from a retired engine")
            return
        }

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
                    discardBufferedChanges()
                    discardMigrationState()
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

        // Retired engines are retained, so one can still ask for a batch. It must never send.
        deferredChangesLock.lock()
        let isRetired = retiredEngines[ObjectIdentifier(engine)] != nil
        deferredChangesLock.unlock()
        guard !isRetired else {
            logger.debug("[\(engineLabel)] Refusing to build a batch for a retired engine")
            return nil
        }

        let scope = context.options.scope
        let pendingChanges = engine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pendingChanges.isEmpty, let modelContainer else { return nil }

        let bgContext = ModelContext(modelContainer)
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var quarantinedThisBatch = false

        /// Keep a per-user settings record out of the share. The shared engine must never send one,
        /// and a private-engine send whose cache points at the other account's zone is handed to
        /// recovery rather than uploaded.
        /// Returns true when the change was handled and must not be added to the batch.
        func handlePerUserRecord(_ recordID: CKRecord.ID, ckRecordData: Data?) -> Bool {
            guard isShared else {
                if isFromSharedZone(ckRecordData) {
                    // A queued save is not proof the user edited this: pushAllLocalData() queues
                    // every per-user record on sign-in and on resync, so the values in memory may
                    // still be the other member's. Uploading them as a fresh record would be
                    // rejected as existing, and the conflict merge has no ancestor to work from, so
                    // last-writer-wins could overwrite this account's private copy. Recovery reads
                    // that copy from the server, which is the only answer that cannot lose it.
                    logger.info("[\(engineLabel)] Deferring per-user record \(recordID.recordName) to recovery instead of pushing possibly-hijacked values")
                    engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    recoverHijackedPerUserRecords([
                        CKRecord.ID(recordName: recordID.recordName, zoneID: zoneID)
                    ])
                    return true
                }
                // A change queued by an earlier build can still name a foreign zone. The record we
                // send is built in our own zone, so the stale pending entry would never be
                // satisfied — replace it with one the send can clear.
                guard recordID.zoneID == zoneID else {
                    engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    engine.state.add(pendingRecordZoneChanges: [
                        .saveRecord(CKRecord.ID(recordName: recordID.recordName, zoneID: zoneID))
                    ])
                    logger.info("[\(engineLabel)] Re-queued per-user record \(recordID.recordName) into our own zone")
                    return true
                }
                return false
            }
            logger.info("[\(engineLabel)] Per-user record \(recordID.recordName) never travels through the share — dropping")
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return true
        }

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
                    if handlePerUserRecord(recordID, ckRecordData: section.ckRecordData) {
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: section, zoneID: zoneID))
                } else if let preferences = try? bgContext.fetch(FetchDescriptor<UserPreferences>(predicate: #Predicate { $0.id == uuid })).first {
                    if handlePerUserRecord(recordID, ckRecordData: preferences.ckRecordData) {
                        continue
                    }
                    recordsToSave.append(RecordConversion.record(from: preferences, zoneID: zoneID))
                } else {
                    // Object deleted locally before send — remove from pending
                    logger.info("[\(engineLabel)] Record \(recordID.recordName) not found locally, removing from pending")
                    engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }
            case .deleteRecord(let recordID):
                // A deletion the old build queued on the shared engine for a hijacked per-user
                // record would delete the owner's settings after the upgrade. Current routing
                // never queues one, so this only catches what is already persisted in the engine
                // state. This is the gate rather than the scrub, because the engine is live from
                // its initialiser and can ask for a batch before publishEngines() gets to run.
                //
                // The well-known IDs are recognisable on sight and go straight in the bin.
                if isShared,
                   let uuid = UUID(uuidString: recordID.recordName),
                   Self.wellKnownPerUserIDs.contains(uuid) {
                    logger.info("[\(engineLabel)] Dropping stale per-user deletion \(recordID.recordName) — these never travel through the share")
                    engine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                    continue
                }
                // Any other foreign-zone deletion from before the scrub finished could be a custom
                // section, whose random UUID tells us nothing. It is withheld and quarantined, and
                // the classification pass asks the server what it actually is.
                if isShared,
                   recordID.zoneID.ownerName != CKCurrentUserDefaultName,
                   !legacySharedDeletionScrubIsDone {
                    logger.info("[\(engineLabel)] Quarantining unclassified legacy deletion \(recordID.recordName) instead of sending it")
                    engine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                    quarantineLegacySharedDeletion(recordID)
                    quarantinedThisBatch = true
                    continue
                }
                recordIDsToDelete.append(recordID)
            @unknown default:
                break
            }
        }

        if quarantinedThisBatch {
            runLegacySharedDeletionClassification()
        }

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }
        logger.info("[\(engineLabel)] Sending batch: \(recordsToSave.count) saves, \(recordIDsToDelete.count) deletes")
        trackInFlightDeletions(recordIDsToDelete, target: isShared ? .sharedDatabase : .privateDatabase)
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
            discardBufferedChanges()
            discardMigrationState()

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

        let pending = pendingChangeNames()

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
            // Per-user settings use fixed UUIDs, so the owner's copy arriving through the share
            // would overwrite this account's own settings and their cached zone identity.
            if fromSharedEngine && Self.perUserRecordTypes.contains(record.recordType) {
                logger.info("[\(engineLabel)] Skipping per-user record \(record.recordID.recordName) (\(record.recordType)) from the share")
                continue
            }

            applyFetchedRecord(record, to: context, pending: pending)
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
            if fromSharedEngine && Self.perUserRecordTypes.contains(deletion.recordType) {
                logger.info("[\(engineLabel)] Skipping per-user deletion \(deletion.recordID.recordName) (\(deletion.recordType)) from the share")
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

        // A fetched AmountOverride changes what the item's headline amount should be, and nothing
        // else recomputes it until the next foreground — widgets read BudgetItem.amount directly,
        // so the derived value has to catch up here.
        BudgetItemAmountRefresher.refreshAll(in: context)

        let sectionCountAfter = (try? context.fetchCount(FetchDescriptor<DashboardSection>())) ?? -1
        if sectionCountBefore != sectionCountAfter {
            logger.warning("DashboardSection count changed: \(sectionCountBefore) -> \(sectionCountAfter)")
        }
    }

    /// The record names with work still queued on either engine.
    private struct PendingChangeNames {
        var saves: Set<String> = []
        var deletions: Set<String> = []
    }

    /// Gather both name sets in one pass over both engines. Computed once per batch: a per-record
    /// scan is O(records × pending), which bites hardest during an Unstuck resync when both sides
    /// are the whole dataset. The zone owner string differs between how we queue a change and how
    /// the server names the record, so the match is by name alone.
    @MainActor
    private func pendingChangeNames() -> PendingChangeNames {
        var pending = PendingChangeNames()
        for engine in [syncEngine, sharedSyncEngine].compactMap({ $0 }) {
            for change in engine.state.pendingRecordZoneChanges {
                switch change {
                case .saveRecord(let pendingID):
                    pending.saves.insert(pendingID.recordName)
                case .deleteRecord(let pendingID):
                    pending.deletions.insert(pendingID.recordName)
                @unknown default:
                    break
                }
            }
        }
        return pending
    }

    /// The last record this device synced for a record name, decoded from whichever model owns it.
    /// Used when CloudKit hands back a conflict without a usable ancestor: the save that failed
    /// was built from this cache, so it is the exact record both sides diverged from.
    @MainActor
    private func cachedRecord(forRecordName name: String, in context: ModelContext) -> CKRecord? {
        guard let uuid = UUID(uuidString: name) else { return nil }

        let cached: Data?
        if let item = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.id == uuid })).first {
            cached = item.ckRecordData
        } else if let override_ = try? context.fetch(FetchDescriptor<AmountOverride>(predicate: #Predicate { $0.id == uuid })).first {
            cached = override_.ckRecordData
        } else if let occurrence = try? context.fetch(FetchDescriptor<Occurrence>(predicate: #Predicate { $0.id == uuid })).first {
            cached = occurrence.ckRecordData
        } else if let member = try? context.fetch(FetchDescriptor<FamilyMember>(predicate: #Predicate { $0.id == uuid })).first {
            cached = member.ckRecordData
        } else if let section = try? context.fetch(FetchDescriptor<DashboardSection>(predicate: #Predicate { $0.id == uuid })).first {
            cached = section.ckRecordData
        } else if let preferences = try? context.fetch(FetchDescriptor<UserPreferences>(predicate: #Predicate { $0.id == uuid })).first {
            cached = preferences.ckRecordData
        } else {
            return nil
        }

        return cached.flatMap { RecordConversion.decodeLastKnownRecord(from: $0) }
    }

    /// Decode a model's cached `ckRecordData` into the record this device last synced.
    private func decodedCache(_ ckRecordData: Data?) -> CKRecord? {
        ckRecordData.flatMap { RecordConversion.decodeLastKnownRecord(from: $0) }
    }

    /// An ancestor is only worth merging against when it carries field values; a system-fields-only
    /// record tells us nothing about which side changed what.
    private func usableAncestor(_ record: CKRecord?) -> CKRecord? {
        guard let record, !record.allKeys().isEmpty else { return nil }
        return record
    }

    /// The record to write into the local model for an incoming server record. When a local save
    /// for the same record is still queued, the local edit must survive, so the incoming record is
    /// merged against `ancestor` and the current local values, and the queued push carries the
    /// merged result. Otherwise the server record is the truth and is applied as is.
    ///
    /// The two callers diverge from different ancestors. On the fetch path the local model last
    /// agreed with the cached record, so that is the ancestor. On the conflict path the model
    /// diverged from the snapshot we submitted, not from the cache, so the caller passes the
    /// submitted record: a value the user has since reverted back to the cached one still reads
    /// as a local change and survives.
    @MainActor
    private func recordToApply(
        incoming: CKRecord,
        ancestor: CKRecord?,
        pendingSaveNames: Set<String>,
        local: () -> CKRecord
    ) -> CKRecord {
        guard pendingSaveNames.contains(incoming.recordID.recordName) else { return incoming }
        return RecordMerge.threeWay(ancestor: ancestor, client: local(), server: incoming).record
    }

    /// Apply a server record to the local store. `merged` is the conflict path's already-merged
    /// record: it stands in for the server record when deciding what the model should hold,
    /// while `record` stays the pristine server copy that gets cached as the next ancestor.
    /// `ancestor` overrides the ancestor the merge diffs against; nil means the cached record.
    @MainActor
    private func applyFetchedRecord(
        _ record: CKRecord,
        to context: ModelContext,
        pending: PendingChangeNames,
        merged: CKRecord? = nil,
        ancestor: CKRecord? = nil
    ) {
        guard let uuid = UUID(uuidString: record.recordID.recordName) else { return }
        let ckData = RecordConversion.encodeRecord(record)

        switch record.recordType {
        case RecordConversion.budgetItemRecordType:
            let predicate = #Predicate<BudgetItem> { $0.id == uuid }
            if let existing = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: predicate)).first {
                let resolved = recordToApply(
                    incoming: merged ?? record,
                    ancestor: ancestor ?? decodedCache(existing.ckRecordData),
                    pendingSaveNames: pending.saves
                ) {
                    RecordConversion.record(from: existing, zoneID: record.recordID.zoneID)
                }
                RecordConversion.applyRecord(resolved, to: existing)
                // The cache is the server's record, never the merged one: the merged values live
                // in the model, and the next push diffs the model against this cache to send
                // exactly the keys the client won. Caching the merge instead would claim the
                // server already holds our edits, so the following conflict would read them as
                // unchanged and drop them.
                existing.ckRecordData = ckData
                // Restore familyMembers relationship
                restoreFamilyMembers(from: resolved, to: existing, in: context)
            } else {
                // The user deleted this locally and the deletion hasn't been sent yet. Inserting
                // the server's copy now would resurrect it: the queued deletion then removes the
                // record from the server and the recreated model is left behind as an orphan.
                guard !pending.deletions.contains(record.recordID.recordName) else {
                    logger.info("Skipping insert of \(record.recordID.recordName) — a local deletion for it is still queued")
                    break
                }
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
                let resolved = recordToApply(
                    incoming: merged ?? record,
                    ancestor: ancestor ?? decodedCache(existing.ckRecordData),
                    pendingSaveNames: pending.saves
                ) {
                    RecordConversion.record(from: existing, zoneID: record.recordID.zoneID)
                }
                RecordConversion.applyRecord(resolved, to: existing)
                existing.ckRecordData = ckData
                // Restore budgetItem relationship if missing (may have been nil if parent wasn't synced yet)
                if existing.budgetItem == nil,
                   let ref = resolved["budgetItemRef"] as? CKRecord.Reference,
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

                // Checked after the duplicate merge above, which reuses an existing local model
                // rather than creating one, so a pending deletion has nothing to resurrect there.
                guard !pending.deletions.contains(record.recordID.recordName) else {
                    logger.info("Skipping insert of \(record.recordID.recordName) — a local deletion for it is still queued")
                    break
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
                let resolved = recordToApply(
                    incoming: merged ?? record,
                    ancestor: ancestor ?? decodedCache(existing.ckRecordData),
                    pendingSaveNames: pending.saves
                ) {
                    RecordConversion.record(from: existing, zoneID: record.recordID.zoneID)
                }
                RecordConversion.applyRecord(resolved, to: existing)
                existing.ckRecordData = ckData
            } else {
                guard !pending.deletions.contains(record.recordID.recordName) else {
                    logger.info("Skipping insert of \(record.recordID.recordName) — a local deletion for it is still queued")
                    break
                }
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
                let resolved = recordToApply(
                    incoming: merged ?? record,
                    ancestor: ancestor ?? decodedCache(existing.ckRecordData),
                    pendingSaveNames: pending.saves
                ) {
                    RecordConversion.record(from: existing, zoneID: record.recordID.zoneID)
                }
                RecordConversion.applyRecord(resolved, to: existing)
                existing.ckRecordData = ckData
            } else {
                guard !pending.deletions.contains(record.recordID.recordName) else {
                    logger.info("Skipping insert of \(record.recordID.recordName) — a local deletion for it is still queued")
                    break
                }
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
                let resolved = recordToApply(
                    incoming: merged ?? record,
                    ancestor: ancestor ?? decodedCache(existing.ckRecordData),
                    pendingSaveNames: pending.saves
                ) {
                    RecordConversion.record(from: existing, zoneID: record.recordID.zoneID)
                }
                RecordConversion.applyRecord(resolved, to: existing)
                existing.ckRecordData = ckData
            } else {
                guard !pending.deletions.contains(record.recordID.recordName) else {
                    logger.info("Skipping insert of \(record.recordID.recordName) — a local deletion for it is still queued")
                    break
                }
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
                let resolved = recordToApply(
                    incoming: merged ?? record,
                    ancestor: ancestor ?? decodedCache(existing.ckRecordData),
                    pendingSaveNames: pending.saves
                ) {
                    RecordConversion.record(from: existing, zoneID: record.recordID.zoneID)
                }
                RecordConversion.applyRecord(resolved, to: existing)
                existing.ckRecordData = ckData
            } else {
                guard !pending.deletions.contains(record.recordID.recordName) else {
                    logger.info("Skipping insert of \(record.recordID.recordName) — a local deletion for it is still queued")
                    break
                }
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
        let targetDatabase: DeferredChange.Target = fromSharedEngine ? .sharedDatabase : .privateDatabase

        // Batch all updates into a single save to avoid per-record main-thread saves
        for savedRecord in changes.savedRecords {
            updateCKRecordData(from: savedRecord, in: context)
            logger.info("[\(engineLabel)] Saved record \(savedRecord.recordID.recordName)")
        }

        // The server has answered for these, either way: an accepted deletion is done, and a
        // refused one is back on the engine, which retries it itself.
        clearInFlightDeletions(changes.deletedRecordIDs)
        clearInFlightDeletions(changes.failedRecordDeletes.map(\.key))

        let pending = pendingChangeNames()

        // Handle failures
        for failure in changes.failedRecordSaves {
            let recordID = failure.record.recordID
            let error = failure.error

            switch error.code {
            case .serverRecordChanged:
                // Conflict — another device saved this record first. Reconcile field by field
                // against the ancestor CloudKit hands back, so edits to different fields both
                // survive instead of one whole copy winning on a timestamp.
                if let serverRecord = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                    let clientRecord = error.userInfo[CKRecordChangedErrorClientRecordKey] as? CKRecord ?? failure.record
                    // CloudKit doesn't always hand back an ancestor, and the one it gives can be
                    // field-less. Falling through to last-writer-wins there would throw away the
                    // server's field edits, and no later merge recovers them. The save that failed
                    // was built from our cached record, so that cache is the exact ancestor.
                    let ancestorRecord = usableAncestor(error.userInfo[CKRecordChangedErrorAncestorRecordKey] as? CKRecord)
                        ?? cachedRecord(forRecordName: recordID.recordName, in: context)
                    let outcome = RecordMerge.threeWay(
                        ancestor: ancestorRecord,
                        client: clientRecord,
                        server: serverRecord
                    )

                    // The pristine server record is what gets cached; the merged copy stands in
                    // for it when deciding the model's values. If the user edited this record
                    // again while the failed save was in flight, that edit queued its own save,
                    // so the pending-save merge runs on top of the conflict merge. That merge
                    // diffs against the record we submitted, not the cache, because that is what
                    // the model has since diverged from.
                    applyFetchedRecord(
                        serverRecord,
                        to: context,
                        pending: pending,
                        merged: outcome.record,
                        ancestor: clientRecord
                    )

                    if outcome.differsFromServer {
                        logger.info("[\(engineLabel)] Conflict for \(recordID.recordName) — merged, re-pushing")
                        enqueue([.saveRecord(recordID)], to: targetDatabase)
                    } else {
                        logger.info("[\(engineLabel)] Conflict for \(recordID.recordName) — server already has the merged result")
                    }
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
                    enqueue([.saveRecord(recordID)], to: targetDatabase)
                }

            case .unknownItem:
                // Record doesn't exist on server — clear lastKnownRecord and retry
                logger.info("[\(engineLabel)] Unknown item \(recordID.recordName) — clearing cached record and retrying")
                clearCKRecordData(for: recordID, in: context)
                enqueue([.saveRecord(recordID)], to: targetDatabase)

            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .requestRateLimited, .operationCancelled:
                // Transient errors — engine retries automatically
                logger.info("[\(engineLabel)] Transient error for \(recordID.recordName): \(error.localizedDescription)")

            default:
                // Don't silently drop: the change stays queued for the engine to
                // retry, and we surface the failure so the state is visible (and the
                // user can reach for "Unstuck" if it never clears).
                logger.error("[\(engineLabel)] Failed to save record \(recordID.recordName): \(error.localizedDescription)")
                let message = error.localizedDescription
                Task { @MainActor in syncStatus = .error(message) }
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

        let ckData = RecordConversion.encodeRecord(record)

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

    // MARK: - Recovery

    /// Undo the per-user settings hijack on a device that ran an earlier build.
    ///
    /// `UserPreferences` and the two default `DashboardSection`s use fixed UUIDs, and both family
    /// members pushed them through their own private zones. The shared engine then delivered the
    /// owner's copies to the participant, which matched them by UUID and adopted the owner's zone
    /// into `ckRecordData` — from then on the participant's settings were written into the owner's
    /// zone, and the two accounts overwrote each other's preferences.
    ///
    /// A custom section that only exists because it leaked in through the share is deleted here and
    /// now. A well-known record cannot be repaired synchronously: the values in memory may be the
    /// *other* member's settings that arrived through the share, so pushing them as our own would
    /// write their preferences over this account's private record. That record almost certainly
    /// still exists on the server under the same fixed UUID, so `recoverHijackedPerUserRecords`
    /// fetches it and adopts it. This returns the IDs it will look up, which is also what makes the
    /// synchronous half testable without CloudKit.
    @MainActor
    @discardableResult
    func reclaimPerUserRecords() -> [CKRecord.ID] {
        guard let context = modelContainer?.mainContext else { return [] }

        let defaultIDs = Self.wellKnownPerUserIDs
        var idsNeedingLookup: [CKRecord.ID] = []
        var deletedCount = 0

        if let preferences = try? context.fetch(FetchDescriptor<UserPreferences>()) {
            for pref in preferences where isFromSharedZone(pref.ckRecordData) {
                if defaultIDs.contains(pref.id) {
                    idsNeedingLookup.append(CKRecord.ID(recordName: pref.id.uuidString, zoneID: zoneID))
                } else {
                    context.delete(pref)
                    deletedCount += 1
                }
            }
        }

        if let sections = try? context.fetch(FetchDescriptor<DashboardSection>()) {
            for section in sections where isFromSharedZone(section.ckRecordData) {
                if defaultIDs.contains(section.id) {
                    idsNeedingLookup.append(CKRecord.ID(recordName: section.id.uuidString, zoneID: zoneID))
                } else {
                    context.delete(section)
                    deletedCount += 1
                }
            }
        }

        guard !idsNeedingLookup.isEmpty || deletedCount > 0 else { return [] }

        do {
            try context.save()
        } catch {
            logger.error("Failed to save reclaimed per-user records: \(error.localizedDescription)")
            return []
        }

        logger.info("Per-user reclaim: \(idsNeedingLookup.count) hijacked record(s) to recover, deleted \(deletedCount) that leaked in through the share")
        return idsNeedingLookup
    }

    /// Second half of the reclaim: fetch this account's own private-zone copy of each hijacked
    /// per-user record and adopt it, so the settings we keep are ours rather than the ones that
    /// arrived through the share.
    ///
    /// Found -> apply it, which both takes the server's values and re-caches the private-zone
    /// record, and that is the repair. `.unknownItem` -> we never had a private copy, so clearing
    /// the cache and pushing what is in memory is the best available answer. Any other error leaves
    /// the record untouched with its foreign cache intact, so the next launch tries again; a
    /// half-repair here would be indistinguishable from the hijack itself.
    func recoverHijackedPerUserRecords(_ recordIDs: [CKRecord.ID]) {
        let toRecover = claimPerUserRecovery(recordIDs)
        guard !toRecover.isEmpty else { return }

        let epoch = currentSessionEpoch()

        Task.detached { [self, logger] in
            defer { releasePerUserRecovery(toRecover) }

            for recordID in toRecover {
                do {
                    let record = try await CloudKitManager.shared.privateDatabase.record(for: recordID)
                    var adopted = false
                    await MainActor.run {
                        guard currentSessionEpoch() == epoch else {
                            logger.info("Account switched mid-recovery — abandoning \(recordID.recordName)")
                            return
                        }
                        guard let context = modelContainer?.mainContext else { return }

                        // The hijack we are repairing happened under a build that cached system
                        // fields only, so there is usually no ancestor to diff a local edit
                        // against. Merging anyway degenerates to whole-record last-writer-wins and
                        // the other member's values can win, reinstating the hijack. Adopting the
                        // private copy wholesale is the only answer that cannot; an edit made
                        // during the second the lookup takes is superseded.
                        var pending = pendingChangeNames()
                        let cached = cachedRecord(forRecordName: recordID.recordName, in: context)
                        if !RecordMerge.hasUsableAncestor(cached) {
                            pending.saves.remove(recordID.recordName)
                        }

                        applyFetchedRecord(record, to: context, pending: pending)
                        do {
                            try context.save()
                        } catch {
                            logger.error("Failed to save recovered per-user record \(recordID.recordName): \(error.localizedDescription)")
                            return
                        }
                        adopted = true
                    }
                    if adopted, let uuid = UUID(uuidString: recordID.recordName) {
                        // Any local edit the merge kept has to go out, now against the private
                        // record's tag rather than the foreign one.
                        await MainActor.run { pushChange(for: uuid) }
                        logger.info("Recovered per-user record \(recordID.recordName) from our own private zone")
                    }
                } catch let error as CKError where error.code == .unknownItem {
                    await MainActor.run {
                        guard currentSessionEpoch() == epoch else {
                            logger.info("Account switched mid-recovery — abandoning \(recordID.recordName)")
                            return
                        }
                        guard let context = modelContainer?.mainContext else { return }
                        clearCKRecordData(for: recordID, in: context)
                        do {
                            try context.save()
                        } catch {
                            logger.error("Failed to clear hijacked cache for \(recordID.recordName): \(error.localizedDescription)")
                            return
                        }
                        pushChanges(for: [recordID])
                        logger.info("No private copy of \(recordID.recordName) on the server — pushing the local values as a fresh record")
                    }
                } catch {
                    logger.error("Could not recover per-user record \(recordID.recordName), leaving it for the next launch: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Take ownership of the records about to be recovered, returning only those no other recovery
    /// already has. Two passes on the same record would each fetch and apply it, and the second
    /// would undo whatever the first merged.
    private func claimPerUserRecovery(_ recordIDs: [CKRecord.ID]) -> [CKRecord.ID] {
        deferredChangesLock.lock()
        defer { deferredChangesLock.unlock() }
        return recordIDs.filter { recoveringPerUserRecords.insert($0.recordName).inserted }
    }

    private func releasePerUserRecovery(_ recordIDs: [CKRecord.ID]) {
        deferredChangesLock.lock()
        for recordID in recordIDs {
            recoveringPerUserRecords.remove(recordID.recordName)
        }
        deferredChangesLock.unlock()
    }

    /// Force a full resync — the "Unstuck" recovery action.
    ///
    /// Drops the persisted sync-engine state tokens (so the engines re-fetch
    /// everything from the server) and re-queues every local record for upload.
    /// Save conflicts that result are resolved by the timestamp-merge path, so both
    /// sides converge on the newest data. Safe — it never deletes data.
    ///
    /// Cached `ckRecordData` is deliberately **kept**: it carries each record's zone
    /// identity, which `pushAllLocalData()` needs to route shared records back to the
    /// shared zone. Clearing it would re-upload shared items as private records and
    /// duplicate them. A stale change tag is harmless — the server rejects with
    /// `.serverRecordChanged` and the merge path reconciles it.
    @MainActor
    func forceFullResync() {
        guard let container = modelContainer else {
            logger.warning("forceFullResync called before sync started")
            return
        }
        logger.info("forceFullResync: dropping sync state and re-queuing local records")

        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        defaults?.removeObject(forKey: stateKey)
        defaults?.removeObject(forKey: sharedStateKey)

        // The re-upload must wait until start(with:) has recreated the engines — it
        // does so asynchronously after an account-status check, so pushing here would
        // be a no-op against nil engines. pendingResyncPush makes start() run the push
        // once the engines exist.
        pendingResyncPush = true
        stop()
        start(with: container)
        syncStatus = .syncing
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
