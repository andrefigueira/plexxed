import Foundation

// MARK: - Containers

struct Envelope<C: Decodable>: Decodable {
    let container: C
    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
}

struct MetadataList: Decodable {
    let items: [PlexItem]
    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: AnyKey.self).list("Metadata")
    }
}

struct DirectoryList: Decodable {
    let sections: [LibrarySection]
    init(from decoder: Decoder) throws {
        sections = try decoder.container(keyedBy: AnyKey.self).list("Directory")
    }
}

struct HubList: Decodable {
    let hubs: [Hub]
    init(from decoder: Decoder) throws {
        hubs = try decoder.container(keyedBy: AnyKey.self).list("Hub")
    }
}

// MARK: - Library

struct LibrarySection: Decodable, Identifiable, Hashable, Sendable {
    let key: String
    let type: String
    let title: String
    let hidden: Bool

    var id: String { key }
    var isVideo: Bool { type == "movie" || type == "show" }
    var symbol: String { type == "show" ? "tv" : "film" }
    /// Plex's numeric item type for `/all?type=`.
    var itemType: Int { type == "show" ? 2 : 1 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let key = c.string("key") else { throw missingField("key", decoder) }
        self.key = key
        type = c.string("type") ?? ""
        title = c.string("title") ?? "Library"
        hidden = c.bool("hidden") ?? false
    }
}

struct Hub: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let identifier: String
    var items: [PlexItem]

    var isContinueWatching: Bool {
        identifier.contains("continue") || identifier.contains("ondeck")
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        title = c.string("title") ?? ""
        identifier = c.string("hubIdentifier") ?? ""
        id = c.string("hubKey") ?? c.string("key") ?? identifier + title
        items = (c.list("Metadata") as [PlexItem]).filter(\.isVideo)
    }
}

// MARK: - Items

struct PlexItem: Decodable, Identifiable, Hashable, Sendable {
    let ratingKey: String
    /// Plex's global id (plex://movie/...). The same film in two libraries shares it.
    let guid: String?
    let type: String
    let title: String
    let titleSort: String?
    let summary: String?
    let tagline: String?
    let year: Int?
    let thumb: String?
    let art: String?
    let clearLogo: String?
    let duration: Int?
    var viewOffset: Int?
    var viewCount: Int?
    let addedAt: Int?
    let lastViewedAt: Int?
    let originallyAvailableAt: String?
    let contentRating: String?
    let rating: Double?
    let audienceRating: Double?
    let studio: String?
    let index: Int?
    let parentIndex: Int?
    let parentTitle: String?
    let parentRatingKey: String?
    let parentThumb: String?
    let grandparentTitle: String?
    let grandparentRatingKey: String?
    let grandparentThumb: String?
    let grandparentArt: String?
    let leafCount: Int?
    var viewedLeafCount: Int?
    let childCount: Int?
    let genres: [String]
    let directors: [String]
    let writers: [String]
    let cast: [String]
    let countries: [String]
    let media: [PlexMedia]
    let markers: [PlexMarker]
    let onDeck: [PlexItem]

    var id: String { ratingKey }

    static func == (a: PlexItem, b: PlexItem) -> Bool {
        a.ratingKey == b.ratingKey && a.viewOffset == b.viewOffset
            && a.viewCount == b.viewCount && a.viewedLeafCount == b.viewedLeafCount
    }

    func hash(into hasher: inout Hasher) { hasher.combine(ratingKey) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let ratingKey = c.string("ratingKey") else { throw missingField("ratingKey", decoder) }
        self.ratingKey = ratingKey
        guid = c.string("guid")
        type = c.string("type") ?? ""
        title = c.string("title") ?? ""
        titleSort = c.string("titleSort")
        summary = c.string("summary")
        tagline = c.string("tagline")
        year = c.int("year")
        thumb = c.string("thumb")
        art = c.string("art")
        duration = c.int("duration")
        viewOffset = c.int("viewOffset")
        viewCount = c.int("viewCount")
        addedAt = c.int("addedAt")
        lastViewedAt = c.int("lastViewedAt")
        originallyAvailableAt = c.string("originallyAvailableAt")
        contentRating = c.string("contentRating")
        rating = c.double("rating")
        audienceRating = c.double("audienceRating")
        studio = c.string("studio")
        index = c.int("index")
        parentIndex = c.int("parentIndex")
        parentTitle = c.string("parentTitle")
        parentRatingKey = c.string("parentRatingKey")
        parentThumb = c.string("parentThumb")
        grandparentTitle = c.string("grandparentTitle")
        grandparentRatingKey = c.string("grandparentRatingKey")
        grandparentThumb = c.string("grandparentThumb")
        grandparentArt = c.string("grandparentArt")
        leafCount = c.int("leafCount")
        viewedLeafCount = c.int("viewedLeafCount")
        childCount = c.int("childCount")
        genres = c.tags("Genre")
        directors = c.tags("Director")
        writers = c.tags("Writer")
        cast = c.tags("Role")
        countries = c.tags("Country")
        media = c.list("Media")
        markers = c.list("Marker")
        let images: [PlexImageRef] = c.list("Image")
        clearLogo = images.first { $0.type == "clearLogo" }?.url
        // Shows fetched with includeOnDeck=1 carry their next episode here.
        if let deck = try? c.decodeIfPresent(MetadataList.self, forKey: AnyKey("OnDeck")) {
            onDeck = deck.items
        } else {
            onDeck = []
        }
    }
}

struct PlexImageRef: Decodable {
    let type: String
    let url: String
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        type = c.string("type") ?? ""
        url = c.string("url") ?? ""
    }
}

struct PlexMedia: Decodable, Hashable, Sendable {
    let id: Int?
    let width: Int?
    let height: Int?
    let videoResolution: String?
    let videoCodec: String?
    let audioCodec: String?
    let audioChannels: Int?
    let container: String?
    let parts: [PlexPart]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("id")
        width = c.int("width")
        height = c.int("height")
        videoResolution = c.string("videoResolution")
        videoCodec = c.string("videoCodec")
        audioCodec = c.string("audioCodec")
        audioChannels = c.int("audioChannels")
        container = c.string("container")
        parts = c.list("Part")
    }
}

struct PlexPart: Decodable, Hashable, Sendable {
    let id: Int
    let key: String
    let file: String?
    let size: Int64?
    let streams: [PlexStream]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("id"), let key = c.string("key") else { throw missingField("Part.key", decoder) }
        self.id = id
        self.key = key
        file = c.string("file")
        size = c.int("size").map(Int64.init)
        streams = c.list("Stream")
    }
}

struct PlexStream: Decodable, Hashable, Sendable {
    enum Kind: Int { case video = 1, audio = 2, subtitle = 3 }

    let id: Int
    let kind: Kind?
    let index: Int?
    let codec: String?
    let language: String?
    let languageCode: String?
    let title: String?
    let displayTitle: String?
    let extendedDisplayTitle: String?
    let selected: Bool
    let isDefault: Bool
    let forced: Bool
    /// Sidecar subtitles (an .srt next to the file) have a key; embedded tracks don't.
    let key: String?
    let colorTrc: String?
    let doviPresent: Bool

    var isExternal: Bool { key != nil }
    var isHDR: Bool { doviPresent || colorTrc == "smpte2084" || colorTrc == "arib-std-b67" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("id") else { throw missingField("Stream.id", decoder) }
        self.id = id
        kind = c.int("streamType").flatMap(Kind.init(rawValue:))
        index = c.int("index")
        codec = c.string("codec")
        language = c.string("language")
        languageCode = c.string("languageCode")
        title = c.string("title")
        displayTitle = c.string("displayTitle")
        extendedDisplayTitle = c.string("extendedDisplayTitle")
        selected = c.bool("selected") ?? false
        isDefault = c.bool("default") ?? false
        forced = c.bool("forced") ?? false
        key = c.string("key")
        colorTrc = c.string("colorTrc")
        doviPresent = c.bool("DOVIPresent") ?? false
    }
}

struct PlexMarker: Decodable, Hashable, Sendable {
    let type: String
    let start: Double
    let end: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        type = c.string("type") ?? ""
        start = Double(c.int("startTimeOffset") ?? 0) / 1000
        end = Double(c.int("endTimeOffset") ?? 0) / 1000
    }
}

// MARK: - plex.tv

struct PlexPin: Decodable {
    let id: Int
    let code: String
    let authToken: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("id"), let code = c.string("code") else { throw missingField("pin", decoder) }
        self.id = id
        self.code = code
        authToken = c.string("authToken")
    }
}

struct PlexResource: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let clientIdentifier: String
    let provides: String
    let owned: Bool
    let accessToken: String?
    let httpsRequired: Bool
    let presence: Bool
    let connections: [PlexConnection]

    var id: String { clientIdentifier }
    var isServer: Bool { provides.split(separator: ",").contains("server") }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.string("clientIdentifier") else { throw missingField("clientIdentifier", decoder) }
        clientIdentifier = id
        name = c.string("name") ?? "Plex Media Server"
        provides = c.string("provides") ?? ""
        owned = c.bool("owned") ?? false
        accessToken = c.string("accessToken")
        httpsRequired = c.bool("httpsRequired") ?? false
        presence = c.bool("presence") ?? false
        connections = c.list("connections")
    }
}

struct PlexConnection: Decodable, Hashable, Sendable {
    let uri: String
    let address: String
    let port: Int
    let local: Bool
    let relay: Bool
    let ipv6: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let uri = c.string("uri") else { throw missingField("uri", decoder) }
        self.uri = uri
        address = c.string("address") ?? ""
        port = c.int("port") ?? 32400
        local = c.bool("local") ?? false
        relay = c.bool("relay") ?? false
        ipv6 = c.bool("IPv6") ?? false
    }
}

// MARK: - History

/// One play from the server's watch history.
struct HistoryEntry: Decodable, Sendable {
    let ratingKey: String
    /// The movie, or the show an episode belongs to.
    let titleKey: String
    let viewedAt: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let key = c.string("ratingKey") ?? c.string("key").map { String($0.split(separator: "/").last ?? "") }
        guard let key, !key.isEmpty else { throw missingField("ratingKey", decoder) }
        ratingKey = key
        let show = c.string("grandparentRatingKey")
            ?? c.string("grandparentKey").map { String($0.split(separator: "/").last ?? "") }
        titleKey = c.string("type") == "episode" ? (show ?? key) : key
        viewedAt = c.int("viewedAt") ?? 0
    }
}

struct HistoryList: Decodable {
    let entries: [HistoryEntry]
    init(from decoder: Decoder) throws {
        entries = try decoder.container(keyedBy: AnyKey.self).list("Metadata")
    }
}
