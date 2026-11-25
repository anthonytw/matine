import Foundation
#if canImport(CloudKit)
import CloudKit
import os

private let log = Logger(subsystem: "io.github.anthonytw.matine", category: "cloud")

/// One at a time, in order: our own explicit `fetchChanges` / `sendChanges` calls on an engine.
/// CKSyncEngine traps (EXC_BREAKPOINT inside CloudKit) when calls overlap or re-enter, and the
/// keywords and the household share one engine. Not reentrant: never `run` from inside `run`.
final class SerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in
                if busy { waiters.append(continuation); return true }
                busy = true
                return false
            }
            if !wait { continuation.resume() }
        }
    }

    private func release() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiters.isEmpty { busy = false; return nil }
            return waiters.removeFirst()   // stays busy: handed straight on
        }
        next?.resume()
    }
}

/// One zone's side of the private database: the keywords, or the household.
/// The engine routes each event to the handlers and each pending change to the
/// handler that owns its zone.
protocol PrivateZoneHandler: AnyObject, Sendable {
    var zoneID: CKRecordZone.ID { get }
    /// Takes what concerns this handler's zone from a fetch or a send.
    func handle(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine)
    /// The record to send for a pending save in this zone; nil if there is none (any more).
    func record(for name: String) -> CKRecord?
    /// This zone was deleted in iCloud.
    func zoneWasDeleted()
    /// What was held is void: another Apple ID (`accountChanged`), or a start over.
    func reset(accountChanged: Bool)
}

/// The ONE `CKSyncEngine` of the process on the owner's private database
/// (Apple allows a single engine per database in production). It owns the
/// engine, its state file and the account-change handling; the keywords and
/// the household each register a handler for their own zone.
public final class PrivateCloudEngine: CKSyncEngineDelegate, @unchecked Sendable {
    public static let containerIdentifier = "iCloud.io.github.anthonytw.matine"

    /// The process's engine, made on first use (a container needs the app's iCloud entitlement).
    public static let shared = PrivateCloudEngine()

    let container: CKContainer
    /// Our own fetches and sends, one at a time (see `SerialGate`).
    let gate = SerialGate()
    private let stateURL: URL
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    private var startOver = false
    private var handlers: [any PrivateZoneHandler] = []

    init(
        stateURL: URL = PrivateCloudEngine.defaultStateURL, legacyStateURLs: [URL] = PrivateCloudEngine.legacyStateURLs,
        container id: String = containerIdentifier
    ) {
        container = CKContainer(identifier: id)
        self.stateURL = stateURL
        // The two engines this one replaces kept their own change tokens: they are void
        // now, and the merged engine starts with a full fetch.
        for url in legacyStateURLs { try? FileManager.default.removeItem(at: url) }
    }

    static var defaultStateURL: URL {
        caches.appending(path: "PrivateCloud/engine-state.json")
    }

    static var legacyStateURLs: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? caches
        return [
            caches.appending(path: "Keywords/engine-state.json"), support.appending(path: "Keywords/engine-state.json"),
            caches.appending(path: "Household/engine-state.json"),
        ]
    }

    private static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    func register(_ handler: any PrivateZoneHandler) {
        lock.withLock {
            handlers.append(handler)
            // An engine already running fetched without this zone's handler: those records
            // went nowhere. Every handler must be made before the first use (the apps build
            // both clouds at launch); starting over is only the release-build fallback.
            if engine != nil {
                log.fault("a zone handler registered after the engine started")
                assertionFailure("register before first use")
                startOver = true
                engine = nil
            }
        }
    }

    /// The engine, made on first use.
    func syncEngine() -> CKSyncEngine {
        lock.withLock {
            if let engine { return engine }
            if startOver {
                try? FileManager.default.removeItem(at: stateURL)
                startOver = false
            }
            let state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
            var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: self)
            configuration.automaticallySync = true
            let made = CKSyncEngine(configuration)
            engine = made
            return made
        }
    }

    /// Forgets the change tokens and anything waiting: the next fetch starts over.
    func reset() {
        let all = lock.withLock {
            startOver = true
            engine = nil
            return handlers
        }
        for handler in all { handler.reset(accountChanged: false) }
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // An engine that was dropped (another Apple ID, or `reset()`) may still call:
        // its state must not overwrite the new engine's.
        guard lock.withLock({ engine === syncEngine }) else { return }
        let all = lock.withLock { handlers }
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: stateURL, options: .atomic)
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn: break
            default:
                // Another Apple ID (or none): what we hold belongs to the old one. The
                // engine is made again, without tokens, at the next use.
                lock.withLock {
                    startOver = true
                    engine = nil
                }
                for handler in all { handler.reset(accountChanged: true) }
            }
        case .fetchedDatabaseChanges(let fetched):
            for handler in all where fetched.deletions.contains(where: { $0.zoneID == handler.zoneID }) { handler.zoneWasDeleted() }
        case .fetchedRecordZoneChanges, .sentRecordZoneChanges:
            for handler in all { handler.handle(event, syncEngine: syncEngine) }
        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let all = lock.withLock { handlers }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            // The handler that owns the zone knows the record.
            guard let record = all.first(where: { $0.zoneID == recordID.zoneID })?.record(for: recordID.recordName) else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return record
        }
    }
}
#endif
