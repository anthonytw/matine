import Foundation
import Testing
@testable import MatineKit

/// Runs the generated script under dash against small synthetic files, with a
/// `docker` shim that runs the local ffmpeg/ffprobe (`/media` mapped to a temp
/// folder). Skipped where there is no ffmpeg.
private let ffmpegDirectory = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first {
    FileManager.default.isExecutableFile(atPath: $0 + "/ffmpeg") && FileManager.default.isExecutableFile(atPath: $0 + "/ffprobe")
}
private let shell = FileManager.default.isExecutableFile(atPath: "/bin/dash") ? "/bin/dash" : "/bin/sh"

private final class Lab {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("matine-lab-\(UUID().uuidString)")
    var media: URL { root.appendingPathComponent("media") }
    var shims: URL { root.appendingPathComponent("shims") }
    var folder: URL { media.appendingPathComponent("Pel i's") }
    var script: URL { root.appendingPathComponent("plan.sh") }
    let streams = [
        MediaStreamInfo(index: 0, type: "Video", codec: "h264", codecTag: "avc1", bitDepth: 8, pixelFormat: "yuv420p"),
        MediaStreamInfo(index: 1, type: "Audio", codec: "aac", channels: 2),
    ]

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: shims, withIntermediateDirectories: true)
        let docker = """
        #!/bin/sh
        case $1 in ps|kill) exit 0 ;; esac
        shift
        tool=
        while [ $# -gt 0 ]; do case $1 in --entrypoint) tool=$2; shift 2; break ;; *) shift ;; esac; done
        shift
        n=$#
        while [ $n -gt 0 ]; do a=$1; shift; set -- "$@" "$(printf %s "$a" | sed "s#^/media#$MEDIA_HOST#")"; n=$((n - 1)); done
        exec \(ffmpegDirectory!)/$(basename "$tool") "$@"
        """
        try write(docker, to: shims.appendingPathComponent("docker"), executable: true)
        // The NAS has GNU coreutils; macOS's chown and chmod have no --reference.
        for (tool, path, format) in [("chown", "/usr/sbin/chown", "%u:%g"), ("chmod", "/bin/chmod", "%Lp")] {
            let shim = """
            #!/bin/sh
            case $1 in --reference=*) ref=${1#--reference=}; shift; exec \(path) "$(stat -f '\(format)' "$ref")" "$@" ;; esac
            exec \(path) "$@"
            """
            try write(shim, to: shims.appendingPathComponent(tool), executable: true)
        }
        try make()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    func ffmpeg(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegDirectory! + "/ffmpeg")
        process.arguments = ["-nostdin", "-loglevel", "error", "-y"] + args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// `a b.mp4` (moov last) and `c'd.mkv` (+ a subrip track).
    func make() throws {
        try write("1\n00:00:00,000 --> 00:00:01,000\nhola\n", to: root.appendingPathComponent("s.srt"))
        let video = ["-f", "lavfi", "-i", "testsrc=d=2:s=160x120:r=10", "-f", "lavfi", "-i", "sine=d=2"]
        try ffmpeg(video + ["-c:v", "libx264", "-c:a", "aac", "-shortest", folder.appendingPathComponent("a b.mp4").path])
        try ffmpeg(video + ["-i", root.appendingPathComponent("s.srt").path, "-map", "0", "-map", "1", "-map", "2",
                            "-c:v", "libx264", "-c:a", "aac", "-c:s", "srt", "-shortest", folder.appendingPathComponent("c'd.mkv").path])
    }

    var checks: [MediaCheck] {
        let sub = MediaStreamInfo(index: 2, type: "Subtitle", codec: "subrip")
        return [
            MediaCheck(file: MediaFile(itemId: "1", sourceId: "1", title: "t", container: "mov,mp4,m4a", path: "/media/Pel i's/a b.mp4", streams: streams), layout: .moovLast),
            MediaCheck(file: MediaFile(itemId: "2", sourceId: "2", title: "t", container: "matroska,webm", path: "/media/Pel i's/c'd.mkv", streams: streams + [sub]), layout: nil),
        ]
    }

    func render() throws { try write(ConversionScript.render(ConversionPlan(checks: checks)), to: script) }

    /// Everything under the media folder, hidden entries too, as relative paths.
    func listing() -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: media.path)
        return (enumerator?.allObjects as? [String] ?? []).sorted()
    }

    func run(_ arguments: [String] = [], env: [String: String] = [:], extraPath: String? = nil, script scriptOverride: URL? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [(scriptOverride ?? script).path] + arguments
        var environment = ["PATH": (extraPath.map { $0 + ":" } ?? "") + shims.path + ":/usr/bin:/bin", "MEDIA_HOST": media.path, "HOME": root.path]
        environment.merge(env) { $1 }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

@Suite(.serialized) struct ConversionLabTests {
    static let original = ["Pel i's", "Pel i's/a b.mp4", "Pel i's/c'd.mkv"]

    @Test func convertUndoConvertUndoLeavesExactlyTheOriginals() throws {
        let lab = try Lab()
        try lab.render()
        let before = try Data(contentsOf: lab.folder.appendingPathComponent("c'd.mkv"))
        let first = try lab.run(env: ["DRY_RUN": "0"])
        #expect(first.status == 0, "\(first.output)")
        #expect(lab.listing().contains("Pel i's/c'd.mp4"))
        #expect(lab.listing().contains("Pel i's/.matine-originals/c'd.mkv"))
        #expect(lab.listing().contains("Pel i's/.matine-convert.tsv") == false)
        #expect(lab.listing().contains(".matine-convert.tsv"))
        #expect(!lab.listing().contains(".matine-lock"))

        let undo1 = try lab.run(["undo"], env: ["DRY_RUN": "0"])
        #expect(undo1.status == 0, "\(undo1.output)")
        #expect(undo1.output.contains("restored: /media/Pel i's/c'd.mkv"))
        let second = try lab.run(env: ["DRY_RUN": "0"])
        #expect(second.status == 0, "\(second.output)")
        #expect(!second.output.contains("skip"), "\(second.output)")
        let undo2 = try lab.run(["undo"], env: ["DRY_RUN": "0"])
        #expect(undo2.status == 0, "\(undo2.output)")
        #expect(!undo2.output.contains("FAILED") && !undo2.output.contains("refusing"), "\(undo2.output)")

        let visible = lab.listing().filter { !$0.contains("/.matine-") && !$0.hasPrefix(".matine") }
        #expect(visible == Self.original)
        #expect(try Data(contentsOf: lab.folder.appendingPathComponent("c'd.mkv")) == before)
        #expect(lab.listing().filter { $0.hasPrefix("Pel i's/.matine-originals/") }.isEmpty)
        // Two undos, two timestamped folders, each holding both converted files.
        let converted = lab.listing().filter { $0.hasPrefix("Pel i's/.matine-converted/") && $0.hasSuffix(".mp4") }
        #expect(converted.count == 4, "\(converted)")
        // The log: an intent and a done per swap, twice.
        let log = try String(contentsOf: lab.media.appendingPathComponent(".matine-convert.tsv"), encoding: .utf8)
        #expect(log.split(separator: "\n").map { $0.split(separator: "\t").first.map(String.init) } == ["intent", "done", "intent", "done", "intent", "done", "intent", "done"])
    }

    @Test func undoWorksFromTheScriptWhenTheLogIsGone() throws {
        let lab = try Lab()
        try lab.render()
        #expect(try lab.run(env: ["DRY_RUN": "0"]).status == 0)
        try FileManager.default.removeItem(at: lab.media.appendingPathComponent(".matine-convert.tsv"))
        let undo = try lab.run(["undo"], env: ["DRY_RUN": "0"])
        #expect(undo.status == 0 && undo.output.contains("no log"), "\(undo.output)")
        #expect(lab.listing().filter { !$0.contains("/.matine-") && !$0.hasPrefix(".matine") } == Self.original)
    }

    @Test func theConvertedFileTakesTheOriginalsMode() throws {
        let lab = try Lab()
        try lab.render()
        let original = lab.folder.appendingPathComponent("a b.mp4").path
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: original)
        let result = try lab.run(env: ["DRY_RUN": "0"])
        #expect(result.status == 0, "\(result.output)")
        let mode = try FileManager.default.attributesOfItem(atPath: original)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }

    @Test func aSecondRunSkipsWhatIsDone() throws {
        let lab = try Lab()
        try lab.render()
        _ = try lab.run(env: ["DRY_RUN": "0"])
        let again = try lab.run(env: ["DRY_RUN": "0"])
        #expect(again.status == 0)
        #expect(again.output.contains("skip"))
    }

    @Test func onlyTheLiteralZeroActs() throws {
        let lab = try Lab()
        try lab.render()
        let before = lab.listing()
        for value in ["yes", "1", "", "false", "00", "o"] {
            let result = try lab.run(env: ["DRY_RUN": value])
            #expect(result.status == 0, "\(result.output)")
            #expect(result.output.contains("DRY RUN"), "DRY_RUN=\(value): \(result.output)")
            #expect(lab.listing() == before, "DRY_RUN=\(value) changed something")
        }
        let unset = try lab.run()
        #expect(unset.output.contains("DRY RUN") && lab.listing() == before)
        // Undo is dry too.
        let undo = try lab.run(["undo"], env: ["DRY_RUN": "yes"])
        #expect(undo.status == 0 && lab.listing() == before)
    }

    @Test func aBadModeIsAUsageError() throws {
        let lab = try Lab()
        try lab.render()
        for arguments in [["bogus"], ["RUN"], ["run", "extra"], ["--undo"]] {
            let result = try lab.run(arguments, env: ["DRY_RUN": "0"])
            #expect(result.status == 2 && result.output.contains("usage"), "\(arguments): \(result.output)")
        }
        #expect(lab.listing() == ["Pel i's", "Pel i's/a b.mp4", "Pel i's/c'd.mkv"])
    }

    @Test func tooLittleDiskStopsTheWholeRunBeforeAnyFfmpeg() throws {
        let lab = try Lab()
        try lab.render()
        let fakeBin = lab.root.appendingPathComponent("fakebin")
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try lab.write("#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted on'\necho '/dev/x 1000 1 500 1% /'\n",
                      to: fakeBin.appendingPathComponent("df"), executable: true)
        let before = lab.listing()
        let result = try lab.run(env: ["DRY_RUN": "0"], extraPath: fakeBin.path)
        #expect(result.status == 3, "\(result.output)")
        #expect(result.output.contains("STOP"))
        #expect(!result.output.contains("[2/2]"), "the second file must not be tried: \(result.output)")
        #expect(lab.listing() == before)
        // The lock is released on the way out.
        #expect(!lab.listing().contains(".matine-lock"))
        // A small reserve passes the same check for these tiny files.
        let ok = try lab.run(env: ["DRY_RUN": "0", "RESERVE_GB": "0"])
        #expect(ok.status == 0, "\(ok.output)")
    }

    @Test func aRunHoldsALock() throws {
        let lab = try Lab()
        try lab.render()
        try FileManager.default.createDirectory(at: lab.media.appendingPathComponent(".matine-lock"), withIntermediateDirectories: false)
        let result = try lab.run(env: ["DRY_RUN": "0"])
        #expect(result.status == 1 && result.output.contains("another run"), "\(result.output)")
    }

    @Test func theConvertedFileKeepsItsStreamsAndHasItsIndexFirst() throws {
        let lab = try Lab()
        try lab.render()
        #expect(try lab.run(env: ["DRY_RUN": "0"]).status == 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegDirectory! + "/ffprobe")
        process.arguments = ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", lab.folder.appendingPathComponent("c'd.mp4").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(text.split(separator: "\n").map(String.init) == ["h264", "aac", "mov_text"])
    }
}

// Same suite as above, so everything that starts ffmpeg runs one test at a time.
extension ConversionLabTests {
    /// Real compact output of ffprobe for a Dolby Vision MP4 (a dvcC box injected), and for the same file
    /// copied without -strict (the box is gone).
    static let withDV = "stream|index=0|codec_type=video|side_datum/dovi_configuration_record:side_data_type=DOVI configuration record\nstream|index=1|codec_type=audio\nformat|duration=2.000000\n"
    static let withoutDV = "stream|index=0|codec_type=video\nstream|index=1|codec_type=audio\nformat|duration=2.000000\n"

    /// Runs the script's own has_dovi on text.
    func hasDovi(_ probe: String) throws -> Bool {
        let script = ConversionScript.render(ConversionPlan(checks: []))
        let start = try #require(script.range(of: "has_dovi() {"))
        let end = try #require(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
        let function = String(script[start.lowerBound..<end.upperBound])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("matine-dovi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("t.sh")
        try (function + "has_dovi \"$1\"\n").write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [file.path, probe]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test func theDolbyVisionCheckReadsFfprobesRealCompactOutput() throws {
        #expect(try hasDovi(Self.withDV))
        #expect(try !hasDovi(Self.withoutDV))
        // Side data on its own line (another ffprobe layout) counts too, but only on the first video stream.
        #expect(try hasDovi("stream|index=0|codec_type=video\nside_data|side_data_type=DOVI configuration record\n"))
        #expect(try !hasDovi("stream|index=0|codec_type=audio|side_data_type=DOVI x\nstream|index=1|codec_type=video\n"))
    }

    @Test(.enabled(if: ffmpegDirectory != nil)) func everyOutputGetsTheStrictFlagAndTheDolbyVisionCheck() throws {
        let lab = try Lab()
        let plan = ConversionPlan(checks: lab.checks)
        #expect(plan.steps.count == 2)
        #expect(plan.steps.allSatisfy { $0.doviCheck == "same" && $0.arguments.contains("-strict") })
        #expect(ConversionScript.render(plan).contains("verify /media/Pel\\ i's") == false)
    }

    @Test(.enabled(if: ffmpegDirectory != nil)) func undoCoversOnlyItsOwnScriptEvenWithASharedLog() throws {
        let lab = try Lab()
        let planA = lab.root.appendingPathComponent("a.sh"), planB = lab.root.appendingPathComponent("b.sh")
        try lab.write(ConversionScript.render(ConversionPlan(checks: [lab.checks[0]])), to: planA)
        try lab.write(ConversionScript.render(ConversionPlan(checks: [lab.checks[1]])), to: planB)
        #expect(try lab.run(env: ["DRY_RUN": "0"], script: planA).status == 0)
        #expect(try lab.run(env: ["DRY_RUN": "0"], script: planB).status == 0)
        let undo = try lab.run(["undo"], env: ["DRY_RUN": "0"], script: planB)
        #expect(undo.status == 0, "\(undo.output)")
        #expect(undo.output.contains("restored: /media/Pel i's/c'd.mkv") && !undo.output.contains("a b.mp4"), "\(undo.output)")
        let listing = lab.listing()
        #expect(listing.contains("Pel i's/c'd.mkv") && !listing.contains("Pel i's/c'd.mp4"))
        // Plan A's file is still converted: its original is still aside.
        #expect(listing.contains("Pel i's/.matine-originals/a b.mp4"))
    }

    @Test(.enabled(if: ffmpegDirectory != nil)) func aHangupLeavesNoLockAndTheLockNamesItsPid() throws {
        let lab = try Lab()
        try lab.render()
        let slow = lab.root.appendingPathComponent("slow")
        try FileManager.default.createDirectory(at: slow, withIntermediateDirectories: true)
        try lab.write("#!/bin/sh\ncase $1 in ps|kill) exit 0 ;; esac\nsleep 2\n", to: slow.appendingPathComponent("docker"), executable: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [lab.script.path]
        process.environment = ["PATH": slow.path + ":/usr/bin:/bin", "MEDIA_HOST": lab.media.path, "DRY_RUN": "0", "RESERVE_GB": "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let lock = lab.media.appendingPathComponent(".matine-lock")
        var waited = 0
        while !FileManager.default.fileExists(atPath: lock.appendingPathComponent("pid").path), waited < 100 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 1
        }
        let pid = try String(contentsOf: lock.appendingPathComponent("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pid == String(process.processIdentifier))
        // A second run is refused, and says whose lock it is.
        let second = try lab.run(env: ["DRY_RUN": "0"])
        #expect(second.status == 1 && second.output.contains("pid \(pid)"), "\(second.output)")
        kill(process.processIdentifier, SIGHUP)
        process.waitUntilExit()
        #expect(process.terminationStatus == 129)
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test(.enabled(if: ffmpegDirectory != nil)) func badSettingsAreRefusedBeforeAnythingRuns() throws {
        let lab = try Lab()
        try lab.render()
        let before = lab.listing()
        for (key, value, word) in [("RESERVE_GB", "20 GB", "whole number"), ("RESERVE_GB", "", "whole number"), ("MEDIA_HOST", lab.media.path + ",x", "comma")] {
            let result = try lab.run(env: ["DRY_RUN": "0", key: value])
            #expect(result.status == 2 && result.output.contains(word), "\(key)=\(value): \(result.output)")
        }
        #expect(lab.listing() == before)
    }

    @Test func theHeaderSaysHowToCheckAStaleLockAndWhatUndoCovers() {
        let script = ConversionScript.render(ConversionPlan(checks: []))
        for text in ["tmux or screen", "kill -0 PID", "docker ps --filter label=matine-convert", "only THIS script's files", "trap 'exit 129' HUP", "--label \"matine-convert=$$\""] {
            #expect(script.contains(text), "\(text)")
        }
    }
}
