import XCTest
@testable import Kairo

private final class CatalogDiscoveryProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    private static var deny = false
    static func reset(deny: Bool = false) { lock.lock(); defer { lock.unlock() }; captured = []; self.deny = deny }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.captured.append(request); let deny = Self.deny; Self.lock.unlock()
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let variables = body["variables"] as? [String: Any] ?? [:]
        let query = variables["query"] as? String
        let wrongHost = request.url?.host != "graphql.animex.one"
        let status = deny || wrongHost ? 403 : 200
        let json: [String: Any]
        if let query, query.count < 3 {
            // This is the actual Animex rejection that made the old sample-seed
            // browse code switch to AniList and expose AniList's 403 instead.
            json = ["errors": [["message": "query must be at least 3 characters"]]]
        } else {
            json = ["data": ["catalogAnime": ["hasNextPage": true, "items": [[
                "id": "fixture-source-id", "anilistId": 21, "titleEnglish": "Fixture anime",
                "titleRomaji": "Fixture", "coverImage": ["large": "https://images.example/cover.jpg"],
                "genres": ["Fantasy"], "episodeCount": 12
            ]]]]]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class CatalogDiscoveryTests: XCTestCase {
    private func api() -> CatalogAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogDiscoveryProtocol.self]
        return CatalogAPI(configuration: configuration)
    }
    func testAnimexBrowseUsesNativePaginationGenresAndSortingWithoutAniList() async throws {
        CatalogDiscoveryProtocol.reset()
        let result = try await api().discover(.animex, page: 2, order: .trending, genre: "Fantasy")
        XCTAssertEqual(result.anime.first?.sourceID, "fixture-source-id")
        XCTAssertTrue(result.hasMore)
        let requests = CatalogDiscoveryProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.host, "graphql.animex.one")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://animex.one")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let variables = try XCTUnwrap(body["variables"] as? [String: Any])
        XCTAssertEqual(variables["offset"] as? Int, 30)
        XCTAssertEqual(variables["limit"] as? Int, 30)
        let filter = try XCTUnwrap(variables["filter"] as? [String: Any])
        XCTAssertNil(filter["query"])
        XCTAssertEqual(filter["genres"] as? [String], ["Fantasy"])
        XCTAssertEqual(filter["isAdult"] as? Bool, false)
        let sort = try XCTUnwrap((variables["sort"] as? [[String: String]])?.first)
        XCTAssertEqual(sort["field"], "TRENDING")
        XCTAssertEqual(sort["direction"], "DESC")
    }
    func testAnimexFailureDoesNotSilentlyRequestAnotherCatalog() async throws {
        CatalogDiscoveryProtocol.reset(deny: true)
        do {
            _ = try await api().discover(.animex, page: 1, order: .popular, genre: "All")
            XCTFail("A denied source should return its own error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("graphql.animex.one"))
            XCTAssertTrue(error.localizedDescription.contains("403"))
        }
        XCTAssertEqual(CatalogDiscoveryProtocol.requests().map { $0.url?.host }, ["graphql.animex.one"])
    }
    func testShortAnimexSearchExplainsMinimumBeforeSendingARequest() async throws {
        CatalogDiscoveryProtocol.reset()
        do { _ = try await api().search("an"); XCTFail("Animex requires at least 3 characters") }
        catch { XCTAssertTrue(error.localizedDescription.contains("3 characters")) }
        XCTAssertTrue(CatalogDiscoveryProtocol.requests().isEmpty)
    }
}
