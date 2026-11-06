import Foundation

extension PlexItem {
    var isVideo: Bool { ["movie", "show", "season", "episode"].contains(type) }
    var isMovie: Bool { type == "movie" }
    var isShow: Bool { type == "show" }
    var isSeason: Bool { type == "season" }
    var isEpisode: Bool { type == "episode" }
    /// Movies and episodes can be played. Shows and seasons are containers.
    var isPlayable: Bool { isMovie || isEpisode }

    var isWatched: Bool {
        if isShow || isSeason {
            guard let leaves = leafCount, leaves > 0 else { return false }
            return (viewedLeafCount ?? 0) >= leaves
        }
        return (viewCount ?? 0) > 0 && (viewOffset ?? 0) == 0
    }

    /// 0...1 for partly watched items, nil otherwise.
    var progress: Double? {
        guard let offset = viewOffset, offset > 0, let duration, duration > 0 else { return nil }
        return min(Double(offset) / Double(duration), 1)
    }

    var remainingMs: Int? {
        guard let offset = viewOffset, offset > 0, let duration else { return nil }
        return max(duration - offset, 0)
    }

    var unwatchedEpisodes: Int? {
        guard isShow || isSeason, let leaves = leafCount else { return nil }
        let left = leaves - (viewedLeafCount ?? 0)
        return left > 0 ? left : nil
    }

    var episodeLabel: String? {
        guard isEpisode, let season = parentIndex, let episode = index else { return nil }
        return "S\(season) E\(episode)"
    }

    var sortTitle: String { titleSort ?? title }

    /// The show this item belongs to (the item itself for shows).
    var showRatingKey: String? {
        switch type {
        case "episode": grandparentRatingKey
        case "season": parentRatingKey
        case "show": ratingKey
        default: nil
        }
    }

    var posterPath: String? {
        switch type {
        case "episode": grandparentThumb ?? parentThumb ?? thumb
        case "season": thumb ?? parentThumb
        default: thumb
        }
    }

    /// 16:9 artwork: an episode's own still, otherwise the backdrop.
    var landscapePath: String? {
        isEpisode ? (thumb ?? grandparentArt ?? art) : (art ?? thumb)
    }

    var backdropPath: String? {
        isEpisode ? (grandparentArt ?? art) : art
    }

    /// The name people recognise: the show for episodes and seasons.
    var headline: String {
        switch type {
        case "episode": grandparentTitle ?? title
        case "season": parentTitle ?? title
        default: title
        }
    }

    var caption: String {
        switch type {
        case "episode":
            [episodeLabel, title].compactMap { $0 }.joined(separator: "  ")
        case "season":
            title
        case "show":
            if let seasons = childCount { seasons == 1 ? "1 season" : "\(seasons) seasons" } else { year.map(String.init) ?? "" }
        default:
            year.map(String.init) ?? ""
        }
    }

    /// The first file of the first version. Plex lists the preferred version first.
    var primaryPart: PlexPart? { media.first?.parts.first }

    var streams: [PlexStream] { primaryPart?.streams ?? [] }

    var qualityLabel: String? {
        guard let media = media.first else { return nil }
        var parts: [String] = []
        if let res = media.videoResolution?.lowercased() {
            switch res {
            case "4k": parts.append("4K")
            case "sd": parts.append("SD")
            default: parts.append(res.hasSuffix("p") ? res : "\(res)p")
            }
        }
        if streams.contains(where: { $0.kind == .video && $0.isHDR }) {
            parts.append(streams.contains(where: { $0.doviPresent }) ? "Dolby Vision" : "HDR")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
