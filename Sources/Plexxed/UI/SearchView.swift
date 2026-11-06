import SwiftUI

struct SearchView: View {
    let query: String
    @Environment(AppModel.self) private var app
    @State private var titles: [PlexItem] = []
    @State private var episodes: [PlexItem] = []
    @State private var searchedFor: String?
    @State private var failure: String?

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 196), spacing: 22, alignment: .top)]
    private let wideColumns = [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 22, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if !titles.isEmpty {
                    section("Movies and shows") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                            ForEach(titles) { item in
                                NavigationLink(value: item) { PosterCard(item: item) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                if !episodes.isEmpty {
                    section("Episodes") {
                        LazyVGrid(columns: wideColumns, alignment: .leading, spacing: 30) {
                            ForEach(episodes) { episode in
                                LandscapeCard(item: episode, width: 280)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 20)
            .padding(.bottom, 56)
        }
        .background(Theme.background)
        .overlay { state }
        .task(id: query) { await search() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.heading).foregroundStyle(Theme.textPrimary)
            content()
        }
    }

    @ViewBuilder
    private var state: some View {
        if titles.isEmpty && episodes.isEmpty {
            if let failure {
                ContentUnavailableView("Search didn't work", systemImage: "wifi.exclamationmark", description: Text(failure))
            } else if searchedFor == query {
                ContentUnavailableView.search(text: query)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func search() async {
        // Waits for a pause in typing so each keystroke doesn't hit the server.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let server = app.server else { return }
        do {
            let hubs = try await server.search(query)
            guard !Task.isCancelled else { return }
            let items = hubs.flatMap(\.items)
            var seen = Set<String>()
            titles = items.filter { ($0.isMovie || $0.isShow) && seen.insert($0.ratingKey).inserted }
            episodes = items.filter { $0.isEpisode && seen.insert($0.ratingKey).inserted }
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
        }
        searchedFor = query
    }
}
