import Foundation

struct RecommendationRow: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [PlexItem]
    /// Why each item is here, keyed by ratingKey. Shown as a tooltip.
    let reasons: [String: String]
}

/// Content-based recommendations computed on the Mac from the cached library and watch history.
///
/// 1. Every title becomes a sparse feature vector (genres, director, writers, cast, studio, decade,
///    audience), weighted by rarity so a shared director counts for more than "Drama".
/// 2. A taste profile sums the vectors of watched titles, weighted by how recently and how much
///    each was watched. A binged show counts for more than one episode; an abandoned film counts against.
/// 3. Unwatched titles are scored by similarity to the profile, nudged by rating and newness,
///    then re-ranked for variety so one franchise can't fill a row.
enum RecommendationEngine {
    struct Input: Sendable {
        let items: [PlexItem]
        let history: [HistoryEntry]
        /// Plex's own similar lists for the seed titles, keyed by seed ratingKey.
        let similar: [String: [String]]
        let now: Date
    }

    // MARK: Entry points

    /// The titles "Because you watched" rows are built from. Fetch Plex's similar lists for these first.
    static func seeds(items: [PlexItem], history: [HistoryEntry], now: Date) -> [String] {
        let model = Model(items: items, history: history, now: now)
        return model.pickSeeds(count: 6).map(\.ratingKey)
    }

    static func build(_ input: Input) -> [RecommendationRow] {
        let model = Model(items: input.items, history: input.history, now: input.now)
        guard !model.profile.isEmpty, model.candidates.count >= 5 else { return [] }

        var rows: [RecommendationRow] = []
        var shown = Set<String>()

        let picks = model.topPicks(count: 20)
        if picks.count >= 5 {
            rows.append(RecommendationRow(
                id: "rec.top",
                title: "Top picks for you",
                items: picks,
                reasons: Dictionary(uniqueKeysWithValues: picks.map { ($0.ratingKey, model.reason(for: $0)) })
            ))
            shown.formUnion(picks.prefix(8).map(model.identity))
        }

        // Walk down the seeds until three have enough unwatched neighbours to fill a row. Then each
        // title stays only in the row that ranks it highest, so the South Park film lands under
        // South Park instead of whichever seed happened to come first.
        let drafts = model.pickSeeds(count: 8)
            .map { seed in
                (seed, model.similarTo(seed, plexSimilar: Set(input.similar[seed.ratingKey] ?? []), excluding: shown, count: 16))
            }
            .filter { $0.1.count >= 6 }
            .prefix(3)
        // Keyed by franchise, so two X Files films can't turn up in two different rows either.
        var home: [String: (row: Int, rank: Int)] = [:]
        for (row, draft) in drafts.enumerated() {
            for (rank, item) in draft.1.enumerated() {
                let key = Model.franchise(item)
                if let current = home[key], current.rank <= rank { continue }
                home[key] = (row, rank)
            }
        }
        for (row, (seed, items)) in drafts.enumerated() {
            let kept = items.filter { home[Model.franchise($0)]?.row == row }
            guard kept.count >= 6 else { continue }
            rows.append(RecommendationRow(
                id: "rec.seed.\(seed.ratingKey)",
                title: "Because you watched \(seed.title)",
                items: kept,
                reasons: [:]
            ))
            shown.formUnion(kept.map(model.identity))
        }

        if let person = model.favouritePerson(excluding: shown) {
            rows.append(RecommendationRow(
                id: "rec.person.\(person.name)",
                title: person.isDirector ? "More from \(person.name)" : "More with \(person.name)",
                items: person.items,
                reasons: [:]
            ))
        }
        return rows
    }

    // MARK: Model

    private struct Model {
        let titles: [PlexItem]
        let vectors: [String: [String: Double]]
        let weights: [String: Double]
        let profile: [String: Double]
        let candidates: [PlexItem]
        let now: Date

        init(items: [PlexItem], history: [HistoryEntry], now: Date) {
            self.now = now
            // One entry per title: the same film in two libraries shares a guid.
            var byIdentity: [String: PlexItem] = [:]
            var aliases: [String: String] = [:]
            for item in items where item.isMovie || item.isShow {
                let id = Self.identity(item)
                aliases[item.ratingKey] = id
                if let existing = byIdentity[id], Self.engagement(existing) >= Self.engagement(item) { continue }
                byIdentity[id] = item
            }
            titles = Array(byIdentity.values)

            // Rarity weighting.
            let raw = Dictionary(uniqueKeysWithValues: titles.map { (Self.identity($0), Self.features($0)) })
            var documentFrequency: [String: Int] = [:]
            for features in raw.values { for key in features.keys { documentFrequency[key, default: 0] += 1 } }
            let n = Double(max(titles.count, 1))
            var vectors: [String: [String: Double]] = [:]
            for (id, features) in raw {
                var vector: [String: Double] = [:]
                for (key, weight) in features {
                    vector[key] = weight * log(1 + n / Double(documentFrequency[key] ?? 1))
                }
                vectors[id] = Self.normalised(vector)
            }
            self.vectors = vectors

            // Watch signals: plays and last play per title, from history and the library's own counters.
            var plays: [String: Int] = [:]
            var lastPlay: [String: Int] = [:]
            for entry in history {
                guard let id = aliases[entry.titleKey] else { continue }
                plays[id, default: 0] += 1
                lastPlay[id] = max(lastPlay[id] ?? 0, entry.viewedAt)
            }
            var weights: [String: Double] = [:]
            for title in titles {
                let id = Self.identity(title)
                let count = max(plays[id] ?? 0, title.viewCount ?? 0, title.viewedLeafCount ?? 0)
                let last = max(lastPlay[id] ?? 0, title.lastViewedAt ?? 0)
                let inProgress = title.progress != nil
                guard count > 0 || inProgress else { continue }
                let ageDays = max(now.timeIntervalSince1970 - Double(last), 0) / 86_400
                let recency = max(exp(-ageDays / 150), 0.12)
                let intensity: Double
                if title.isShow {
                    intensity = min(1.0, 0.3 + 0.18 * log2(1 + Double(count)))
                } else if count > 0 {
                    intensity = min(1.3, 1.0 + 0.15 * log2(Double(count)))
                } else if let progress = title.progress, progress < 0.25, ageDays > 30 {
                    intensity = -0.25
                } else {
                    intensity = 0.5
                }
                weights[id] = recency * intensity
            }
            self.weights = weights

            var profile: [String: Double] = [:]
            for (id, weight) in weights {
                for (key, value) in vectors[id] ?? [:] { profile[key, default: 0] += weight * value }
            }
            self.profile = Self.normalised(profile.filter { $0.value > 0 })

            candidates = titles.filter { title in
                weights[Self.identity(title)] == nil && title.progress == nil && (title.viewedLeafCount ?? 0) == 0
            }
        }

        func identity(_ item: PlexItem) -> String { Self.identity(item) }

        // Rows

        func topPicks(count: Int) -> [PlexItem] {
            let scored = candidates.map { item -> (PlexItem, Double) in
                let similarity = Self.dot(profile, vectors[identity(item)] ?? [:])
                return (item, 0.78 * similarity + 0.14 * quality(item) + 0.08 * freshness(item))
            }
            return diversify(scored, count: count, lambda: 0.72)
        }

        func similarTo(_ seed: PlexItem, plexSimilar: Set<String>, excluding: Set<String>, count: Int) -> [PlexItem] {
            let seedVector = vectors[identity(seed)] ?? [:]
            let seedAudience = Self.audience(seed)
            let scored = candidates.compactMap { item -> (PlexItem, Double)? in
                guard !excluding.contains(identity(item)) else { return nil }
                let similarity = Self.dot(seedVector, vectors[identity(item)] ?? [:])
                let plexBonus = plexSimilar.contains(item.ratingKey) ? 0.12 : 0
                let score = (0.85 * similarity + 0.10 * quality(item) + plexBonus)
                    * Self.audienceFit(seed: seedAudience, candidate: Self.audience(item))
                return score > 0.11 ? (item, score) : nil
            }
            return diversify(scored, count: count, lambda: 0.82)
        }

        /// Strongly watched titles, skipping any too close to one already picked so rows differ.
        func pickSeeds(count: Int) -> [PlexItem] {
            let ranked = titles
                .filter { (weights[identity($0)] ?? 0) > 0 }
                .sorted { (weights[identity($0)] ?? 0) > (weights[identity($1)] ?? 0) }
            var picked: [PlexItem] = []
            for title in ranked {
                let vector = vectors[identity(title)] ?? [:]
                if picked.contains(where: { Self.dot(vectors[identity($0)] ?? [:], vector) > 0.55 }) { continue }
                picked.append(title)
                if picked.count == count { break }
            }
            return picked
        }

        struct Person {
            let name: String
            let isDirector: Bool
            let items: [PlexItem]
        }

        /// The director or actor you watch most who still has unwatched titles here.
        func favouritePerson(excluding: Set<String>) -> Person? {
            var affinity: [String: Double] = [:]
            for title in titles {
                guard let weight = weights[identity(title)], weight > 0 else { continue }
                for name in title.directors.prefix(2) { affinity["d:" + name, default: 0] += weight * 1.2 }
                for name in title.cast.prefix(3) { affinity["c:" + name, default: 0] += weight }
            }
            for (key, _) in affinity.sorted(by: { $0.value > $1.value }).prefix(12) {
                let isDirector = key.hasPrefix("d:")
                let name = String(key.dropFirst(2))
                let matches = candidates.filter {
                    (isDirector ? $0.directors : $0.cast).contains(name) && !excluding.contains(identity($0))
                }
                if matches.count >= 3 {
                    // Closest to your taste first, so a voice role in a kids film doesn't lead a Star Trek row.
                    let ranked = matches
                        .map { ($0, Self.dot(profile, vectors[identity($0)] ?? [:])) }
                        .sorted { $0.1 > $1.1 }
                        .map(\.0)
                    return Person(name: name, isDirector: isDirector, items: ranked)
                }
            }
            return nil
        }

        /// "Because you watched X": the watched title that contributes most to this pick.
        func reason(for item: PlexItem) -> String {
            let vector = vectors[identity(item)] ?? [:]
            let best = titles
                .compactMap { title -> (PlexItem, Double)? in
                    guard let weight = weights[identity(title)], weight > 0 else { return nil }
                    return (title, weight * Self.dot(vectors[identity(title)] ?? [:], vector))
                }
                .max { $0.1 < $1.1 }
            guard let best, best.1 > 0 else { return "Picked for your taste" }
            return "Because you watched \(best.0.title)"
        }

        // Scoring helpers

        private func quality(_ item: PlexItem) -> Double {
            min(max(((item.audienceRating ?? item.rating ?? 6.5) - 5) / 4, 0), 1)
        }

        private func freshness(_ item: PlexItem) -> Double {
            guard let added = item.addedAt else { return 0 }
            return exp(-max(now.timeIntervalSince1970 - Double(added), 0) / 86_400 / 45)
        }

        /// Maximal marginal relevance: each next pick trades its score against similarity to picks so far.
        /// One title per franchise, so a row never turns into three Final Destination films.
        private func diversify(_ scored: [(PlexItem, Double)], count: Int, lambda: Double) -> [PlexItem] {
            var seenFranchises = Set<String>()
            let unique = scored.sorted { $0.1 > $1.1 }.filter { seenFranchises.insert(Self.franchise($0.0)).inserted }
            var pool = Array(unique.prefix(count * 3))
            var picked: [PlexItem] = []
            var pickedVectors: [[String: Double]] = []
            while picked.count < count, !pool.isEmpty {
                var bestIndex = 0
                var bestValue = -Double.infinity
                for (index, candidate) in pool.enumerated() {
                    let vector = vectors[identity(candidate.0)] ?? [:]
                    let redundancy = pickedVectors.map { Self.dot($0, vector) }.max() ?? 0
                    let value = lambda * candidate.1 - (1 - lambda) * redundancy
                    if value > bestValue {
                        bestValue = value
                        bestIndex = index
                    }
                }
                let choice = pool.remove(at: bestIndex)
                picked.append(choice.0)
                pickedVectors.append(vectors[identity(choice.0)] ?? [:])
            }
            return picked
        }

        // Features

        static func identity(_ item: PlexItem) -> String {
            item.guid ?? "\(item.type)|\(item.title.lowercased())|\(item.year ?? 0)"
        }

        static func engagement(_ item: PlexItem) -> Int {
            (item.viewCount ?? 0) + (item.viewedLeafCount ?? 0) + (item.progress != nil ? 1 : 0)
        }

        static func features(_ item: PlexItem) -> [String: Double] {
            var features: [String: Double] = [:]
            for genre in item.genres { features["g:" + genre.lowercased()] = 1.0 }
            for name in item.directors.prefix(2) { features["d:" + name] = 1.3 }
            for name in item.writers.prefix(2) { features["w:" + name] = 0.8 }
            for (rank, name) in item.cast.prefix(4).enumerated() { features["c:" + name] = 0.7 - 0.1 * Double(rank) }
            if let studio = item.studio { features["s:" + studio] = 0.5 }
            for country in item.countries.prefix(2) { features["n:" + country] = 0.3 }
            if let year = item.year { features["y:\(year / 10 * 10)"] = 0.5 }
            if let audience = audience(item) { features["a:" + audience] = 1.2 }
            features["t:" + item.type] = 0.4
            return features
        }

        /// Kids, teen or adult, from the rating and a few telling genres. Keeps cartoons out of crime rows.
        static func audience(_ item: PlexItem) -> String? {
            let genres = Set(item.genres.map { $0.lowercased() })
            if !genres.isDisjoint(with: ["children", "kids", "family"]) { return "kids" }
            guard var rating = item.contentRating?.uppercased() else { return nil }
            if let slash = rating.lastIndex(of: "/") { rating = String(rating[rating.index(after: slash)...]) }
            switch rating {
            case "G", "U", "TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G", "0", "6", "ALL": return "kids"
            // A PG cartoon film is a family film. A PG Bond film isn't, and neither is a TV-PG show like The Simpsons.
            case "PG" where item.isMovie && genres.contains("animation"): return "kids"
            case "PG", "TV-PG", "PG-13", "TV-14", "7", "12", "12A", "13", "14": return "teen"
            case "R", "TV-MA", "NC-17", "15", "16", "18", "R18", "MA15+": return "adult"
            default: return nil
            }
        }

        /// A South Park row shouldn't fill up with Pixar, and a Pixar row shouldn't fill up with R-rated films.
        /// Kids titles under a grown-up seed are rarely wanted, so that direction costs more than teen to adult.
        static func audienceFit(seed: String?, candidate: String?) -> Double {
            guard let seed, let candidate, seed != candidate else { return 1 }
            switch (seed, candidate) {
            case ("teen", "adult"), ("adult", "teen"): return 0.85
            case ("kids", "teen"): return 0.7
            case ("kids", _): return 0.3
            default: return 0.45
            }
        }

        /// Groups sequels and spin-offs by their base title: "The Final Destination" and "Final Destination 5"
        /// both become "final destination", "Venom: The Last Dance" becomes "venom".
        static func franchise(_ item: PlexItem) -> String {
            var title = item.title.lowercased()
            if let colon = title.firstIndex(of: ":") { title = String(title[..<colon]) }
            if title.hasPrefix("the ") { title.removeFirst(4) }
            let numerals: Set<String> = ["ii", "iii", "iv", "v", "vi", "part"]
            var words = title.split(separator: " ").map(String.init)
            while let last = words.last, words.count > 1, Int(last) != nil || numerals.contains(last) {
                words.removeLast()
            }
            return words.joined(separator: " ")
        }

        static func normalised(_ vector: [String: Double]) -> [String: Double] {
            let norm = vector.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { return [:] }
            return vector.mapValues { $0 / norm }
        }

        static func dot(_ a: [String: Double], _ b: [String: Double]) -> Double {
            let (small, large) = a.count <= b.count ? (a, b) : (b, a)
            return small.reduce(0) { $0 + $1.value * (large[$1.key] ?? 0) }
        }
    }
}
