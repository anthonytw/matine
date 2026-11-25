import Foundation

/// One picture-subtitle track (PGS) that can't live in an MP4 but can sit
/// beside it as a `.sup` file, which Jellyfin picks up as an external subtitle.
public struct SubtitleSidecar: Sendable, Hashable {
    public var streamIndex: Int
    /// Where it ends up, next to the converted file.
    public var path: String
    /// Where ffmpeg writes it first (a dot-name, ignored by Jellyfin's scanner).
    public var tempPath: String
    public var arguments: [String]
}

/// What happens to one file: the ffmpeg run, how the result is checked, and
/// the swap. Paths are as Jellyfin reports them, which is also where the
/// one-off container sees them (the same mount point), so they appear in the
/// ffmpeg arguments exactly as they are.
public struct ConversionStep: Sendable, Hashable {
    public var check: MediaCheck
    /// `faststart`, `remux` or `reencode`.
    public var kind: MediaVerdict
    public var sourcePath: String
    public var outputPath: String
    /// A dot-name beside the output (the scanner ignores it, so a half-written
    /// file is never imported).
    public var tempPath: String
    /// Where the original is moved to, never deleted: `.matine-originals/` beside it.
    public var originalPath: String
    public var arguments: [String]
    public var sidecars: [SubtitleSidecar]
    /// Streams the result must have. `nil` means "as many as the original has"
    /// (a faststart rewrite copies everything).
    public var expected: StreamCounts?
    /// ffmpeg's muxer: `mp4`, or `mov` for a `.mov` file.
    public var format: String
    public var notes: [String]
    /// The source's size in bytes, for the disk-space estimate.
    public var sizeBytes: Int64?
    /// What the result must show for Dolby Vision: `"0"` nothing to check,
    /// `"1"` a DOVI configuration record on the first video stream (a `dvh1`
    /// retag), `"same"` whatever the original shows.
    public var doviCheck: String

    public struct StreamCounts: Sendable, Hashable {
        public var video: Int
        public var audio: Int
        public var subtitle: Int
    }

    /// A different path means Jellyfin sees a new item after the rescan
    /// (no watched state, progress or favorite): carry-over restores them.
    public var isRename: Bool { sourcePath != outputPath }

    /// The ffmpeg command as it would be typed (arguments quoted for sh).
    public var command: String { (["ffmpeg"] + arguments).map(ShellQuote.quote).joined(separator: " ") }
}

/// A file the converter leaves alone, and why.
public struct SkippedFile: Sendable, Hashable {
    public var check: MediaCheck
    public var reason: String
}

/// Turns a report's verdicts into per-file conversion steps. Pure: nothing is
/// read or written here; `ConversionScript` renders the steps for the NAS.
///
/// Rules, from the owner: never re-encode what already plays; the original
/// is moved aside, never deleted; and a file whose conversion would lose
/// something that can't be kept is left alone, with the reason said.
public struct ConversionPlan: Sendable {
    public var steps: [ConversionStep]
    public var skipped: [SkippedFile]

    /// Disk the run needs at most: every source's size plus 10 % (originals stay
    /// beside the new files until the owner removes them). The script also keeps a reserve free.
    public var bytesNeeded: Int64 { steps.reduce(0) { $0 + ($1.sizeBytes ?? 0) / 10 * 11 } }

    /// The directory (inside the container and on the host) all media lives under.
    public static let defaultMediaRoot = "/media"
    public static let originalsFolder = ".matine-originals"
    static let tempPrefix = ".matine-part."
    /// Longest file name most file systems take, in bytes.
    static let maxNameBytes = 255

    /// - Parameters:
    ///   - only: the verdicts to act on (default: all three that need work).
    ///   - limit: at most this many steps (after ordering: faststart, remux, reencode).
    public init(checks: [MediaCheck], only: Set<MediaVerdict> = [.faststart, .remux, .reencode], limit: Int? = nil,
                mediaRoot: String = ConversionPlan.defaultMediaRoot) {
        var candidates: [ConversionStep] = []
        var skipped: [SkippedFile] = []
        var seen: Set<String> = []
        // Every path the library has (any verdict), case-folded: a new name must not land on one.
        let existing = Set(checks.compactMap { $0.file.path?.lowercased() })
        let order: [MediaVerdict] = [.faststart, .remux, .reencode]
        let wanted = checks.filter { only.contains($0.verdict) && order.contains($0.verdict) }.sorted {
            let (a, b) = (order.firstIndex(of: $0.verdict)!, order.firstIndex(of: $1.verdict)!)
            return a != b ? a < b : ($0.file.path ?? "", $0.file.title) < ($1.file.path ?? "", $1.file.title)
        }
        for check in wanted {
            switch Self.step(for: check, mediaRoot: mediaRoot) {
            case .success(let step):
                // Two sources of one item, or one file listed twice: convert it once.
                if seen.insert(step.sourcePath).inserted { candidates.append(step) }
            case .failure(let refusal):
                skipped.append(SkippedFile(check: check, reason: refusal.text))
            }
        }
        // Two files that would become the same name (X.avi and X.mkv to X.mp4), or a file
        // that would land on one the library has, are left alone: all of them.
        var outputs: [String: Int] = [:]
        for step in candidates { outputs[step.outputPath.lowercased(), default: 0] += 1 }
        var steps: [ConversionStep] = []
        for step in candidates {
            let folded = step.outputPath.lowercased()
            if step.isRename, outputs[folded, default: 0] > 1 {
                skipped.append(SkippedFile(check: step.check, reason: "another file would become the same name (\(step.outputPath))"))
            } else if step.isRename, existing.contains(folded) {
                skipped.append(SkippedFile(check: step.check, reason: "\(step.outputPath) already exists in the library"))
            } else if limit.map({ steps.count < $0 }) ?? true {
                steps.append(step)
            }
        }
        self.steps = steps
        self.skipped = skipped
    }

    struct Refusal: Error { let text: String }

    static func step(for check: MediaCheck, mediaRoot: String) -> Result<ConversionStep, Refusal> {
        let file = check.file
        guard let source = file.path, !source.isEmpty else { return .failure(Refusal(text: "Jellyfin gave no path")) }
        guard source.hasPrefix(mediaRoot + "/") else { return .failure(Refusal(text: "not under \(mediaRoot)/ (the container's mount)")) }
        // `..`, `.` and empty parts would walk out of the media tree on the host.
        guard !source.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            return .failure(Refusal(text: "the path has a . or .. part, or an empty one"))
        }
        // The log is tab-separated lines; the script reads it line by line.
        guard !source.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            return .failure(Refusal(text: "the path has a control character (tab or newline)"))
        }
        guard check.streams.allSatisfy({ $0.stream.index != nil }) else { return .failure(Refusal(text: "a stream has no index")) }
        let kind = check.verdict
        let (directory, name) = split(source)
        let output = kind == .faststart ? source : directory + "/" + outputName(name)
        let outputBase = split(output).name
        guard (tempPrefix + outputBase).utf8.count <= maxNameBytes else {
            return .failure(Refusal(text: "the file name is too long for a temporary name beside it"))
        }
        let format = output.lowercased().hasSuffix(".mov") ? "mov" : "mp4"
        let temp = directory + "/" + tempPrefix + outputBase
        let original = directory + "/" + originalsFolder + "/" + name
        var step = ConversionStep(
            check: check, kind: kind, sourcePath: source, outputPath: output, tempPath: temp, originalPath: original,
            arguments: [], sidecars: [], expected: nil, format: format, notes: check.notes, sizeBytes: file.size, doviCheck: "same"
        )
        if kind == .faststart {
            // A Dolby Vision file copied by the mov muxer loses its dvcC/dvvC box unless -strict unofficial (or
            // looser). Jellyfin's range type can be missing or odd, so every copy gets the flag and the check.
            let strict = ["-strict", "unofficial"]
            step.arguments = common(source) + ["-map", "0", "-c", "copy", "-copy_unknown", "-map_metadata", "0"] + strict + ["-movflags", "+faststart", "-f", format, temp]
            return .success(step)
        }
        return streamByStream(&step)
    }

    /// `X.mkv` → `X.mp4`; an MP4-family name keeps its extension.
    static func outputName(_ name: String) -> String {
        let lower = name.lowercased()
        if [".mp4", ".m4v", ".mov"].contains(where: lower.hasSuffix) { return name }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name + ".mp4" }
        return String(name[..<dot]) + ".mp4"
    }

    static func split(_ path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    static func common(_ source: String) -> [String] {
        ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", source]
    }

    /// Remux and re-encode: every kept stream is mapped by its index and
    /// treated per its action; anything else stays out of the MP4.
    static func streamByStream(_ step: inout ConversionStep) -> Result<ConversionStep, Refusal> {
        var maps: [String] = [], options: [String] = []
        var counts = (video: 0, audio: 0, subtitle: 0, data: 0)
        var sidecars: [SubtitleSidecar] = []
        var needsStrict = false, needsCopyUnknown = false
        var notes = step.notes
        let (directory, name) = split(step.outputPath)
        let stem = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
        var sidecarNames: [String: Int] = [:]

        for plan in step.check.streams {
            let s = plan.stream
            let index = s.index!
            let range = s.videoRangeType ?? ""
            // Dolby Vision with an enhancement layer: a copy into MP4 loses the layer,
            // an encode loses it and the HDR. Better as it is.
            if s.type == "Video", range.hasPrefix("DOVIWithEL") {
                return .failure(Refusal(text: "Dolby Vision profile 7 (enhancement layer): left alone"))
            }
            if case .encode = plan.action, s.type == "Video", range.lowercased() != "sdr" {
                return .failure(Refusal(text: range.isEmpty || range.lowercased() == "unknown"
                    ? "can't tell whether the video is HDR, and a re-encode would drop its HDR metadata: left alone"
                    : "HDR video would need a re-encode that drops its HDR metadata: left alone"))
            }
            if case .leaveOut(let why) = plan.action {
                guard s.type == "Subtitle" else { continue }
                let codec = (s.codec ?? "").lowercased()
                guard codec.contains("pgs") else {
                    return .failure(Refusal(text: "\(s.label) can't go into MP4 or be extracted to a file: original kept (\(why))"))
                }
                let language = String(String.UnicodeScalarView((s.language ?? "").unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }))
                let tag = language.isEmpty ? "und" : language.lowercased()
                let taken = sidecarNames[tag, default: 0]
                sidecarNames[tag] = taken + 1
                let sidecar = directory + "/" + stem + "." + tag + (taken == 0 ? "" : ".\(taken + 1)") + ".sup"
                let temp = directory + "/" + tempPrefix + split(sidecar).name
                guard (tempPrefix + split(sidecar).name).utf8.count <= maxNameBytes else {
                    return .failure(Refusal(text: "the subtitle file name is too long for a temporary name beside it"))
                }
                sidecars.append(SubtitleSidecar(
                    streamIndex: index, path: sidecar, tempPath: temp,
                    arguments: common(step.sourcePath) + ["-map", "0:\(index)", "-c", "copy", "-f", "sup", temp]
                ))
                notes.append("\(s.label) → \(split(sidecar).name) (beside the file)")
                continue
            }
            maps += ["-map", "0:\(index)"]
            switch s.type {
            case "Video", "EmbeddedImage":
                let n = counts.video
                counts.video += 1
                switch plan.action {
                case .retag(let tag):
                    options += ["-c:v:\(n)", "copy", "-tag:v:\(n)", tag]
                    if tag == "dvh1" { step.doviCheck = "1" }
                case .encode(let codec):
                    if codec == "hevc" {
                        let pixel = (s.bitDepth ?? 8) > 8 ? "yuv420p10le" : "yuv420p"
                        options += ["-c:v:\(n)", "libx265", "-preset:v:\(n)", "medium", "-crf:v:\(n)", "20", "-pix_fmt:v:\(n)", pixel, "-tag:v:\(n)", "hvc1"]
                        options += ["-x265-params", "log-level=error"]
                    } else {
                        options += ["-c:v:\(n)", "libx264", "-preset:v:\(n)", "medium", "-crf:v:\(n)", "18", "-pix_fmt:v:\(n)", "yuv420p"]
                    }
                default: options += ["-c:v:\(n)", "copy"]
                }
            case "Audio":
                let n = counts.audio
                counts.audio += 1
                if case .encode(let codec) = plan.action {
                    let channels = s.channels ?? 2
                    switch codec {
                    case "flac":
                        options += ["-c:a:\(n)", "flac"]
                        needsStrict = true
                    case "eac3": options += ["-c:a:\(n)", "eac3", "-b:a:\(n)", channels <= 4 ? "384k" : "640k"]
                    default: options += ["-c:a:\(n)", "aac", "-b:a:\(n)", channels <= 1 ? "96k" : channels == 2 ? "192k" : "\(64 * channels)k"]
                    }
                } else {
                    options += ["-c:a:\(n)", "copy"]
                }
            case "Subtitle":
                let n = counts.subtitle
                counts.subtitle += 1
                options += ["-c:s:\(n)", plan.action == .toMovText ? "mov_text" : "copy"]
            default:
                let n = counts.data
                counts.data += 1
                needsCopyUnknown = true
                options += ["-c:d:\(n)", "copy"]
            }
        }
        guard counts.video > 0 else { return .failure(Refusal(text: "no video stream would be kept")) }
        var args = common(step.sourcePath) + maps + options
        if needsCopyUnknown { args.append("-copy_unknown") }
        // FLAC in MP4 was "experimental" before ffmpeg 4.4; jellyfin-ffmpeg 7.x doesn't need the flag, and it's harmless there.
        // dvh1 needs -strict unofficial or looser to get its dvcC/dvvC box. "experimental" is looser than
        // "unofficial" (ffmpeg's compliance levels: unofficial -1, experimental -2), so one value covers both.
        // Every output gets it: a copied Dolby Vision stream (whatever Jellyfin calls its range) keeps its box.
        args += ["-strict", needsStrict ? "experimental" : "unofficial"]
        if step.doviCheck == "1" {
            notes.append("dvh1 needs -strict unofficial for its Dolby Vision box: check the first real DV file with jellyfin-ffmpeg (verify does)")
        }
        args += ["-map_metadata", "0", "-map_chapters", "0", "-movflags", "+faststart", "-f", step.format, step.tempPath]
        step.arguments = args
        step.sidecars = sidecars
        step.expected = .init(video: counts.video, audio: counts.audio, subtitle: counts.subtitle)
        step.notes = notes
        return .success(step)
    }
}

/// Quoting for `sh`.
public enum ShellQuote {
    static let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:=+,@%-")

    /// Left bare when every character is safe; otherwise in single quotes,
    /// each embedded `'` written `'\''`.
    public static func quote(_ value: String) -> String {
        if !value.isEmpty, value.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
