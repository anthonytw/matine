import Foundation
import Testing
@testable import MatineKit

private func film(_ id: String) -> Item { Item(id: id, name: "Pelicula" + id, kind: .movie) }
private func tempFile(_ name: String) -> KeywordStoreFile {
    KeywordStoreFile(url: FileManager.default.temporaryDirectory.appending(path: "kws-\(UUID().uuidString)/\(name).json"))
}
private func entry(_ id: String, _ words: [String], generation: String = "foundation-models/v1-aaaa", made: Int = 1) -> ItemKeywords {
    ItemKeywords(words: words, sourceHash: KeywordSource(item: film(id)).hash, made: made, generation: generation)
}
private func name(_ id: String) -> String { KeywordRecordName.make(serverId: "s", itemId: id) }

private struct Offline: Error {}

/// A zone in memory, private or shared: what it holds and what it hands out as changes.
private final class FakeZone: SharedKeywordCloud, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String: ItemKeywords] = [:]
    private var pending = KeywordCloudChanges()
    private var state: KeywordShareState = .participant
    private var stateFails = false
    private(set) var saves: [[String]] = []
    private(set) var resets = 0

    func account() async -> KeywordCloudAccount { .available }
    func fetchChanges() async throws -> KeywordCloudChanges { lock.withLock { defer { pending = KeywordCloudChanges() }; return pending } }
    func save(_ records: [KeywordCloudRecord]) async throws -> [String] {
        lock.withLock {
            saves.append(records.map(\.name))
            for r in records { held[r.name] = r.keywords }
            return records.map(\.name)
        }
    }
    func reset() async { lock.withLock { resets += 1 } }
    func accountId() async -> String? { "user-a" }
    func shareState() async throws -> KeywordShareState {
        try lock.withLock { if stateFails { throw Offline() }; return state }
    }

    func seed(_ id: String, _ keywords: ItemKeywords) {
        lock.withLock { held[name(id)] = keywords; pending.saved.append(KeywordCloudRecord(name: name(id), keywords: keywords)) }
    }
    func setState(_ new: KeywordShareState) { lock.withLock { state = new } }
    func failState(_ on: Bool) { lock.withLock { stateFails = on } }
    func queueReset() { lock.withLock { pending = KeywordCloudChanges(reset: true) } }
    func holds(_ id: String) -> ItemKeywords? { lock.withLock { held[name(id)] } }
    var saveCount: Int { lock.withLock { saves.count } }
}

@Suite struct KeywordShareTests {
    private func make(_ role: KeywordSync.Role = .writer, priv: FakeZone, shared: FakeZone, local: KeywordStoreFile = tempFile("l")) -> KeywordSync {
        KeywordSync(cloud: priv, role: role, localFile: local, remoteFile: tempFile("r"), shared: shared, sharedFile: tempFile("s"))
    }

    @Test func theBestOfTheThreeSourcesWins() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        priv.seed("a", entry("a", ["privado"], generation: "translation/2"))
        shared.seed("a", entry("a", ["compartido"], generation: "foundation-models/v1-aaaa"))
        shared.seed("b", entry("b", ["solo-compartido"]))
        priv.seed("c", entry("c", ["solo-privado"]))
        let sync = make(priv: priv, shared: shared)
        await sync.adopt([(id: "a", keywords: entry("a", ["propio"], generation: "translation/2", made: 0))])
        let items = [film("a"), film("b"), film("c")]
        _ = await sync.sync(items: items, serverId: "s")
        let view = await sync.resolved(items: items, serverId: "s")
        #expect(view.keywords(for: "a")?.words == ["compartido"])   // the better generator, wherever it came from
        #expect(view.keywords(for: "b")?.words == ["solo-compartido"])
        #expect(view.keywords(for: "c")?.words == ["solo-privado"])
    }

    @Test func onTheSameQualityTheNewerOneWins() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        priv.seed("a", entry("a", ["viejo"], made: 5))
        shared.seed("a", entry("a", ["nuevo"], made: 9))
        let sync = make(priv: priv, shared: shared)
        _ = await sync.sync(items: [film("a")], serverId: "s")
        #expect(await sync.resolved(items: [film("a")], serverId: "s").keywords(for: "a")?.words == ["nuevo"])
    }

    @Test func aParticipantWritesToTheSharedZoneAndNotToItsOwn() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        let sync = make(priv: priv, shared: shared)
        await sync.adopt([(id: "a", keywords: entry("a", ["perro"]))])
        let report = await sync.sync(items: [film("a")], serverId: "s")
        #expect(report.participating && report.sent == 1)
        #expect(shared.holds("a")?.words == ["perro"])
        #expect(priv.saveCount == 0)
    }

    @Test func withoutAShareTheWriterSendsToItsOwnZone() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        shared.setState(.none)
        let sync = make(priv: priv, shared: shared)
        await sync.adopt([(id: "a", keywords: entry("a", ["perro"]))])
        let report = await sync.sync(items: [film("a")], serverId: "s")
        #expect(!report.participating && report.sent == 1)
        #expect(priv.holds("a")?.words == ["perro"])
        #expect(shared.saveCount == 0)
    }

    @Test func aParticipantDoesNotResendWhatTheSharedZoneAlreadyHas() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        shared.seed("a", entry("a", ["perro"], made: 9))
        let sync = make(priv: priv, shared: shared)
        await sync.adopt([(id: "a", keywords: entry("a", ["perro"], made: 1))])
        #expect(await sync.sync(items: [film("a")], serverId: "s").sent == 0)
        #expect(shared.saveCount == 0 && priv.saveCount == 0)
    }

    @Test func whenTheShareGoesItsWordsAreKeptAndGoToTheOwnZone() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        shared.seed("a", entry("a", ["compartido"]))
        let local = tempFile("l")
        let sync = make(priv: priv, shared: shared, local: local)
        let items = [film("a")]
        _ = await sync.sync(items: items, serverId: "s")
        #expect(await sync.resolved(items: items, serverId: "s").keywords(for: "a")?.words == ["compartido"])

        shared.setState(.none)   // the owner stopped sharing
        let report = await sync.sync(items: items, serverId: "s")
        #expect(report.shareEnded && !report.participating)
        #expect(await sync.resolved(items: items, serverId: "s").keywords(for: "a")?.words == ["compartido"])
        #expect(priv.holds("a")?.words == ["compartido"])   // now in her own zone
        #expect(local.load().keywords(for: "a")?.words == ["compartido"])
        #expect(shared.resets == 1)
    }

    @Test func aZoneDeletedEventEndsTheShareTheSameWay() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        shared.seed("a", entry("a", ["compartido"]))
        let sync = make(priv: priv, shared: shared)
        let items = [film("a")]
        _ = await sync.sync(items: items, serverId: "s")
        shared.queueReset()
        let report = await sync.sync(items: items, serverId: "s")
        #expect(report.shareEnded)
        #expect(await sync.resolved(items: items, serverId: "s").keywords(for: "a")?.words == ["compartido"])
        #expect(priv.holds("a")?.words == ["compartido"])
    }

    @Test func aReaderForgetsTheSharedWordsWhenTheShareGoes() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        shared.seed("a", entry("a", ["compartido"]))
        let sync = make(.reader, priv: priv, shared: shared)
        let items = [film("a")]
        _ = await sync.sync(items: items, serverId: "s")
        #expect(await sync.resolved(items: items, serverId: "s").keywords(for: "a")?.words == ["compartido"])
        shared.setState(.none)
        _ = await sync.sync(items: items, serverId: "s")
        #expect(await sync.resolved(items: items, serverId: "s").keywords(for: "a") == nil)
        #expect(priv.saveCount == 0 && shared.saveCount == 0)
    }

    @Test func aReaderReadsButNeverSends() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        shared.seed("a", entry("a", ["compartido"]))
        let sync = make(.reader, priv: priv, shared: shared)
        let report = await sync.sync(items: [film("a")], serverId: "s")
        #expect(report.received == 1 && report.sent == 0)
    }

    @Test func notKnowingTheShareStateWritesNowhereForAParticipant() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        shared.seed("a", entry("a", ["compartido"]))
        let sync = make(priv: priv, shared: shared)
        _ = await sync.sync(items: [film("a")], serverId: "s")
        shared.failState(true)
        await sync.adopt([(id: "b", keywords: entry("b", ["perro"]))])
        let report = await sync.sync(items: [film("a"), film("b")], serverId: "s")
        #expect(report.sent == 0 && !report.shareEnded)
        #expect(priv.saveCount == 0 && shared.saveCount == 0)
    }

    @Test func notKnowingTheShareStateKeepsANonParticipantOnItsOwnZone() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        shared.failState(true)
        let sync = make(priv: priv, shared: shared)
        await sync.adopt([(id: "a", keywords: entry("a", ["perro"]))])
        let report = await sync.sync(items: [film("a")], serverId: "s")
        #expect(report.sent == 1 && priv.saveCount == 1 && shared.saveCount == 0)
    }

    @Test func theSharedCacheSurvivesARestart() async {
        let (priv, shared) = (FakeZone(), FakeZone())
        shared.seed("a", entry("a", ["compartido"]))
        let (r, s, l) = (tempFile("r"), tempFile("s"), tempFile("l"))
        _ = await KeywordSync(cloud: priv, role: .writer, localFile: l, remoteFile: r, shared: shared, sharedFile: s).sync(items: [film("a")], serverId: "s")
        let again = KeywordSync(cloud: FakeZone(), role: .writer, localFile: l, remoteFile: r, shared: FakeZone(), sharedFile: s)
        #expect(await again.resolved(items: [film("a")], serverId: "s").keywords(for: "a")?.words == ["compartido"])
    }

    @Test func withoutASharedCloudNothingChanges() async {
        let priv = FakeZone()
        priv.seed("a", entry("a", ["privado"]))
        let sync = KeywordSync(cloud: priv, role: .writer, localFile: tempFile("l"), remoteFile: tempFile("r"))
        let report = await sync.sync(items: [film("a")], serverId: "s")
        #expect(!report.participating && report.received == 1)
    }
}
