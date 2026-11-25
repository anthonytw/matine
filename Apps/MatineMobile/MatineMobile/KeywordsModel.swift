import BackgroundTasks
import CloudKit
import Foundation
import SwiftUI
import MatineKit
import Observation
import UIKit

/// The phone makes the bilingual search keywords (Apple's model, translation
/// for titles it refuses) and sends them to the owner's private iCloud
/// database; the Apple TV reads them there. Keywords are per server, not per
/// profile. Nothing here knows what anyone watched.
@MainActor @Observable
final class KeywordsModel {
    static let taskIdentifier = "io.github.anthonytw.matine.keywords"
    /// Titles made per run. On battery a run only goes on while the app is on screen.
    private static let budget = 400
    /// Titles per call to the builder: the catalog is hashed once per call, and the
    /// count on the profile screen moves, and a stop loses at most this many.
    private static let batch = 5

    private(set) var progress: (have: Int, of: Int)?
    /// Why no keywords are being made right now (nil while they are, or when all are done).
    private(set) var problem: KeywordProblem?
    /// True while titles are being made.
    private(set) var making = false
    /// Bumped when new keywords are ready: search rebuilds its index.
    private(set) var version = 0
    /// A share of someone else's keywords is accepted on this Apple ID: their words are read here, and what this phone makes goes to them too.
    private(set) var participating = false
    /// Said once in an alert: a share was accepted, ended or refused.
    var shareNotice: LocalizedStringKey?

    @ObservationIgnored private let sync: KeywordSync
    @ObservationIgnored private let settings: any KeyValueStore
    @ObservationIgnored private var running = false
    /// The catalog as last read: coming back to the app within `catalogFreshFor` doesn't read it again.
    @ObservationIgnored private var catalog: (key: String, items: [Item], at: Date)?
    @ObservationIgnored private var reading: (key: String, id: UUID, task: Task<[Item], any Error>)?
    private static let catalogFreshFor: TimeInterval = 10 * 60

    init(settings: any KeyValueStore = UserDefaults.standard) {
        self.settings = settings
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory).appending(path: "Keywords")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let files = KeywordFiles.prepare(in: base)
        // Built now: it registers with the shared engine before the household does (see PrivateCloudEngine).
        let cloud = CloudKitKeywordCloud(stateURL: files.state, writer: true)
        // The shared database has its own engine and state (never the private engine: one per database).
        let shared = CloudKitSharedKeywordCloud(stateURL: files.sharedState, writer: true)
        sync = KeywordSync(cloud: cloud, role: .writer, localFile: files.local, remoteFile: files.remote, shared: shared, sharedFile: files.shared)
    }

    /// Accepts the share the system handed over (the link was opened). Only the keywords zone is accepted.
    func acceptShare(_ metadata: CKShare.Metadata) async {
        do {
            guard try await KeywordShare.accept(metadata) else { return }
            shareNotice = "Ya recibes las palabras clave de la otra persona, y las tuyas le llegan a ella."
        } catch {
            shareNotice = "No se pudo aceptar la invitación. Ábrela otra vez cuando haya conexión y iCloud esté activo."
        }
    }

    /// Notes what a sync found about the share.
    private func note(_ report: KeywordSync.Report) {
        participating = report.participating
        if report.shareEnded { shareNotice = "Se dejó de compartir. Conservas las palabras clave que ya habían llegado." }
    }

    private var charging: Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return [.charging, .full].contains(UIDevice.current.batteryState)
    }

    /// The catalog key: the server and the profile (ids are only unique per server).
    static func catalogKey(_ account: Account) -> String { account.server.absoluteString + "|" + account.id }

    /// The SERVER's catalog for `key`, read once for Search and for the keyword run alike:
    /// held for `catalogFreshFor`, and a read already under way is joined rather than repeated.
    /// Only server reads belong here (never the offline mirror's list): `fetch` must not fall back.
    /// `fresh` reads again regardless (the system's task, hours after the last look).
    func sharedCatalog(key: String, fresh: Bool = false, fetch: @escaping @Sendable () async throws -> [Item]) async throws -> [Item] {
        if !fresh, let held = catalog, held.key == key, Date().timeIntervalSince(held.at) < Self.catalogFreshFor { return held.items }
        if !fresh, let reading, reading.key == key { return try await reading.task.value }
        let task = Task { try await fetch() }
        let id = UUID()
        reading = (key, id, task)
        // Only the read still current clears or sets anything: a newer one may have replaced it.
        defer { if reading?.id == id { reading = nil } }
        let items = try await task.value
        if reading?.id == id { catalog = (key, items, Date()) }
        return items
    }

    /// What search uses for `items`: this phone's and iCloud's keywords, as of the last sync.
    func store(for items: [Item], account: Account, profiles: Profiles) async -> KeywordStore {
        guard let serverId = await KeywordFiles.serverId(for: account.server, profiles: profiles, settings: settings) else { return KeywordStore() }
        return await sync.resolved(items: items, serverId: serverId)
    }

    /// Takes iCloud's keywords, makes some for the titles that lack them
    /// (while the app is open, or charging), and sends them.
    func refresh(
        account: Account, client: JellyfinClient, profiles: Profiles, background: Bool = false,
        keepGoing: @escaping @MainActor () -> Bool = { true }
    ) async {
        guard !running else { return }
        running = true
        defer { running = false }
        guard let items = try? await sharedCatalog(key: Self.catalogKey(account), fresh: background, fetch: { try await client.catalog(userId: account.id, credits: false) }) else { return }
        guard let serverId = await KeywordFiles.serverId(for: account.server, profiles: profiles, settings: settings) else { return }
        let first = await sync.sync(items: items, serverId: serverId)
        note(first)
        var changed = first.changed
        let before = await sync.progress(items: items, serverId: serverId)
        progress = before
        let made = await make(items: items, serverId: serverId, budget: Self.budget, onlyWhileOpen: !background, keepGoing: keepGoing)
        // Out of time (the system's task expired): what was made is saved, sending waits for the next run.
        if !Task.isCancelled {
            let report = await sync.sync(items: items, serverId: serverId)
            note(report)
            changed = changed || report.changed
        }
        let after = await sync.progress(items: items, serverId: serverId)
        progress = after
        if changed || made > 0 || after.have != before.have { version += 1 }
    }

    /// How many titles got keywords. A few titles at a time (`batch`), so the count on the
    /// profile screen moves as they are made and a stop loses at most one batch.
    private func make(items: [Item], serverId: String, budget: Int, onlyWhileOpen: Bool, keepGoing: @MainActor () -> Bool) async -> Int {
        let translation = TranslationKeywordGenerator()
        let translationReady = (try? await translation.checkAvailable()) != nil
        let modelReason = ModelKeywordGenerator.unavailableReason
        let builder: KeywordBuilder
        if modelReason == nil {
            builder = KeywordBuilder(generator: ModelKeywordGenerator(), fallback: translationReady ? translation : nil)
        } else if translationReady {
            builder = KeywordBuilder(generator: translation)
        } else {
            problem = KeywordProblem(modelReason: modelReason)
            return 0
        }
        problem = nil
        making = true
        defer {
            making = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        var made = 0
        var sent = 0
        // Titles both generators refused, or whose new entry lost to a better one,
        // this run: not asked again until the next one.
        var refused = Set<String>()
        // Resolved once; each batch fills this store and hands on only what it made.
        var store = await sync.resolved(items: items, serverId: serverId)
        while made < budget, !Task.isCancelled, keepGoing() {
            // On battery, stop when the app leaves the screen (charging, the system's task carries on).
            if onlyWhileOpen, !charging, UIApplication.shared.applicationState != .active { break }
            // Plugged in with the app open, the screen stays on until the run ends:
            // a locked phone suspends the app, and the system's task may wait for hours.
            UIApplication.shared.isIdleTimerDisabled = charging && UIApplication.shared.applicationState == .active
            let before = store.entries
            /// What this batch added or changed (also when it ends early).
            func newEntries(_ store: KeywordStore) -> [(id: String, keywords: ItemKeywords)] {
                store.entries.filter { before[$0.key] != $0.value }.map { (id: $0.key, keywords: $0.value) }
            }
            let report: KeywordBuilder.Report
            do {
                report = try await builder.fill(
                    &store, items: items.filter { !refused.contains($0.id) }, limit: min(Self.batch, budget - made),
                    checkpointEvery: 0
                )
            } catch is CancellationError {
                let done = newEntries(store)
                await sync.adopt(done)
                made += done.count
                break
            } catch {
                // The generator went away mid-run.
                let done = newEntries(store)
                await sync.adopt(done)
                made += done.count
                problem = .failed("\(error)")
                break
            }
            if report.generated == 0 && report.failed.isEmpty && report.skipped.isEmpty { break }   // nothing left to make
            if let failed = report.failed.first {
                // The model and the fallback both refused this title: it stays without keywords.
                problem = .failed(failed.message)
            }
            refused.formUnion(report.failed.map(\.id))
            refused.formUnion(report.skipped)
            await sync.adopt(newEntries(store))
            made += report.generated
            progress = await sync.progress(items: items, serverId: serverId)
            // A long charging run sends as it goes, so the TV doesn't wait for the end.
            if made - sent >= 20 {
                sent = made
                _ = await sync.sync(items: items, serverId: serverId)
            }
        }
        return made
    }

    // MARK: Background

    /// Registers the system's charging-time task. Call before the app finishes launching.
    ///
    /// Both closures are `@Sendable` ON PURPOSE: the system calls them on its own queue, and
    /// BackgroundTasks' blocks aren't annotated, so a closure written inside this `@MainActor`
    /// class would silently become `@MainActor` and trap (executor check) when launched in the
    /// background. A `@Sendable` closure is nonisolated; it hops to the main actor itself.
    func registerBackgroundTask(run: @escaping @MainActor @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { @Sendable [self] task in
            let box = TaskBox(task: task)
            let work = Task { @MainActor in
                // Ask again first: a run that is cut short still leaves the next one booked.
                self.scheduleBackgroundTask()
                await run()
                self.scheduleBackgroundTask()
                box.finish(success: !Task.isCancelled)
            }
            // Out of time: stop, and say so now, not when the work notices.
            task.expirationHandler = { @Sendable in
                work.cancel()
                box.finish(success: false)
            }
        }
    }

    /// Asks for a run while the phone charges, if titles still lack keywords.
    func scheduleBackgroundTask() {
        guard progress.map({ $0.have < $0.of }) ?? true else { return }
        Task {
            // A pending request keeps its date: booking again at every move to the
            // background would push it an hour further out each time.
            let pending = await BGTaskScheduler.shared.pendingTaskRequests()
            if pending.contains(where: { $0.identifier == Self.taskIdentifier }) { return }
            let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = true
            request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
            try? await BGTaskScheduler.shared.submitTaskRequest(request)
        }
    }

    /// Completes the system's task once, from whichever of the run and the expiry comes first.
    private final class TaskBox: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var done = false
        init(task: BGTask) { self.task = task }
        func finish(success: Bool) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { task.setTaskCompleted(success: success) }
        }
    }
}

/// Why the phone isn't making keywords, said plainly on the profile screen.
enum KeywordProblem: Equatable {
    case appleIntelligenceOff
    case notEligible
    case modelDownloading
    case failed(String)

    init(modelReason: String?) {
        let reason = modelReason ?? ""
        if reason.contains("appleIntelligenceNotEnabled") { self = .appleIntelligenceOff }
        else if reason.contains("deviceNotEligible") { self = .notEligible }
        else if reason.contains("modelNotReady") { self = .modelDownloading }
        else { self = .failed(reason) }
    }
}
