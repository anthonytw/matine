import Foundation
import Testing
@testable import MatineKit

private func stream(_ index: Int, _ type: String, _ codec: String, tag: String? = nil, profile: String? = nil, bits: Int? = 8,
                    pixel: String? = "yuv420p", range: String? = nil, channels: Int? = nil, language: String? = nil, width: Int? = 1920) -> MediaStreamInfo {
    MediaStreamInfo(index: index, type: type, codec: codec, codecTag: tag, profile: profile, bitDepth: bits, pixelFormat: pixel, width: width,
                    videoRangeType: range, channels: channels, language: language)
}

private func check(_ path: String?, _ container: String, _ streams: [MediaStreamInfo], layout: MP4Layout? = nil,
                   userData: UserData? = nil, id: String = "i") -> MediaCheck {
    MediaCheck(file: MediaFile(itemId: id, sourceId: "s-" + id, title: "Title " + id, container: container, path: path, streams: streams, userData: userData), layout: layout)
}

private let basic = [stream(0, "Video", "h264", tag: "avc1", profile: "High"), stream(1, "Audio", "aac", channels: 2)]

@Suite struct ConversionPlanTests {
    @Test func faststartCopiesEverythingAndMovesTheIndex() throws {
        let plan = ConversionPlan(checks: [check("/media/Movies/A.mp4", "mov,mp4,m4a", basic, layout: .moovLast)])
        let step = try #require(plan.steps.first)
        #expect(step.kind == .faststart)
        #expect(step.outputPath == "/media/Movies/A.mp4")
        #expect(!step.isRename)
        #expect(step.tempPath == "/media/Movies/.matine-part.A.mp4")
        #expect(step.originalPath == "/media/Movies/.matine-originals/A.mp4")
        #expect(step.arguments == [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-i", "/media/Movies/A.mp4",
            "-map", "0", "-c", "copy", "-copy_unknown", "-map_metadata", "0", "-strict", "unofficial", "-movflags", "+faststart", "-f", "mp4",
            "/media/Movies/.matine-part.A.mp4",
        ])
        #expect(step.expected == nil)
    }

    @Test func aMovFileStaysAMov() throws {
        let step = try #require(ConversionPlan(checks: [check("/media/x/A.MOV", "mov,mp4,m4a", basic, layout: .moovLast)]).steps.first)
        #expect(step.format == "mov")
        #expect(step.arguments.suffix(3) == ["-f", "mov", "/media/x/.matine-part.A.MOV"])
    }

    @Test func remuxMapsEachStreamAndCarriesTextSubtitlesAsMovText() throws {
        let streams = basic + [stream(2, "Audio", "ac3", channels: 6), stream(3, "Subtitle", "subrip", language: "spa"),
                               stream(4, "Subtitle", "ass", language: "eng")]
        let step = try #require(ConversionPlan(checks: [check("/media/Movies/B.mkv", "matroska,webm", streams)]).steps.first)
        #expect(step.kind == .remux)
        #expect(step.outputPath == "/media/Movies/B.mp4")
        #expect(step.isRename)
        #expect(step.tempPath == "/media/Movies/.matine-part.B.mp4")
        #expect(step.originalPath == "/media/Movies/.matine-originals/B.mkv")
        #expect(step.arguments == [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-i", "/media/Movies/B.mkv",
            "-map", "0:0", "-map", "0:1", "-map", "0:2", "-map", "0:3", "-map", "0:4",
            "-c:v:0", "copy", "-c:a:0", "copy", "-c:a:1", "copy", "-c:s:0", "mov_text", "-c:s:1", "mov_text",
            "-strict", "unofficial", "-map_metadata", "0", "-map_chapters", "0", "-movflags", "+faststart", "-f", "mp4", "/media/Movies/.matine-part.B.mp4",
        ])
        #expect(step.expected == .init(video: 1, audio: 2, subtitle: 2))
    }

    @Test func hevcWithTheWrongTagIsRetagged() throws {
        let streams = [stream(0, "Video", "hevc", tag: "hev1", profile: "Main 10", bits: 10), stream(1, "Audio", "aac")]
        let step = try #require(ConversionPlan(checks: [check("/media/M/C.mp4", "mov,mp4,m4a", streams, layout: .moovFirst)]).steps.first)
        #expect(step.kind == .remux)
        #expect(!step.isRename)
        #expect(step.arguments.contains("-tag:v:0"))
        #expect(Array(step.arguments[step.arguments.firstIndex(of: "-c:v:0")!...].prefix(4)) == ["-c:v:0", "copy", "-tag:v:0", "hvc1"])
    }

    @Test func dolbyVisionProfile8GetsItsOwnTag() throws {
        let streams = [stream(0, "Video", "hevc", tag: "hev1", profile: "Main 10", bits: 10, range: "DOVIWithHDR10"), stream(1, "Audio", "aac")]
        let step = try #require(ConversionPlan(checks: [check("/media/M/D.mkv", "matroska,webm", streams)]).steps.first)
        #expect(step.arguments.contains("dvh1"))
    }

    @Test func dolbyVisionProfile7IsLeftAloneWithANote() {
        let streams = [stream(0, "Video", "hevc", tag: "hev1", profile: "Main 10", bits: 10, range: "DOVIWithEL"), stream(1, "Audio", "aac")]
        let plan = ConversionPlan(checks: [check("/media/M/E.mkv", "matroska,webm", streams)])
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.first?.reason.contains("profile 7") == true)
    }

    @Test func reencodeTouchesOnlyTheStreamThatCannotPlay() throws {
        let streams = [
            stream(0, "Video", "h264", tag: "avc1", profile: "High"),
            stream(1, "Audio", "aac", channels: 2),
            stream(2, "Audio", "dts", profile: "DTS", channels: 6),
            stream(3, "Audio", "truehd", channels: 8),
            stream(4, "Audio", "dts", profile: "DTS-HD MA", channels: 2),
            stream(5, "Audio", "wmapro", channels: 8),
            stream(6, "Audio", "vorbis", channels: 1),
        ]
        let step = try #require(ConversionPlan(checks: [check("/media/M/F.mkv", "matroska,webm", streams)]).steps.first)
        #expect(step.kind == .reencode)
        let a = step.arguments
        #expect(a.contains("-c:v:0") && a[a.firstIndex(of: "-c:v:0")! + 1] == "copy")
        func pair(_ key: String) -> String { a[a.firstIndex(of: key)! + 1] }
        #expect(pair("-c:a:0") == "copy")
        #expect(pair("-c:a:1") == "eac3" && pair("-b:a:1") == "640k")
        #expect(pair("-c:a:2") == "flac")
        #expect(pair("-c:a:3") == "flac")
        #expect(pair("-c:a:4") == "aac" && pair("-b:a:4") == "512k")
        #expect(pair("-c:a:5") == "aac" && pair("-b:a:5") == "96k")
        // FLAC in MP4 is experimental before ffmpeg 4.4.
        #expect(Array(a.suffix(10).prefix(2)) == ["-strict", "experimental"] || a.contains("experimental"))
    }

    @Test func aStreamEncodeWithoutFlacNeedsNoStrictFlag() throws {
        let streams = basic + [stream(2, "Audio", "ac3-weird", channels: 2)]
        let step = try #require(ConversionPlan(checks: [check("/media/M/G.mp4", "mov,mp4,m4a", streams, layout: .moovFirst)]).steps.first)
        #expect(!step.arguments.contains("experimental"))
    }

    @Test func videoEncodesPickTheTargetAndBitDepth() throws {
        let hevc = [stream(0, "Video", "hevc", tag: "hvc1", profile: "Main 4:4:4 12", bits: 12, pixel: "yuv444p12le", range: "SDR"), stream(1, "Audio", "aac")]
        let a = try #require(ConversionPlan(checks: [check("/media/M/H.mkv", "matroska,webm", hevc)]).steps.first).arguments
        #expect(a[a.firstIndex(of: "-c:v:0")! + 1] == "libx265")
        #expect(a[a.firstIndex(of: "-pix_fmt:v:0")! + 1] == "yuv420p10le")
        let old = [stream(0, "Video", "mpeg4", bits: 8, range: "SDR"), stream(1, "Audio", "aac")]
        let b = try #require(ConversionPlan(checks: [check("/media/M/I.avi", "avi", old)]).steps.first)
        #expect(b.outputPath == "/media/M/I.mp4")
        #expect(b.arguments[b.arguments.firstIndex(of: "-c:v:0")! + 1] == "libx264")
        #expect(b.arguments[b.arguments.firstIndex(of: "-pix_fmt:v:0")! + 1] == "yuv420p")
    }

    @Test func hdrThatWouldBeReencodedIsLeftAlone() {
        let streams = [stream(0, "Video", "vp9", bits: 10, range: "HDR10"), stream(1, "Audio", "aac")]
        let plan = ConversionPlan(checks: [check("/media/M/J.mkv", "matroska,webm", streams)])
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.first?.reason.contains("HDR") == true)
    }

    @Test func pgsSubtitlesBecomeSupSidecars() throws {
        let streams = basic + [stream(2, "Subtitle", "hdmv_pgs_subtitle", language: "spa"), stream(3, "Subtitle", "hdmv_pgs_subtitle", language: "spa"),
                               stream(4, "Subtitle", "hdmv_pgs_subtitle")]
        let step = try #require(ConversionPlan(checks: [check("/media/M/K.mkv", "matroska,webm", streams)]).steps.first)
        #expect(step.sidecars.map(\.path) == ["/media/M/K.spa.sup", "/media/M/K.spa.2.sup", "/media/M/K.und.sup"])
        #expect(step.sidecars[0].tempPath == "/media/M/.matine-part.K.spa.sup")
        #expect(step.sidecars[0].arguments == [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-i", "/media/M/K.mkv", "-map", "0:2", "-c", "copy", "-f", "sup", "/media/M/.matine-part.K.spa.sup",
        ])
        #expect(!step.arguments.contains("0:2"))
        #expect(step.expected == .init(video: 1, audio: 1, subtitle: 0))
    }

    @Test func pictureSubtitlesThatCannotBeExtractedKeepTheOriginal() {
        let streams = basic + [stream(2, "Subtitle", "dvd_subtitle")]
        let plan = ConversionPlan(checks: [check("/media/M/L.mkv", "matroska,webm", streams)])
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.first?.reason.contains("original kept") == true)
    }

    @Test func coverArtAndFontsAreDroppedFromARemux() throws {
        let streams = basic + [stream(2, "EmbeddedImage", "mjpeg"), stream(3, "Data", "ttf")]
        let step = try #require(ConversionPlan(checks: [check("/media/M/N.mkv", "matroska,webm", streams)]).steps.first)
        #expect(step.arguments.filter { $0 == "-map" }.count == 2)
        #expect(step.expected == .init(video: 1, audio: 1, subtitle: 0))
    }

    @Test func orderingOnlyAndLimit() {
        let checks = [
            check("/media/b.mkv", "matroska,webm", basic, id: "1"),
            check("/media/a.mp4", "mov,mp4,m4a", basic, layout: .moovLast, id: "2"),
            check("/media/c.mp4", "mov,mp4,m4a", basic, layout: .moovLast, id: "3"),
            check("/media/d.mp4", "mov,mp4,m4a", basic, layout: .moovFirst, id: "4"),
        ]
        #expect(ConversionPlan(checks: checks).steps.map(\.sourcePath) == ["/media/a.mp4", "/media/c.mp4", "/media/b.mkv"])
        #expect(ConversionPlan(checks: checks, limit: 2).steps.map(\.sourcePath) == ["/media/a.mp4", "/media/c.mp4"])
        #expect(ConversionPlan(checks: checks, only: [.remux]).steps.map(\.sourcePath) == ["/media/b.mkv"])
    }

    @Test func unsafeOrForeignPathsAreSkippedWithAReason() {
        let checks = [
            check(nil, "matroska,webm", basic, id: "1"),
            check("/elsewhere/x.mkv", "matroska,webm", basic, id: "2"),
            check("/media/tab\there.mkv", "matroska,webm", basic, id: "3"),
            check("/media/" + String(repeating: "x", count: 250) + ".mkv", "matroska,webm", basic, id: "4"),
        ]
        let plan = ConversionPlan(checks: checks)
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.count == 4)
    }

    @Test func quotingSurvivesNastyPaths() {
        #expect(ShellQuote.quote("plain/path-1.mp4") == "plain/path-1.mp4")
        #expect(ShellQuote.quote("it's a $(rm -rf) `x`; \"y\" é.mp4") == "'it'\\''s a $(rm -rf) `x`; \"y\" é.mp4'")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("a b") == "'a b'")
    }
}

@Suite struct ConversionScriptTests {
    static let nasty = "/media/Películas/It's \"a\" $HOME `x`; (2019)/Pel\u{00ED}cula & más.mkv"

    func render(_ checks: [MediaCheck]) -> String { ConversionScript.render(ConversionPlan(checks: checks)) }

    @Test func theScriptIsADryRunByDefaultAndStopsOnErrors() {
        let script = render([check("/media/a.mp4", "mov,mp4,m4a", basic, layout: .moovLast)])
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("\nset -eu\n"))
        #expect(script.contains("DRY_RUN=${DRY_RUN:-1}"))
        #expect(script.contains("--entrypoint /usr/lib/jellyfin-ffmpeg/ffmpeg"))
        #expect(script.contains("--entrypoint /usr/lib/jellyfin-ffmpeg/ffprobe"))
        #expect(script.contains("--user \"$RUN_AS\""))
        #expect(script.contains("RUN_AS=${RUN_AS:-1000:1000}"))
        #expect(script.contains("MEDIA_HOST=${MEDIA_HOST:-/srv/media}"))
        #expect(script.contains("IMAGE=${IMAGE:-jellyfin/jellyfin:12.4@sha256:"))
        #expect(script.contains("sh plan.sh undo"))
        // Only the literal 0 acts; a bad mode is a usage error.
        #expect(script.contains("is_dry() { [ \"$DRY_RUN\" != 0 ]; }"))
        #expect(!script.contains("[ \"$DRY_RUN\" = 1 ]"))
        #expect(script.contains("case $MODE in run|undo) ;; *) usage ;; esac"))
        #expect(script.contains("LOG=${LOG:-$MEDIA_HOST/.matine-convert.tsv}"))
        #expect(script.contains("--mount \"type=bind,src=$MEDIA_HOST,dst=/media\""))
        #expect(!script.contains(" -v \""))
        #expect(script.contains("@sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771"))
        #expect(script.contains("mkdir \"$LOCK\""))
        #expect(script.contains("need_space \"$HS\" \"${HT%/*}\""))
        #expect(script.contains("# Disk: about"))
        #expect(script.contains("'MATINE_STEPS'\n/media/a.mp4\t/media/a.mp4\tfaststart\nMATINE_STEPS"))
    }

    @Test func eachFileBlockWritesATempVerifiesAndSwapsWithoutDeleting() {
        let script = render([check("/media/a.mp4", "mov,mp4,m4a", basic, layout: .moovLast)])
        #expect(script.contains("convert_1() {"))
        #expect(script.contains("begin faststart /media/a.mp4 /media/a.mp4 /media/.matine-part.a.mp4 /media/.matine-originals/a.mp4 || return 0"))
        #expect(script.contains("act ffm -hide_banner -nostdin -loglevel error -i /media/a.mp4 -map 0 -c copy -copy_unknown"))
        #expect(script.contains("verify /media/.matine-part.a.mp4 \"$REF\" same same same"))
        #expect(script.contains("move \"$HS\" \"$HO\""))
        #expect(script.contains("move \"$HT\" \"$HD\""))
        #expect(!script.contains("act mv -n"))
        #expect(script.contains("record intent \"$S\" \"$D\" \"$KIND\""))
        #expect(script.contains("record done \"$S\" \"$D\" \"$KIND\""))
        // Nothing in the script removes an original: the only rm is of its own temp files.
        for line in script.split(separator: "\n") where line.contains(" rm ") && !line.hasPrefix("#") && !line.contains("docker run") && !line.contains("LOCK") && !line.contains("rm -f \"$1\"") && !line.contains("rm -f \"$HT\"") && !line.contains("rm -f \"$(host") {
            Issue.record("unexpected rm: \(line)")
        }
        #expect(script.contains("convert_1 || FAILS=$((FAILS + 1))"))
    }

    @Test func nastyPathsAreQuotedAndNeverBreakOutOfTheirQuotes() {
        let script = render([check(Self.nasty, "matroska,webm", basic)])
        let quoted = ShellQuote.quote(Self.nasty)
        #expect(quoted.hasPrefix("'") && quoted.contains("'\\''"))
        #expect(script.contains("-i \(quoted)"))
        #expect(script.contains("begin remux \(quoted) "))
        // What the shell makes of the quoted text is the exact original, whatever it holds.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(quoted)"]
        let out = Pipe()
        process.standardOutput = out
        try? process.run()
        process.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == Self.nasty)
    }

    @Test func aRemuxWithSidecarsExtractsFromTheReferenceAndPlacesThemAfterTheSwap() {
        let streams = basic + [stream(2, "Subtitle", "hdmv_pgs_subtitle", language: "spa")]
        let script = render([check("/media/M/K.mkv", "matroska,webm", streams)])
        #expect(script.contains("-i \"$REF\" -map 0:2 -c copy -f sup /media/M/.matine-part.K.spa.sup"))
        let extract = script.range(of: "-f sup")!.lowerBound
        let swap = script.range(of: "  swap || {")!.lowerBound
        let place = script.range(of: "sidecar_place \"$(host /media/M/.matine-part.K.spa.sup)\"")!.lowerBound
        #expect(extract < swap && swap < place)
    }

    @Test func theNewFileTakesTheOriginalsOwnerGroupAndModeBeforeTheSwap() {
        let script = render([check("/media/a.mp4", "mov,mp4,m4a", basic, layout: .moovLast)])
        let swap = script.range(of: "\nswap() {")!.lowerBound
        let body = String(script[swap...])
        let chown = body.range(of: "act chown --reference=\"$(host \"$REF\")\" \"$HT\" || return 1")!.lowerBound
        let chmod = body.range(of: "act chmod --reference=\"$(host \"$REF\")\" \"$HT\" || return 1")!.lowerBound
        let move = body.range(of: "move \"$HS\" \"$HO\"")!.lowerBound
        #expect(chown < chmod && chmod < move)
        #expect(!script.contains("chown 1000:1000"))
    }

    @Test func theHeaderListsRenamesAndSkips() {
        let dv = [stream(0, "Video", "hevc", profile: "Main 10", bits: 10, range: "DOVIWithEL"), stream(1, "Audio", "aac")]
        let script = render([check("/media/x.mkv", "matroska,webm", basic, id: "1"), check("/media/y.mkv", "matroska,webm", dv, id: "2")])
        #expect(script.contains("# 1 file(s): 0 faststart, 1 remux, 0 reencode"))
        #expect(script.contains("NEW item"))
        #expect(script.contains("# left alone: /media/y.mkv: Dolby Vision profile 7"))
    }

    @Test func aScriptLineNeverCarriesAControlCharacterFromATitle() {
        let script = render([check("/media/ok.mkv", "matroska,webm", basic)])
        #expect(!script.contains("\r"))
    }

    /// The generated script runs under /bin/sh: parse every rendering with `sh -n`.
    @Test func theRenderedScriptParses() throws {
        let streams = basic + [stream(2, "Subtitle", "hdmv_pgs_subtitle", language: "spa"), stream(3, "Subtitle", "subrip")]
        let script = render([
            check(Self.nasty, "matroska,webm", streams, id: "1"),
            check("/media/a b/c.mp4", "mov,mp4,m4a", basic, layout: .moovLast, id: "2"),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("matine-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plan.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", file.path]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
    }
}

@Suite struct CarryOverTests {
    static let data = UserData(played: false, isFavorite: true, playbackPositionTicks: 600_000_000)

    @Test func theSnapshotKeepsOnlyRenamedFilesWithState() {
        let files = [
            check("/media/a.mkv", "matroska,webm", basic, userData: Self.data, id: "1").file,
            check("/media/b.mkv", "matroska,webm", basic, userData: UserData(played: true), id: "2").file,
            check("/media/c.mkv", "matroska,webm", basic, userData: UserData(played: false), id: "3").file,
            // Same path after conversion: nothing to carry.
            check("/media/d.mp4", "mov,mp4,m4a", basic, layout: .moovLast, userData: Self.data, id: "4").file,
        ]
        let snapshot = CarryOver.snapshot(files: files, profile: "kids")
        #expect(snapshot.profile == "kids")
        #expect(snapshot.renamed == 3)
        #expect(snapshot.entries.map(\.oldPath) == ["/media/a.mkv", "/media/b.mkv"])
        #expect(snapshot.entries[0].newPath == "/media/a.mp4")
        #expect(snapshot.entries[0].positionTicks == 600_000_000 && snapshot.entries[0].favorite && !snapshot.entries[0].played)
        #expect(snapshot.entries[1].played)
        let decoded = try? JSONDecoder().decode(CarryOverSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    func snapshot() -> CarryOverSnapshot {
        CarryOverSnapshot(profile: nil, renamed: 3, entries: [
            .init(oldPath: "/media/a.mkv", newPath: "/media/a.mp4", title: "A", played: false, positionTicks: 600_000_000, favorite: true, newPathExisted: false),
            .init(oldPath: "/media/b.mkv", newPath: "/media/b.mp4", title: "B", played: true, positionTicks: 5, favorite: false, newPathExisted: false),
            .init(oldPath: "/media/c.mkv", newPath: "/media/c.mp4", title: "C", played: true, positionTicks: 0, favorite: false, newPathExisted: false),
        ])
    }

    @Test func restoreMatchesByNewPathAndOnlyAddsWhatIsMissing() {
        let files = [
            check("/media/a.mp4", "mov,mp4,m4a", basic, layout: .moovFirst, userData: UserData(played: false), id: "NA").file,
            check("/media/b.mp4", "mov,mp4,m4a", basic, layout: .moovFirst, userData: UserData(played: false), id: "NB").file,
            // Old item still listed (rescan not done for it): not matched by its old path.
            check("/media/c.mkv", "matroska,webm", basic, id: "OC").file,
        ]
        let result = CarryOver.restore(snapshot(), files: files)
        #expect(result.actions == [
            CarryOverAction(itemId: "NA", title: "A", kind: .position(ticks: 600_000_000)),
            CarryOverAction(itemId: "NA", title: "A", kind: .favorite),
            CarryOverAction(itemId: "NB", title: "B", kind: .played),
        ])
        #expect(result.missing.isEmpty)
        #expect(result.unsafe.map(\.newPath) == ["/media/c.mp4"])
        #expect(result.alreadyDone == 0)
    }

    @Test func restoreNeverOverwritesNewerState() {
        let files = [
            check("/media/a.mp4", "mov,mp4,m4a", basic, layout: .moovFirst, userData: UserData(played: false, isFavorite: true, playbackPositionTicks: 99), id: "NA").file,
            check("/media/b.mp4", "mov,mp4,m4a", basic, layout: .moovFirst, userData: UserData(played: true), id: "NB").file,
            check("/media/c.mp4", "mov,mp4,m4a", basic, layout: .moovFirst, userData: UserData(played: true), id: "NC").file,
        ]
        let result = CarryOver.restore(snapshot(), files: files)
        #expect(result.actions.isEmpty)
        #expect(result.alreadyDone == 3)
    }

    @Test func applySendsOnlyPerUserCallsWithTheTokenInAHeader() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/UserItems/NA/UserData")
        transport.on("POST", "/UserFavoriteItems/NA")
        transport.on("POST", "/UserPlayedItems/NB")
        let client = makeClient(transport)
        try await client.apply([
            CarryOverAction(itemId: "NA", title: "A", kind: .position(ticks: 600_000_000)),
            CarryOverAction(itemId: "NA", title: "A", kind: .favorite),
            CarryOverAction(itemId: "NB", title: "B", kind: .played),
        ], userId: "u1")
        let sent = transport.requests
        #expect(sent.map { "\($0.httpMethod!) \($0.url!.path)" } == ["POST /UserItems/NA/UserData", "POST /UserFavoriteItems/NA", "POST /UserPlayedItems/NB"])
        for request in sent {
            #expect(request.query("userId") == "u1")
            #expect(!request.url!.absoluteString.contains("tok-123"))
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("tok-123") == true)
        }
        let body = try #require(sent[0].httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"PlaybackPositionTicks":600000000}"#)
        #expect(sent[1].httpBody == nil && sent[2].httpBody == nil)
    }

    @Test func filesReadWithUserDataCarryItAndAskTheServerForIt() async throws {
        let transport = FakeTransport()
        let page = """
        {"Items":[{"Id":"X1","Name":"Synthetic","Type":"Movie","UserData":{"Played":true,"IsFavorite":true,"PlaybackPositionTicks":0},
        "MediaSources":[{"Id":"S1","Container":"mp4","Path":"/media/s/x.mp4","MediaStreams":[]}]}],"TotalRecordCount":1}
        """
        transport.on("GET", "/Items", body: page)
        transport.singlePage = ["/Items"]
        let files = try await makeClient(transport).mediaFiles(userId: "u", withUserData: true)
        #expect(files.first?.userData?.played == true && files.first?.userData?.isFavorite == true)
        #expect(transport.requests.first?.query("enableUserData") == "true")
    }
}

@Suite struct ConversionSafetyPlanTests {
    @Test func aDolbyVisionRetagGetsItsBoxOrAStrictFlagThatCoversBoth() throws {
        let dv = [stream(0, "Video", "hevc", tag: "hev1", profile: "Main 10", bits: 10, range: "DOVIWithHDR10"), stream(1, "Audio", "aac")]
        let step = try #require(ConversionPlan(checks: [check("/media/M/D.mkv", "matroska,webm", dv)]).steps.first)
        #expect(step.doviCheck == "1")
        #expect(step.arguments.filter { $0 == "-strict" }.count == 1)
        #expect(step.arguments[step.arguments.firstIndex(of: "-strict")! + 1] == "unofficial")
        #expect(step.notes.contains { $0.contains("check the first real DV file") })
        // FLAC needs "experimental", which is looser than "unofficial": one -strict value, the looser.
        let both = dv + [stream(2, "Audio", "truehd", channels: 8)]
        let step2 = try #require(ConversionPlan(checks: [check("/media/M/D2.mkv", "matroska,webm", both)]).steps.first)
        #expect(step2.arguments.filter { $0 == "-strict" }.count == 1)
        #expect(step2.arguments[step2.arguments.firstIndex(of: "-strict")! + 1] == "experimental")
        #expect(step2.doviCheck == "1")
    }

    @Test func aFaststartOfADolbyVisionFileKeepsItsBoxToo() throws {
        let dv = [stream(0, "Video", "hevc", tag: "dvh1", profile: "Main 10", bits: 10, range: "DOVIWithHDR10"), stream(1, "Audio", "aac")]
        let step = try #require(ConversionPlan(checks: [check("/media/M/F.mp4", "mov,mp4,m4a", dv, layout: .moovLast)]).steps.first)
        #expect(step.arguments.contains("unofficial"))
        #expect(step.doviCheck == "same")
        let plain = try #require(ConversionPlan(checks: [check("/media/M/G.mp4", "mov,mp4,m4a", basic, layout: .moovLast)]).steps.first)
        #expect(plain.arguments.contains("unofficial") && plain.doviCheck == "same")
    }

    @Test func aMissingRangeIsNotTreatedAsSDRForAReencode() {
        let streams = [stream(0, "Video", "mpeg4", bits: 8), stream(1, "Audio", "aac")]
        let plan = ConversionPlan(checks: [check("/media/M/H.avi", "avi", streams)])
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.first?.reason.contains("can't tell whether the video is HDR") == true)
    }

    @Test func filesThatWouldBecomeTheSameNameAreAllLeftAlone() {
        let checks = [
            check("/media/M/X.avi", "avi", [stream(0, "Video", "h264", tag: "avc1"), stream(1, "Audio", "aac")], id: "1"),
            check("/media/M/X.mkv", "matroska,webm", basic, id: "2"),
            check("/media/M/x.MKV", "matroska,webm", basic, id: "3"),
            check("/media/M/Y.mkv", "matroska,webm", basic, id: "4"),
        ]
        let plan = ConversionPlan(checks: checks)
        #expect(plan.steps.map(\.sourcePath) == ["/media/M/Y.mkv"])
        #expect(plan.skipped.count == 3)
        #expect(plan.skipped.allSatisfy { $0.reason.contains("same name") })
    }

    @Test func aNameThatAlreadyExistsInTheLibraryIsRefusedWhateverTheCase() {
        let checks = [
            check("/media/M/Z.mkv", "matroska,webm", basic, id: "1"),
            check("/media/M/z.MP4", "mov,mp4,m4a", basic, layout: .moovFirst, id: "2"),
        ]
        let plan = ConversionPlan(checks: checks)
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.first?.reason.contains("already exists in the library") == true)
    }

    @Test func limitCountsOnlyWhatIsPlanned() {
        let checks = (1...5).map { check("/media/M/f\($0).mkv", "matroska,webm", basic, id: "\($0)") }
        #expect(ConversionPlan(checks: checks, limit: 3).steps.count == 3)
    }

    @Test func aTooLongSidecarNameIsRefused() {
        let long = String(repeating: "y", count: 235)
        let streams = basic + [stream(2, "Subtitle", "hdmv_pgs_subtitle", language: "spa")]
        let plan = ConversionPlan(checks: [check("/media/M/" + long + ".mkv", "matroska,webm", streams)])
        #expect(plan.steps.isEmpty)
    }

    @Test func theDiskEstimateIsTheSourcesPlusTenPercent() {
        var file = check("/media/M/a.mp4", "mov,mp4,m4a", basic, layout: .moovLast, id: "1").file
        file.size = 1_000_000
        let plan = ConversionPlan(checks: [MediaCheck(file: file, layout: .moovLast)])
        #expect(plan.bytesNeeded == 1_100_000)
    }

    @Test func restoreSkipsEntriesItDoesNotOwn() {
        let entry = CarryOverSnapshot.Entry(oldPath: "/media/a.mkv", newPath: "/media/a.mp4", title: "A", played: true, positionTicks: 0, favorite: false, newPathExisted: true)
        let other = CarryOverSnapshot.Entry(oldPath: "/media/b.mkv", newPath: "/media/b.mp4", title: "B", played: true, positionTicks: 0, favorite: false, newPathExisted: false)
        let files = [
            check("/media/a.mp4", "mov,mp4,m4a", basic, layout: .moovFirst, id: "NA").file,
            check("/media/b.mp4", "mov,mp4,m4a", basic, layout: .moovFirst, id: "NB").file,
            // the old file is still listed
            check("/media/b.mkv", "matroska,webm", basic, id: "OB").file,
        ]
        let result = CarryOver.restore(CarryOverSnapshot(profile: nil, renamed: 2, entries: [entry, other]), files: files)
        #expect(result.actions.isEmpty)
        #expect(result.unsafe.count == 2)
    }

    @Test func theSnapshotRecordsAPreExistingNewPath() {
        // Not reachable through the plan (it refuses such renames), but a library listing can change between runs.
        let files = [check("/media/a.mkv", "matroska,webm", basic, userData: UserData(played: true), id: "1").file]
        #expect(CarryOver.snapshot(files: files, profile: nil).entries.first?.newPathExisted == false)
    }
}

@Suite struct ConversionPathTests {
    @Test func aPathThatWalksOutOfTheMediaTreeIsRefused() {
        let streams = [stream(0, "Video", "h264"), stream(1, "Audio", "aac")]
        for path in ["/media/../appdata/x.mkv", "/media/M/../../x.mkv", "/media/./x.mkv", "/media//x.mkv", "/media/M/x.mkv/"] {
            let plan = ConversionPlan(checks: [check(path, "matroska,webm", streams)])
            #expect(plan.steps.isEmpty, "\(path)")
            #expect(plan.skipped.count == 1, "\(path)")
        }
        #expect(ConversionPlan(checks: [check("/media/M/..x/a..b.mkv", "matroska,webm", streams)]).steps.count == 1)
    }
}
