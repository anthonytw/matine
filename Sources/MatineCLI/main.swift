import Foundation
import MatineKit

// Row titles repeat the app's (Apps/Matine/Matine/HomeViews.swift): the app's
// are localization keys, these are plain Spanish for the terminal.
//
// `matine`: MatineKit from the command line, against a real Jellyfin server. Every
// feature lands here before (or with) its screen, so it can be checked end to
// end without the simulator. State lives in ~/.config/matine/cli (0700 dir,
// 0600 files): the profile list and its tokens. Passwords are never stored.

let usage = """
usage: matine <command> [options]

  login --server URL --user NAME   sign in (password from MATINE_PASSWORD or stdin)
  dev-login                        sign in with ~/.config/matine/dev-account
  (any command) --store NAME       use a separate profile store, ~/.config/matine/cli-NAME: a second
                                   device id for the same account (a sender next to a `listen`)
  info [--server URL]              server name and version (no sign-in needed)
                                   (commands that need a server take --server URL or MATINE_SERVER)
  profiles                         saved profiles
  home [--profile NAME] [--json]   the home rows, as the app shows them
  topshelf [--profile NAME]        the Top Shelf the app would write for that profile (JSON)
  libraries [--profile NAME]       the profile's libraries
  library LIBRARY_ID [--sort date] one page of a library (--start N for the next page)
  discover LIBRARY_ID              what a library page shows below its titles: what's
                                   partway through there, and a random handful
  search TEXT [--profile NAME] [--keywords FILE]     the app's search, grouped: titles, original titles, synopses,
                                   genres and tags; --meaning adds related titles from the
                                   on-device language model (if this Mac session has it)
  keywords [--library ID] [--limit N] [--generator model|translate] [--no-fallback] [--save FILE] [--force] [--prune]
  keywords --import FILE --save FILE   merge another keywords file into the saved one (no server needed; also how to try the app's private + shared merge; the better
                                   generator's entry for the same text wins, else the newer)
                                   make bilingual search keywords on this Mac (on-device model; read-only
                                   on the server) and print item -> words; --save keeps them in FILE and
                                   only redoes items whose text changed (an entry a better generator made is
                                   kept: --generator translate leaves the model's alone); the model run falls
                                   back to translation for an item it refuses, unless --no-fallback;
                                   --prune drops saved
                                   items no longer in the catalog (run from a parent profile that sees every
                                   library: a kid profile's catalog lacks the rest); search TEXT --keywords FILE uses them
  next SERIES_ID                   the episode Play would start on that series
  seasons SERIES_ID                the seasons of a series
  episodes SERIES_ID [--season N]  its episodes (all, or one season by number): label, name, progress
  playback ITEM_ID [--probe]       how the server will stream it; --probe fetches the
                                   first bytes with the token in a header only
  pins [--profile NAME]            pinned items (Fijados)
  pin ITEM_ID | unpin ITEM_ID      pin or unpin one item [--profile NAME]
  item ITEM_ID [--json]            one item, with its credits, ratings and studio
  person PERSON_ID                 what the library holds with this person (ids come from `item`)
  logout [--profile NAME]          end the session and forget the profile
  robot [SEED] [--color NAME]      a profile robot as SVG (no seed: a sheet of 24 random ones)
  look [--profile NAME]            the profile's name, role and avatar
  look --set-name TEXT | --set-role adult|kid | --set-color NAME | --set-robot SEED | --set-animal NAME
  recent [--profile NAME]          the profile's recent searches (--clear forgets them)
  household [--json]               the household records these profiles would publish to iCloud (the PIN as
                                   set/none; no token, no device id)
  household --cloud FILE --store NAME [--json]
                                   sync with a JSON file standing in for iCloud (the CLI has no iCloud
                                   entitlement): takes what the file holds into this store (profiles arrive
                                   without a token), writes what is newer here, and prints what happened.
                                   The file holds PINs in clear (mode 0600): only with a scratch --store,
                                   never your real profiles
  quickconnect start [--server URL] [--announce]
                                   sign in without a password: prints a 6-digit code to approve on a
                                   signed-in device (the app's profile page, `quickconnect approve`,
                                   or Jellyfin's web app), waits, then saves the profile;
                                   --announce also announces the code on this network, as the
                                   phone app does, so a nearby Apple TV can offer to approve it
  nearby [--seconds N]             lists the sign-in codes announced on this network (default 5 s)
  quickconnect approve CODE [--profile NAME]
                                   approve another device's code as that signed-in profile
  media-report [--library ID]     what each file needs to play as it is on the Apple TV (fine,
                                   faststart, remux, reencode; unchecked when its start wasn't
                                   read): read-only; --quick skips reading the first bytes of
                                   each MP4; --all lists the fine ones too; --json (with each
                                   stream's action) for the converter
  convert-plan [--library ID]     a POSIX sh script, for the machine that holds your media, that makes the files that need it play
                                   as they are: faststart (moov to the front), remux (MKV to MP4),
                                   reencode (only the stream that can't play). --only faststart|remux|
                                   reencode; --limit N. The script is a dry run until DRY_RUN=0;
                                   originals move to a sibling .matine-originals/, never deleted.
                                   Read-only here: matine convert-plan > plan.sh (summary on stderr)
  carry-over --snapshot FILE.json [--profile NAME] [--library ID]
                                   BEFORE the swap: save watched, progress and favorite for the files
                                   a conversion renames (.mkv to .mp4: Jellyfin makes a new item)
  carry-over --restore FILE.json [--profile NAME] [--apply]
                                   AFTER the rescan: find each new item by its path and write that
                                   state back; without --apply it only prints. State is per user:
                                   run both once per profile (each family member), each with its own token
  listen [--profile NAME]          be the TV: report capabilities, connect to the server's WebSocket
                                   and print the remote-control commands that arrive (Ctrl-C ends)
  sessions [--profile NAME]        sessions this profile may control: id, device, remote control support
  tvs [--profile NAME]             the TVs this profile can send a video to, numbered (what the phone app lists)
  play-on N ITEM_ID [--start SECONDS]   send an item to TV number N from `tvs`, as the phone app does
  send-play SESSION_ID ITEM_ID [--start SECONDS]   ask that session to play an item now
  send SESSION_ID pause|unpause|stop|playpause     control that session's playback
  send SESSION_ID seek SECONDS
  download ITEM_ID --to DIR [--season SEASON_ID --series SERIES_ID] [--cellular]
                                   download a film, video or episode (or a whole season) into the offline mirror
                                   under DIR, as the phone app does: the original file, the token in a header only
  downloads --store DIR [--remove ITEM_ID | --clear | --sync | --mirror]
                                   list what is downloaded for the profile (state, size, where); --mirror prints
                                   the offline library as the app would show it; --sync sends progress made
                                   offline; --remove / --clear delete downloads (here --store is the folder)
  api-check [--server URL]         compare the calls and fields we use with the server's live API spec
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `--name value` options and bare arguments, in order.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let flagNames: Set<String> = ["--json", "--probe", "--clear", "--meaning", "--quick", "--all", "--apply", "--force", "--prune", "--stats", "--no-credits", "--announce", "--cellular", "--sync", "--mirror", "--no-fallback"]

    init(_ raw: [String]) throws {
        var rest = raw[...]
        while let next = rest.popFirst() {
            if Self.flagNames.contains(next) {
                flags.insert(next)
            } else if next.hasPrefix("--") {
                guard let value = rest.popFirst(), !value.hasPrefix("--") else { throw CLIError("\(next) needs a value") }
                options[next] = value
            } else {
                positional.append(next)
            }
        }
    }
}

/// Files under ~/.config/matine/cli, owner-only.
struct FileStore: KeyValueStore, SecretStore, @unchecked Sendable {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Tighten an existing directory too, not only a new one.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func path(_ key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"))
    }

    func data(forKey key: String) -> Data? { try? Data(contentsOf: path(key)) }

    func set(_ data: Data?, forKey key: String) {
        if let data { try? write(data, for: key) } else { try? delete(key) }
    }

    func read(_ key: String) throws -> Data? { data(forKey: key) }

    func write(_ value: Data, for key: String) throws {
        let url = path(key)
        try value.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete(_ key: String) throws {
        let url = path(key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// The secrets only (tokens, PINs, attempt records); this one directory
    /// also holds the profile list, which stays.
    func removeAll() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
        where ["token.", "pin.", "pin-attempts."].contains(where: name.hasPrefix) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

let configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/matine")

func makeProfiles(store: String? = nil) throws -> Profiles {
    if store?.filter({ $0.isLetter || $0.isNumber || $0 == "-" }).isEmpty == true { throw CLIError("--store needs a name of letters, digits or dashes") }
    let folder = store.map { "cli-" + $0.filter { $0.isLetter || $0.isNumber || $0 == "-" } } ?? "cli"
    let files = try FileStore(directory: configDirectory.appendingPathComponent(folder))
    return Profiles(
        store: AccountStore(settings: files, secrets: files),
        pins: PinGate(secrets: files),
        deviceName: "matine CLI",
        version: "0.1.0"
    )
}

/// `--server` cleaned up like the app does (https assumed, /web/… dropped); else
/// `MATINE_SERVER`; else the server in the dev-account file. There is no built-in default.
func server(_ args: Arguments) throws -> URL {
    guard let typed = args.options["--server"] ?? ProcessInfo.processInfo.environment["MATINE_SERVER"] else {
        if let (devServer, _, _) = try? readDevAccount() { return devServer }
        throw CLIError("which server? pass --server URL or set MATINE_SERVER")
    }
    guard let url = Profiles.serverURL(from: typed) else { throw CLIError("--server must be an https:// or http:// address") }
    if !Profiles.isSecure(url) {
        FileHandle.standardError.write(Data("warning: \(url.absoluteString) is not encrypted; the password and token cross the network in the clear\n".utf8))
    }
    return url
}

func pickAccount(_ profiles: Profiles, _ args: Arguments) throws -> (Account, JellyfinClient) {
    let account = try pickProfile(profiles, args)
    guard let client = try profiles.client(for: account) else { throw CLIError("profile \(account.name) has no token; log in again") }
    return (account, client)
}

func pickProfile(_ profiles: Profiles, _ args: Arguments) throws -> Account {
    let accounts = profiles.store.accounts()
    let account: Account
    if let name = args.options["--profile"] {
        guard let match = accounts.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw CLIError("no profile named \(name); see `matine profiles`")
        }
        account = match
    } else {
        guard let first = accounts.first else { throw CLIError("no profiles; run `matine login` first") }
        account = first
    }
    return account
}

/// From the terminal without echo; from a pipe (scripts) as one line. The
/// MATINE_PASSWORD fallback is for scripts only: it sits in the environment.
func readPassword() throws -> String {
    if let env = ProcessInfo.processInfo.environment["MATINE_PASSWORD"], !env.isEmpty { return env }
    if isatty(STDIN_FILENO) == 1 {
        var buffer = [CChar](repeating: 0, count: 512)
        defer { buffer.withUnsafeMutableBufferPointer { _ = memset($0.baseAddress, 0, $0.count) } }
        guard readpassphrase("Contraseña: ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { throw CLIError("no password entered") }
        let password = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !password.isEmpty else { throw CLIError("no password entered") }
        return password
    }
    guard let line = readLine(strippingNewline: true), !line.isEmpty else { throw CLIError("no password on stdin or in MATINE_PASSWORD") }
    return line
}

func readDevAccount() throws -> (URL, String, String) {
    let file = configDirectory.appendingPathComponent("dev-account")
    if let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, mode & 0o077 != 0 {
        FileHandle.standardError.write(Data("matine: warning: \(file.path) is readable by others; chmod 600 it\n".utf8))
    }
    let text = try String(contentsOf: file, encoding: .utf8)
    var fields: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    guard let server = fields["server"].flatMap(URL.init(string:)), let user = fields["user"], let password = fields["password"] else {
        throw CLIError("dev-account needs server=, user= and password= lines")
    }
    return (server, user, password)
}

func downloadLine(_ entry: DownloadedItem) -> String {
    "\(entry.item.id)  \(entry.state.rawValue)  \(entry.method.rawValue)  \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))  \(entry.item.tileCaption(.default))"
}

func describe(_ item: Item, caption: String? = nil) -> String {
    var label = caption ?? item.tileCaption(.default)
    if item.kind != .episode || item.seriesName == nil, let year = item.productionYear {
        label += " (\(year))"
    }
    if let percent = item.progressPercent { label += " · \(Int(percent))%" }
    return "\(item.id)  \(label)"
}

func printCredits(_ item: Item) {
    let facts = [item.officialRating, item.ratingText, item.studios?.joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }
    if !facts.isEmpty { print("  " + facts.joined(separator: " · ")) }
    item.taglines?.first.map { print("  “\($0)”") }
    if !item.directors.isEmpty { print("  Dirección: " + item.directors.map(\.name).joined(separator: ", ")) }
    if !item.writers.isEmpty { print("  Guion: " + item.writers.map(\.name).joined(separator: ", ")) }
    for (label, people) in [("Reparto", item.cast), ("Estrellas invitadas", item.guestStars)] where !people.isEmpty {
        print("  \(label):")
        for person in people { print("    \(person.id)  \(person.name)" + (person.role.map { " — \($0)" } ?? "") + (person.image == nil ? "  (sin foto)" : "")) }
    }
}

func title(_ group: SearchResults.Group) -> String {
    switch group {
    case .movies: "Películas"
    case .series: "Series"
    case .episodes: "Episodios"
    case .videos: "Vídeos"
    case .related: "Relacionado"
    }
}

func title(_ row: HomeRow) -> String {
    switch row.kind {
    case .pinned: "Fijados"
    case .continueWatching: "Seguir viendo"
    case .latest(_, let name): "Novedades en \(name)"
    }
}

func gigabytes(_ bytes: Int64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1e9)
}

extension String {
    func leftPadded(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}

/// One file of `media-report --json`: what the converter needs to act on it.
struct MediaCheckJSON: Encodable {
    struct Stream: Encodable {
        let index: Int?
        let type: String
        let codec: String?
        let action: String
        let target: String?
    }

    let itemId, sourceId, title, verdict: String
    let path: String?
    let size: Int64?
    /// moov_first, moov_last, unknown, or nil when not read.
    let layout: String?
    let streams: [Stream]
    let notes: [String]

    init(_ check: MediaCheck) {
        itemId = check.file.itemId
        sourceId = check.file.sourceId
        title = check.file.title
        verdict = check.verdict.rawValue
        path = check.file.path
        size = check.file.size
        layout = check.layout.map {
            switch $0 {
            case .moovFirst: "moov_first"
            case .moovLast: "moov_last"
            case .unknown: "unknown"
            }
        }
        streams = check.streams.map {
            let (action, target) = $0.action.parts
            return Stream(index: $0.stream.index, type: $0.stream.type, codec: $0.stream.codec, action: action, target: target)
        }
        notes = check.notes
    }
}

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

struct RowJSON: Encodable {
    let id: String
    let title: String
    let items: [Item]
}

/// A JSON file standing in for the owner's iCloud: the members it holds, newest wins.
struct FileHouseholdCloud: HouseholdCloud {
    let url: URL

    private func load() -> [HouseholdMember] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([HouseholdMember].self, from: $0) } ?? []
    }

    func account() async -> KeywordCloudAccount { .available }
    func accountId() async -> String? { "file" }
    func fetchChanges() async throws -> HouseholdCloudChanges { HouseholdCloudChanges(saved: load()) }
    func save(members: [HouseholdMember], requests: [ApprovalRequest]) async throws -> Set<String> {
        var held = Dictionary(uniqueKeysWithValues: load().map { ($0.recordName, $0) })
        for member in members { held[member.recordName] = member }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(held.values.sorted { $0.recordName < $1.recordName })
        // Owner-only from the moment it exists: it holds PINs in clear.
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CLIError("can't write \(url.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        return Set(members.map(\.recordName))
    }
    func delete(requestIds: [String]) async throws {}
    func reset() async {}
}

struct HouseholdLine: Encodable {
    let record: String
    let userId: String
    let name: String
    let displayName: String
    let role: String
    let language: String
    let hasPin: Bool
    let hasToken: Bool
}

func household(_ profiles: Profiles, _ args: Arguments) async throws {
    if let path = args.options["--cloud"] {
        guard args.options["--store"] != nil else {
            throw CLIError("household --cloud writes PINs in clear to the file: use a scratch store (--store NAME)")
        }
        let sync = HouseholdSync(cloud: FileHouseholdCloud(url: URL(fileURLWithPath: path)), profiles: profiles)
        let report = await sync.sync()
        print("changed here: \(report.changed ? "yes" : "no") · removed: \(report.removed.map(\.name)) · held back: \(report.held)")
        if let why = report.unavailable { print("unavailable: \(why)") }
    }
    let lines = try profiles.store.accounts().map { account -> HouseholdLine in
        HouseholdLine(
            record: HouseholdRecordName.make(server: account.server, userId: account.id), userId: account.id, name: account.name,
            displayName: account.displayName ?? "", role: account.role.rawValue, language: account.language.rawValue,
            hasPin: try profiles.pins.hasPin(account.id), hasToken: try profiles.store.token(for: account.id) != nil
        )
    }
    if args.flags.contains("--json") {
        try printJSON(lines)
    } else {
        for line in lines {
            print("\(line.record) · \(line.name) · \(line.role) · \(line.language)\(line.hasPin ? " · PIN" : "")\(line.hasToken ? "" : " · needs sign-in")")
        }
    }
}

func run(_ raw: [String]) async throws {
    guard let command = raw.first else { print(usage); return }
    let args = try Arguments(Array(raw.dropFirst()))
    // `downloads --store DIR` names a folder, not a profile store.
    let profiles = try makeProfiles(store: command == "downloads" ? nil : args.options["--store"])

    switch command {
    case "login":
        guard let user = args.options["--user"] else { throw CLIError("login needs --user") }
        let account = try await profiles.signIn(server: try server(args), username: user, password: try readPassword())
        print("signed in as \(account.name) (\(account.id))")
    case "dev-login":
        let (server, user, password) = try readDevAccount()
        let account = try await profiles.signIn(server: server, username: user, password: password)
        print("signed in as \(account.name) (\(account.id))")
    case "info":
        let info = try await profiles.anonymousClient(server: try server(args)).publicInfo()
        print("\(info.serverName) · Jellyfin \(info.version)")
    case "profiles":
        for account in profiles.store.accounts() {
            let pin = try profiles.pins.hasPin(account.id) ? " · PIN" : ""
            print("\(account.name) · \(account.language.rawValue) · \(account.server.absoluteString)\(pin)")
        }
    case "home":
        let (account, client) = try pickAccount(profiles, args)
        let rows = try await HomeLoader(client: client, userId: account.id).load().rows
        if args.flags.contains("--json") {
            try printJSON(rows.map { RowJSON(id: $0.id, title: title($0), items: $0.items) })
        } else {
            for row in rows {
                print("== \(title(row)) (\(row.items.count))")
                row.items.forEach { print("  " + describe($0)) }
            }
        }
    case "topshelf":
        let (account, client) = try pickAccount(profiles, args)
        let rows = try await HomeLoader(client: client, userId: account.id).load().rows
        if (try? profiles.pins.hasPin(account.id)) != false {
            print("no shelf: this profile has a PIN")
        } else if let shelf = TopShelfSnapshot.make(account: account, client: client, rows: rows) {
            try printJSON(shelf)
        } else {
            print("no shelf: nothing to show")
        }
    case "libraries":
        let (account, client) = try pickAccount(profiles, args)
        for library in try await client.libraries(userId: account.id) {
            print("\(library.id)  \(library.name) · \(library.collectionType ?? "mixed")")
        }
    case "discover":
        guard let libraryId = args.positional.first else { throw CLIError("discover needs a LIBRARY_ID") }
        let (account, client) = try pickAccount(profiles, args)
        async let watching = client.resume(userId: account.id, libraryId: libraryId)
        async let random = client.shuffled(userId: account.id, libraryId: libraryId)
        print("Seguir viendo:")
        for item in try await watching { print("  \(item.id)  \(item.searchCaption)") }
        print("Al azar:")
        for item in try await random { print("  \(item.id)  \(item.searchCaption)") }
    case "library":
        guard let libraryId = args.positional.first else { throw CLIError("library needs a LIBRARY_ID; see `matine libraries`") }
        let (account, client) = try pickAccount(profiles, args)
        let sort: LibrarySort = args.options["--sort"] == "date" ? .dateAdded : .title
        let start = Int(args.options["--start"] ?? "0") ?? 0
        let page = try await client.libraryPage(userId: account.id, libraryId: libraryId, sort: sort, start: start, countTotal: true)
        page.items.forEach { print(describe($0)) }
        print("(\(start + page.items.count)\(page.total.map { " of \($0)" } ?? ""))")
    case "search":
        let text = args.positional.joined(separator: " ")
        guard !text.isEmpty else { throw CLIError("search needs TEXT") }
        let (account, client) = try pickAccount(profiles, args)
        let started = ContinuousClock.now
        let raw = try await client.catalogData(userId: account.id, credits: !args.flags.contains("--no-credits"))
        let catalog = try JellyfinClient.decodeCatalog(raw)
        if args.flags.contains("--stats") {
            print("catalog: \(catalog.count) titles, \(raw.count / 1024) KiB, \(ContinuousClock.now - started)")
        }
        var keywordStore: KeywordStore?
        if let file = args.options["--keywords"] { keywordStore = try KeywordStore(data: Data(contentsOf: URL(fileURLWithPath: file))) }
        let index = SearchIndex(items: catalog, keywords: keywordStore)
        var related: [Item] = []
        if args.flags.contains("--meaning") {
            guard let model = await ContextualVectors.make() else { throw CLIError("the on-device language model isn't available here") }
            let meaning = await MeaningIndex.build(items: catalog, model: model)
            related = try await meaning.related(to: model.vectors(for: text))
        }
        let results = index.search(text, related: related)
        if results.isEmpty { print("no results for “\(text)” in \(catalog.count) titles") }
        for section in results.sections {
            print("\(title(section.group)):")
            for item in section.items {
                // As the phone's tile: the name, then where it is from.
                let caption = item.displayName + (item.searchSubtitle(.default).map { " — \($0)" } ?? "")
                print("  " + describe(item, caption: caption) + (results.reasons[item.id].map { "   [\($0.text)]" } ?? ""))
            }
        }
    case "keywords":
        if let importPath = args.options["--import"] {
            guard let savePath = args.options["--save"] else { throw CLIError("--import needs --save FILE (the file to merge into)") }
            let target = URL(fileURLWithPath: savePath)
            var store = try (try? Data(contentsOf: target)).map { try KeywordStore(data: $0) } ?? KeywordStore()
            let before = store.count
            let held = store
            store.merge(try KeywordStore(data: Data(contentsOf: URL(fileURLWithPath: importPath))))
            // The same rule the app applies to its own, the private zone's and a shared zone's words
            // (a share has no CLI: CloudKit needs the app's entitlement): say who won.
            let took = store.entries.filter { held.entries[$0.key] != $0.value }.count
            print("took \(took) from \(importPath) (new or better), kept \(store.count - took) already in \(savePath)")
            try store.data().write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            print("merged \(importPath): \(before) -> \(store.count) in \(savePath)")
            break
        }
        let (account, client) = try pickAccount(profiles, args)
        let generator: any KeywordGenerator
        var fallback: (any KeywordGenerator)?
        switch args.options["--generator"] ?? "model" {
        case "model":
            let translation = TranslationKeywordGenerator()
            let useFallback = !args.flags.contains("--no-fallback")
            if let reason = ModelKeywordGenerator.unavailableReason {
                // No model here: translation alone does the run, if it can.
                guard useFallback else { throw CLIError(reason) }
                do { try await translation.checkAvailable() } catch { throw CLIError("\(reason); and the fallback: \(error)") }
                print("model unavailable (\(reason)); using translation")
                generator = translation
            } else {
                generator = ModelKeywordGenerator()
                if useFallback { fallback = translation }
            }
        case "translate": generator = TranslationKeywordGenerator()
        case let other: throw CLIError("--generator is model or translate, not \(other)")
        }
        do { try await generator.checkAvailable() } catch let error as KeywordsUnavailable { throw CLIError(error.description) }
        let catalog = try await client.catalog(userId: account.id, libraryId: args.options["--library"], credits: false)
        let file = args.options["--save"].map { URL(fileURLWithPath: $0) }
        var store = KeywordStore()
        if let file, let data = try? Data(contentsOf: file) { store = try KeywordStore(data: data) }
        let limit = try args.options["--limit"].map { text -> Int in
            guard let n = Int(text), n > 0 else { throw CLIError("--limit needs a positive number") }
            return n
        }
        func save(_ store: KeywordStore) {
            guard let file else { return }
            do {
                try store.data().write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { FileHandle.standardError.write(Data("matine: couldn't save \(file.path): \(error)\n".utf8)) }
        }
        let report: KeywordBuilder.Report
        do {
            report = try await KeywordBuilder(generator: generator, fallback: fallback).fill(&store, items: catalog, force: args.flags.contains("--force"), limit: limit, checkpointEvery: 10, checkpoint: save) { item, keywords in
                print("\(item.id)  \(item.displayName)\n    \(keywords.words.joined(separator: ", "))")
            }
        } catch let error as KeywordsUnavailable {
            throw CLIError(error.description)
        }
        print("\(report.generated) made (\(report.fellBack) by the fallback), \(report.failed.count) failed, \(store.count) in store (\(generator.identifier))")
        for failure in report.failed { print("  failed \(failure.id): \(failure.message)") }
        if let file {
            if KeywordBuilder.mayPrune(requested: args.flags.contains("--prune"), library: args.options["--library"], catalogCount: catalog.count) { store.prune(keeping: Set(catalog.map(\.id))) }
            save(store)
            print("saved \(file.path)")
        }
    case "next":
        guard let seriesId = args.positional.first else { throw CLIError("next needs a SERIES_ID") }
        let (account, client) = try pickAccount(profiles, args)
        if let episode = try await client.episodeToPlay(seriesId: seriesId, userId: account.id) {
            print(describe(episode))
        } else {
            print("no episodes")
        }
    case "seasons":
        guard let seriesId = args.positional.first else { throw CLIError("seasons needs a SERIES_ID") }
        let (account, client) = try pickAccount(profiles, args)
        for season in try await client.seasons(seriesId: seriesId, userId: account.id) {
            let unwatched = season.userData?.unplayedItemCount.map { " · \($0) sin ver" } ?? ""
            print("\(season.id)  \(season.seasonIndex.map { "T\($0)" } ?? "—") · \(season.name)\(unwatched)")
        }
    case "episodes":
        guard let seriesId = args.positional.first else { throw CLIError("episodes needs a SERIES_ID") }
        let (account, client) = try pickAccount(profiles, args)
        let seasons = try await client.seasons(seriesId: seriesId, userId: account.id)
        let wanted = try args.options["--season"].map { raw -> [Item] in
            guard let number = Int(raw), let season = seasons.first(where: { $0.seasonIndex == number }) else {
                throw CLIError("no season \(raw); see `matine seasons \(seriesId)`")
            }
            return [season]
        } ?? seasons
        for season in wanted {
            for episode in try await client.seasonEpisodes(seriesId: seriesId, seasonId: season.id, userId: account.id) {
                let state = episode.userData?.played == true ? "visto" : episode.progressPercent.map { "\(Int($0))%" } ?? ""
                print("\(episode.id)  \(episode.episodeTitle(.default))\(state.isEmpty ? "" : " · " + state)")
            }
        }
    case "playback":
        guard let itemId = args.positional.first else { throw CLIError("playback needs an ITEM_ID") }
        let (account, client) = try pickAccount(profiles, args)
        let plan = try await client.playbackPlan(itemId: itemId, userId: account.id)
        print("\(plan.method.rawValue) · source \(plan.mediaSourceId)")
        print(plan.url.absoluteString)
        if args.flags.contains("--probe") {
            var request = URLRequest(url: plan.url)
            client.streamHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            // The app's own session: no cache, same-origin redirects only.
            let (data, response) = try await URLSessionTransport.shared.fetch(request)
            let type = response?.value(forHTTPHeaderField: "Content-Type") ?? "?"
            print("probe: HTTP \(response?.statusCode ?? 0) · \(type) · \(data.count) bytes")
            if type.contains("mpegurl"), let text = String(data: data, encoding: .utf8) {
                // Jellyfin writes the caller's token into its playlists: never print it.
                Redaction.tokens(in: text).split(separator: "\n").prefix(8).forEach { print("  \($0)") }
            }
        }
    case "pins":
        let (account, client) = try pickAccount(profiles, args)
        try await client.pinned(userId: account.id).forEach { print(describe($0)) }
    case "pin", "unpin":
        guard let itemId = args.positional.first else { throw CLIError("\(command) needs an ITEM_ID") }
        let (account, client) = try pickAccount(profiles, args)
        try await client.setPinned(command == "pin", itemId: itemId, userId: account.id)
        print(command == "pin" ? "pinned \(itemId)" : "unpinned \(itemId)")
    case "item":
        guard let itemId = args.positional.first else { throw CLIError("item needs an ITEM_ID") }
        let (account, client) = try pickAccount(profiles, args)
        let item = try await client.item(itemId, userId: account.id)
        if args.flags.contains("--json") { try printJSON(item) } else { print(describe(item)); printCredits(item) }
    case "person":
        guard let personId = args.positional.first else { throw CLIError("person needs a PERSON_ID") }
        let (account, client) = try pickAccount(profiles, args)
        let found = try await client.personItems(personId: personId, userId: account.id)
        let titles = Item.grouped(byPerson: found)
        if titles.isEmpty { print("nothing in the library with \(personId)") }
        titles.forEach { print(describe($0)) }
    case "logout":
        // No token needed: a profile whose token is gone can still be removed.
        let account = try pickProfile(profiles, args)
        let rules = HouseRules(accounts: profiles.store.accounts(), hasPin: { (try? profiles.pins.hasPin($0)) ?? true })
        if let refusal = rules.refusal(removing: account) { throw CLIError("can't sign out \(account.name): \(refusal)") }
        try await profiles.signOut(account)
        print("signed out \(account.name)")
    case "quickconnect":
        switch args.positional.first {
        case "start":
            let session = try await profiles.startQuickConnect(server: try server(args))
            // The code only; the request's secret never leaves MatineKit.
            print("code: \(session.code)")
            print("approve it on a signed-in device; waiting up to 5 minutes...")
            fflush(stdout)
            let announcement = args.flags.contains("--announce") ? NearbyJoin(kind: .other, code: session.code) : nil
            let advertiser = announcement.map(NearbyAdvertiser.init)
            defer { advertiser?.stop() }
            // The CLI has its own profile store and no grown-up screen: it is a developer tool.
            let account = try await profiles.finishQuickConnect(session, policy: .newProfile(grownUpCleared: true)).account
            print("signed in as \(account.name) (\(account.id))")
        case "approve":
            guard args.positional.count == 2 else { throw CLIError("usage: matine quickconnect approve CODE [--profile NAME]") }
            let account = try pickProfile(profiles, args)
            try await profiles.approveQuickConnect(code: args.positional[1], as: account)
            print("approved \(args.positional[1]) as \(account.name)")
        default:
            throw CLIError("usage: matine quickconnect start | approve CODE")
        }
    case "nearby":
        let seconds = args.options["--seconds"].flatMap(Double.init) ?? 5
        let listing = Task { () -> [NearbyJoin] in
            var last: [NearbyJoin] = []
            for await joins in NearbyBrowser.joins() { last = joins }
            return last
        }
        try await Task.sleep(for: .seconds(seconds))
        listing.cancel()
        let joins = await listing.value
        if joins.isEmpty { print("nothing announced") }
        for join in joins { print("\(join.spacedCode)  \(join.kind.rawValue)") }
    case "media-report":
        let (account, client) = try pickAccount(profiles, args)
        let report = try await client.mediaReport(userId: account.id, libraryId: args.options["--library"], readLayout: !args.flags.contains("--quick"))
        if args.flags.contains("--json") {
            try printJSON(report.checks.map(MediaCheckJSON.init))
            break
        }
        let total = report.checks.reduce(Int64(0)) { $0 + ($1.file.size ?? 0) }
        print("\(report.checks.count) files · \(gigabytes(total))")
        for verdict in MediaVerdict.allCases {
            print("  \(verdict.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(report.count(verdict)).leftPadded(5)) · \(gigabytes(report.bytes(verdict)))")
        }
        for verdict in MediaVerdict.allCases.reversed() where report.count(verdict) > 0 && (verdict != .fine || args.flags.contains("--all")) {
            print("== \(verdict.rawValue) (\(report.count(verdict)))")
            for check in report.checks where check.verdict == verdict {
                print("  \(check.file.itemId)  \(check.file.title)" + (check.notes.isEmpty ? "" : " · " + check.notes.joined(separator: "; ")))
            }
        }
    case "convert-plan":
        var only: Set<MediaVerdict> = [.faststart, .remux, .reencode]
        if let raw = args.options["--only"] {
            guard let verdict = MediaVerdict(rawValue: raw), only.contains(verdict) else { throw CLIError("--only is faststart, remux or reencode") }
            only = [verdict]
        }
        let limit = try args.options["--limit"].map { raw -> Int in
            guard let n = Int(raw), n > 0 else { throw CLIError("--limit is a positive number") }
            return n
        }
        let (account, client) = try pickAccount(profiles, args)
        let report = try await client.mediaReport(userId: account.id, libraryId: args.options["--library"])
        let plan = ConversionPlan(checks: report.checks, only: only, limit: limit)
        func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
        if report.count(.unchecked) > 0 { note("matine: \(report.count(.unchecked)) file(s) are unchecked (layout not read); they are not in the plan") }
        note("matine: \(plan.steps.count) file(s) planned, \(plan.skipped.count) left alone, \(plan.steps.filter(\.isRename).count) renamed")
        note("matine: needs about \(gigabytes(plan.bytesNeeded)) free (sources x 1.1; originals stay beside the new files), plus a 20 GB reserve the script keeps")
        for skipped in plan.skipped { note("  left alone: \(skipped.check.file.title): \(skipped.reason)") }
        var command = "matine convert-plan"
        if let library = args.options["--library"] { command += " --library \(library)" }
        if let raw = args.options["--only"] { command += " --only \(raw)" }
        if let limit { command += " --limit \(limit)" }
        print(ConversionScript.render(plan, command: command), terminator: "")
    case "carry-over":
        let (account, client) = try pickAccount(profiles, args)
        if let file = args.options["--snapshot"] {
            let files = try await client.mediaFiles(userId: account.id, libraryId: args.options["--library"], withUserData: true)
            let snapshot = CarryOver.snapshot(files: files, profile: account.name)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            // Watch history: owner-only, also when the file already existed.
            let url = URL(fileURLWithPath: file)
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            print("\(account.name): \(snapshot.renamed) file(s) will be renamed, \(snapshot.entries.count) with state to carry → \(file)")
        } else if let file = args.options["--restore"] {
            let snapshot = try JSONDecoder().decode(CarryOverSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            if let owner = snapshot.profile, owner.lowercased() != account.name.lowercased() {
                throw CLIError("\(file) was taken for profile \(owner), not \(account.name); pass --profile \(owner)")
            }
            let files = try await client.mediaFiles(userId: account.id, libraryId: args.options["--library"], withUserData: true)
            let restore = CarryOver.restore(snapshot, files: files)
            for action in restore.actions { print("\(action.itemId)  \(action.title): \(action.summary)") }
            for entry in restore.missing { print("not found yet: \(entry.newPath)") }
            for entry in restore.unsafe { print("skipped (new path pre-existed or old file still listed): \(entry.newPath)") }
            print("\(restore.actions.count) write(s), \(restore.alreadyDone) already done, \(restore.missing.count) not found, \(restore.unsafe.count) skipped")
            if args.flags.contains("--apply") {
                try await client.apply(restore.actions, userId: account.id)
                print("applied")
            } else if !restore.actions.isEmpty {
                print("dry run: add --apply to write")
            }
        } else {
            throw CLIError("carry-over needs --snapshot FILE or --restore FILE")
        }
    case "listen":
        let (account, client) = try pickAccount(profiles, args)
        print("listening as \(account.name) on \(client.identity.deviceName); Ctrl-C to stop")
        setvbuf(stdout, nil, _IOLBF, 0)
        for await event in RemoteListener.events(client: client) {
            switch event {
            case .connected: print("connected")
            case .command(let command):
                print("command: \(command)")
                if command.playItemId != nil {
                    if let target = await client.remotePlayTarget(command, userId: account.id) {
                        print("  would play: \(describe(target.item)) from \(Int(Ticks.seconds(target.startTicks))) s")
                    } else {
                        print("  would not play: not found, not playable, or not visible to this profile")
                    }
                }
            case .disconnected(let final): print(final ? "refused (token rejected); not retrying" : "disconnected; reconnecting")
            }
        }
    case "sessions":
        let (account, client) = try pickAccount(profiles, args)
        for session in try await client.controllableSessions(userId: account.id) {
            print("\(session.id)  \(session.deviceName ?? "?") · \(session.client ?? "?") · \(session.userName ?? "?") · remote control: \(session.supportsRemoteControl ? "yes" : "no")")
        }
    case "tvs":
        let (account, client) = try pickAccount(profiles, args)
        for (index, tv) in try await client.tvs(userId: account.id).enumerated() {
            print("\(index + 1)  \(tv.name)  \(tv.id)\(tv.isPlaying ? "  (playing)" : "")")
        }
    case "play-on":
        guard args.positional.count >= 2, let number = Int(args.positional[0]) else { throw CLIError("play-on needs N ITEM_ID (N from `matine tvs`)") }
        let (account, client) = try pickAccount(profiles, args)
        let tvs = try await client.tvs(userId: account.id)
        guard tvs.indices.contains(number - 1) else { throw CLIError("no TV number \(number); `matine tvs` lists \(tvs.count)") }
        let start = Double(args.options["--start"] ?? "0") ?? 0
        try await client.sendPlay(sessionId: tvs[number - 1].id, itemId: args.positional[1], startTicks: Ticks.from(seconds: start))
        print("asked \(tvs[number - 1].name) to play")
    case "send-play":
        guard args.positional.count >= 2 else { throw CLIError("send-play needs SESSION_ID ITEM_ID") }
        let (_, client) = try pickAccount(profiles, args)
        let start = Double(args.options["--start"] ?? "0") ?? 0
        try await client.sendPlay(sessionId: args.positional[0], itemId: args.positional[1], startTicks: Ticks.from(seconds: start))
        print("asked \(args.positional[0]) to play")
    case "send":
        guard args.positional.count >= 2 else { throw CLIError("send needs SESSION_ID pause|unpause|stop|playpause|seek SECONDS") }
        let (_, client) = try pickAccount(profiles, args)
        let sessionId = args.positional[0]
        switch args.positional[1] {
        case "pause": try await client.sendPlaystate(sessionId: sessionId, .pause)
        case "unpause": try await client.sendPlaystate(sessionId: sessionId, .unpause)
        case "stop": try await client.sendPlaystate(sessionId: sessionId, .stop)
        case "playpause": try await client.sendPlaystate(sessionId: sessionId, .playPause)
        case "seek":
            guard args.positional.count >= 3, let seconds = Double(args.positional[2]) else { throw CLIError("seek needs SECONDS") }
            try await client.sendPlaystate(sessionId: sessionId, .seek, seekTicks: Ticks.from(seconds: seconds))
        default: throw CLIError("send takes pause, unpause, stop, playpause or seek SECONDS")
        }
        print("sent \(args.positional[1])")
    case "download":
        guard let dir = args.options["--to"] else { throw CLIError("download needs --to DIR") }
        let (account, client) = try pickAccount(profiles, args)
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        let engine = URLSessionDownloadEngine.foreground(destination: Downloader.destination(root: root))
        let downloader = Downloader(root: root, engine: engine, onUpdate: { update in
            if let fraction = update.fraction, update.state == .downloading, Int(fraction * 100) % 10 == 0 {
                FileHandle.standardError.write(Data("\(update.itemId) \(Int(fraction * 100))%\n".utf8))
            }
        })
        await downloader.start()
        if args.flags.contains("--cellular") { await downloader.setAllowsCellular(true) }
        // A run that was interrupted left entries marked downloading with no transfer: pick them up again.
        await downloader.resumeAll(client: client, userId: account.id)
        if let season = args.options["--season"] {
            guard let series = args.options["--series"] else { throw CLIError("--season needs --series") }
            try await downloader.enqueueSeason(seriesId: series, seasonId: season, client: client, userId: account.id)
        } else {
            guard let itemId = args.positional.first else { throw CLIError("download needs an ITEM_ID") }
            try await downloader.enqueue(itemId: itemId, client: client, userId: account.id)
        }
        let store = downloader.store(for: account.id)
        // Stop when nothing is marked downloading, or when no transfer is left to finish it.
        // (Twice in a row, so a transfer that just ended has time to be recorded.)
        var idle = 0
        while store.entries().contains(where: { $0.state == .downloading }), idle < 2 {
            idle = (await engine.activeKeys()).isEmpty ? idle + 1 : 0
            try await Task.sleep(for: .milliseconds(300))
        }
        FileHandle.standardError.write(Data("\n".utf8))
        for entry in store.entries() { print(downloadLine(entry)) }
        if store.entries().contains(where: { $0.state == .failed }) { throw CLIError("a download failed") }
    case "downloads":
        guard let dir = args.options["--store"] else { throw CLIError("downloads needs --store DIR") }
        let account = try pickProfile(profiles, args)
        let store = DownloadStore(root: URL(fileURLWithPath: dir, isDirectory: true), userId: account.id)
        if args.flags.contains("--clear") { store.removeAll() }
        if let id = args.options["--remove"] { store.remove(id) }
        let queue = ProgressQueue(store: store)
        if args.flags.contains("--sync") {
            guard let client = try profiles.client(for: account) else { throw CLIError("profile \(account.name) has no token; log in again") }
            print("sent \(try await DownloadSync.run(store: store, queue: queue, client: client)) progress update(s)")
        }
        if args.flags.contains("--mirror") {
            let source = LocalLibrarySource(store: store, queue: queue)
            for library in try await source.libraries() {
                print("\(library.name) (\(library.id))")
                for item in try await source.libraryPage(libraryId: library.id, sort: .title, start: 0, limit: 500, countTotal: false).items {
                    print("  \(describe(item))")
                    if item.kind == .series {
                        for season in try await source.seasons(seriesId: item.id) {
                            print("    \(season.name)")
                            for episode in try await source.episodes(seriesId: item.id, seasonId: season.id) { print("      \(describe(episode))") }
                        }
                    }
                }
            }
        } else {
            for entry in store.entries() { print(downloadLine(entry)) }
        }
        print("\(ByteCountFormatter.string(fromByteCount: store.bytesUsed(), countStyle: .file)) on disk · \(queue.pending.count) progress update(s) waiting")
    case "api-check":
        let server = try server(args)
        let spec = try await profiles.anonymousClient(server: server).openAPISpec()
        let problems = try APIManifest.problems(in: spec)
        if problems.isEmpty {
            print("ok: all \(APIManifest.calls.count) calls and their fields exist on \(server.host ?? "the server")")
        } else {
            problems.forEach { print($0) }
            exit(1)
        }
    case "robot":
        let color = try args.options["--color"].map { name in
            guard let color = ProfileColor(rawValue: name) else {
                throw CLIError("no color \(name); one of \(ProfileColor.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return color
        }
        if let raw = args.positional.first {
            guard let seed = UInt64(raw) else { throw CLIError("SEED is a whole number") }
            print(Robot(seed: seed, background: color ?? .ocean).svg(background: color ?? .ocean), terminator: "")
        } else {
            // A sheet: six across, each seed printed under its robot.
            var body: [String] = []
            for index in 0..<24 {
                let seed = UInt64.random(in: 0...UInt64.max)
                let background = color ?? ProfileColor.allCases[index % ProfileColor.allCases.count]
                let (x, y) = (Double(index % 6) * 120 + 10, Double(index / 6) * 130 + 10)
                body.append(Robot(seed: seed, background: background).svgGroup(background: background, transform: "translate(\(x) \(y))"))
                body.append("<text x=\"\(x + 50)\" y=\"\(y + 116)\" font-size=\"7\" text-anchor=\"middle\" font-family=\"Menlo\">\(seed)</text>")
            }
            print("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 720 520\" width=\"1440\" height=\"1040\">\n<rect width=\"720\" height=\"520\" fill=\"#fff\"/>\n" + body.joined(separator: "\n") + "\n</svg>")
        }
    case "look":
        var account = try pickProfile(profiles, args)
        var changed = false
        if let name = args.options["--set-name"] { account.displayName = Profiles.cleanDisplayName(name); changed = true }
        if let raw = args.options["--set-role"] {
            guard let role = ProfileRole(rawValue: raw) else { throw CLIError("--set-role is adult or kid") }
            let rules = HouseRules(accounts: profiles.store.accounts(), hasPin: { (try? profiles.pins.hasPin($0)) ?? true })
            if let refusal = rules.refusal(changing: account, to: role) { throw CLIError(refusal.description) }
            account.role = role
            changed = true
        }
        if let raw = args.options["--set-color"] {
            guard let color = ProfileColor(rawValue: raw) else { throw CLIError("no color \(raw)") }
            account.avatar.color = color
            changed = true
        }
        if let raw = args.options["--set-robot"] {
            guard let seed = UInt64(raw) else { throw CLIError("--set-robot takes a whole number") }
            account.avatar.figure = .robot(seed: seed)
            changed = true
        }
        if let raw = args.options["--set-animal"] {
            guard let animal = ProfileAnimal.allCases.first(where: { "\($0)" == raw }) else {
                throw CLIError("no animal \(raw); one of \(ProfileAnimal.allCases.map { "\($0)" }.joined(separator: ", "))")
            }
            account.avatar.figure = .animal(animal)
            changed = true
        }
        if changed { try profiles.store.update(account) }
        let figure = switch account.avatar.figure {
        case .robot(let seed): "robot \(seed)"
        case .animal(let animal): "\(animal)"
        }
        print("\(account.shownName) (\(account.name)) · \(account.role.rawValue) · \(figure) on \(account.avatar.color.rawValue)")
    case "recent":
        let account = try pickProfile(profiles, args)
        let recent = profiles.store.recentSearches(for: account.id)
        if args.flags.contains("--clear") { recent.clear() }
        recent.list().forEach { print($0) }
    case "household":
        try await household(profiles, args)
    case "help", "-h", "--help":
        print(usage)
    default:
        throw CLIError("unknown command \(command)\n\n\(usage)")
    }
}

// Owner-only for every file this process creates, with no window between
// create and chmod.
umask(0o077)
do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("matine: \(error)\n".utf8))
    exit(1)
}
