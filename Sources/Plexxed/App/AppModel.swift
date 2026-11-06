import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut
        case awaitingApproval(URL)
        case choosingServer([PlexResource])
        case connecting(String)
        case failed(String)
        case ready
    }

    var phase: Phase = .launching
    private(set) var server: PlexServer?
    private(set) var sections: [LibrarySection] = []
    private(set) var playback: PlaybackSession?
    /// Bumped when watch state changes, so visible screens refetch what they show.
    private(set) var revision = 0
    /// An item to open once the library is showing (set by the --open developer flag).
    var pendingOpen: PlexItem?
    let library = LibraryStore()
    let recommendations = RecommendationStore()

    @ObservationIgnored private var userToken: String?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var recommendationTask: Task<Void, Never>?

    // MARK: Launch

    func bootstrap() async {
        guard phase == .launching else { return }
        Log.rotateIfNeeded()
        ImagePipeline.shared.trimDisk()
        guard let credentials = CredentialStore.load() else {
            phase = .signedOut
            return
        }
        userToken = credentials.userToken
        // The last server usually still answers at the same address. Check it before asking plex.tv.
        if let saved = credentials.server {
            if let plain = saved.plainLANURL, await ServerConnector.probe(plain, token: saved.token, timeout: 1.5) {
                let server = saved.with(baseURL: plain)
                CredentialStore.save(Credentials(userToken: credentials.userToken, server: server))
                activate(server)
                return
            }
            if await ServerConnector.probe(saved.baseURL, token: saved.token, timeout: 2.5) {
                activate(saved)
                return
            }
        }
        await discoverServers(preferring: credentials.server?.machineID)
    }

    func discoverServers(preferring machineID: String? = nil, alwaysAsk: Bool = false) async {
        guard let token = userToken else {
            phase = .signedOut
            return
        }
        phase = .connecting("Looking for your servers")
        do {
            let servers = try await PlexTV.resources(token: token).filter(\.isServer)
            guard !servers.isEmpty else {
                phase = .failed(PlexError.noServers.localizedDescription)
                return
            }
            if !alwaysAsk, let match = servers.first(where: { $0.clientIdentifier == machineID }) ?? (servers.count == 1 ? servers[0] : nil) {
                await connect(match)
            } else {
                phase = .choosingServer(servers.sorted { ($0.owned ? 0 : 1, $0.name) < ($1.owned ? 0 : 1, $1.name) })
            }
        } catch PlexError.unauthorized {
            signOut()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func connect(_ resource: PlexResource) async {
        guard let token = userToken else { return }
        phase = .connecting("Connecting to \(resource.name)")
        guard let server = await ServerConnector.connect(resource, userToken: token) else {
            phase = .failed(PlexError.unreachable(resource.name).localizedDescription)
            return
        }
        CredentialStore.save(Credentials(userToken: token, server: server))
        activate(server)
    }

    private func activate(_ server: PlexServer) {
        if self.server?.machineID != server.machineID {
            library.reset()
            recommendations.reset()
        }
        self.server = server
        if let cached = ResponseCache.read(sectionsKey(server)), let list = PlexServer.decodeSections(cached) {
            sections = list.filter { $0.isVideo && !$0.hidden }
        }
        phase = .ready
        Task { await refreshSections() }
        // Developer flags: --play <ratingKey> or --open <ratingKey> right after connecting.
        for flag in ["--play", "--open"] {
            guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { continue }
            let key = CommandLine.arguments[index + 1]
            Task {
                guard let item = try? await server.metadata(key) else { return }
                if flag == "--play" { play(item) } else { pendingOpen = item }
            }
        }
    }

    func refreshSections() async {
        guard let server else { return }
        do {
            let data = try await server.sectionsData()
            guard let list = PlexServer.decodeSections(data) else { return }
            sections = list.filter { $0.isVideo && !$0.hidden }
            ResponseCache.write(data, key: sectionsKey(server))
        } catch PlexError.unauthorized {
            signOut()
        } catch {
            Log.error("Loading libraries failed: \(error.localizedDescription)")
        }
    }

    private func sectionsKey(_ server: PlexServer) -> String { "\(server.machineID)-sections" }

    // MARK: Sign in

    func beginSignIn() {
        signInTask?.cancel()
        signInTask = Task { await runSignIn() }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        phase = .signedOut
    }

    private func runSignIn() async {
        do {
            let pin = try await PlexTV.createPin()
            let url = PlexTV.authURL(code: pin.code)
            phase = .awaitingApproval(url)
            NSWorkspace.shared.open(url)
            let deadline = Date().addingTimeInterval(15 * 60)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(1.5))
                let status = try await PlexTV.pin(id: pin.id)
                if let token = status.authToken, !token.isEmpty {
                    userToken = token
                    CredentialStore.save(Credentials(userToken: token, server: nil))
                    NSApp.activate()
                    await discoverServers()
                    return
                }
            }
            phase = .signedOut
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func signOut() {
        closePlayer()
        signInTask?.cancel()
        CredentialStore.clear()
        ResponseCache.clear()
        library.reset()
        recommendations.reset()
        server = nil
        userToken = nil
        sections = []
        phase = .signedOut
    }

    // MARK: Recommendations

    /// Loads every library (disk first, network when stale) and rebuilds the recommendation rows.
    /// Runs in its own task so Home restarting its `.task` can't cancel a refresh halfway through.
    /// Calls that overlap share the run already going.
    func refreshRecommendations() async {
        if let running = recommendationTask { return await running.value }
        let task = Task { await buildRecommendations() }
        recommendationTask = task
        await task.value
        recommendationTask = nil
    }

    private func buildRecommendations() async {
        guard let server, !sections.isEmpty else { return }
        let sections = sections
        await withTaskGroup(of: Void.self) { group in
            for section in sections {
                group.addTask { await self.library.load(section, server: server) }
            }
        }
        let items = sections.flatMap { library.items[$0.key] ?? [] }
        await recommendations.refresh(server: server, items: items, forceHistory: revision > 0)
    }

    // MARK: Playback

    func play(_ item: PlexItem, fromStart: Bool = false) {
        guard let server, item.isPlayable else { return }
        playback?.close()
        let session = PlaybackSession(server: server, item: item, fromStart: fromStart)
        session.onProgress = { [weak self] progress in self?.library.apply(progress) }
        session.onFinished = { [weak self] in self?.closePlayer() }
        playback = session
    }

    func closePlayer() {
        guard let session = playback else { return }
        session.close()
        playback = nil
        revision += 1
    }

    /// Quitting mid-film: close the player and wait until Plex has the final position, so the
    /// resume point is exact and the server drops its "now playing" entry.
    func closePlayerBeforeQuit() async {
        guard let session = playback else { return }
        session.close()
        playback = nil
        await session.waitForFinalWrites()
    }

    func setWatched(_ item: PlexItem, _ watched: Bool) {
        guard let server else { return }
        Task {
            do {
                try await server.setWatched(item.ratingKey, watched)
                library.apply(PlaybackProgress(
                    ratingKey: item.ratingKey,
                    showRatingKey: item.showRatingKey == item.ratingKey ? nil : item.showRatingKey,
                    viewOffsetMs: nil,
                    watched: watched,
                    markedUnwatched: !watched
                ))
                if item.isShow || item.isSeason, let section = sectionContaining(item) {
                    await library.load(section, server: server, force: true)
                }
                revision += 1
            } catch {
                Log.error("Marking watched failed: \(error.localizedDescription)")
            }
        }
    }

    private func sectionContaining(_ item: PlexItem) -> LibrarySection? {
        let key = item.showRatingKey ?? item.ratingKey
        return sections.first { section in library.items[section.key]?.contains { $0.ratingKey == key } ?? false }
    }
}

/// Every library's items, served from disk first and refreshed in the background.
@MainActor
@Observable
final class LibraryStore {
    private(set) var items: [String: [PlexItem]] = [:]
    private(set) var versions: [String: Int] = [:]
    private(set) var failures: [String: String] = [:]
    @ObservationIgnored private var lastRefresh: [String: Date] = [:]
    @ObservationIgnored private var inflight: Set<String> = []

    func load(_ section: LibrarySection, server: PlexServer, force: Bool = false) async {
        let key = section.key
        let cacheKey = "\(server.machineID)-section-\(key)"
        if items[key] == nil {
            let cached = await Task.detached(priority: .userInitiated) { () -> [PlexItem]? in
                guard let data = ResponseCache.read(cacheKey) else { return nil }
                return Self.decode(data)
            }.value
            if let cached, items[key] == nil { set(cached, for: key) }
        }
        if !force, let last = lastRefresh[key], Date().timeIntervalSince(last) < 600 { return }
        guard !inflight.contains(key) else { return }
        inflight.insert(key)
        defer { inflight.remove(key) }
        do {
            let data = try await server.sectionItemsData(section)
            let fresh = await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
            if let fresh {
                set(fresh, for: key)
                failures[key] = nil
                lastRefresh[key] = Date()
                ResponseCache.write(data, key: cacheKey)
            }
        } catch {
            if items[key] == nil { failures[key] = error.localizedDescription }
        }
    }

    nonisolated private static func decode(_ data: Data) -> [PlexItem]? {
        (try? JSONDecoder().decode(Envelope<MetadataList>.self, from: data))?.container.items
    }

    private func set(_ list: [PlexItem], for key: String) {
        items[key] = list
        versions[key, default: 0] += 1
    }

    /// Updates watch state in place after playback, so the grid is right without a refetch.
    func apply(_ progress: PlaybackProgress) {
        for (key, list) in items {
            var changed = false
            var updated = list
            for i in updated.indices {
                if updated[i].ratingKey == progress.ratingKey, updated[i].isPlayable {
                    updated[i].viewOffset = progress.viewOffsetMs
                    if progress.watched { updated[i].viewCount = max(updated[i].viewCount ?? 0, 1) }
                    if progress.markedUnwatched { updated[i].viewCount = 0 }
                    changed = true
                } else if let show = progress.showRatingKey, updated[i].ratingKey == show,
                          progress.watched || progress.markedUnwatched, let leaves = updated[i].leafCount {
                    let step = progress.markedUnwatched ? -1 : 1
                    updated[i].viewedLeafCount = min(max((updated[i].viewedLeafCount ?? 0) + step, 0), leaves)
                    changed = true
                }
            }
            if changed { set(updated, for: key) }
        }
    }

    func reset() {
        items = [:]
        versions = [:]
        failures = [:]
        lastRefresh = [:]
    }
}
