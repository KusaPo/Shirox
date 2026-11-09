import XCTest
import AVKit
@testable import Kairo

private final class SubtitleProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = "[Events]\nFormat: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text\nDialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Hello, world\\NSecond line\n"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
private final class CountingPlayerController: AVPlayerViewController {
    var assignments = 0
    override var player: AVPlayer? { didSet { assignments += 1 } }
}
final class SubtitleTests: XCTestCase {
    private let track = SubtitleTrack(url: URL(string: "https://fixture.flixcloud.cc/english.ass")!, label: "English", format: "ass")
    func testASSDialoguePreservesCommasUnicodeAndLineBreaksWithoutDrawingCommands() {
        let source = #"""
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:03.50,0:00:05.00,Main,,0,0,0,,{\i1}Hello, world!\Nこんにちは
        Dialogue: 0,0:00:00.00,0:00:02.00,Main,,0,0,0,,First
        Dialogue: 0,0:00:01.00,0:00:02.00,Main,,0,0,0,,{\p1}m 0 0 l 10 10
        Dialogue: 0,0:00:09.00,0:00:08.00,Main,,0,0,0,,Invalid range
        """#
        let cues = SubtitleParser.parse(source, format: "ass")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(SubtitleParser.text(at: 0.5, cues: cues), "First")
        XCTAssertEqual(SubtitleParser.text(at: 4, cues: cues), "Hello, world!\nこんにちは")
        XCTAssertEqual(SubtitleParser.text(at: 5, cues: cues), "")
        XCTAssertEqual(SubtitleParser.text(at: 0.5, cues: cues), "First", "Seeking backwards must restore the earlier caption")
    }
    func testSRTAndVTTParseTimingSettingsAndOverlappingCues() {
        let srt = "1\r\n00:00:01,000 --> 00:00:03,000\r\n<i>One</i> &amp; two\r\n\r\n2\r\n00:00:02,000 --> 00:00:04,000\r\nSecond\r\n"
        let cues = SubtitleParser.parse(srt, format: "srt")
        XCTAssertEqual(SubtitleParser.text(at: 2.5, cues: cues), "One & two\nSecond")
        XCTAssertEqual(SubtitleParser.text(at: 3, cues: cues), "Second")
        let vtt = "WEBVTT\n\n00:01.250 --> 00:02.500 align:center\nHello\n"
        XCTAssertEqual(SubtitleParser.parse(vtt, format: "vtt").first?.start, 1.25)
    }
    func testSubtitleArchiveIsReadyOfflineAndKeepsDifferentMediaFilesSeparate() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SubtitleProtocol.self]
        let service = SubtitleService(configuration: configuration)
        let document = try await service.document(track)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("episode-1.mp4"), second = root.appendingPathComponent("episode-2.mp4")
        try SubtitleService.save(document, beside: first)
        XCTAssertEqual(SubtitleService.saved(at: first), [document])
        XCTAssertTrue(SubtitleService.saved(at: second).isEmpty)
        let archived = await service.archive([track])
        let archive = try XCTUnwrap(archived)
        XCTAssertEqual(try JSONDecoder().decode([SubtitleDocument].self, from: Data(archive.utf8)).first?.cues.first?.text, "Hello, world\nSecond line")
    }
    func testBackgroundPreflightIncludesCaptionArchiveWithoutFetchingVideoSegments() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SubtitleProtocol.self]
        let service = SubtitleService(configuration: configuration)
        let source = URL(string: "https://fixture.flixcloud.cc/master.m3u8")!
        let media = ReAnimeMedia(url: source, playlistKey: nil, subtitles: [track])
        let client = DownloadHTTPClient(transport: { request in
            guard request.url?.pathExtension == "m3u8" else { throw URLError(.unsupportedURL) }
            let body = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nhttps://fixture.flixcloud.cc/segment.ts\n#EXT-X-ENDLIST\n"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let job = try await HLSDownloadTransfer(client: client, reanimeMedia: media, subtitleService: service)
            .prepareBackground(id: UUID(), url: source, headers: [:], folder: folder, wifiOnly: true)
        let saved = try XCTUnwrap(job.manifests[SubtitleService.archiveName])
        let documents = try JSONDecoder().decode([SubtitleDocument].self, from: Data(saved.utf8))
        XCTAssertEqual(documents.first?.cues.first?.text, "Hello, world\nSecond line")
        XCTAssertEqual(job.resources.count, 1)
        XCTAssertEqual(job.resources[0].url.lastPathComponent, "segment.ts")
    }

    @MainActor func testProgressAndCaptionRefreshesDoNotReattachTheAudioPlayer() {
        let controller = CountingPlayerController(), player = AVPlayer()
        for _ in 0..<20 { NativePlayer.configure(controller, player: player, nativeControls: false, fill: false, subtitleText: "") }
        XCTAssertEqual(controller.assignments, 1, "Progress updates must not reassign the same AVPlayer and reconfigure playback")
        XCTAssertTrue(controller.player === player)
    }
    @MainActor func testDownloadedCaptionsCanBeTurnedOnOffAndRestoredWithoutNetwork() async throws {
        let old = UserDefaults.standard.object(forKey: "playerSubtitlesEnabled")
        let oldTrack = UserDefaults.standard.object(forKey: "playerSubtitleTrack")
        defer { UserDefaults.standard.set(old, forKey: "playerSubtitlesEnabled"); UserDefaults.standard.set(oldTrack, forKey: "playerSubtitleTrack") }
        UserDefaults.standard.set(false, forKey: "playerSubtitlesEnabled")
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kairo/Downloads/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent("playlist.m3u8")
        try "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n".write(to: local, atomically: true, encoding: .utf8)
        try Data(base64Encoded: HLSDownloadTests.video)!.write(to: folder.appendingPathComponent("segment.ts"))
        let document = SubtitleDocument(track: track, cues: [SubtitleCue(start: 0, end: 100, text: "Saved caption")])
        try SubtitleService.save(document, beside: local)
        let store = AppStore(directory: folder.appendingPathComponent("state")), controller = PlaybackController()
        defer { controller.stop() }
        await controller.open(PlaybackRequest(anime: Anime(title: "Offline captions"), episode: 1, localURL: local, localAudio: .sub), store: store)
        for _ in 0..<60 where controller.subtitleChoices.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.subtitleChoices.map(\.label), ["English"])
        controller.selectSubtitle(track.id)
        XCTAssertEqual(controller.subtitleText, "Saved caption")
        let view = CaptionPlayerViewController()
        NativePlayer.configure(view, player: controller.player, nativeControls: false, fill: false, subtitleText: controller.subtitleText)
        let label = try XCTUnwrap(view.contentOverlayView?.subviews.compactMap { $0 as? UILabel }.first)
        XCTAssertEqual(label.text, "Saved caption")
        XCTAssertFalse(label.isHidden)
        controller.selectSubtitle(nil)
        XCTAssertEqual(controller.subtitleText, "")
        NativePlayer.configure(view, player: controller.player, nativeControls: false, fill: false, subtitleText: controller.subtitleText)
        XCTAssertTrue(label.isHidden, "Off must clear the actual player overlay, not just the menu state")
        XCTAssertNil(controller.subtitleSelection)
        controller.selectSubtitle(track.id)
        XCTAssertEqual(controller.subtitleText, "Saved caption")
    }
}
