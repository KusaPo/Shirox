import XCTest
import AVFoundation
@testable import Kairo

private final class DownloadTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 0)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; instant.addTimeInterval(seconds) }
    func gate() -> DownloadHostGate { DownloadHostGate(now: { self.now() }, sleep: { self.advance($0); try Task.checkCancellation() }) }
}
private actor DownloadFixture {
    var calls: [String: Int] = [:]
    var requests: [URLRequest] = []
    let media: Data
    let failAt: String?
    let limitAt: String?
    let retryAfter: String
    init(media: Data = Data([0x47, 1, 2, 3]), failAt: String? = nil, limitAt: String? = "/seg1.ts", retryAfter: String = "3") {
        self.media = media; self.failAt = failAt; self.limitAt = limitAt; self.retryAfter = retryAfter
    }
    func response(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!, path = url.path
        calls[path, default: 0] += 1
        let status = path == failAt ? 403 : (path == limitAt && calls[path] == 1 ? 429 : 200)
        let body = path.hasSuffix("m3u8") ? Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nseg0.ts\n#EXTINF:2,\nseg1.ts\n#EXT-X-ENDLIST\n".utf8) : media
        return (status == 200 ? body : Data("rate limited".utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Retry-After":retryAfter])!)
    }
    func count(_ path: String) -> Int { calls[path, default: 0] }
    func preservedHeaders() -> Bool { requests.allSatisfy { $0.value(forHTTPHeaderField: "Referer") == "https://source.example/" && $0.value(forHTTPHeaderField: "User-Agent") == "FixtureAgent" } }
}

final class HLSDownloadTests: XCTestCase {
    private let origin = URL(string: "https://media.example/index.m3u8")!
    private let headers = ["Referer":"https://source.example/", "User-Agent":"FixtureAgent"]
    private func temporaryFolder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testRateLimitedSegmentRetriesAndKeepsCorrectBytes() async throws {
        let clock = DownloadTestClock(), fixture = DownloadFixture()
        let client = DownloadHTTPClient(gate: clock.gate(), transport: { try await fixture.response($0) })
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let local = try await HLSDownloadTransfer(client: client).download(url: origin, headers: headers, folder: folder, onProgress: { _ in }, onWait: { _ in })
        let count = await fixture.count("/seg1.ts")
        let headersOK = await fixture.preservedHeaders()
        XCTAssertEqual(count, 2)
        XCTAssertTrue(headersOK)
        XCTAssertGreaterThanOrEqual(clock.now().timeIntervalSince1970, 3)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("v_seg_1.ts")), Data([0x47, 1, 2, 3]))
        let manifest = try String(contentsOf: local, encoding: .utf8)
        XCTAssertFalse(manifest.contains("https://"))
        XCTAssertTrue(manifest.contains("#EXT-X-ENDLIST"))
    }
    func testRetryKeepsCompletedSegmentAfterLaterFailure() async throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = DownloadFixture(failAt: "/seg1.ts", limitAt: nil)
        let firstClient = DownloadHTTPClient(gate: DownloadTestClock().gate(), transport: { try await first.response($0) })
        do {
            _ = try await HLSDownloadTransfer(client: firstClient).download(url: origin, headers: headers, folder: folder, onProgress: { _ in }, onWait: { _ in })
            XCTFail("403 must not become a completed download")
        } catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("v_seg_0.ts").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("playlist.m3u8").path))
        let second = DownloadFixture(limitAt: nil)
        let secondClient = DownloadHTTPClient(gate: DownloadTestClock().gate(), transport: { try await second.response($0) })
        _ = try await HLSDownloadTransfer(client: secondClient).download(url: origin, headers: headers, folder: folder, onProgress: { _ in }, onWait: { _ in })
        let firstCount = await second.count("/seg0.ts"), secondCount = await second.count("/seg1.ts")
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
    }
    func testPersistent429IsBoundedAndDoesNotWriteAnErrorPage() async throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = DownloadFixture(limitAt: "/index.m3u8")
        let client = DownloadHTTPClient(gate: DownloadTestClock().gate(), transport: { request in
            (Data("limited".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After":"0"])!)
        })
        do {
            _ = try await HLSDownloadTransfer(client: client).download(url: origin, headers: [:], folder: folder, onProgress: { _ in }, onWait: { _ in })
            XCTFail("Persistent 429 must stop with a useful error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("429")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("playlist.m3u8").path))
        _ = fixture
    }
    func testRetryAfterDateAndMinimumBackoff() {
        XCTAssertEqual(DownloadRetryPolicy.delay(attempt: 1, retryAfter: "0"), 2)
        XCTAssertEqual(DownloadRetryPolicy.delay(attempt: 2, retryAfter: "9"), 9)
        XCTAssertEqual(DownloadRetryPolicy.delay(attempt: 1, retryAfter: "Thu, 01 Jan 1970 00:01:00 GMT", now: Date(timeIntervalSince1970: 0)), 60)
        XCTAssertEqual(DownloadRetryPolicy.delay(attempt: 4, retryAfter: "bad"), 16)
    }
    func testOfflineRoutingRejectsTraversalAndSidecarFiles() {
        let root = URL(fileURLWithPath: "/tmp/downloads")
        XCTAssertNil(OfflineHLSServer.resolve(path: "/token/%2e%2e/private.mp4", root: root, token: "token"))
        XCTAssertNil(OfflineHLSServer.resolve(path: "/wrong/episode/playlist.m3u8", root: root, token: "token"))
        XCTAssertNil(OfflineHLSServer.resolve(path: "/token/episode/v_seg_0.ts.sha256", root: root, token: "token"))
        XCTAssertEqual(OfflineHLSServer.resolve(path: "/token/episode/playlist.m3u8", root: root, token: "token")?.path, "/tmp/downloads/episode/playlist.m3u8")
    }
    func testCancellationReleasesTheSharedHostLane() async throws {
        let gate = DownloadHostGate()
        let url = origin
        let client = DownloadHTTPClient(gate: gate, transport: { _ in
            try await Task.sleep(for: .seconds(60))
            return (Data([1]), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let task = Task { try await client.fetch(url, headers: [:]) }
        await Task.yield(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled transfer must throw") } catch { }
        // A cancelled transfer must leave the lane available to another episode.
        let next = DownloadHTTPClient(gate: gate, transport: { request in
            (Data([7]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let (data, _) = try await next.fetch(url, headers: [:])
        XCTAssertEqual(data, Data([7]))
    }
    @MainActor func testSavedVideoOpensLocallyAfterA429() async throws {
        let fixture = DownloadFixture(media: Data(base64Encoded: Self.video)!, limitAt: "/seg0.ts")
        let client = DownloadHTTPClient(gate: DownloadTestClock().gate(), transport: { request in
            let (data, response) = try await fixture.response(request)
            if request.url!.path.hasSuffix("m3u8"), response.statusCode == 200 {
                return (Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nseg0.ts\n#EXT-X-ENDLIST\n".utf8), response)
            }
            return (data, response)
        })
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kairo/Downloads/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = try await HLSDownloadTransfer(client: client).download(url: origin, headers: headers, folder: folder, onProgress: { _ in }, onWait: { _ in })
        let address = try await OfflineHLSServer.shared.playbackURL(for: local)
        XCTAssertEqual(address.host, "127.0.0.1")
        let asset = AVURLAsset(url: address)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(playable)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.2)
        let segment = address.deletingLastPathComponent().appendingPathComponent("v_seg_0.ts")
        var request = URLRequest(url: segment)
        request.setValue("bytes=0-187", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data.count, 188)
    }
    // Two seconds of synthetic purple frames and silence, generated with FFmpeg.
    private static let video = "R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABAAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB/IX4AAAAB4AAAgIAFIQAH6LUAAAABCfAAAAABZ0LACtoQmwEQAAADABAAAAMBgPEiagAAAAFozg/IAAABBgX//1DcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY0IHIzMTA4IDMxZTE5ZjkgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDIzIC0gaHR0cDovL3d3dy52aWRlb2xhbi5HAQARb3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X0cBABJwc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTIgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9MjUwIGtleWludF9taW49MTIgRwEAMycA//////////////////////////////////////////////////9zY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAAAAWWIhDoRigACJTHAAEDiOAAIKUnJyddddddddddddeBHQQA0mRAAAI3HfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEACSNNAAAAAQnwAAAAAUGaIBGgjEdBADWZEAAAnG1+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAJXeUAAAABCfAAAAABQZpAEaCMR0EANpkQAACrE34A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAAmYfQAAAAEJ8AAAAAFBmmARoIxHQQA3mRAAALm5fgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEACdMVAAAAAQnwAAAAAUGagBKgjEdBATABQAAAAcAA6YCABSEAB9hh//FQgAPf/N4CAExhdmM2MC4zMS4xMDIAQiAIwRg4//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whRwEBMX4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8QBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBxHQQA4mRAAAMhffgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEACw2tAAAAAQnwAAAAAUGaoBKgjEdBADmZEAAA1wV+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQALSEUAAAABCfAAAAABQZrAEqCMR0EAOpkQAADlq34A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAAuC3QAAAAEJ8AAAAAFBmuASoIxHQQA7mRAAAPRRfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAC711AAAAAQnwAAAAAUGbABKgjEdBATIBQAAAAcAA2ICABSEACd2b//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMRwEBM48A/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////xz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBxHQQA8mRAAAQL3fgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAC/gNAAAAAQnwAAAAAUGbIBKgjEdBAD2ZEAABEZ1+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQANMqUAAAABCfAAAAABQZtAEqCMR0EAPpkQAAEgQ34A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAA1tPQAAAAEJ8AAAAAFBm2ASoIxHQQA/mRAAAS7pfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEADafVAAAAAQnwAAAAAUGbgBKgjEdBADCZEAABPY9+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAN4m0AAAABCfAAAAABQZugEqCMR0EBNAFAAAABwADYgIAFIQAL4tX/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIxHAQE1jwD/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////HP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHEdBADGZEAABTDV+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAPHQUAAAABCfAAAAABQZvAEqCMR0EAMpkQAAFa234A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAA9XnQAAAAEJ8AAAAAFBm+ASoIxHQQAzmRAAAWmBfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAD5I1AAAAAQnwAAAAAUGaABKgjEdBADSZEAABeCd+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAPzM0AAAABCfAAAAABQZogEqCMR0EBNgFAAAABwADYgIAFIQAN6A3/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIxHAQE3jwD/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////HP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHEdBADWZEAABhs1+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQARB2UAAAABCfAAAAABQZpAEqCMR0EANpkQAAGVc34A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhABFB/QAAAAEJ8AAAAAFBmmASoIxHQQA3mRAAAaQZfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAEXyVAAAAAQnwAAAAAUGagBKgjEdBADiZEAABsr9+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQARty0AAAABCfAAAAABQZqgEqCMR0EAOZkQAAHBZX4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhABHxxQAAAAEJ8AAAAAFBmsASoIxHQQE4AUAAAAHAANiAgAUhAA/tR//xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjEcBATmPAP////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8c//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwcR0EAOpkQAAHQC34A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhABMsXQAAAAEJ8AAAAAFBmuASoIxHQQE6QUD/////////////////////////////////////////////////////////////////////////////////////AAABwABwgIAFIQAR8oH/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHP/xUIABv/whEARgjBz/8VCAAb/8IRAEYIwc//FQgAG//CEQBGCMHA=="
}
