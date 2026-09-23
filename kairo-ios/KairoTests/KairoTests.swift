import XCTest
import AVFoundation
@testable import Kairo

final class KairoTests: XCTestCase {
    func testStoredHLSSessionsCreateTasksForBothNetworkPolicies() {
        let prefix = "net.kusapo.kairo.test-hls." + UUID().uuidString + "."
        let sessions = DownloadSessions(prefix: prefix, delegate: nil)
        defer { sessions.all.forEach { $0.invalidateAndCancel() } }
        XCTAssertEqual(Set(sessions.all.compactMap { $0.configuration.identifier }),
                       Set(["hls.wifi", "hls.any", "file.wifi", "file.any"].map { prefix + $0 }))
        for wifiOnly in [true, false] {
            // Exercise the production storage/lookup path, not just Apple's factory.
            let session = sessions.hls(wifiOnly: wifiOnly)
            XCTAssertEqual(session.configuration.allowsCellularAccess, !wifiOnly)
            XCTAssertEqual(sessions.file(wifiOnly: wifiOnly).configuration.allowsCellularAccess, !wifiOnly)
            XCTAssertTrue(session === sessions.hls(wifiOnly: wifiOnly))
            let erased: URLSession = session
            print("HLS session runtime: \(type(of: erased)); legacy downcast succeeds: \(erased is AVAssetDownloadURLSession)")
            let asset = AVURLAsset(url: URL(string: "https://example.com/episode.m3u8")!)
            let configuration = AVAssetDownloadConfiguration(asset: asset, title: "Stored session test")
            let task = session.makeAssetDownloadTask(downloadConfiguration: configuration)
            defer { task.cancel() }
            XCTAssertEqual(task.state, .suspended)
        }
        // Never resume: source downloads and the OS background worker need a device test.
    }
    func testEpisodePreviewsMatchExplicitNumbersNotArrayOrder() {
        let rows: [[String: Any]] = [
            ["title": "Episode 12 - Finale", "thumbnail": "https://images.example.com/12.jpg"],
            ["title": "Episode 2 – Arrival", "thumbnail": "https://images.example.com/2.jpg"],
            ["title": "Episode 12.5 - Recap"],
            ["title": "Season 2 Trailer"],
            ["title": "Episode 1-2 - Double feature"]
        ]
        let result = EpisodeMetadata.merge(rows.compactMap(EpisodeMetadata.streamingEpisode))
        XCTAssertEqual(result[12]?.title, "Finale")
        XCTAssertEqual(result[2]?.thumbnail?.lastPathComponent, "2.jpg")
        XCTAssertNil(result[3])
        XCTAssertNil(result[1])
        XCTAssertEqual(result.count, 2)
    }
    func testEpisodeTitleFallbackPreservesAvailableThumbnail() {
        let preview = EpisodeMetadata(number: 5, thumbnail: URL(string: "https://images.example.com/5.jpg"))
        let title = EpisodeMetadata.jikanEpisode(["mal_id": 5, "title": "A New Beginning"])
        let result = EpisodeMetadata.merge([preview, title!, EpisodeMetadata(number: 5)])
        XCTAssertEqual(result[5]?.title, "A New Beginning")
        XCTAssertEqual(result[5]?.thumbnail, preview.thumbnail)
        XCTAssertNil(EpisodeMetadata.jikanEpisode(["mal_id": 5.5, "title": "Special"]))
    }
    func testOlderSavedAnimeDecodesWithoutMetadataIdentifier() throws {
        let original = Data(#"{"anilistID":1,"sourceID":"original","title":"Saved title","synopsis":"","genres":[]}"#.utf8)
        let anime = try JSONDecoder().decode(Anime.self, from: original)
        XCTAssertEqual(anime.id, "anilist:1")
        XCTAssertNil(anime.malID)
    }
    func testCanonicalIdentityDoesNotDependOnProviderURL() {
        let first = Anime(anilistID: 151807, sourceID: "old-slug", title: "Example")
        let changed = Anime(anilistID: 151807, sourceID: "new-slug", title: "Localized title")
        XCTAssertEqual(first.id, changed.id)
        XCTAssertEqual(WatchProgress.key(first.id, 2), WatchProgress.key(changed.id, 2))
        XCTAssertNotEqual(WatchProgress.key(first.id, 2), WatchProgress.key(changed.id, 3))
    }
    func testSourceParsesBothImageShapesAndNumericIDs() {
        let row: [String: Any] = ["id": 123, "anilistId": 99, "titleRomaji": "Example", "coverImage": ["large": "https://images.example.com/a.jpg"], "episodeCount": 12]
        let result = CatalogAPI.animexAnime(row)
        XCTAssertEqual(result?.sourceID, "123")
        XCTAssertEqual(result?.anilistID, 99)
        XCTAssertEqual(result?.cover?.path, "/a.jpg")
        XCTAssertEqual(CatalogAPI.image("https://images.example.com/b.jpg")?.path, "/b.jpg")
    }
    func testProgressAndDownloadsPersistAcrossStoreRecreation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let anime = Anime(anilistID: 1, title: "Example")
        let store = AppStore(directory: folder)
        store.record(anime, episode: 3, seconds: 124, duration: 1400)
        store.state.downloads = [DownloadRecord(anime: anime, episode: 3, audio: .sub, provider: "provider-a", state: .paused)]
        store.save()
        let restored = AppStore(directory: folder)
        XCTAssertEqual(restored.progress(anime, episode: 3)?.seconds, 124)
        XCTAssertEqual(restored.state.downloads.first?.state, .paused)
        XCTAssertEqual(restored.state.downloads.first?.provider, "provider-a")
        XCTAssertNil(restored.storageError)
    }
    func testUnreadableStateIsNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("state.json")
        let original = Data("unreadable old data".utf8)
        try original.write(to: file)
        let store = AppStore(directory: folder)
        XCTAssertNotNil(store.storageError)
        store.toggleSaved(Anime(anilistID: 1, title: "Example"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testCompletedLatestEpisodeDoesNotResurrectOlderResumePoint() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(directory: folder)
        let anime = Anime(anilistID: 1, title: "Example")
        store.record(anime, episode: 1, seconds: 50, duration: 1000)
        store.record(anime, episode: 2, seconds: 1000, duration: 1000, finished: true)
        XCTAssertTrue(store.continuing.isEmpty)
    }
    func testLocalDownloadPathCannotEscapeSandbox() {
        var item = DownloadRecord(anime: Anime(title: "Example"), episode: 1, audio: .sub)
        item.relativePath = "../../outside.mp4"
        XCTAssertNil(item.localURL)
        item.relativePath = "/tmp/outside.mp4"
        XCTAssertNil(item.localURL)
        item.relativePath = "Library/Application Support/Kairo/a.mp4"
        XCTAssertNotNil(item.localURL)
    }
    func testDownloadLocationRecognizesAliasesOfTheSameContainer() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let container = fixture.appendingPathComponent("container")
        let alias = fixture.appendingPathComponent("alias")
        let path = "Library/Episode 1 日本.movpkg"
        let package = container.appendingPathComponent(path)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: container)
        let aliasPackage = alias.appendingPathComponent(path)
        // Reproduce the old text-prefix failure with two real paths to one folder.
        XCTAssertFalse(aliasPackage.path.hasPrefix(container.path + "/"))
        XCTAssertEqual(LocalDownloadStorage.relativePath(for: aliasPackage, within: container), path)
        XCTAssertEqual(LocalDownloadStorage.relativePath(for: package, within: alias), path)
        let systemLocation = URL(fileURLWithPath: "/.nofollow" + package.path)
        XCTAssertEqual(LocalDownloadStorage.relativePath(for: systemLocation, within: container), path)
        let restored = try XCTUnwrap(LocalDownloadStorage.url(forRelativePath: path, within: alias))
        XCTAssertTrue(fm.fileExists(atPath: restored.path))
        XCTAssertEqual(restored.path, package.resolvingSymlinksInPath().standardizedFileURL.path)
    }
    func testDownloadStorageRejectsSiblingFoldersAndEscapingSymlinks() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let container = fixture.appendingPathComponent("container")
        let sibling = fixture.appendingPathComponent("container-other")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: container.appendingPathComponent("escape"), withDestinationURL: sibling)
        XCTAssertNil(LocalDownloadStorage.relativePath(for: sibling, within: container))
        XCTAssertNil(LocalDownloadStorage.relativePath(for: container, within: container))
        XCTAssertNil(LocalDownloadStorage.relativePath(for: URL(string: "https://example.com/a.movpkg")!, within: container))
        XCTAssertNil(LocalDownloadStorage.url(forRelativePath: "escape/a.movpkg", within: container))
        XCTAssertNil(LocalDownloadStorage.relativePath(for: container.appendingPathComponent("escape/a.movpkg"), within: container))
        XCTAssertNil(LocalDownloadStorage.url(forRelativePath: "", within: container))
        XCTAssertNil(LocalDownloadStorage.url(forRelativePath: ".", within: container))
    }
    func testStoredDownloadPathSurvivesContainerRelocation() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let old = fixture.appendingPathComponent("old")
        let new = fixture.appendingPathComponent("new")
        let package = old.appendingPathComponent("Library/episode.movpkg")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let path = try XCTUnwrap(LocalDownloadStorage.relativePath(for: package, within: old))
        var record = DownloadRecord(anime: Anime(title: "Saved"), episode: 1, audio: .sub)
        record.relativePath = path
        let saved = try JSONEncoder().encode(record)
        try fm.moveItem(at: old, to: new)
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: saved)
        let restored = try XCTUnwrap(LocalDownloadStorage.url(forRelativePath: try XCTUnwrap(decoded.relativePath), within: new))
        XCTAssertTrue(fm.fileExists(atPath: restored.path))
    }
    func testRejectsEmbeddedCredentialsAndLocalLiteralAddresses() {
        XCTAssertNil(WebAddress.media("https://user:password@example.com/a.mp4"))
        XCTAssertNil(WebAddress.media("https://127.0.0.1/a.mp4"))
        XCTAssertNil(WebAddress.media("http://example.com/a.mp4"))
        XCTAssertNotNil(WebAddress.media("https://cdn.example.com/a.m3u8?token=example"))
    }
}
