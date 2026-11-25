#if canImport(CloudKit)
import CloudKit
import Foundation

/// The thin CloudKit side of `KeywordCloud`: the "Keywords" zone of the owner's
/// private database, one record per item, sent and fetched through the
/// process's one `PrivateCloudEngine`. The apps are the only callers (the
/// macOS CLI has no iCloud entitlement). A reader never creates the zone or sends.
///
/// Every field is an encrypted value (`CloudKit/schema.ckdb`): the words are
/// readable only on the owner's devices, the record names only hash ids.
public final class CloudKitKeywordCloud: KeywordCloud, PrivateZoneHandler, @unchecked Sendable {
    public static let containerIdentifier = PrivateCloudEngine.containerIdentifier
    static let zoneID = CKRecordZone.ID(zoneName: "Keywords", ownerName: CKCurrentUserDefaultName)
    static let recordType = "ItemKeywords"

    var zoneID: CKRecordZone.ID { Self.zoneID }

    private let engine: PrivateCloudEngine
    private let writer: Bool
    private let lock = NSLock()
    private var zoneQueued = false
    /// Arrived since the last drain, by record name.
    private var saved: [String: KeywordCloudRecord] = [:]
    private var deleted: Set<String> = []
    private var reset = false
    private var accountChanged = false
    /// Waiting to be sent, by record name.
    private var outgoing: [String: KeywordCloudRecord] = [:]
    /// Names CloudKit confirmed since the last `save` began.
    private var confirmed: Set<String> = []
    /// The server's copy of each record, so a save carries its change tag.
    private var serverRecords: [String: CKRecord] = [:]

    /// `stateURL` is the old engine's state file, no longer used (the shared
    /// engine keeps one); the shared engine is the default.
    public init(stateURL: URL, writer: Bool, container: String = CloudKitKeywordCloud.containerIdentifier, engine: PrivateCloudEngine = .shared) {
        _ = (stateURL, container)
        self.engine = engine
        self.writer = writer
        engine.register(self)
    }

    // MARK: KeywordCloud

    public func account() async -> KeywordCloudAccount {
        do {
            switch try await engine.container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .unavailable("iCloud is restricted")
            case .temporarilyUnavailable: return .unavailable("iCloud is temporarily unavailable")
            default: return .unavailable("iCloud status unknown")
            }
        } catch {
            return .unavailable("\(error)")
        }
    }

    public func fetchChanges() async throws -> KeywordCloudChanges {
        let syncEngine = engine.syncEngine()
        try await engine.gate.run { try await syncEngine.fetchChanges() }
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
        let engine = engine.syncEngine()
        let needsZone = lock.withLock {
            confirmed = []
            for record in records { outgoing[record.name] = record }
            let needs = !zoneQueued
            zoneQueued = true
            return needs
        }
        if needsZone { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]) }
        engine.state.add(pendingRecordZoneChanges: records.map { .saveRecord(CKRecord.ID(recordName: $0.name, zoneID: Self.zoneID)) })
        try await self.engine.gate.run { try await engine.sendChanges() }
        return lock.withLock { Array(confirmed) }
    }

    public func accountId() async -> String? {
        try? await engine.container.userRecordID().recordName
    }

    public func reset() async {
        engine.reset()
    }

    // MARK: PrivateZoneHandler

    func reset(accountChanged changed: Bool) {
        lock.withLock {
            saved = [:]
            deleted = []
            outgoing = [:]
            confirmed = []
            serverRecords = [:]
            zoneQueued = false
            reset = changed
            accountChanged = changed
        }
    }

    func zoneWasDeleted() {
        lock.withLock {
            reset = true
            saved = [:]
            serverRecords = [:]
            zoneQueued = false
        }
    }

    func handle(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .fetchedRecordZoneChanges(let fetched):
            lock.withLock {
                for modification in fetched.modifications where modification.record.recordID.zoneID == Self.zoneID { take(modification.record) }
                for deletion in fetched.deletions where deletion.recordID.zoneID == Self.zoneID && deletion.recordType == Self.recordType {
                    let name = deletion.recordID.recordName
                    saved[name] = nil
                    serverRecords[name] = nil
                    deleted.insert(name)
                }
            }
        case .sentRecordZoneChanges(let sent):
            var zoneMissing: [CKRecord.ID] = []
            lock.withLock {
                for record in sent.savedRecords where record.recordID.zoneID == Self.zoneID {
                    let name = record.recordID.recordName
                    serverRecords[name] = record
                    outgoing[name] = nil
                    confirmed.insert(name)
                }
                for failure in sent.failedRecordSaves where failure.record.recordID.zoneID == Self.zoneID {
                    let name = failure.record.recordID.recordName
                    switch failure.error.code {
                    case .serverRecordChanged:
                        // Someone else wrote first: take theirs as a fetched record;
                        // the sync merges and sends again if ours is better.
                        if let server = failure.error.serverRecord { take(server) }
                        outgoing[name] = nil
                    case .zoneNotFound:
                        zoneMissing.append(failure.record.recordID)
                        zoneQueued = true
                    default:
                        // Not confirmed: the sync sends it again next time (a schema not yet
                        // deployed, quota, no network). Nothing is recorded as sent.
                        break
                    }
                }
            }
            if !zoneMissing.isEmpty {
                // The zone is gone (or never made): make it, then send those again.
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                syncEngine.state.add(pendingRecordZoneChanges: zoneMissing.map { .saveRecord($0) })
            }
        default:
            break
        }
    }

    // MARK: Records

    /// Caller holds the lock.
    private func take(_ record: CKRecord) {
        guard record.recordType == Self.recordType, let keywords = Self.keywords(from: record) else { return }
        let name = record.recordID.recordName
        serverRecords[name] = record
        deleted.remove(name)
        saved[name] = KeywordCloudRecord(name: name, keywords: keywords)
    }

    func record(for name: String) -> CKRecord? {
        lock.withLock {
            guard let wanted = outgoing[name] else { return nil }
            let record = serverRecords[name] ?? CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: name, zoneID: Self.zoneID))
            Self.fill(record, with: wanted.keywords)
            return record
        }
    }

    /// The fields, all encrypted. The words are one string, one phrase per line.
    static func fill(_ record: CKRecord, with keywords: ItemKeywords) {
        record.encryptedValues["h"] = keywords.sourceHash
        record.encryptedValues["g"] = keywords.generation
        record.encryptedValues["w"] = keywords.words.joined(separator: "\n")
        record.encryptedValues["t"] = Int64(keywords.made)
        record.encryptedValues["r"] = keywords.retryAfter
    }

    static func keywords(from record: CKRecord) -> ItemKeywords? {
        let values = record.encryptedValues
        guard let hash = values["h"] as? String, let words = values["w"] as? String else { return nil }
        return ItemKeywords(
            words: words.split(separator: "\n").map(String.init), sourceHash: hash, made: Int((values["t"] as? Int64) ?? 0),
            generation: (values["g"] as? String) ?? "", retryAfter: values["r"] as? String
        )
    }
}
#endif
