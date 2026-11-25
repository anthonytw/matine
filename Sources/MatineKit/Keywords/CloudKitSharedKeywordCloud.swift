#if canImport(CloudKit)
import CloudKit
import Foundation
import os

private let log = Logger(subsystem: "io.github.anthonytw.matine", category: "keyword-share")

/// The participant's side of a shared "Keywords" zone: a SECOND `CKSyncEngine`,
/// on the SHARED database (never the private one, so the "one engine per
/// database" rule of `PrivateCloudEngine` stands). It has its own state file.
///
/// The zone belongs to the owner and appears in the shared database of every
/// device of the participant's Apple ID once one of them accepted the share
/// (`KeywordShare.accept`), the Apple TV included. Only the "Keywords" zone is
/// ever looked at: the Household zone is not shared, and any other zone that
/// might show up here is ignored. The apps only call it in a signed-in
/// process (it needs the iCloud entitlement); it never creates zones (a
/// participant can't) and a reader never sends.
public final class CloudKitSharedKeywordCloud: SharedKeywordCloud, CKSyncEngineDelegate, @unchecked Sendable {
    private let container: CKContainer
    private let stateURL: URL
    private let writer: Bool
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    /// The owner's zone, as found in the shared database.
    private var zone: CKRecordZone.ID?
    private var saved: [String: KeywordCloudRecord] = [:]
    private var deleted: Set<String> = []
    private var reset = false
    private var accountChanged = false
    private var outgoing: [String: KeywordCloudRecord] = [:]
    private var confirmed: Set<String> = []
    private var serverRecords: [String: CKRecord] = [:]

    public init(stateURL: URL, writer: Bool, container id: String = PrivateCloudEngine.containerIdentifier) {
        container = CKContainer(identifier: id)
        self.stateURL = stateURL
        self.writer = writer
    }

    // MARK: SharedKeywordCloud

    public func shareState() async throws -> KeywordShareState {
        let zones = try await container.sharedCloudDatabase.allRecordZones()
        // One owner's zone is read; if two people shared, the first found wins.
        let found = zones.map(\.zoneID).filter { $0.zoneName == CloudKitKeywordCloud.zoneID.zoneName }.sorted { $0.ownerName < $1.ownerName }.first
        lock.withLock {
            if zone != found { serverRecords = [:] }
            zone = found
        }
        return found == nil ? .none : .participant
    }

    // MARK: KeywordCloud

    public func account() async -> KeywordCloudAccount {
        do {
            return try await container.accountStatus() == .available ? .available : .unavailable("iCloud is not available")
        } catch {
            return .unavailable("\(error)")
        }
    }

    public func fetchChanges() async throws -> KeywordCloudChanges {
        let syncEngine = syncEngine()
        try await gate.run { try await syncEngine.fetchChanges() }
        return lock.withLock {
            let changes = KeywordCloudChanges(saved: Array(saved.values), deleted: Array(deleted), reset: reset, accountChanged: accountChanged)
            saved = [:]
            deleted = []
            reset = false
            accountChanged = false
            return changes
        }
    }

    public func save(_ records: [KeywordCloudRecord]) async throws -> [String] {
        guard writer, !records.isEmpty else { return [] }
        let engine = syncEngine()
        guard let zone = lock.withLock({ zone }) else { return [] }
        lock.withLock {
            confirmed = []
            for record in records { outgoing[record.name] = record }
        }
        engine.state.add(pendingRecordZoneChanges: records.map { .saveRecord(CKRecord.ID(recordName: $0.name, zoneID: zone)) })
        try await gate.run { try await engine.sendChanges() }
        return lock.withLock { Array(confirmed) }
    }

    public func accountId() async -> String? {
        try? await container.userRecordID().recordName
    }

    public func reset() async {
        lock.withLock {
            engine = nil
            zone = nil
            saved = [:]
            deleted = []
            outgoing = [:]
            confirmed = []
            serverRecords = [:]
            reset = false
        }
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: Engine

    /// Our own fetches and sends on this engine, one at a time.
    private let gate = SerialGate()

    private func syncEngine() -> CKSyncEngine {
        lock.withLock {
            if let engine { return engine }
            let state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
            var configuration = CKSyncEngine.Configuration(database: container.sharedCloudDatabase, stateSerialization: state, delegate: self)
            configuration.automaticallySync = true
            let made = CKSyncEngine(configuration)
            engine = made
            return made
        }
    }

    private func isKeywords(_ id: CKRecordZone.ID) -> Bool { id.zoneName == CloudKitKeywordCloud.zoneID.zoneName }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // An engine dropped by `reset()` or an account change must not write the new one's state.
        guard lock.withLock({ engine === syncEngine }) else { return }
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: stateURL, options: .atomic)
            }
        case .accountChange(let change):
            if case .signIn = change.changeType {} else {
                lock.withLock {
                    engine = nil
                    zone = nil
                    saved = [:]
                    deleted = []
                    outgoing = [:]
                    confirmed = []
                    serverRecords = [:]
                    reset = true
                    accountChanged = true
                }
                try? FileManager.default.removeItem(at: stateURL)
            }
        case .fetchedDatabaseChanges(let fetched):
            // The owner stopped sharing, or this person left: the zone is gone from here.
            if fetched.deletions.contains(where: { isKeywords($0.zoneID) }) {
                log.info("the shared keywords zone is gone")
                lock.withLock {
                    reset = true
                    saved = [:]
                    deleted = []
                    outgoing = [:]
                    serverRecords = [:]
                    zone = nil
                }
            }
        case .fetchedRecordZoneChanges(let fetched):
            lock.withLock {
                for modification in fetched.modifications where isKeywords(modification.record.recordID.zoneID) { take(modification.record) }
                for deletion in fetched.deletions where isKeywords(deletion.recordID.zoneID) && deletion.recordType == CloudKitKeywordCloud.recordType {
                    let name = deletion.recordID.recordName
                    saved[name] = nil
                    serverRecords[name] = nil
                    deleted.insert(name)
                }
            }
        case .sentRecordZoneChanges(let sent):
            lock.withLock {
                for record in sent.savedRecords where isKeywords(record.recordID.zoneID) {
                    let name = record.recordID.recordName
                    serverRecords[name] = record
                    outgoing[name] = nil
                    confirmed.insert(name)
                }
                for failure in sent.failedRecordSaves where isKeywords(failure.record.recordID.zoneID) {
                    let name = failure.record.recordID.recordName
                    // A conflict: take theirs, the sync merges and sends again if ours is better.
                    // Anything else (read-only participant, zone gone, no network) stays unconfirmed:
                    // the next sync tries again, or finds the share gone.
                    if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
                        take(server)
                        outgoing[name] = nil
                    }
                }
            }
        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            guard let record = self.record(for: recordID) else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return record
        }
    }

    /// Caller holds the lock.
    private func take(_ record: CKRecord) {
        guard record.recordType == CloudKitKeywordCloud.recordType, let keywords = CloudKitKeywordCloud.keywords(from: record) else { return }
        let name = record.recordID.recordName
        serverRecords[name] = record
        deleted.remove(name)
        saved[name] = KeywordCloudRecord(name: name, keywords: keywords)
    }

    private func record(for id: CKRecord.ID) -> CKRecord? {
        lock.withLock {
            guard isKeywords(id.zoneID), let wanted = outgoing[id.recordName] else { return nil }
            let record = serverRecords[id.recordName] ?? CKRecord(recordType: CloudKitKeywordCloud.recordType, recordID: id)
            CloudKitKeywordCloud.fill(record, with: wanted.keywords)
            return record
        }
    }
}
#endif
