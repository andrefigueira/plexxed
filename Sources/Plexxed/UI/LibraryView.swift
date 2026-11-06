import SwiftUI

enum LibrarySort: String, CaseIterable {
    case title, added, year, rating, watched

    var label: String {
        switch self {
        case .title: "Title"
        case .added: "Recently added"
        case .year: "Release year"
        case .rating: "Rating"
        case .watched: "Recently watched"
        }
    }
}

enum LibraryFilter: String, CaseIterable {
    case all, unwatched, inProgress

    var label: String {
        switch self {
        case .all: "All"
        case .unwatched: "Unwatched"
        case .inProgress: "In progress"
        }
    }
}

/// Sorting and filtering run locally on the cached list, so they are instant and cost the server nothing.
struct LibraryView: View {
    let section: LibrarySection
    @Environment(AppModel.self) private var app
    @State private var sort: LibrarySort
    @State private var filter: LibraryFilter
    @State private var display: [PlexItem] = []

    init(section: LibrarySection) {
        self.section = section
        let defaults = UserDefaults.standard
        _sort = State(initialValue: LibrarySort(rawValue: defaults.string(forKey: "sort.\(section.key)") ?? "") ?? .title)
        _filter = State(initialValue: LibraryFilter(rawValue: defaults.string(forKey: "filter.\(section.key)") ?? "") ?? .all)
    }

    private var items: [PlexItem]? { app.library.items[section.key] }
    private var version: Int { app.library.versions[section.key] ?? 0 }

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 196), spacing: 22, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                grid
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 20)
            .padding(.bottom, 56)
        }
        .background(Theme.background)
        .navigationTitle(section.title)
        .task {
            guard let server = app.server else { return }
            await app.library.load(section, server: server)
        }
        .onChange(of: version, initial: true) { recompute() }
        .onChange(of: sort) {
            UserDefaults.standard.set(sort.rawValue, forKey: "sort.\(section.key)")
            recompute()
        }
        .onChange(of: filter) {
            UserDefaults.standard.set(filter.rawValue, forKey: "filter.\(section.key)")
            recompute()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(section.title).font(.hero).foregroundStyle(Theme.textPrimary)
            if let items {
                Text(countLabel(items.count)).font(.body13).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Dropdown(options: LibraryFilter.allCases.map { ($0, $0.label) }, selection: $filter)
            Dropdown(options: LibrarySort.allCases.map { ($0, $0.label) }, selection: $sort)
        }
    }

    @ViewBuilder
    private var grid: some View {
        if let items {
            if display.isEmpty {
                ContentUnavailableView(
                    items.isEmpty ? "This library is empty" : "Nothing matches",
                    systemImage: section.symbol,
                    description: Text(items.isEmpty ? "Add files to it in Plex and they'll appear here." : "Try another filter.")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                    ForEach(display) { item in
                        NavigationLink(value: item) { PosterCard(item: item) }
                            .buttonStyle(.plain)
                    }
                }
            }
        } else if let failure = app.library.failures[section.key] {
            ContentUnavailableView {
                Label("\(section.title) didn't load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(failure)
            } actions: {
                SecondaryButton("Try again") {
                    Task {
                        guard let server = app.server else { return }
                        await app.library.load(section, server: server, force: true)
                    }
                }
            }
            .padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                ForEach(0..<18, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface).aspectRatio(2 / 3, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(width: 90, height: 10)
                    }
                }
            }
            .accessibilityLabel("Loading \(section.title)")
        }
    }

    private func countLabel(_ count: Int) -> String {
        let noun = section.type == "show" ? (count == 1 ? "show" : "shows") : (count == 1 ? "movie" : "movies")
        return "\(count.formatted()) \(noun)"
    }

    private func recompute() {
        guard let items else {
            display = []
            return
        }
        let filtered: [PlexItem] = switch filter {
        case .all: items
        case .unwatched: items.filter { !$0.isWatched }
        case .inProgress: items.filter { $0.progress != nil || (($0.viewedLeafCount ?? 0) > 0 && !$0.isWatched) }
        }
        display = switch sort {
        case .title: filtered.sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
        case .added: filtered.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        case .year: filtered.sorted { ($0.year ?? 0, $1.sortTitle) > ($1.year ?? 0, $0.sortTitle) }
        case .rating: filtered.sorted { ($0.audienceRating ?? $0.rating ?? 0) > ($1.audienceRating ?? $1.rating ?? 0) }
        case .watched: filtered.sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }
        }
    }
}
