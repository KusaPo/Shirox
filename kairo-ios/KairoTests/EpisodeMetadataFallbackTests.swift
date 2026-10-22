import XCTest
@testable import Kairo

private final class EpisodeMetadataProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host
        let status = host == "api.anira.dev" ? 200 : 503
        let rows: [[String: Any]] = [
            ["episode": 2, "absolute": 14, "title": "Tennyo Island", "thumbnail": "https://images.example/2.jpg"],
            ["episode": 1, "absolute": 13, "title": "An Unwanted Repayment", "thumbnail": "https://images.example/1.jpg"],
            ["episode": 3, "title": NSNull(), "thumbnail": NSNull()]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: host == "api.anira.dev" ? rows as Any : ["error": "Unavailable"] as Any)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class EpisodeMetadataFallbackTests: XCTestCase {
    func testMappedArtworkAndNamesSurviveOtherMetadataProviderOutage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EpisodeMetadataProtocol.self]
        let api = EpisodeMetadataAPI(configuration: configuration)
        var anime = Anime(anilistID: 205909, sourceID: "fixture", title: "Firefly Wedding")
        anime.malID = 63293
        anime.episodeCount = 4
        let result = try await api.episodes(for: anime, page: 1)
        XCTAssertEqual(result.episodes[1]?.title, "An Unwanted Repayment")
        XCTAssertEqual(result.episodes[2]?.title, "Tennyo Island")
        XCTAssertEqual(result.episodes[2]?.thumbnail?.lastPathComponent, "2.jpg")
        XCTAssertNil(result.episodes[14])
        XCTAssertNil(result.episodes[3]?.title)
        XCTAssertNil(result.episodes[3]?.thumbnail)
        XCTAssertNil(result.notice, "A failed optional fallback must not mark usable metadata as failed")
    }

    func testMalformedAndGenericMappedEpisodesDoNotInventDetails() {
        XCTAssertNil(EpisodeMetadata.mappedEpisode(["episode": 1.5, "title": "Special"]))
        XCTAssertNil(EpisodeMetadata.mappedEpisode(["episode": 0, "title": "Trailer"]))
        let future = EpisodeMetadata.mappedEpisode(["episode": 4, "title": " Episode 4 ", "thumbnail": NSNull()])
        XCTAssertEqual(future?.number, 4)
        XCTAssertNil(future?.title)
        XCTAssertNil(future?.thumbnail)
    }

    func testSeparateProvidersFillOnlyMissingMappedFields() throws {
        let mapped = try XCTUnwrap(EpisodeMetadata.mappedEpisode(["episode": 2, "title": "Episode 2", "thumbnail": "https://images.example/2.jpg"]))
        let fallback = try XCTUnwrap(EpisodeMetadata.jikanEpisode(["mal_id": 2, "title": "The Real Title"]))
        let result = EpisodeMetadata.merge([mapped, fallback])
        XCTAssertEqual(result[2]?.title, "The Real Title")
        XCTAssertEqual(result[2]?.thumbnail, mapped.thumbnail)
    }
}
