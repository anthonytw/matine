import Foundation

/// A cloud made on first use: building a CloudKit container needs the app's
/// iCloud entitlement, so nothing is touched until a sync is asked for.
public final class LazyHouseholdCloud: HouseholdCloud, @unchecked Sendable {
    private let make: @Sendable () -> any HouseholdCloud
    private let lock = NSLock()
    private var made: (any HouseholdCloud)?

    public init(_ make: @escaping @Sendable () -> any HouseholdCloud) { self.make = make }

    private var cloud: any HouseholdCloud {
        lock.withLock {
            if let made { return made }
            let new = make()
            made = new
            return new
        }
    }

    public func account() async -> KeywordCloudAccount { await cloud.account() }
    public func fetchChanges() async throws -> HouseholdCloudChanges { try await cloud.fetchChanges() }
    public func save(members: [HouseholdMember], requests: [ApprovalRequest]) async throws -> Set<String> {
        try await cloud.save(members: members, requests: requests)
    }
    public func delete(requestIds: [String]) async throws { try await cloud.delete(requestIds: requestIds) }
    public func reset() async { await cloud.reset() }
    public func accountId() async -> String? { await cloud.accountId() }
}

#if canImport(CloudKit)
import CloudKit
import os

private let log = Logger(subsystem: "io.github.anthonytw.matine", category: "household")

/// The thin CloudKit side of `HouseholdCloud`: the "Household" zone of the
/// owner's PRIVATE database, a record per profile and a short-lived record per
/// approval request, sent and fetched through the process's one
/// `PrivateCloudEngine`. Every field is an encrypted value (`CloudKit/schema.ckdb`).
/// The record names only hash ids or are random.
///
/// The Household zone must NEVER be shared (CKShare): it holds PINs, and an
/// approval request signs a device in as someone. Only the Keywords zone may be
/// shared one day. A share participant's writes would land in the owner's
/// private database, so records are also checked for who wrote them.
public final class CloudKitHouseholdCloud: HouseholdCloud, PrivateZoneHandler, @unchecked Sendable {
    static let zoneID = CKRecordZone.ID(zoneName: "Household", ownerName: CKCurrentUserDefaultName)
    static let memberType = "HouseholdMember"
    static let approvalType = "ApprovalRequest"

    var zoneID: CKRecordZone.ID { Self.zoneID }

    private let engine: PrivateCloudEngine
    private let lock = NSLock()
    private var zoneQueued = false
    private var members: [String: HouseholdMember] = [:]
    private var requests: [String: ApprovalRequest] = [:]
    private var reset = false
    private var accountChanged = false
    private var outgoingMembers: [String: HouseholdMember] = [:]
    private var outgoingRequests: [String: ApprovalRequest] = [:]
    /// Confirmed and not yet handed to a `save` call, so concurrent saves each get their own.
    private var confirmed: Set<String> = []
    private var serverRecords: [String: CKRecord] = [:]
    private var activity: (@Sendable () -> Void)?
    /// The engine itself fetched household records (a push, its own schedule) that no sync has taken yet:
    /// the next `fetchChanges` hands them over WITHOUT calling into the engine again.
    private var deliveredByEngine = false
    /// Our own `fetchChanges` calls in flight (see `handle`).
    private var ownFetches = 0
    /// The signed-in user's own record name, read before each fetch.
    private var ownerName: String?

    public init(engine: PrivateCloudEngine = .shared) {
        self.engine = engine
        engine.register(self)
    }

    /// Called when the engine fetched something in this zone on its own (a push): the app syncs then.
    public func onActivity(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { activity = handler }
    }

    // MARK: HouseholdCloud

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

    public func fetchChanges() async throws -> HouseholdCloudChanges {
        let owner = try? await engine.container.userRecordID().recordName
        lock.withLock { if let owner { ownerName = owner } }
        // The engine just fetched these itself: don't ask it to fetch again (an overlapping fetch traps in CloudKit).
        let held = lock.withLock { () -> Bool in defer { deliveredByEngine = false }; return deliveredByEngine }
        if !held {
            let syncEngine = engine.syncEngine()
            // What our own fetch brings is handed over below: it neither marks the
            // records as the engine's nor starts another sync.
            lock.withLock { ownFetches += 1 }
            defer { lock.withLock { ownFetches -= 1 } }
            try await engine.gate.run { try await syncEngine.fetchChanges() }
        }
        return lock.withLock {
            let changes = HouseholdCloudChanges(
                saved: Array(members.values), requests: Array(requests.values), reset: reset, accountChanged: accountChanged
            )
            members = [:]
            requests = [:]
            reset = false
            accountChanged = false
            return changes
        }
    }

    public func save(members: [HouseholdMember], requests: [ApprovalRequest]) async throws -> Set<String> {
        guard !members.isEmpty || !requests.isEmpty else { return [] }
        let engine = engine.syncEngine()
        let names = members.map(\.recordName) + requests.map(\.id)
        let needsZone = lock.withLock {
            for member in members { outgoingMembers[member.recordName] = member }
            for request in requests { outgoingRequests[request.id] = request }
            let needs = !zoneQueued
            zoneQueued = true
            return needs
        }
        if needsZone { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]) }
        engine.state.add(pendingRecordZoneChanges: names.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: Self.zoneID)) })
        try await self.engine.gate.run { try await engine.sendChanges() }
        return lock.withLock {
            let mine = confirmed.intersection(names)
            confirmed.subtract(mine)
            return mine
        }
    }

    public func delete(requestIds: [String]) async throws {
        guard !requestIds.isEmpty else { return }
        let engine = engine.syncEngine()
        lock.withLock { for id in requestIds { outgoingRequests[id] = nil } }
        engine.state.add(pendingRecordZoneChanges: requestIds.map { .deleteRecord(CKRecord.ID(recordName: $0, zoneID: Self.zoneID)) })
        try await self.engine.gate.run { try await engine.sendChanges() }
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
            members = [:]
            requests = [:]
            outgoingMembers = [:]
            outgoingRequests = [:]
            confirmed = []
            serverRecords = [:]
            zoneQueued = false
            reset = changed
            accountChanged = changed
            // Whatever the old engine delivered is gone: the next fetch asks the new one.
            deliveredByEngine = false
        }
    }

    func zoneWasDeleted() {
        lock.withLock {
            reset = true
            members = [:]
            requests = [:]
            serverRecords = [:]
            zoneQueued = false
            deliveredByEngine = false
        }
    }

    func handle(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .fetchedRecordZoneChanges(let fetched):
            let handler: (@Sendable () -> Void)? = lock.withLock {
                let mine = fetched.modifications.filter { $0.record.recordID.zoneID == Self.zoneID }
                for modification in mine { take(modification.record) }
                for deletion in fetched.deletions where deletion.recordID.zoneID == Self.zoneID {
                    let name = deletion.recordID.recordName
                    serverRecords[name] = nil
                    requests[name] = nil
                }
                // During our own fetch its caller takes these; only the engine's own fetch (a push, its schedule) wakes the app.
                guard !mine.isEmpty, ownFetches == 0 else { return nil }
                deliveredByEngine = true
                return activity
            }
            // This runs inside the engine's delegate callback: never start a sync from here, or from
            // a Task that inherits its task-locals (CloudKit traps on a fetch made from its own callback).
            // A detached task starts clean (it may run while the engine's own fetch is still going,
            // which is allowed: only a call made from the callback's context traps).
            if let handler { Task.detached { handler() } }
        case .sentRecordZoneChanges(let sent):
            var zoneMissing: [CKRecord.ID] = []
            lock.withLock {
                for record in sent.savedRecords where record.recordID.zoneID == Self.zoneID {
                    let name = record.recordID.recordName
                    serverRecords[name] = record
                    outgoingMembers[name] = nil
                    outgoingRequests[name] = nil
                    confirmed.insert(name)
                }
                for id in sent.deletedRecordIDs where id.zoneID == Self.zoneID { serverRecords[id.recordName] = nil }
                for failure in sent.failedRecordSaves where failure.record.recordID.zoneID == Self.zoneID {
                    let name = failure.record.recordID.recordName
                    switch failure.error.code {
                    case .serverRecordChanged:
                        // Someone else wrote first: take theirs; the sync merges and sends again if ours wins.
                        if let server = failure.error.serverRecord { take(server) }
                        outgoingMembers[name] = nil
                    case .zoneNotFound:
                        zoneMissing.append(failure.record.recordID)
                        zoneQueued = true
                    default:
                        break
                    }
                }
            }
            if !zoneMissing.isEmpty {
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
        let name = record.recordID.recordName
        switch record.recordType {
        case Self.memberType:
            guard isOwners(record) else {
                log.notice("household: dropped a record not written by the owner (1)")
                return
            }
            guard let member = Self.member(from: record) else { return }
            serverRecords[name] = record
            members[name] = member
        case Self.approvalType:
            guard let request = Self.request(from: record, ownedByOwner: isOwners(record)) else { return }
            requests[name] = request
        default:
            break
        }
    }

    func record(for name: String) -> CKRecord? {
        lock.withLock {
            if let member = outgoingMembers[name] {
                let record = serverRecords[name] ?? CKRecord(recordType: Self.memberType, recordID: CKRecord.ID(recordName: name, zoneID: Self.zoneID))
                Self.fill(record, with: member)
                return record
            }
            if let request = outgoingRequests[name] {
                let record = CKRecord(recordType: Self.approvalType, recordID: CKRecord.ID(recordName: name, zoneID: Self.zoneID))
                Self.fill(record, with: request)
                return record
            }
            return nil
        }
    }

    static func fill(_ record: CKRecord, with member: HouseholdMember) {
        let values = record.encryptedValues
        values["srv"] = member.server.absoluteString
        values["uid"] = member.userId
        values["nam"] = member.name
        values["dsp"] = member.displayName
        values["rol"] = member.role.rawValue
        values["avt"] = (try? JSONEncoder().encode(member.avatar)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        values["lng"] = member.language.rawValue
        values["pin"] = member.pin
        values["mod"] = member.modified
        values["rem"] = Int64(member.removed ? 1 : 0)
    }

    static func member(from record: CKRecord) -> HouseholdMember? {
        let values = record.encryptedValues
        guard let server = (values["srv"] as? String).flatMap(URL.init(string:)), let userId = values["uid"] as? String,
              let name = values["nam"] as? String, let modified = values["mod"] as? Int64 else { return nil }
        let avatar = (values["avt"] as? String).flatMap { try? JSONDecoder().decode(Avatar.self, from: Data($0.utf8)) }
        return HouseholdMember(
            server: server, userId: userId, name: name, displayName: (values["dsp"] as? String) ?? "",
            role: (values["rol"] as? String).flatMap(ProfileRole.init(rawValue:)) ?? .adult, avatar: avatar,
            language: (values["lng"] as? String).flatMap(AppLanguage.init(rawValue:)) ?? .default,
            pin: (values["pin"] as? String) ?? "", modified: modified, removed: ((values["rem"] as? Int64) ?? 0) != 0
        )
    }

    static func fill(_ record: CKRecord, with request: ApprovalRequest) {
        let values = record.encryptedValues
        values["srv"] = request.server.absoluteString
        values["uid"] = request.userId
        values["cod"] = request.code
        values["dev"] = request.device
        values["cre"] = Int64(request.created.timeIntervalSince1970)
    }

    /// Created and last written by the database's owner. A share participant's write would
    /// land in the owner's private database too, and must count for nothing.
    /// A missing id counts as the owner's; any other must be the default owner or the
    /// signed-in user's own record name. The caller holds the lock (`ownerName`).
    func isOwners(_ record: CKRecord) -> Bool {
        func ours(_ id: CKRecord.ID?) -> Bool {
            guard let id else { return true }
            return id.recordName == CKCurrentUserDefaultName || id.recordName == ownerName
        }
        return ours(record.creatorUserRecordID) && ours(record.lastModifiedUserRecordID)
    }

    static func request(from record: CKRecord, ownedByOwner: Bool) -> ApprovalRequest? {
        let values = record.encryptedValues
        guard let server = (values["srv"] as? String).flatMap(URL.init(string:)), let userId = values["uid"] as? String,
              let code = values["cod"] as? String, let created = values["cre"] as? Int64 else { return nil }
        // Only the owner's own writes count as private; anyone else's is "shared" and never approved.
        return ApprovalRequest(
            id: record.recordID.recordName, server: server, userId: userId, code: code, device: (values["dev"] as? String) ?? "",
            created: Date(timeIntervalSince1970: TimeInterval(created)), database: ownedByOwner ? .private : .shared
        )
    }
}
#endif
