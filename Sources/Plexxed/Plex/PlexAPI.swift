import AppKit
import Foundation
import SystemConfiguration

enum PlexError: LocalizedError {
    case unauthorized
    case http(Int)
    case network(String)
    case decoding
    case noServers
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your Plex sign-in has expired. Sign in again to continue."
        case .http(let code): "The server answered with error \(code)."
        case .network(let message): message
        case .decoding: "The server sent something Plexxed couldn't read."
        case .noServers: "This Plex account has no media servers linked to it."
        case .unreachable(let name): "Couldn't reach \(name) on any of its addresses."
        }
    }
}

// MARK: - HTTP

enum PlexClient {
    static let product = "Plexxed"
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"

    /// Stable per install. Plex uses it to recognise this app as one device.
    static let identifier: String = {
        let key = "plexClientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    static let deviceName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func headers(token: String?) -> [String: String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var headers = [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": identifier,
            "X-Plex-Platform": "macOS",
            "X-Plex-Platform-Version": "\(os.majorVersion).\(os.minorVersion)",
            "X-Plex-Device": "Mac",
            "X-Plex-Device-Name": deviceName,
            "X-Plex-Model": product,
        ]
        if let token { headers["X-Plex-Token"] = token }
        return headers
    }

    static func request(
        _ url: URL,
        token: String?,
        method: String = "GET",
        timeout: TimeInterval = 20,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (name, value) in headers(token: token).merging(extraHeaders, uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PlexError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw PlexError.network("No response from server.") }
        if http.statusCode == 401 { throw PlexError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            Log.error("HTTP \(http.statusCode) for \(method) \(url.path)")
            throw PlexError.http(http.statusCode)
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.error("Decoding \(T.self) failed: \(error)")
            throw PlexError.decoding
        }
    }

    /// Strict RFC 3986 unreserved set, plus "/" so Plex paths stay readable.
    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    )

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }

    static func query(_ items: [String: String]) -> String {
        items.sorted { $0.key < $1.key }
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
    }
}

// MARK: - plex.tv

enum PlexTV {
    private static let base = "https://plex.tv/api/v2"

    static func createPin() async throws -> PlexPin {
        let data = try await PlexClient.request(URL(string: "\(base)/pins?strong=true")!, token: nil, method: "POST")
        return try PlexClient.decode(PlexPin.self, from: data)
    }

    static func pin(id: Int) async throws -> PlexPin {
        let data = try await PlexClient.request(URL(string: "\(base)/pins/\(id)")!, token: nil)
        return try PlexClient.decode(PlexPin.self, from: data)
    }

    static func authURL(code: String) -> URL {
        let params = PlexClient.query([
            "clientID": PlexClient.identifier,
            "code": code,
            "context[device][product]": PlexClient.product,
        ])
        return URL(string: "https://app.plex.tv/auth#?\(params)")!
    }

    static func resources(token: String) async throws -> [PlexResource] {
        let url = URL(string: "\(base)/resources?includeHttps=1&includeRelay=1")!
        let data = try await PlexClient.request(url, token: token)
        return try PlexClient.decode(LossyArray<PlexResource>.self, from: data).items
    }
}

// MARK: - Connecting

enum ServerConnector {
    /// Tries every address a server publishes at once and keeps the first that answers.
    /// Plain HTTP on the LAN goes first with a head start: TLS costs a weak NAS CPU on every byte streamed.
    static func connect(_ resource: PlexResource, userToken: String) async -> PlexServer? {
        let token = resource.accessToken ?? userToken
        var local: [Candidate] = []
        var remote: [Candidate] = []
        for connection in resource.connections where !connection.ipv6 {
            if connection.local, !resource.httpsRequired,
               let plain = URL(string: "http://\(connection.address):\(connection.port)") {
                local.append(Candidate(url: plain, delay: 0))
            }
            guard let uri = URL(string: connection.uri) else { continue }
            if connection.local {
                local.append(Candidate(url: uri, delay: 200))
            } else {
                remote.append(Candidate(url: uri, delay: connection.relay ? 1500 : 0))
            }
        }
        var seen = Set<URL>()
        local = local.filter { seen.insert($0.url).inserted }
        remote = remote.filter { seen.insert($0.url).inserted }

        func connected(_ url: URL) -> PlexServer {
            Log.info("Connected to \(resource.name) at \(url.host() ?? "?")")
            return PlexServer(name: resource.name, machineID: resource.clientIdentifier, baseURL: url, token: token)
        }

        if let url = await firstReachable(local, token: token, timeout: 4) { return connected(url) }

        // The first LAN request can be held by macOS's Local Network prompt. Keep retrying the LAN
        // for a few seconds before settling for a remote route, which is slower and may be a capped relay.
        let remoteCandidates = remote
        async let fallback = firstReachable(remoteCandidates, token: token, timeout: 6)
        if !local.isEmpty {
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1))
                if let url = await firstReachable(local.map { Candidate(url: $0.url, delay: 0) }, token: token, timeout: 2) {
                    return connected(url)
                }
            }
        }
        return await fallback.map(connected)
    }

    struct Candidate: Sendable {
        let url: URL
        let delay: Int
    }

    /// Probes every candidate at once (after its head-start delay) and returns the first that answers.
    private static func firstReachable(_ candidates: [Candidate], token: String, timeout: TimeInterval) async -> URL? {
        guard !candidates.isEmpty else { return nil }
        return await withTaskGroup(of: URL?.self) { group in
            for candidate in candidates {
                group.addTask {
                    if candidate.delay > 0 { try? await Task.sleep(for: .milliseconds(candidate.delay)) }
                    if Task.isCancelled { return nil }
                    return await probe(candidate.url, token: token, timeout: timeout) ? candidate.url : nil
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    static func probe(_ url: URL, token: String, timeout: TimeInterval) async -> Bool {
        do {
            _ = try await PlexClient.request(url.appending(path: "identity"), token: token, timeout: timeout)
            return true
        } catch is CancellationError {
            return false
        } catch let error as URLError where error.code == .cancelled {
            return false
        } catch {
            Log.info("No answer from \(url.host() ?? "?") in \(timeout) s: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Server

struct PlexServer: Codable, Hashable, Sendable {
    let name: String
    let machineID: String
    let baseURL: URL
    let token: String

    func with(baseURL: URL) -> PlexServer {
        PlexServer(name: name, machineID: machineID, baseURL: baseURL, token: token)
    }

    /// For a LAN address like https://192-168-1-10.<hash>.plex.direct:32400, the same server over
    /// plain HTTP. It needs no DNS, so it keeps working when the internet is down.
    var plainLANURL: URL? {
        guard let host = baseURL.host(), host.hasSuffix(".plex.direct"),
              let label = host.split(separator: ".").first else { return nil }
        let ip = label.replacingOccurrences(of: "-", with: ".")
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return nil }
        let isPrivate = octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1]))
        guard isPrivate else { return nil }
        return URL(string: "http://\(ip):\(baseURL.port ?? 32400)")
    }

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var string = baseURL.absoluteString
        if string.hasSuffix("/") { string.removeLast() }
        string += path
        if !query.isEmpty {
            string += (path.contains("?") ? "&" : "?") + PlexClient.query(query)
        }
        return URL(string: string)!
    }

    func data(_ path: String, _ query: [String: String] = [:], method: String = "GET") async throws -> Data {
        try await PlexClient.request(url(path, query), token: token, method: method)
    }

    private func items(_ path: String, _ query: [String: String] = [:]) async throws -> [PlexItem] {
        try PlexClient.decode(Envelope<MetadataList>.self, from: try await data(path, query)).container.items
    }

    // Library

    func sectionsData() async throws -> Data {
        try await data("/library/sections")
    }

    static func decodeSections(_ data: Data) -> [LibrarySection]? {
        (try? JSONDecoder().decode(Envelope<DirectoryList>.self, from: data))?.container.sections
    }

    func sectionItemsData(_ section: LibrarySection) async throws -> Data {
        try await data("/library/sections/\(section.key)/all", [
            "type": String(section.itemType),
            "includeGuids": "0",
        ])
    }

    func hubsData() async throws -> Data {
        try await data("/hubs", ["count": "20", "includeLibraryPlaylists": "0", "includeExternalMedia": "0"])
    }

    static func decodeHubs(_ data: Data) -> [Hub]? {
        (try? JSONDecoder().decode(Envelope<HubList>.self, from: data))?.container.hubs
    }

    func metadata(_ ratingKey: String) async throws -> PlexItem? {
        try await items("/library/metadata/\(ratingKey)", [
            "includeMarkers": "1",
            "includeOnDeck": "1",
            "includeChapters": "0",
            "includeExtras": "0",
        ]).first
    }

    func children(_ ratingKey: String) async throws -> [PlexItem] {
        try await items("/library/metadata/\(ratingKey)/children")
    }

    func allEpisodes(ofShow ratingKey: String) async throws -> [PlexItem] {
        try await items("/library/metadata/\(ratingKey)/allLeaves")
    }

    /// The most recent plays across the server, newest first.
    func historyData(limit: Int = 1500) async throws -> Data {
        try await data("/status/sessions/history/all", [
            "sort": "viewedAt:desc",
            "X-Plex-Container-Start": "0",
            "X-Plex-Container-Size": String(limit),
        ])
    }

    static func decodeHistory(_ data: Data) -> [HistoryEntry]? {
        (try? JSONDecoder().decode(Envelope<HistoryList>.self, from: data))?.container.entries
    }

    /// Plex's own "more like this" list for an item.
    func similar(_ ratingKey: String) async throws -> [String] {
        try await items("/library/metadata/\(ratingKey)/similar", ["count": "30"]).map(\.ratingKey)
    }

    func search(_ query: String) async throws -> [Hub] {
        let data = try await data("/hubs/search", [
            "query": query,
            "limit": "24",
            "includeCollections": "0",
            "includeExternalMedia": "0",
        ])
        return try PlexClient.decode(Envelope<HubList>.self, from: data).container.hubs
    }

    // Watch state

    func setWatched(_ ratingKey: String, _ watched: Bool) async throws {
        _ = try await data(watched ? "/:/scrobble" : "/:/unscrobble", [
            "identifier": "com.plexapp.plugins.library",
            "key": ratingKey,
        ])
    }

    func reportTimeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int, sessionID: String) async {
        let url = url("/:/timeline", [
            "ratingKey": ratingKey,
            "key": "/library/metadata/\(ratingKey)",
            "state": state,
            "time": String(timeMs),
            "duration": String(durationMs),
            "playbackTime": String(timeMs),
            "identifier": "com.plexapp.plugins.library",
            "context": "library",
        ])
        _ = try? await PlexClient.request(url, token: token, timeout: 8, extraHeaders: ["X-Plex-Session-Identifier": sessionID])
    }

    /// Saves the chosen audio or subtitle track on the server so every Plex app remembers it.
    func selectStreams(partID: Int, audioStreamID: Int? = nil, subtitleStreamID: Int? = nil) async {
        var query = ["allParts": "1"]
        if let audioStreamID { query["audioStreamID"] = String(audioStreamID) }
        if let subtitleStreamID { query["subtitleStreamID"] = String(subtitleStreamID) }
        _ = try? await data("/library/parts/\(partID)", query, method: "PUT")
    }

    // Media URLs

    /// The original file. mpv streams it with range requests, so the server never transcodes.
    func mediaURL(_ partKey: String) -> URL { url(partKey) }

    /// Artwork resized by the server once (it caches the result), then cached on disk here.
    func image(_ path: String?, width: Int, height: Int) -> ImageRequest? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") {
            guard let url = URL(string: path) else { return nil }
            return ImageRequest(url: url, token: nil, cacheKey: "\(path)@\(width)", maxPixel: max(width, height))
        }
        let url = url("/photo/:/transcode", [
            "width": String(width),
            "height": String(height),
            "minSize": "1",
            "upscale": "1",
            "url": path,
        ])
        return ImageRequest(url: url, token: token, cacheKey: "\(machineID)\(path)@\(width)x\(height)", maxPixel: max(width, height))
    }

    /// Transparent title logos must skip the transcoder, which outputs JPEG.
    func rawImage(_ path: String?, maxPixel: Int) -> ImageRequest? {
        guard let path, !path.isEmpty else { return nil }
        let url = path.hasPrefix("http") ? URL(string: path) : url(path)
        guard let url else { return nil }
        return ImageRequest(url: url, token: path.hasPrefix("http") ? nil : token, cacheKey: "\(machineID)\(path)@raw\(maxPixel)", maxPixel: maxPixel)
    }
}

// MARK: - Image sizes

enum ArtSize {
    static let poster = (width: 360, height: 540)
    static let landscape = (width: 640, height: 360)
    static let still = (width: 480, height: 270)
    static let backdrop = (width: 1920, height: 1080)
}
