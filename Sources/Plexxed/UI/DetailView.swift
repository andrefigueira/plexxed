import SwiftUI

/// Movies get a single page. Shows, seasons and episodes all open the show page,
/// with the relevant season already selected.
struct DetailView: View {
    let item: PlexItem
    @Environment(AppModel.self) private var app
    @State private var full: PlexItem?
    @State private var seasons: [PlexItem] = []
    @State private var selectedSeason: String?
    @State private var episodes: [String: [PlexItem]] = [:]
    @State private var failure: String?
    @State private var summaryExpanded = false

    private var isShowPage: Bool { !item.isMovie }
    private var targetKey: String { item.showRatingKey ?? item.ratingKey }
    /// What the header shows before the full record arrives.
    private var header: PlexItem? { full ?? (item.isShow || item.isMovie ? item : nil) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Backdrop(
                    request: app.server?.image(full?.art ?? item.backdropPath, width: ArtSize.backdrop.width, height: ArtSize.backdrop.height),
                    height: 520
                )
                VStack(alignment: .leading, spacing: 40) {
                    overview
                    if isShowPage { seasonSection }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, -190)
                .padding(.bottom, 56)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
        .navigationTitle(header?.title ?? item.headline)
        .task(id: "\(targetKey)-\(app.revision)") { await loadMain() }
        .task(id: "\(selectedSeason ?? "")-\(app.revision)") { await loadEpisodes() }
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            TitleArt(title: header?.title ?? item.headline, logo: app.server?.rawImage(full?.clearLogo, maxPixel: 900))
            MetaLine(values: metaValues)
            actions.padding(.top, 2)
            if let summary = header?.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary)
                        .font(.body13)
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(3)
                        .lineLimit(summaryExpanded ? nil : 4)
                        .frame(maxWidth: 660, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if summary.count > 320 {
                        TextButton(summaryExpanded ? "Less" : "More") {
                            withAnimation(.calm) { summaryExpanded.toggle() }
                        }
                    }
                }
            }
            credits
            if let failure {
                Text(failure).font(.body13).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var metaValues: [String] {
        guard let header else { return [] }
        var values: [String] = []
        if let year = header.year { values.append(String(year)) }
        if header.isMovie, let runtime = Format.runtime(ms: header.duration) { values.append(runtime) }
        if header.isShow, let count = header.childCount { values.append(count == 1 ? "1 season" : "\(count) seasons") }
        if let rating = header.contentRating { values.append(rating) }
        if let score = header.audienceRating ?? header.rating { values.append(String(format: "%.1f rating", score)) }
        if header.isMovie, let quality = header.qualityLabel { values.append(quality) }
        return values
    }

    @ViewBuilder
    private var credits: some View {
        if let header {
            VStack(alignment: .leading, spacing: 4) {
                if !header.cast.isEmpty {
                    Text("Starring \(header.cast.prefix(4).joined(separator: ", "))")
                }
                if !header.directors.isEmpty {
                    Text("Directed by \(header.directors.prefix(2).joined(separator: ", "))")
                }
                if !header.genres.isEmpty {
                    Text(header.genres.prefix(3).joined(separator: ", "))
                }
            }
            .font(.body13)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .frame(maxWidth: 660, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            if let target = playTarget {
                PrimaryButton(playLabel(for: target), systemImage: "play.fill") { app.play(target) }
                if target.progress != nil {
                    SecondaryButton("From the beginning", systemImage: "backward.end.fill") {
                        app.play(target, fromStart: true)
                    }
                }
            } else {
                PrimaryButton("Play", systemImage: "play.fill") {}
                    .disabled(true)
                    .opacity(0)
            }
            if let header {
                IconButton(
                    systemImage: header.isWatched ? "checkmark.circle.fill" : "checkmark.circle",
                    help: header.isWatched ? "Mark as unwatched" : "Mark as watched"
                ) {
                    app.setWatched(header, !header.isWatched)
                }
            }
        }
    }

    /// The movie itself, or for a show: the episode Plex has on deck, else the first unwatched one.
    private var playTarget: PlexItem? {
        guard let header else { return nil }
        if header.isMovie { return header }
        if let deck = header.onDeck.first { return deck }
        let current = selectedSeason.flatMap { episodes[$0] } ?? []
        return current.first { !$0.isWatched } ?? current.first
    }

    private func playLabel(for target: PlexItem) -> String {
        let verb = target.progress != nil ? "Resume" : "Play"
        guard target.isEpisode, let label = target.episodeLabel else { return verb }
        return "\(verb) \(label)"
    }

    // MARK: Seasons

    @ViewBuilder
    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(seasons) { season in
                            SeasonTab(title: season.title, selected: season.ratingKey == selectedSeason) {
                                selectedSeason = season.ratingKey
                            }
                        }
                    }
                }
            } else if let only = seasons.first {
                Text(only.title).font(.heading).foregroundStyle(Theme.textPrimary)
            }

            if let key = selectedSeason, let list = episodes[key] {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(list) { episode in
                        EpisodeRow(episode: episode)
                    }
                }
                .padding(.horizontal, -12)
            } else if !seasons.isEmpty {
                ProgressView().controlSize(.small).padding(.vertical, 24)
            }
        }
    }

    // MARK: Loading

    private func loadMain() async {
        guard let server = app.server else { return }
        do {
            async let metadata = server.metadata(targetKey)
            if isShowPage {
                let children = try await server.children(targetKey).filter(\.isSeason)
                seasons = children
                if selectedSeason == nil || !children.contains(where: { $0.ratingKey == selectedSeason }) {
                    selectedSeason = initialSeason(in: children)
                }
            }
            full = try await metadata
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }

    private func initialSeason(in seasons: [PlexItem]) -> String? {
        if item.isSeason { return item.ratingKey }
        if item.isEpisode, let parent = item.parentRatingKey { return parent }
        return seasons.first { !$0.isWatched && ($0.index ?? 0) > 0 }?.ratingKey
            ?? seasons.first { ($0.index ?? 0) > 0 }?.ratingKey
            ?? seasons.first?.ratingKey
    }

    private func loadEpisodes() async {
        guard let key = selectedSeason, let server = app.server else { return }
        do {
            episodes[key] = try await server.children(key).filter(\.isEpisode)
        } catch is CancellationError {
        } catch {
            if episodes[key] == nil { failure = error.localizedDescription }
        }
    }
}

private struct SeasonTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.heading)
                .foregroundStyle(selected || hovered ? Theme.textPrimary : Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct EpisodeRow: View {
    let episode: PlexItem
    @Environment(AppModel.self) private var app
    @State private var hovered = false

    private var meta: [String] {
        [Format.runtime(ms: episode.duration), Format.airDate(episode.originallyAvailableAt)].compactMap { $0 }
    }

    var body: some View {
        Button { app.play(episode) } label: {
            HStack(alignment: .top, spacing: 18) {
                PlexImage(app.server?.image(episode.thumb, width: ArtSize.still.width, height: ArtSize.still.height))
                    .frame(width: 224, height: 126)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(Theme.background, in: Circle())
                            .opacity(hovered ? 1 : 0)
                    }
                    .overlay(alignment: .bottom) {
                        if let progress = episode.progress { ProgressLine(fraction: progress).padding(8) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if episode.isWatched { WatchedMark().padding(6) }
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text(episode.index.map { "\($0). \(episode.title)" } ?? episode.title)
                        .font(.body13Strong)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    MetaLine(values: meta, font: .caption11)
                    if let summary = episode.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.body13)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                            .lineSpacing(2)
                            .frame(maxWidth: 620, alignment: .leading)
                    }
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(hovered ? Theme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.quick, value: hovered)
        .contextMenu { ItemMenu(item: episode) }
    }
}
