import Foundation
import CryptoKit
import CommonCrypto

/// The site returns an embed, encoded playlists, and image-wrapped media. Resolve
/// those on the device; WebKit is used only as a disposable WASM sandbox, never a player.
struct ReAnimeMedia: Equatable {
    let url: URL
    let playlistKey: Data?
    static let headers = ["User-Agent": "Mozilla/5.0", "Referer": "https://flixcloud.cc/", "Origin": "https://flixcloud.cc"]
    static func permits(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "flixcloud.cc" || host.hasSuffix(".flixcloud.cc")
            || host.hasSuffix(".rundowncdn.top")
    }
    func playlist(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), text.hasPrefix("#EXTM3U") { return text }
        guard data.count <= 2_000_000, let encoded = String(data: data, encoding: .utf8),
              var bytes = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = playlistKey, !key.isEmpty else { throw KairoError.message("ReAnime returned an unsupported playlist.") }
        for index in bytes.indices { bytes[index] ^= key[index % key.count] }
        guard let text = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), text.hasPrefix("#EXTM3U") else {
            throw KairoError.message("ReAnime's playlist format changed. Try another server.")
        }
        return text
    }
    static func unwrap(_ data: Data) -> Data {
        let webp = data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data.subdata(in: 8..<12) == Data("WEBP".utf8)
        let png = data.starts(with: [137,80,78,71,13,10,26,10])
        let offset = webp ? 12 : png ? 8 : 0
        guard offset > 0 else { return data }
        var bytes = Data(data.dropFirst(offset))
        let mask: [UInt8] = [157,42,241,71,179,142,92,112,166,25,228,59,216,98,15,197]
        // AES ciphertext may coincidentally start with 0x47. Confirm multiple
        // TS sync bytes before treating an image payload as already clear.
        let clearTransport = bytes.count > 376 && bytes[0] == 0x47 && bytes[188] == 0x47 && bytes[376] == 0x47
        if !clearTransport { for index in bytes.indices { bytes[index] ^= mask[index % mask.count] } }
        return bytes
    }
}

actor ReAnimeNativeResolver {
    static let shared = ReAnimeNativeResolver()
    private let session: URLSession
    private var cache: [URL: (Date, ReAnimeMedia)] = [:]
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        session = URLSession(configuration: configuration, delegate: ReAnimeRedirects(), delegateQueue: nil)
    }
    func resolve(_ embed: URL) async throws -> ReAnimeMedia {
        guard embed.scheme == "https", embed.host == "flixcloud.cc", embed.path.hasPrefix("/e/"),
              ["1", "2"].contains(URLComponents(url: embed, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value ?? "") else {
            throw KairoError.message("Unsupported ReAnime player address.")
        }
        if let cached = cache[embed], Date().timeIntervalSince(cached.0) < 240 { return cached.1 }
        let (html, _) = try await fetch(embed, limit: 2_000_000)
        let literal = try Self.pageLiteral(String(decoding: html, as: UTF8.self))
        let parsed = try await ModuleRunner.execute(script: ReAnimeJavaScript.json5 + "\nfunction extractDetails(input) { return JSON5.parse(input); }",
            function: "extractDetails", argument: Self.normalize(literal), timeout: 15)
        guard let root = try JSONSerialization.jsonObject(with: Data(parsed.utf8)) as? [String: Any],
              let seed = root["obfuscation_seed"] as? String, seed.count >= 8, seed.count < 512,
              seed.allSatisfy({ $0.isHexDigit }), let wasm = root["w_payload"] as? String, wasm.count < 1_000_000 else {
            throw KairoError.message("ReAnime changed its player metadata.")
        }
        var first = seed
        for index in 0..<3 { first = Self.hash(first + String(index)) }
        var second = first
        for index in 0..<3 { second = Self.hash(second + String(index)) }
        func piece(_ text: String, _ start: Int, _ end: Int) -> String { String(Array(text)[start..<end]) }
        let container = "cd_" + piece(first, 24, 32), array = "ad_" + piece(first, 32, 40), object = "od_" + piece(first, 40, 48)
        let crypto = root["obfuscated_crypto_data"] as? [String: Any]
        let values = ((crypto?[container] as? [String: Any])?[array] as? [[String: Any]])?.first?[object] as? [String: Any]
        let tokenField = piece(first, 48, 64) + "_" + piece(first, 56, 64)
        guard let token = root[tokenField] as? String, !token.isEmpty, token.count < 2048,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }),
              let fragment = values?["kf_" + piece(first, 8, 16)] as? String,
              let ivText = values?["ivf_" + piece(first, 16, 24)] as? String,
              let other = root[piece(second, 0, 16) + "_" + piece(second, 16, 24)] as? String else {
            throw KairoError.message("ReAnime did not provide native media information.")
        }
        let (reply, _) = try await fetch(URL(string: "https://flixcloud.cc/api/m3u8/\(token)")!, limit: 1_000_000)
        guard let payload = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let encryptedText = payload[String(Self.hash(token + "vid").prefix(10))] as? String,
              let third = payload[String(Self.hash(token + "key").prefix(10))] as? String,
              let encrypted = Data(base64Encoded: encryptedText), let iv = Data(base64Encoded: ivText), iv.count == 16 else {
            throw KairoError.message("ReAnime returned incomplete media information.")
        }
        let input = try JSONSerialization.data(withJSONObject: ["wasm": wasm, "first": fragment, "second": other, "third": third, "seed": seed])
        let transformed = try await ModuleRunner.execute(script: ReAnimeJavaScript.transform, function: "extractDetails", argument: String(decoding: input, as: UTF8.self), timeout: 15)
        guard let result = try JSONSerialization.jsonObject(with: Data(transformed.utf8)) as? [String: Any],
              let materialText = result["material"] as? String, let material = Data(base64Encoded: materialText) else {
            throw KairoError.message("ReAnime's media transform failed.")
        }
        let key = try Self.derive(material, seed: seed)
        let clear = try Self.decrypt(encrypted, key: key, iv: iv)
        guard let text = String(data: clear, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), ReAnimeMedia.permits(url), url.pathExtension == "m3u8" else {
            throw KairoError.message("ReAnime returned an unsupported media host.")
        }
        let playlistKey = (result["playlistKey"] as? String).flatMap { Data(base64Encoded: $0) }
        let media = ReAnimeMedia(url: url, playlistKey: playlistKey)
        let (manifest, _) = try await fetch(url, limit: 2_000_000)
        _ = try media.playlist(manifest)
        if cache.count >= 50 { cache.removeAll() }
        cache[embed] = (Date(), media)
        return media
    }
    private func fetch(_ url: URL, limit: Int) async throws -> (Data, URL) {
        guard ReAnimeMedia.permits(url) else { throw KairoError.message("Unsupported ReAnime media host.") }
        var request = URLRequest(url: url); request.allHTTPHeaderFields = ReAnimeMedia.headers
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), bytes.count <= limit,
              let final = http.url, ReAnimeMedia.permits(final) else { throw KairoError.message("ReAnime media request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).") }
        return (bytes, final)
    }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func derive(_ material: Data, seed: String) throws -> Data {
        var key = Data(count: 32)
        let salt = Data(seed.utf8)
        let status = key.withUnsafeMutableBytes { output in material.withUnsafeBytes { password in salt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: Int8.self), material.count,
                salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1000,
                output.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
        } } }
        guard status == kCCSuccess else { throw KairoError.message("ReAnime key derivation failed.") }
        let seedBytes = Array(seed.utf8)
        for index in key.indices { key[index] ^= seedBytes[index % seedBytes.count] }
        return Data(SHA256.hash(data: key))
    }
    static func decrypt(_ encrypted: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw KairoError.message("Invalid ReAnime media key.") }
        var output = Data(count: encrypted.count + 16), count = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in encrypted.withUnsafeBytes { data in key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key.baseAddress, 32,
                iv.baseAddress, data.baseAddress, encrypted.count, out.baseAddress, capacity, &count)
        } } } }
        guard status == kCCSuccess else { throw KairoError.message("ReAnime's media format changed. Try another server.") }
        return output.prefix(count)
    }
    static func pageLiteral(_ html: String) throws -> String {
        guard let marker = html.range(of: #"\{type:"data",data:\s*\{"#, options: .regularExpression),
              let start = html[marker].lastIndex(of: "{") else { throw KairoError.message("ReAnime's player contains no media metadata.") }
        var depth = 0, quote: Character?, escaped = false
        for index in html.indices where index >= start {
            let c = html[index]
            if let current = quote {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == current { quote = nil }
            } else if c == "\"" || c == "'" { quote = c }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(html[start...index]) } }
        }
        throw KairoError.message("Incomplete ReAnime player metadata.")
    }
    static func normalize(_ source: String) -> String {
        // Only replace JS-only values outside strings; JSON5 parses data, not code.
        let chars = Array(source); var output = "", quote: Character?, escaped = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if let current = quote {
                output.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == current { quote = nil }
                i += 1; continue
            }
            if c == "\"" || c == "'" { quote = c; output.append(c); i += 1; continue }
            if String(chars[i...].prefix(9)) == "undefined", (i == 0 || !(chars[i-1].isLetter || chars[i-1].isNumber || chars[i-1] == "_")),
               (i+9 == chars.count || !(chars[i+9].isLetter || chars[i+9].isNumber || chars[i+9] == "_" || chars[i+9] == ":")) {
                output += "null"; i += 9; continue
            }
            if c == "!", i+1 < chars.count, chars[i+1] == "0" || chars[i+1] == "1" { output += chars[i+1] == "0" ? "true" : "false"; i += 2; continue }
            output.append(c); i += 1
        }
        return output
    }
}

final class ReAnimeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ReAnimeMedia.permits(url) else { completionHandler(nil); return }
        var clean = request; clean.allHTTPHeaderFields = ReAnimeMedia.headers; completionHandler(clean)
    }
}
