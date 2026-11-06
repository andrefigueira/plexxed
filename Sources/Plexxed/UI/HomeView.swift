import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var hubs: [Hub] = []
    @State private var loaded = false
    @State private var failure: String?

    private var rows: [Hub] { hubs.filter { !$0.items.isEmpty } }

    /// Continue Watching first. On Deck repeats most of it, so only its extra items are kept.
    private var continueRows: [Hub] {
        var seen = Set<String>()
        return rows.filter(\.isContinueWatching).compactMap { hub in
            var copy = hub
            copy.items = hub.items.filter { seen.insert($0.ratingKey).inserted }
            return copy.items.isEmpty ? nil : copy
        }
    }

    private var otherRows: [Hub] { rows.filter { !$0.isContinueWatching } }

    private var hero: PlexItem? {
        if let next = continueRows.first?.items.first { return next }
        if let pick = app.recommendations.rows.first?.items.first(where: { $0.backdropPath != nil }) { return pick }
        return rows.first?.items.first { $0.backdropPath != nil }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 44) {
                if let hero {
                    HeroView(item: hero)
                } else {
                    Color.clear.frame(height: 72)
                }
                ForEach(continueRows) { hub in
                    ShelfRow(title: hub.title, items: hub.items, landscape: true)
                }
                ForEach(app.recommendations.rows) { row in
                    ShelfRow(title: row.title, items: row.items, reasons: row.reasons)
                }
                ForEach(otherRows) { hub in
                    ShelfRow(title: hub.title, items: hub.items)
                }
            }
            .padding(.bottom, 56)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
        .overlay { placeholder }
        .task(id: app.revision) { await load() }
        .task(id: "\(app.revision)-\(app.sections.count)") { await app.refreshRecommendations() }
    }

    @ViewBuilder
    private var placeholder: some View {
        if rows.isEmpty {
            if let failure {
                ContentUnavailableView {
                    Label("Home didn't load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    SecondaryButton("Try again") { Task { await load() } }
                }
            } else if loaded {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "film.stack",
                    description: Text("Recently added and in-progress titles show up here.")
                )
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func load() async {
        guard let server = app.server else { return }
        let key = "\(server.machineID)-hubs"
        if hubs.isEmpty, let data = ResponseCache.read(key), let cached = PlexServer.decodeHubs(data) {
            hubs = cached
        }
        do {
            let data = try await server.hubsData()
            if let fresh = PlexServer.decodeHubs(data) {
                hubs = fresh
                ResponseCache.write(data, key: key)
            }
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            if hubs.isEmpty { failure = error.localizedDescription }
        }
        loaded = true
    }
}

// MARK: - Hero

struct HeroView: View {
    let item: PlexItem
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator
    @State private var show: PlexItem?

    private var logoSource: PlexItem? { item.isEpisode || item.isSeason ? show : item }

    private var details: [String] {
        if item.isEpisode {
            return [[item.episodeLabel, item.title].compactMap { $0 }.joined(separator: "  ")]
        }
        return [item.year.map(String.init), Format.runtime(ms: item.duration), item.contentRating].compactMap { $0 }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Backdrop(
                request: app.server?.image(item.backdropPath, width: ArtSize.backdrop.width, height: ArtSize.backdrop.height),
                height: 500
            )
            VStack(alignment: .leading, spacing: 14) {
                Button { navigator.open(item) } label: {
                    TitleArt(
                        title: item.headline,
                        logo: app.server?.rawImage(logoSource?.clearLogo, maxPixel: 900)
                    )
                }
                .buttonStyle(.plain)
                MetaLine(values: details)
                HStack(spacing: 16) {
                    if item.isPlayable {
                        PrimaryButton(item.progress != nil ? "Resume" : "Play", systemImage: "play.fill") {
                            app.play(item)
                        }
                    } else {
                        PrimaryButton("Open", systemImage: "arrow.right") { navigator.open(item) }
                    }
                    if let progress = item.progress, let remaining = item.remainingMs {
                        ProgressLine(fraction: progress).frame(width: 96)
                        Text(Format.remaining(ms: remaining))
                            .font(.body13)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, Theme.gutter)
        }
        .task(id: item.showRatingKey) {
            guard item.isEpisode || item.isSeason, let key = item.showRatingKey, let server = app.server else { return }
            show = try? await server.metadata(key)
        }
    }
}

// MARK: - Rows

/// A titled horizontal row with paging buttons, for mouse users who can't scroll sideways.
struct ShelfRow: View {
    let title: String
    let items: [PlexItem]
    var landscape = false
    var reasons: [String: String] = [:]
    @State private var visible: [String] = []

    private var ids: [String] { items.map(\.id) }
    private var atStart: Bool { visible.isEmpty || visible.contains(ids.first ?? "") }
    private var atEnd: Bool { visible.isEmpty || visible.contains(ids.last ?? "") }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    if !(atStart && atEnd) {
                        HStack(spacing: 4) {
                            PagerButton(systemImage: "chevron.left", help: "Previous", disabled: atStart) {
                                page(proxy, forward: false)
                            }
                            PagerButton(systemImage: "chevron.right", help: "Next", disabled: atEnd) {
                                page(proxy, forward: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(items) { item in
                            card(item).id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, Theme.gutter)
                    .padding(.vertical, 6)
                }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { visible = $0 }
            }
        }
    }

    @ViewBuilder
    private func card(_ item: PlexItem) -> some View {
        if landscape {
            LandscapeCard(item: item)
        } else {
            NavigationLink(value: item) {
                PosterCard(item: item).frame(width: 150)
            }
            .buttonStyle(.plain)
            .help(reasons[item.ratingKey] ?? "")
        }
    }

    /// Moves one screenful, keeping the last visible card on screen as the anchor.
    private func page(_ proxy: ScrollViewProxy, forward: Bool) {
        let shown = ids.filter { visible.contains($0) }
        guard let first = shown.first, let last = shown.last,
              let firstIndex = ids.firstIndex(of: first), let lastIndex = ids.firstIndex(of: last) else { return }
        let span = max(lastIndex - firstIndex, 1)
        let target = forward ? min(lastIndex, ids.count - 1) : max(firstIndex - span, 0)
        withAnimation(.calm) { proxy.scrollTo(ids[target], anchor: .leading) }
    }
}

private struct PagerButton: View {
    let systemImage: String
    let help: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(disabled ? Theme.track : (hovered ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 28, height: 28)
                .background(hovered && !disabled ? Theme.surface : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(help)
    }
}
