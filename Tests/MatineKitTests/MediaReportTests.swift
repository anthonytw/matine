import Foundation
import Synchronization
import Testing
@testable import MatineKit

@Suite struct MediaCheckTests {
    static func video(_ codec: String, tag: String? = nil, profile: String? = nil, bits: Int? = 8, pixel: String? = "yuv420p") -> MediaStreamInfo {
        MediaStreamInfo(index: 0, type: "Video", codec: codec, codecTag: tag, profile: profile, bitDepth: bits, pixelFormat: pixel)
    }
    static func audio(_ codec: String) -> MediaStreamInfo { MediaStreamInfo(index: 1, type: "Audio", codec: codec) }
    static func subtitle(_ codec: String, external: Bool = false) -> MediaStreamInfo {
        MediaStreamInfo(index: 2, type: "Subtitle", codec: codec, isExternal: external)
    }
    static func file(_ container: String, _ streams: [MediaStreamInfo], protocol: String = "File", videoType: String = "VideoFile") -> MediaFile {
        MediaFile(itemId: "i", sourceId: "s", title: "t", container: container, protocol: `protocol`, videoType: videoType, streams: streams)
    }
    static let plain = [video("h264", tag: "avc1", profile: "Main"), audio("aac")]

    @Test func anMP4WithItsIndexFirstIsFine() {
        #expect(MediaCheck(file: Self.file("mp4", Self.plain), layout: .moovFirst).verdict == .fine)
    }

    @Test func anMP4WithItsIndexLastNeedsFaststart() {
        let check = MediaCheck(file: Self.file("mp4", Self.plain), layout: .moovLast)
        #expect(check.verdict == .faststart)
        #expect(check.notes == ["index (moov) at the end of the file"])
    }

    @Test func anUnreadLayoutIsUncheckedNeverFine() {
        let check = MediaCheck(file: Self.file("m4v", Self.plain), layout: .unknown("read failed"))
        #expect(check.verdict == .unchecked)
        #expect(check.notes == ["layout not read: read failed"])
        #expect(MediaCheck(file: Self.file("mp4", Self.plain), layout: nil).verdict == .unchecked)
    }

    @Test func aFileWithoutStreamInfoIsSkipped() {
        let check = MediaCheck(file: Self.file("mp4", []), layout: .moovFirst)
        #expect(check.verdict == .skip)
        #expect(check.notes == ["no video stream info from Jellyfin"])
        #expect(MediaCheck(file: Self.file("mp4", [Self.audio("aac")]), layout: .moovFirst).verdict == .skip)
    }

    @Test func anMKVOfCompatibleStreamsIsARemuxWithTextSubtitlesKept() {
        let check = MediaCheck(file: Self.file("mkv", Self.plain + [Self.subtitle("subrip")]), layout: nil)
        #expect(check.verdict == .remux)
        #expect(check.streams.map(\.action) == [.copy, .copy, .toMovText])
        #expect(check.notes.first == "mkv → mp4")
    }

    @Test func pictureSubtitlesAndFontsAreLeftOutOfTheMP4() {
        let font = MediaStreamInfo(index: 3, type: "Data", codec: "ttf")
        let cover = MediaStreamInfo(index: 4, type: "EmbeddedImage", codec: "mjpeg")
        let check = MediaCheck(file: Self.file("mkv", Self.plain + [Self.subtitle("PGSSUB"), font, cover]), layout: nil)
        #expect(check.verdict == .remux)
        #expect(check.streams.map(\.action).suffix(3) == [
            .leaveOut("picture subtitles can't go into MP4"), .leaveOut("data track"), .leaveOut("cover picture"),
        ])
        #expect(check.notes.contains("subtitle 2 PGSSUB: picture subtitles can't go into MP4, kept outside the MP4"))
    }

    @Test func streamsAlreadyInAnMP4NeverForceARemux() {
        let extras = [Self.subtitle("dvd_subtitle"), MediaStreamInfo(index: 3, type: "Data", codec: "bin_data"), Self.video("mjpeg")]
        let check = MediaCheck(file: Self.file("mp4", Self.plain + extras), layout: .moovFirst)
        #expect(check.verdict == .fine)
        #expect(check.notes.isEmpty)
        #expect(MediaCheck(file: Self.file("mp4", Self.plain + extras), layout: .moovLast).verdict == .faststart)
    }

    @Test func styledSubtitlesSayTheirStylingGoes() {
        let check = MediaCheck(file: Self.file("mkv", Self.plain + [Self.subtitle("ass")]), layout: nil)
        #expect(check.notes.contains("subtitle 2 ass → mov_text (styling lost)"))
    }

    @Test func aMotionJPEGMovieIsEncodedNotDropped() {
        let check = MediaCheck(file: Self.file("avi", [Self.video("mjpeg", pixel: "yuvj422p"), Self.audio("pcm_s16le")]), layout: nil)
        #expect(check.verdict == .reencode)
        #expect(check.streams.map(\.action) == [.encode("h264"), .encode("flac")])
    }

    @Test func hevcTaggedHev1NeedsTheHvc1Tag() {
        let check = MediaCheck(file: Self.file("mp4", [Self.video("hevc", tag: "hev1", profile: "Main 10", bits: 10, pixel: "yuv420p10le"), Self.audio("eac3")]), layout: .moovFirst)
        #expect(check.verdict == .remux)
        #expect(check.streams.first?.action == .retag("hvc1"))
        #expect(MediaCheck(file: Self.file("mp4", [Self.video("hevc", tag: "hvc1", profile: "Main 10", bits: 10), Self.audio("aac")]), layout: .moovFirst).verdict == .fine)
    }

    @Test func onlyTheStreamTheTVCantDecodeIsEncodedAgain() {
        let check = MediaCheck(file: Self.file("mkv", [Self.video("h264", profile: "High"), Self.audio("dts"), Self.audio("AC3")]), layout: nil)
        #expect(check.verdict == .reencode)
        #expect(check.streams.map(\.action) == [.copy, .encode("aac"), .copy])
    }

    @Test func audioKeepsWhatItHas() {
        func audio(_ codec: String, profile: String? = nil, channels: Int) -> StreamAction {
            MediaCheckTests.action(MediaStreamInfo(type: "Audio", codec: codec, profile: profile, channels: channels))
        }
        #expect(audio("truehd", channels: 8) == .encode("flac"))
        #expect(audio("dts", profile: "DTS-HD MA", channels: 6) == .encode("flac"))
        #expect(audio("pcm_s24le", channels: 2) == .encode("flac"))
        #expect(audio("dts", profile: "DTS", channels: 6) == .encode("eac3"))
        #expect(audio("opus", channels: 2) == .encode("aac"))
        #expect(audio("dts", profile: "DTS-HD HRA", channels: 8) == .encode("aac"))
        #expect(audio("flac", channels: 6) == .copy)
    }

    @Test func videoKeepsItsDepthHDRAndSize() {
        #expect(MediaCheckTests.action(Self.video("vp9", bits: 8, pixel: "yuv420p")) == .encode("h264"))
        var uhd = Self.video("av1")
        uhd.width = 3840
        #expect(MediaCheckTests.action(uhd) == .encode("hevc"))
        var hdr = Self.video("vp9")
        hdr.videoRangeType = "HDR10"
        #expect(MediaCheckTests.action(hdr) == .encode("hevc"))
    }

    @Test func dolbyVisionKeepsItsOwnTag() {
        var video = Self.video("hevc", tag: "dvh1", profile: "Main 10", bits: 10)
        video.videoRangeType = "DOVI"
        #expect(MediaCheckTests.action(video) == .copy)
        video.codecTag = "hvc1"
        video.videoRangeType = "DOVIWithHDR10"
        #expect(MediaCheckTests.action(video) == .retag("dvh1"))
        video.codecTag = nil
        #expect(MediaCheck.action(for: video, inMP4: false) == .retag("dvh1"))
        video.videoRangeType = "DOVIWithEL"
        #expect(MediaCheck.action(for: video, inMP4: false) == .retag("hvc1"))
    }

    @Test func aDolbyVisionTagIsKeptWhenJellyfinDoesNotSayItIsDolbyVision() {
        let tagged = Self.video("hevc", tag: "dvh1", profile: "Main 10", bits: 10)
        #expect(MediaCheckTests.action(tagged) == .copy)
        #expect(MediaCheck.action(for: Self.video("hevc", tag: "dvhe", profile: "Main 10", bits: 10), inMP4: false) == .retag("dvh1"))
        var unknown = Self.video("hevc", tag: "dvh1", profile: "Main 10", bits: 10)
        unknown.videoRangeType = "Unknown"
        #expect(MediaCheckTests.action(unknown) == .copy)
        #expect(MediaCheckTests.action(Self.video("hevc", tag: "hev1", profile: "Main")) == .retag("hvc1"))
    }

    @Test func dolbyVisionProfile7IsNoted() {
        var video = Self.video("hevc", tag: "hvc1", profile: "Main 10", bits: 10)
        video.videoRangeType = "DOVIWithELHDR10Plus"
        let check = MediaCheck(file: Self.file("mp4", [video, Self.audio("eac3")]), layout: .moovFirst)
        #expect(check.verdict == .fine)
        #expect(check.notes.first?.contains("profile 7") == true)
    }

    @Test func tenBitH264AndOtherVideoCodecsAreEncoded() {
        #expect(MediaCheckTests.action(Self.video("h264", profile: "High 10", bits: 10, pixel: "yuv420p10le")) == .encode("hevc"))
        #expect(MediaCheckTests.action(Self.video("h264", profile: "High 4:4:4 Predictive", pixel: "yuv444p")) == .encode("h264"))
        #expect(MediaCheckTests.action(Self.video("mpeg4")) == .encode("h264"))
        #expect(MediaCheckTests.action(Self.video("vc1")) == .encode("h264"))
        #expect(MediaCheckTests.action(Self.video("hevc", tag: "hvc1", profile: "Rext", bits: 12)) == .encode("hevc"))
    }

    static func action(_ stream: MediaStreamInfo) -> StreamAction { MediaCheck.action(for: stream, inMP4: true) }

    @Test func sidecarSubtitlesAreNotPartOfTheFile() {
        let check = MediaCheck(file: Self.file("mp4", Self.plain + [Self.subtitle("subrip", external: true)]), layout: .moovFirst)
        #expect(check.streams.count == 2)
        #expect(check.verdict == .fine)
    }

    @Test func discsAndRemoteStreamsAreSkipped() {
        #expect(MediaCheck(file: Self.file("mp4", Self.plain, protocol: "Http"), layout: nil).verdict == .skip)
        #expect(MediaCheck(file: Self.file("", [], videoType: "BluRay"), layout: nil).verdict == .skip)
    }

    @Test func theReportCountsAndSortsTheMostWorkFirst() {
        let report = MediaReport(checks: [
            MediaCheck(file: Self.file("mp4", Self.plain), layout: .moovFirst),
            MediaCheck(file: Self.file("mkv", Self.plain), layout: nil),
            MediaCheck(file: Self.file("mp4", Self.plain), layout: .moovLast),
        ])
        #expect(report.checks.map(\.verdict) == [.remux, .faststart, .fine])
        #expect(report.count(.fine) == 1)
    }
}

@Suite struct MP4LayoutTests {
    static func box(_ type: String, size: Int) -> [UInt8] {
        withUnsafeBytes(of: UInt32(size).bigEndian, Array.init) + Array(type.utf8) + [UInt8](repeating: 0, count: max(0, size - 8))
    }

    static func layout(_ bytes: [UInt8], reads: Counter = Counter()) async throws -> MP4Layout {
        try await MediaCheck.layout(size: Int64(bytes.count)) { offset, count in
            reads.add()
            let start = Int(offset)
            return start < bytes.count ? Data(bytes[start..<min(bytes.count, start + count)]) : Data()
        }
    }

    final class Counter: @unchecked Sendable {
        var value = 0
        func add() { value += 1 }
    }

    @Test func moovBeforeMdatIsFirst() async throws {
        let reads = Counter()
        #expect(try await Self.layout(Self.box("ftyp", size: 24) + Self.box("moov", size: 100) + Self.box("mdat", size: 500), reads: reads) == .moovFirst)
        #expect(reads.value == 2)
    }

    @Test func mdatBeforeMoovIsLast() async throws {
        #expect(try await Self.layout(Self.box("ftyp", size: 24) + Self.box("free", size: 8) + Self.box("mdat", size: 500) + Self.box("moov", size: 100)) == .moovLast)
    }

    @Test func aSixtyFourBitBoxSizeIsFollowed() async throws {
        // `wide` with size 1 and a 64-bit size of 24, then moov.
        let wide: [UInt8] = [0, 0, 0, 1] + Array("wide".utf8) + withUnsafeBytes(of: UInt64(24).bigEndian, Array.init) + [UInt8](repeating: 0, count: 8)
        #expect(try await Self.layout(Self.box("ftyp", size: 16) + wide + Self.box("moov", size: 8)) == .moovFirst)
    }

    @Test func brokenFilesAreUnknownNotAnError() async throws {
        #expect(try await Self.layout(Array(Self.box("ftyp", size: 24).prefix(6))) == .unknown("file ends inside a box header"))
        #expect(try await Self.layout(Self.box("ftyp", size: 24) + Self.box("free", size: 0)) == .unknown("free box runs to the end"))
        #expect(try await Self.layout([0, 0, 0, 4] + Array("ftyp".utf8)) == .unknown("bad box size"))
        #expect(try await Self.layout(Self.box("ftyp", size: 24) + Self.box("free", size: 16)) == .unknown("no moov or mdat"))
        #expect(try await Self.layout(Self.box("ftyp", size: 24) + Array(Self.box("free", size: 400).prefix(16))) == .unknown("free box runs past the end"))
    }

    @Test func aHugeBoxSizeIsUnknownNotACrash() async throws {
        let huge: [UInt8] = [0, 0, 0, 1] + Array("free".utf8) + withUnsafeBytes(of: UInt64(Int64.max).bigEndian, Array.init)
        #expect(try await Self.layout(Self.box("ftyp", size: 16) + huge) == .unknown("free box runs past the end"))
        // Without a known size, the sum overflows: still unknown.
        let unsized = try await MediaCheck.layout(size: nil) { offset, _ in
            offset == 0 ? Data(Self.box("ftyp", size: 16)) : Data(huge)
        }
        #expect(unsized == .unknown("bad box size"))
        let tiny: [UInt8] = [0, 0, 0, 1] + Array("free".utf8) + withUnsafeBytes(of: UInt64(8).bigEndian, Array.init)
        #expect(try await Self.layout(Self.box("ftyp", size: 16) + tiny + Self.box("moov", size: 8)) == .unknown("bad box size"))
    }

    @Test func mdatToTheEndOrSixtyFourBitIsStillMediaFirst() async throws {
        #expect(try await Self.layout(Self.box("ftyp", size: 16) + [0, 0, 0, 0] + Array("mdat".utf8) + [1, 2, 3, 4]) == .moovLast)
        let wide: [UInt8] = [0, 0, 0, 1] + Array("mdat".utf8) + withUnsafeBytes(of: UInt64(5_000_000_000).bigEndian, Array.init)
        #expect(try await MediaCheck.layout(size: nil) { offset, _ in offset == 0 ? Data(Self.box("ftyp", size: 16)) : Data(wide) } == .moovLast)
    }
}

@Suite struct MediaFilesTests {
    @Test func filesComeOnePerSourceWithTheirStreams() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items", fixture: "media-items")
        transport.singlePage = ["/Items"]
        let files = try await makeClient(transport).mediaFiles(userId: "u", libraryId: "lib")
        #expect(files.map(\.sourceId) == ["src-ep-1", "src-a", "src-b"])
        #expect(files[0].title == "Serie Uno · T1 · E1 · Piloto")
        #expect(files[0].path == "/media/tv/Serie Uno/e1.mp4")
        #expect(files[0].streams.map(\.type) == ["Video", "Audio", "Subtitle"])
        #expect(files[2].isMP4 && files[2].streams.isEmpty)
        let request = try #require(transport.requests.first)
        #expect(request.query("fields") == "MediaSources")
        #expect(request.query("parentId") == "lib")
        #expect(request.url!.absoluteString.contains("ApiKey") == false)
    }

    /// Serves `items` items in pages of at most `cap`, whatever limit is asked
    /// (a server that caps page sizes).
    final class PagingTransport: HTTPTransport, @unchecked Sendable {
        let items: Int, cap: Int
        /// What the server says it holds, when that differs from what it serves.
        let counted: Int?
        let sendsCount: Bool
        var starts: [Int] = []
        init(items: Int, cap: Int, counted: Int? = nil, sendsCount: Bool = true) {
            (self.items, self.cap, self.counted, self.sendsCount) = (items, cap, counted, sendsCount)
        }

        func perform(_ request: URLRequest) async throws -> (Data, Int) {
            let start = Int(request.query("startIndex")!)!
            starts.append(start)
            let ids = start < items ? Array(start..<min(items, start + cap)) : []
            let total = start == 0 && sendsCount ? ",\"TotalRecordCount\":\(counted ?? items)" : ""
            let json = ids.map { #"{"Id":"i\#($0)","Name":"n","Type":"Movie","MediaSources":[{"Id":"s\#($0)","Container":"mp4","MediaStreams":[]}]}"# }
            return (Data(#"{"Items":[\#(json.joined(separator: ","))]\#(total)}"#.utf8), 200)
        }

        func performRange(_ request: URLRequest, maxBytes: Int) async throws -> (Data, Int, String?) { (Data(), 404, nil) }
    }

    @Test func pagesAreReadUntilAnEmptyOne() async throws {
        let transport = PagingTransport(items: 7, cap: 3)
        let client = JellyfinClient(server: testServer, identity: testIdentity, token: "t", transport: transport)
        let files = try await client.mediaFiles(userId: "u", pageSize: 200)
        #expect(files.map(\.sourceId) == (0..<7).map { "s\($0)" })
        // The server said 7 on the first page: no request for an empty one after the last.
        #expect(transport.starts == [0, 3, 6])
    }

    @Test func aServerThatSendsNoCountIsReadUntilAnEmptyPage() async throws {
        let transport = PagingTransport(items: 7, cap: 3, sendsCount: false)
        let client = JellyfinClient(server: testServer, identity: testIdentity, token: "t", transport: transport)
        let files = try await client.mediaFiles(userId: "u", pageSize: 200)
        #expect(files.count == 7)
        #expect(transport.starts == [0, 3, 6, 7])
    }

    @Test func aReadShortOfTheServersCountThrows() async throws {
        let transport = PagingTransport(items: 5, cap: 3, counted: 6)
        let client = JellyfinClient(server: testServer, identity: testIdentity, token: "t", transport: transport)
        await #expect(throws: MediaReportError.incomplete(read: 5, total: 6)) { _ = try await client.mediaFiles(userId: "u") }
    }

    @Test func aWrongRangeOrASignedOutTokenFails() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Videos/i/stream", status: 206, body: "0123456789abcdef")
        transport.contentRange = "bytes 0-15/99"
        await #expect(throws: JellyfinError.decoding("Content-Range bytes 0-15/99")) {
            _ = try await makeClient(transport).fileBytes(itemId: "i", sourceId: "s", offset: 100, count: 16)
        }
        transport.on("GET", "/Videos/i/stream", status: 401)
        await #expect(throws: JellyfinError.unauthorized) {
            _ = try await makeClient(transport).fileBytes(itemId: "i", sourceId: "s", offset: 0, count: 16)
        }
    }

    @Test func aRangeTheServerIgnoredFails() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Videos/i/stream", status: 200, body: "whole file")
        await #expect(throws: JellyfinError.http(status: 200)) {
            _ = try await makeClient(transport).fileBytes(itemId: "i", sourceId: "s", offset: 0, count: 16)
        }
    }

    @Test func aRangeReadSendsTheRangeAndTheTokenInHeaders() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Videos/i/stream", status: 206, body: "0123456789abcdefEXTRA")
        let data = try await makeClient(transport).fileBytes(itemId: "i", sourceId: "s", offset: 100, count: 16)
        #expect(data.count == 16)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=100-115")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == true)
        #expect(request.query("static") == "true" && request.query("mediaSourceId") == "s")
    }

    @Test func theReportReadsOnlyTheStartsThatMatter() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items", fixture: "media-items")
        transport.singlePage = ["/Items"]
        let header = [UInt8]([0, 0, 0, 16]) + Array("ftyp".utf8) + [UInt8](repeating: 0, count: 8)
        transport.on("GET", "/Videos/ep-1/stream", status: 206, body: String(decoding: header, as: UTF8.self))
        let report = try await makeClient(transport).mediaReport(userId: "u")
        // ep-1 answers every read with an ftyp box: the walk gives up after 32 boxes.
        #expect(report.checks.first { $0.file.sourceId == "src-ep-1" }?.layout == .unknown("too many boxes before the media"))
        // src-b has no stream info and src-a is an MKV to re-encode: neither start is read.
        #expect(report.checks.first { $0.file.sourceId == "src-b" }?.layout == nil)
        #expect(report.checks.first { $0.file.sourceId == "src-a" }?.layout == nil)
        #expect(transport.requests.allSatisfy { !$0.url!.path.hasPrefix("/Videos/movie-1") })
        #expect(report.checks.map(\.verdict) == [.skip, .reencode, .unchecked])

        // A read that fails leaves the file unchecked, never fine.
        transport.on("GET", "/Videos/ep-1/stream", status: 500)
        let failed = try await makeClient(transport).mediaReport(userId: "u")
        #expect(failed.checks.first { $0.file.sourceId == "src-ep-1" }?.verdict == .unchecked)
        // Signed out partway: no half report.
        transport.on("GET", "/Videos/ep-1/stream", status: 401)
        await #expect(throws: JellyfinError.unauthorized) { _ = try await makeClient(transport).mediaReport(userId: "u") }
    }
}

/// The real transport against a stub server: a server that ignores Range
/// and answers 200 with a large body.
@Suite(.serialized) struct RangeTransportTests {
    final class WholeFile: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var sent = 0
        static let chunk = Data(repeating: 7, count: 64 * 1024)
        static let chunks = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Range": "bytes 0-15/13107200"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Thread.detachNewThread { [self] in
                for _ in 0..<Self.chunks {
                    if stopped.withLock({ $0 }) { return }
                    Self.sent += Self.chunk.count
                    client?.urlProtocol(self, didLoad: Self.chunk)
                    Thread.sleep(forTimeInterval: 0.002)
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        let stopped = Mutex(false)
        override func stopLoading() { stopped.withLock { $0 = true } }
    }

    static func transport() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WholeFile.self]
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    @Test func aWholeFileAnswerIsRefusedWithoutReadingIt() async throws {
        WholeFile.status = 200
        WholeFile.sent = 0
        let request = URLRequest(url: URL(string: "https://tv.example.test/Videos/i/stream")!)
        let (data, status, _) = try await Self.transport().performRange(request, maxBytes: 16)
        #expect(status == 200 && data.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        // Cancelled at the headers: far less than the 12.5 MB on offer.
        #expect(WholeFile.sent < WholeFile.chunk.count * WholeFile.chunks / 4)
    }

    @Test func aPartialAnswerIsReadOnlyAsFarAsAsked() async throws {
        WholeFile.status = 206
        let request = URLRequest(url: URL(string: "https://tv.example.test/Videos/i/stream")!)
        let (data, status, range) = try await Self.transport().performRange(request, maxBytes: 16)
        #expect(status == 206 && data.count == 16 && range == "bytes 0-15/13107200")
    }
}
