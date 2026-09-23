import XCTest
@testable import Kairo

final class KairoTests: XCTestCase {
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
    func testRejectsEmbeddedCredentialsAndLocalLiteralAddresses() {
        XCTAssertNil(WebAddress.media("https://user:password@example.com/a.mp4"))
        XCTAssertNil(WebAddress.media("https://127.0.0.1/a.mp4"))
        XCTAssertNil(WebAddress.media("http://example.com/a.mp4"))
        XCTAssertNotNil(WebAddress.media("https://cdn.example.com/a.m3u8?token=example"))
    }
}
