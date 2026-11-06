import Foundation
import Observation

/// Gathers what the engine needs (the cached library, watch history, Plex's similar lists for a few
/// seed titles) and runs it off the main thread. Costs the server one history request every few minutes.
@MainActor
@Observable
final class RecommendationStore {
    private(set) var rows: [RecommendationRow] = []

    @ObservationIgnored private var history: [HistoryEntry]?
    @ObservationIgnored private var historyFetchedAt = Date.distantPast
    @ObservationIgnored private var similar: [String: [String]] = [:]
    @ObservationIgnored private var running = false
    /// Bumped by reset(), so a run that started before a server switch can't publish the old server's rows.
    @ObservationIgnored private var generation = 0

    func refresh(server: PlexServer, items: [PlexItem], forceHistory: Bool = false) async {
        guard !items.isEmpty, !running else { return }
        running = true
        defer { running = false }
        let generationAtStart = generation

        let cacheKey = "\(server.machineID)-history"
        if history == nil, let data = ResponseCache.read(cacheKey) {
            history = PlexServer.decodeHistory(data)
        }
        if forceHistory || Date().timeIntervalSince(historyFetchedAt) > 300 {
            do {
                let data = try await server.historyData()
                guard generation == generationAtStart else { return }
                if let fresh = PlexServer.decodeHistory(data) {
                    history = fresh
                    historyFetchedAt = Date()
                    ResponseCache.write(data, key: cacheKey)
                }
            } catch is CancellationError {
                // Nothing to report. The cached history still feeds this run.
            } catch {
                Log.error("Loading watch history failed: \(error.localizedDescription)")
            }
        }

        let plays = history ?? []
        let now = Date()
        let seeds = await Task.detached(priority: .utility) {
            RecommendationEngine.seeds(items: items, history: plays, now: now)
        }.value
        for seed in seeds where similar[seed] == nil {
            // Only keep real answers, so a failed request is retried next time.
            let list = try? await server.similar(seed)
            guard generation == generationAtStart else { return }
            if let list { similar[seed] = list }
        }

        let input = RecommendationEngine.Input(items: items, history: plays, similar: similar, now: now)
        let started = Date()
        let built = await Task.detached(priority: .utility) { RecommendationEngine.build(input) }.value
        guard generation == generationAtStart else { return }
        Log.info("Recommendations: \(built.count) rows from \(items.count) titles and \(plays.count) plays in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        for row in built {
            Log.info("  \(row.title): \(row.items.prefix(8).map(\.title).joined(separator: ", "))")
        }
        rows = built
    }

    func reset() {
        generation += 1
        rows = []
        history = nil
        historyFetchedAt = .distantPast
        similar = [:]
    }
}
