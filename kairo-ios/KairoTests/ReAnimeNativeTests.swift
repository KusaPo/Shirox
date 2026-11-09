import XCTest
import AVFoundation
@testable import Kairo

private final class ReAnimeMediaProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static let key = Data(repeating: 4, count: 16)
    static let iv = Data(repeating: 0, count: 16)
    static var segment: Data {
        let clear = Data(base64Encoded: HLSDownloadTests.video)!
        let cipher = HLSManifestParser.encryptAES128CBC(clear, key: key, iv: iv)!
        let mask: [UInt8] = [157,42,241,71,179,142,92,112,166,25,228,59,216,98,15,197]
        let wrapped = Data(cipher.enumerated().map { $0.element ^ mask[$0.offset % mask.count] })
        return Data([137,80,78,71,13,10,26,10]) + wrapped
    }
    static let manifest = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x00000000000000000000000000000000\n#EXTINF:2,\nhttps://vault-fixture.rundowncdn.top/segment.png\n#EXT-X-ENDLIST\n"
    static func encode(_ text: String) -> Data {
        Data(Data(text.utf8).map { $0 ^ 7 }).base64EncodedData()
    }
    override func startLoading() {
        let body: Data
        switch request.url?.lastPathComponent {
        case "master.m3u8": body = Self.encode(Self.manifest)
        case "key.bin": body = Self.key
        case "segment.png": body = Self.segment
        default: client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class ReAnimeNativeTests: XCTestCase {
    private var media: ReAnimeMedia { ReAnimeMedia(url: URL(string: "https://fixture.flixcloud.cc/master.m3u8")!, playlistKey: Data(repeating: 7, count: 32)) }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReAnimeMediaProtocol.self]; return config
    }
    func testPlayerDataIsParsedAsDataAndCryptoMatchesIndependentNodeFixture() throws {
        let literal = try ReAnimeNativeResolver.pageLiteral(ReAnimeNativeFixture.html)
        XCTAssertTrue(literal.contains("obfuscation_seed"))
        XCTAssertEqual(ReAnimeNativeResolver.normalize(#"{a:undefined,b:!0,c:"undefined !1 }"}"#), #"{a:null,b:true,c:"undefined !1 }"}"#)
        let derived = try ReAnimeNativeResolver.derive(Data(repeating: 3, count: 32), seed: "1234567890abcdef")
        XCTAssertEqual(derived.map { String(format: "%02x", $0) }.joined(), ReAnimeNativeFixture.derivedKey)
        XCTAssertThrowsError(try ReAnimeNativeResolver.pageLiteral("no player data"))
    }
    func testBackgroundPlanPersistsUnwrapInstructionAndProducesPlayableOfflineEpisode() async throws {
        let session = URLSession(configuration: configuration())
        let client = DownloadHTTPClient(transport: { request in
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        })
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kairo/Downloads/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = HLSDownloadTransfer(client: client, reanimeMedia: media)
        let prepared = try await transfer.prepareBackground(id: UUID(), url: media.url, headers: ReAnimeMedia.headers, folder: root, wifiOnly: true)
        var restored = try JSONDecoder().decode(BackgroundHLSJob.self, from: JSONEncoder().encode(prepared))
        XCTAssertEqual(restored.resources.count, 1)
        XCTAssertEqual(restored.resources[0].url.host, "vault-fixture.rundowncdn.top")
        XCTAssertEqual(restored.resources[0].reanimeWrapped, true)
        XCTAssertFalse(restored.resources[0].url.host == "127.0.0.1", "Background tasks must use CDN URLs, not the in-app listener")
        let incoming = root.appendingPathComponent("incoming")
        try ReAnimeMediaProtocol.segment.write(to: incoming)
        let response = HTTPURLResponse(url: restored.resources[0].url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        try restored.resources[0].install(incoming, response: response, folder: root)
        restored.resources[0].complete = true
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(restored.resources[0].name)), Data(base64Encoded: HLSDownloadTests.video))
        let local = try restored.finish(in: root)
        let playback = try await OfflineHLSServer.shared.playbackURL(for: local)
        let playable = try await AVURLAsset(url: playback).load(.isPlayable)
        XCTAssertTrue(playable)
    }
    @MainActor func testNativePlayerStreamsEncodedPlaylistAndWrappedMediaWithoutExternalGateway() async throws {
        let server = ReAnimePlaybackServer(configuration: configuration())
        let url = try await server.playbackURL(media)
        XCTAssertEqual(url.host, "127.0.0.1")
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 1)
    }
    func testWrappedCiphertextStartingWithTransportSyncByteStillUnwraps() {
        let ciphertext = Data([UInt8(0x47) ^ UInt8(157), 20, 30, 40, 50, 60, 70, 80])
        let mask: [UInt8] = [157,42,241,71,179,142,92,112,166,25,228,59,216,98,15,197]
        let encoded = Data(ciphertext.enumerated().map { $0.element ^ mask[$0.offset % mask.count] })
        XCTAssertEqual(encoded.first, 0x47)
        let wrapped = Data([137,80,78,71,13,10,26,10]) + encoded
        XCTAssertEqual(ReAnimeMedia.unwrap(wrapped), ciphertext)
    }

    func testMediaAllowlistRejectsPrivateAndLookalikeHostsAndRangeIsBounded() {
        for text in ["https://127.0.0.1/segment.ts", "https://flixcloud.cc.evil.example/x", "http://a.flixcloud.cc/x", "https://a.flixcloud.cc:8443/x", "https://user:pass@a.flixcloud.cc/x"] {
            XCTAssertFalse(ReAnimeMedia.permits(URL(string: text)!))
        }
        XCTAssertTrue(ReAnimeMedia.permits(URL(string: "https://vault-92.rundowncdn.top/seg.webp")!))
        XCTAssertTrue(ReAnimeMedia.permits(URL(string: "https://vault-93.kineticcdn.top/seg.webp")!))
        XCTAssertTrue(ReAnimeMedia.permits(URL(string: "https://vault-99.ignitecdn.top/seg.webp")!))
        XCTAssertEqual(ReAnimePlaybackServer.byteRange("bytes=2-999", count: 10), 2..<10)
        XCTAssertEqual(ReAnimePlaybackServer.byteRange("bytes=-3", count: 10), 7..<10)
        XCTAssertNil(ReAnimePlaybackServer.byteRange("bytes=10-20", count: 10))
        XCTAssertNil(ReAnimePlaybackServer.byteRange("bytes=0-1,4-5", count: 10))
    }
}
