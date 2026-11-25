import Foundation
import Testing
@testable import MatineKit

private struct Refused: Error {}

private struct Gen: KeywordGenerator {
    let identifier: String
    var words: [String] = ["palabra"]
    var refuses: Set<String> = []
    var unavailable = false
    func checkAvailable() async throws { if unavailable { throw KeywordsUnavailable("off") } }
    func keywords(for source: KeywordSource) async throws -> [String] {
        if unavailable { throw KeywordsUnavailable("off") }
        if refuses.contains(source.id) { throw Refused() }
        return words
    }
}

private func film(_ id: String, _ name: String = "Pelicula") -> Item { Item(id: id, name: name + id, kind: .movie) }

/// A cloud in memory: what it holds, and what it hands out as changes.
private final class FakeCloud: KeywordCloud, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String: ItemKeywords] = [:]
    private var pending = KeywordCloudChanges()
    private var signedIn = true
    private var refusing = false
    private(set) var saves = 0
    private(set) var resets = 0
    var accountName: String? = "user-a"

    func account() async -> KeywordCloudAccount { signedIn ? .available : .noAccount }
    func fetchChanges() async throws -> KeywordCloudChanges {
        lock.withLock { defer { pending = KeywordCloudChanges() }; return pending }
    }
    func save(_ records: [KeywordCloudRecord]) async throws -> [String] {
        lock.withLock {
            saves += 1
            // CloudKit refusing (schema not deployed, quota) doesn't throw: nothing is confirmed.
            if refusing { return [] }
            for r in records { held[r.name] = r.keywords }
            return records.map(\.name)
        }
    }
    func reset() async { lock.withLock { resets += 1 } }
    func accountId() async -> String? { lock.withLock { accountName } }
    func signIn(as name: String) { lock.withLock { signedIn = true; accountName = name } }
    func refuse(_ on: Bool) { lock.withLock { refusing = on } }
    func queue(_ changes: KeywordCloudChanges) { lock.withLock { pending = changes } }
    func seed(_ name: String, _ keywords: ItemKeywords) {
        lock.withLock { held[name] = keywords; pending.saved.append(KeywordCloudRecord(name: name, keywords: keywords)) }
    }
    func signOut() { lock.withLock { signedIn = false } }
    func holds(_ name: String) -> ItemKeywords? { lock.withLock { held[name] } }
}

private func tempFile(_ name: String) -> KeywordStoreFile {
    KeywordStoreFile(url: FileManager.default.temporaryDirectory.appending(path: "kw-\(UUID().uuidString)/\(name).json"))
}

private let model = "foundation-models/v1-aaaa"
private let translate = "translation/2"

@Suite struct KeywordFallbackTests {
    @Test func aRefusedItemFallsBackToTranslationAndIsMarkedForRetry() async throws {
        let items = [film("a"), film("b")]
        var store = KeywordStore()
        let builder = KeywordBuilder(generator: Gen(identifier: model, words: ["modelo"], refuses: ["b"]), fallback: Gen(identifier: translate, words: ["literal"]))
        let report = try await builder.fill(&store, items: items)
        #expect(report.generated == 2 && report.fellBack == 1 && report.failed.isEmpty)
        #expect(store.keywords(for: "a")?.generation == model && store.keywords(for: "a")?.retryAfter == nil)
        #expect(store.keywords(for: "b")?.generation == translate && store.keywords(for: "b")?.retryAfter == model)
    }

    @Test func aFallbackEntryIsNotRetriedUntilTheModelChanges() async throws {
        let item = film("b")
        var store = KeywordStore()
        let refusing = Gen(identifier: model, refuses: ["b"])
        _ = try await KeywordBuilder(generator: refusing, fallback: Gen(identifier: translate)).fill(&store, items: [item])
        // Same model: nothing to do (no model call at all).
        let again = try await KeywordBuilder(generator: refusing, fallback: Gen(identifier: translate)).fill(&store, items: [item])
        #expect(again.generated == 0)
        // A new model generation: retried, and the model's entry replaces it.
        let report = try await KeywordBuilder(generator: Gen(identifier: "foundation-models/v2-bbbb", words: ["mejor"]), fallback: Gen(identifier: translate)).fill(&store, items: [item])
        #expect(report.generated == 1 && report.fellBack == 0)
        #expect(store.keywords(for: "b")?.words == ["mejor"] && store.keywords(for: "b")?.retryAfter == nil)
    }

    @Test func modelUnavailableMidRunUsesFallbackForTheRest() async throws {
        var store = KeywordStore()
        let report = try await KeywordBuilder(generator: Gen(identifier: model, unavailable: true), fallback: Gen(identifier: translate)).fill(&store, items: [film("a"), film("b")])
        #expect(report.generated == 2 && report.fellBack == 2)
        // Without a fallback it still stops the run.
        var empty = KeywordStore()
        await #expect(throws: KeywordsUnavailable("off")) {
            _ = try await KeywordBuilder(generator: Gen(identifier: model, unavailable: true)).fill(&empty, items: [film("a")])
        }
    }

    @Test func translateRunKeepsEntriesAModelMadeButRedoesItsOwnOlderVersion() async throws {
        let (a, b, c) = (film("a"), film("b"), film("c"))
        var store = KeywordStore()
        _ = try await KeywordBuilder(generator: Gen(identifier: model, words: ["modelo"])).fill(&store, items: [a])
        _ = try await KeywordBuilder(generator: Gen(identifier: "translation/1", words: ["viejo"])).fill(&store, items: [b])
        let report = try await KeywordBuilder(generator: Gen(identifier: translate, words: ["nuevo"])).fill(&store, items: [a, b, c])
        #expect(report.generated == 2)
        #expect(store.keywords(for: "a")?.words == ["modelo"])
        #expect(store.keywords(for: "b")?.words == ["nuevo"] && store.keywords(for: "c")?.words == ["nuevo"])
        // A model run does redo what translation made without a retry mark.
        let model2 = try await KeywordBuilder(generator: Gen(identifier: model, words: ["modelo"])).fill(&store, items: [a, b, c])
        #expect(model2.generated == 2)
    }

    @Test func changedTextIsAlwaysRedoneEvenByAWorseGenerator() async throws {
        var item = film("a")
        var store = KeywordStore()
        _ = try await KeywordBuilder(generator: Gen(identifier: model)).fill(&store, items: [item])
        item.overview = "Otra historia."
        let report = try await KeywordBuilder(generator: Gen(identifier: translate, words: ["nuevo"])).fill(&store, items: [item])
        #expect(report.generated == 1 && store.keywords(for: "a")?.words == ["nuevo"])
    }

    @Test func aFallbackNeverReplacesAModelEntryOfTheSameText() async throws {
        let item = film("a")
        var store = KeywordStore()
        _ = try await KeywordBuilder(generator: Gen(identifier: model, words: ["modelo"])).fill(&store, items: [item])
        // Forced rerun, and the model now refuses: the old model entry stays.
        _ = try await KeywordBuilder(generator: Gen(identifier: model, refuses: ["a"]), fallback: Gen(identifier: translate)).fill(&store, items: [item], force: true)
        #expect(store.keywords(for: "a")?.words == ["modelo"])
    }
}

@Suite struct KeywordMergeRuleTests {
    @Test func betterGeneratorBeatsNewerFallbackForTheSameText() {
        let model = ItemKeywords(words: ["m"], sourceHash: "h", made: 1, generation: "foundation-models/v1-x")
        let fallback = ItemKeywords(words: ["f"], sourceHash: "h", made: 9, generation: "translation/2", retryAfter: "foundation-models/v1-x")
        #expect(model.wins(over: fallback))
        #expect(!fallback.wins(over: model))
        // Changed text: the matching one wins whatever made it; else the newer.
        let edited = ItemKeywords(words: ["e"], sourceHash: "h2", made: 5, generation: "translation/2")
        #expect(edited.wins(over: model, currentHash: "h2"))
        #expect(!edited.wins(over: model, currentHash: "h"))
        #expect(edited.wins(over: model))
    }

    @Test func recordNamesHideTitlesAndSeparateServers() {
        let a = KeywordRecordName.make(serverId: "s1", itemId: "i1")
        #expect(a == KeywordRecordName.make(serverId: "s1", itemId: "i1"))
        #expect(a != KeywordRecordName.make(serverId: "s2", itemId: "i1"))
        #expect(!a.contains("i1") && a.count == 33)
    }

    @Test func retryMarkRoundTripsAndOldFilesStillRead() throws {
        let entry = ItemKeywords(words: ["x"], sourceHash: "h", made: 1, generation: "translation/2", retryAfter: "foundation-models/v1-x")
        var store = KeywordStore()
        store.set("a", entry)
        #expect(try KeywordStore(data: store.data()) == store)
        #expect(try KeywordStore(data: Data(#"{"e":{"a":{"h":"h","t":1,"w":["x"]}},"v":1}"#.utf8)).keywords(for: "a")?.retryAfter == nil)
    }
}

@Suite struct KeywordSyncTests {
    private func sync(_ cloud: FakeCloud, _ role: KeywordSync.Role = .writer, local: KeywordStoreFile = tempFile("l"), remote: KeywordStoreFile = tempFile("r")) -> KeywordSync {
        KeywordSync(cloud: cloud, role: role, localFile: local, remoteFile: remote)
    }

    @Test func writerSendsWhatItMadeAndAReaderResolvesItByRecordName() async throws {
        let items = [film("a"), film("b")]
        let cloud = FakeCloud()
        let writer = sync(cloud)
        var store = await writer.resolved(items: items, serverId: "s")
        _ = try await KeywordBuilder(generator: Gen(identifier: model, words: ["perro"])).fill(&store, items: items)
        await writer.adopt(store)
        let report = await writer.sync(items: items, serverId: "s")
        #expect(report.sent == 2)
        let name = KeywordRecordName.make(serverId: "s", itemId: "a")
        #expect(cloud.holds(name)?.words == ["perro"])
        // Nothing left to send.
        #expect(await writer.sync(items: items, serverId: "s").sent == 0)

        // The TV: another object, empty local store, same cloud content.
        let tv = FakeCloud()
        tv.seed(name, cloud.holds(name)!)
        let reader = sync(tv, .reader)
        _ = await reader.sync(items: items, serverId: "s")
        let view = await reader.resolved(items: items, serverId: "s")
        #expect(view.keywords(for: "a")?.words == ["perro"] && view.keywords(for: "b") == nil)
        #expect(SearchIndex(items: items, keywords: view).search("perro").sections.flatMap(\.items).map(\.id) == ["a"])
        // Another server's records are not this server's items.
        #expect(await reader.resolved(items: items, serverId: "other").count == 0)
        #expect(tv.saves == 0)
    }

    @Test func aReaderNeverSends() async throws {
        let cloud = FakeCloud()
        let reader = sync(cloud, .reader)
        var store = KeywordStore()
        store.set("a", ItemKeywords(words: ["x"], sourceHash: "h", made: 1, generation: model))
        await reader.adopt(store)
        #expect(await reader.sync(items: [film("a")], serverId: "s").sent == 0)
        #expect(cloud.saves == 0)
    }

    @Test func aFallbackNeverOverwritesTheCloudsModelEntry() async throws {
        let item = film("a")
        let hash = KeywordSource(item: item).hash
        let cloud = FakeCloud()
        let name = KeywordRecordName.make(serverId: "s", itemId: "a")
        cloud.seed(name, ItemKeywords(words: ["modelo"], sourceHash: hash, made: 1, generation: model))
        let writer = sync(cloud)
        var store = KeywordStore()
        store.set("a", ItemKeywords(words: ["literal"], sourceHash: hash, made: 99, generation: translate, retryAfter: model))
        await writer.adopt(store)
        let report = await writer.sync(items: [item], serverId: "s")
        #expect(report.sent == 0 && cloud.holds(name)?.words == ["modelo"])
        #expect(await writer.resolved(items: [item], serverId: "s").keywords(for: "a")?.words == ["modelo"])
    }

    @Test func aModelEntryReplacesTheCloudsFallbackAndChangedTextWins() async throws {
        var item = film("a")
        let cloud = FakeCloud()
        let name = KeywordRecordName.make(serverId: "s", itemId: "a")
        cloud.seed(name, ItemKeywords(words: ["literal"], sourceHash: KeywordSource(item: item).hash, made: 5, generation: translate, retryAfter: model))
        let writer = sync(cloud)
        var store = KeywordStore()
        store.set("a", ItemKeywords(words: ["modelo"], sourceHash: KeywordSource(item: item).hash, made: 1, generation: model))
        await writer.adopt(store)
        #expect(await writer.sync(items: [item], serverId: "s").sent == 1)
        #expect(cloud.holds(name)?.words == ["modelo"])
        // The text changes and the cloud's entry is now stale: the fresh local one is sent.
        item.overview = "Nueva."
        var fresh = KeywordStore()
        fresh.set("a", ItemKeywords(words: ["nuevo"], sourceHash: KeywordSource(item: item).hash, made: 2, generation: translate))
        await writer.adopt(fresh)
        // Older text, weaker generator: adopt keeps the held entry unless it wins.
        let view = await writer.resolved(items: [item], serverId: "s")
        #expect(view.keywords(for: "a")?.words == ["nuevo"])
    }

    @Test func deletionsAndResetsEmptyTheCache() async throws {
        let items = [film("a")]
        let name = KeywordRecordName.make(serverId: "s", itemId: "a")
        let cloud = FakeCloud()
        cloud.seed(name, ItemKeywords(words: ["x"], sourceHash: "h", made: 1, generation: model))
        let reader = sync(cloud, .reader)
        _ = await reader.sync(items: items, serverId: "s")
        #expect(await reader.resolved(items: items, serverId: "s").count == 1)
        await reader.apply(KeywordCloudChanges(deleted: [name]))
        #expect(await reader.resolved(items: items, serverId: "s").count == 0)
        await reader.apply(KeywordCloudChanges(saved: [KeywordCloudRecord(name: name, keywords: ItemKeywords(words: ["y"], sourceHash: "h", made: 1))]))
        await reader.apply(KeywordCloudChanges(reset: true))
        #expect(await reader.resolved(items: items, serverId: "s").count == 0)
    }

    @Test func withoutICloudSyncReportsWhyAndLocalWorksOn() async throws {
        let cloud = FakeCloud()
        cloud.signOut()
        let writer = sync(cloud)
        var store = KeywordStore()
        store.set("a", ItemKeywords(words: ["x"], sourceHash: "h", made: 1, generation: model))
        await writer.adopt(store)
        let report = await writer.sync(items: [film("a")], serverId: "s")
        #expect(report.unavailable != nil && report.sent == 0)
        #expect(await writer.resolved(items: [film("a")], serverId: "s").count == 1)
    }

    @Test func storesPersistAcrossLaunchesAndProgressCounts() async throws {
        let (l, r) = (tempFile("l"), tempFile("r"))
        let items = [film("a"), film("b"), Item(id: "s", name: "Temporada", kind: .season)]
        let cloud = FakeCloud()
        let first = sync(cloud, .writer, local: l, remote: r)
        var store = KeywordStore()
        let hash = KeywordSource(item: items[0]).hash
        store.set("a", ItemKeywords(words: ["x"], sourceHash: hash, made: 1, generation: model))
        await first.adopt(store)
        _ = await first.sync(items: items, serverId: "s")
        let second = sync(FakeCloud(), .writer, local: l, remote: r)
        let (have, of) = await second.progress(items: items, serverId: "s")
        #expect(have == 1 && of == 2)
        #expect(FileManager.default.fileExists(atPath: r.url.path))
    }

    @Test func recordsCloudKitRefusedAreNotMarkedSentAndGoAgainLater() async throws {
        let item = film("a")
        let cloud = FakeCloud()
        cloud.refuse(true)
        let writer = sync(cloud)
        var store = KeywordStore()
        store.set("a", ItemKeywords(words: ["x"], sourceHash: KeywordSource(item: item).hash, made: 1, generation: model))
        await writer.adopt(store)
        let failed = await writer.sync(items: [item], serverId: "s")
        #expect(failed.sent == 0 && cloud.holds(KeywordRecordName.make(serverId: "s", itemId: "a")) == nil)
        cloud.refuse(false)
        let again = await writer.sync(items: [item], serverId: "s")
        #expect(again.sent == 1 && cloud.holds(KeywordRecordName.make(serverId: "s", itemId: "a"))?.words == ["x"])
    }

    @Test func signedOutClearsTheCachedWordsAndMakesTheEngineStartOver() async throws {
        let items = [film("a")]
        let name = KeywordRecordName.make(serverId: "s", itemId: "a")
        let cloud = FakeCloud()
        cloud.seed(name, ItemKeywords(words: ["x"], sourceHash: "h", made: 1, generation: model))
        let reader = sync(cloud, .reader)
        #expect(await reader.sync(items: items, serverId: "s").changed)
        cloud.signOut()
        let report = await reader.sync(items: items, serverId: "s")
        #expect(report.changed && cloud.resets == 1)
        #expect(await reader.resolved(items: items, serverId: "s").count == 0)
        // Nothing left to clear the second time.
        #expect(await !reader.sync(items: items, serverId: "s").changed)
    }

    @Test func anotherAppleIdKeepsThePhonesOldWordsOutOfTheNewAccount() async throws {
        let item = film("a")
        let cloud = FakeCloud()
        let writer = sync(cloud)
        var store = KeywordStore()
        store.set("a", ItemKeywords(words: ["x"], sourceHash: KeywordSource(item: item).hash, made: 1, generation: model))
        await writer.adopt(store)
        cloud.queue(KeywordCloudChanges(accountChanged: true))
        let report = await writer.sync(items: [item], serverId: "s")
        #expect(report.sent == 0 && report.changed == false)
        #expect(cloud.holds(KeywordRecordName.make(serverId: "s", itemId: "a")) == nil)
        // A zone someone deleted is not an account change: the phone's own words go up again.
        var again = KeywordStore()
        again.set("a", ItemKeywords(words: ["y"], sourceHash: KeywordSource(item: item).hash, made: 2, generation: model))
        await writer.adopt(again)
        cloud.queue(KeywordCloudChanges(reset: true))
        #expect(await writer.sync(items: [item], serverId: "s").sent == 1)
    }

    @Test func aResetWithNothingReceivedStillReportsAChange() async throws {
        let items = [film("a")]
        let cloud = FakeCloud()
        cloud.seed(KeywordRecordName.make(serverId: "s", itemId: "a"), ItemKeywords(words: ["x"], sourceHash: "h", made: 1, generation: model))
        let reader = sync(cloud, .reader)
        _ = await reader.sync(items: items, serverId: "s")
        cloud.queue(KeywordCloudChanges(reset: true))
        let report = await reader.sync(items: items, serverId: "s")
        #expect(report.received == 0 && report.changed)
    }

    @Test func versionsAreOrderedSoBuildsNeverRedoEachOthersEntries() async throws {
        #expect(KeywordGenerations.version(of: "foundation-models/v2-abcd") == 2)
        #expect(KeywordGenerations.version(of: "foundation-models/1a2b3c4d") == 1) // before versions existed
        #expect(KeywordGenerations.version(of: "translation/2") == 2)
        let item = film("a")
        var store = KeywordStore()
        _ = try await KeywordBuilder(generator: Gen(identifier: "foundation-models/v2-bbbb", words: ["nuevo"])).fill(&store, items: [item])
        // The older build runs: the newer build's entry stays.
        let old = try await KeywordBuilder(generator: Gen(identifier: "foundation-models/v1-aaaa")).fill(&store, items: [item])
        #expect(old.generated == 0)
        // The newer build redoes an older build's.
        var older = KeywordStore()
        _ = try await KeywordBuilder(generator: Gen(identifier: "foundation-models/v1-aaaa")).fill(&older, items: [item])
        #expect(try await KeywordBuilder(generator: Gen(identifier: "foundation-models/v2-bbbb")).fill(&older, items: [item]).generated == 1)
        // A fallback waits for a newer version of the generator that refused it, not a different edition.
        var fell = KeywordStore()
        _ = try await KeywordBuilder(generator: Gen(identifier: "foundation-models/v2-bbbb", refuses: ["a"]), fallback: Gen(identifier: translate)).fill(&fell, items: [item])
        #expect(fell.isFresh(item, generation: "foundation-models/v1-aaaa"))
        #expect(!fell.isFresh(item, generation: "foundation-models/v3-cccc"))
        // The same text from two builds merges to the newer version, not the newer clock.
        let v1 = ItemKeywords(words: ["a"], sourceHash: "h", made: 9, generation: "foundation-models/v1-aaaa")
        let v2 = ItemKeywords(words: ["b"], sourceHash: "h", made: 1, generation: "foundation-models/v2-bbbb")
        #expect(v2.wins(over: v1) && !v1.wins(over: v2))
    }

    @Test func anotherAccountAfterASignOutNeverReceivesTheOldWords() async throws {
        let item = film("a")
        let (l, r) = (tempFile("l"), tempFile("r"))
        let name = KeywordRecordName.make(serverId: "s", itemId: "a")
        let cloud = FakeCloud()
        let writer = sync(cloud, .writer, local: l, remote: r)
        var store = KeywordStore()
        store.set("a", ItemKeywords(words: ["x"], sourceHash: KeywordSource(item: item).hash, made: 1, generation: model))
        await writer.adopt(store)
        #expect(await writer.sync(items: [item], serverId: "s").sent == 1)
        // Signed out, the app is opened, another Apple ID signs in: no event, a new engine.
        cloud.signOut()
        _ = await writer.sync(items: [item], serverId: "s")
        let other = FakeCloud()
        other.signIn(as: "user-b")
        let relaunched = sync(other, .writer, local: l, remote: r)
        let report = await relaunched.sync(items: [item], serverId: "s")
        #expect(report.sent == 0 && other.holds(name) == nil)
        #expect(await relaunched.resolved(items: [item], serverId: "s").count == 0)
        // The same account signing out and in again keeps what the phone made.
        let again = FakeCloud()
        var made = KeywordStore()
        made.set("a", ItemKeywords(words: ["y"], sourceHash: KeywordSource(item: item).hash, made: 2, generation: model))
        await relaunched.adopt(made)
        _ = await relaunched.sync(items: [item], serverId: "s")
        again.signIn(as: "user-b")
        let back = sync(again, .writer, local: l, remote: r)
        _ = await back.sync(items: [item], serverId: "s")
        #expect(await back.resolved(items: [item], serverId: "s").keywords(for: "a")?.words == ["y"])
    }
}

@Suite struct KeywordSkipTests {
    @Test func aFallbackThatLosesToTheHeldEntryIsReportedSkipped() async throws {
        let item = film("a")
        var store = KeywordStore()
        _ = try await KeywordBuilder(generator: Gen(identifier: model, words: ["modelo"])).fill(&store, items: [item])
        // A newer model generation refuses it; the translation loses to the held model entry.
        let builder = KeywordBuilder(generator: Gen(identifier: "foundation-models/v2-bbbb", refuses: ["a"]), fallback: Gen(identifier: translate))
        let report = try await builder.fill(&store, items: [item], limit: 1)
        #expect(report.generated == 0 && report.failed.isEmpty)
        #expect(report.skipped == ["a"])
        #expect(store.keywords(for: "a")?.generation == model)
    }

    @Test func adoptingMadeEntriesLeavesTheCloudsCopiesOutOfTheLocalFile() async throws {
        let cloud = FakeCloud()
        let local = tempFile("l")
        let writer = KeywordSync(cloud: cloud, role: .writer, localFile: local, remoteFile: tempFile("r"))
        let made = ItemKeywords(words: ["perro"], sourceHash: KeywordSource(item: film("a")).hash, made: 1, generation: model, retryAfter: nil)
        await writer.adopt([(id: "a", keywords: made)])
        #expect(local.load().count == 1)
        #expect(local.load().keywords(for: "a")?.words == ["perro"])
    }
}
