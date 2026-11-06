import AppKit
import Foundation
import Observation

struct TrackOption: Identifiable, Hashable {
    enum Kind: Hashable { case audio, subtitle }

    let id: String
    let kind: Kind
    let title: String
    let detail: String?
    let selected: Bool
    let mpvID: Int?
    /// The Plex stream to remember on the server. 0 means subtitles off.
    let plexStreamID: Int?
    /// A sidecar subtitle file mpv hasn't loaded yet.
    let externalURL: URL?
    var isOff: Bool { kind == .subtitle && plexStreamID == 0 && mpvID == nil }
}

/// What changed for an item when playback ended, so the library can update without a refetch.
struct PlaybackProgress {
    let ratingKey: String
    let showRatingKey: String?
    let viewOffsetMs: Int?
    let watched: Bool
    var markedUnwatched = false
}

@MainActor
@Observable
final class PlaybackSession {
    let server: PlexServer
    let player: MPVPlayer?
    let videoView: MPVVideoView?

    private(set) var item: PlexItem
    private(set) var details: PlexItem?
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = false
    private(set) var buffering = true
    private(set) var errorMessage: String?
    private(set) var volume: Double
    private(set) var muted = false
    private(set) var mpvTracks: [MPVTrack] = []
    private(set) var nextEpisode: PlexItem?
    private(set) var upNextCountdown: Int?

    @ObservationIgnored var onProgress: ((PlaybackProgress) -> Void)?
    @ObservationIgnored var onFinished: (() -> Void)?

    @ObservationIgnored private var sessionID = UUID().uuidString
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var lastReport = Date.distantPast
    /// The "stopped" report and watched flag for the item being left, so quitting can wait for them.
    @ObservationIgnored private var finalWrites: [Task<Void, Never>] = []

    func waitForFinalWrites() async {
        for write in finalWrites { await write.value }
    }
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var cacheStalled = false
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var tracksReconciled = false
    @ObservationIgnored private var pendingExternalSubtitle: PlexStream?
    @ObservationIgnored private var upNextDismissed = false
    @ObservationIgnored private var upNextDeadline: Date?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?

    private static let volumeKey = "playerVolume"

    init(server: PlexServer, item: PlexItem, fromStart: Bool) {
        self.server = server
        self.item = item
        let savedVolume = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double ?? 100
        volume = savedVolume
        let headers = [
            "X-Plex-Token": server.token,
            "X-Plex-Client-Identifier": PlexClient.identifier,
            "X-Plex-Product": PlexClient.product,
        ]
        if let player = MPVPlayer(httpHeaders: headers, volume: savedVolume), let handle = player.handle {
            self.player = player
            videoView = MPVVideoView(mpv: handle)
        } else {
            player = nil
            videoView = nil
            errorMessage = "The video player couldn't start. Reinstall mpv with `brew install mpv`."
            return
        }
        player?.onEvents = { [weak self] events in
            MainActor.assumeIsolated { self?.handle(events) }
        }
        load(item, fromStart: fromStart)
    }

    // MARK: Presentation

    var title: String { item.headline }

    var subtitle: String? {
        if item.isEpisode { return [item.episodeLabel, item.title].compactMap { $0 }.joined(separator: "  ") }
        return item.year.map(String.init)
    }

    var activeIntro: PlexMarker? {
        details?.markers.first { $0.type == "intro" && position >= $0.start && position < $0.end - 1 }
    }

    var showsUpNext: Bool { upNextCountdown != nil && nextEpisode != nil }

    // MARK: Loading

    private func load(_ target: PlexItem, fromStart: Bool) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Hub and library listings omit streams and markers, so fetch the full record.
                guard let full = try await server.metadata(target.ratingKey) else {
                    errorMessage = "This item is no longer on the server."
                    return
                }
                guard !Task.isCancelled, !closed else { return }
                details = full
                item = full
                guard let part = full.primaryPart else {
                    errorMessage = "This item has no playable file."
                    return
                }
                start(full, part: part, fromStart: fromStart)
                if full.isEpisode { await findNextEpisode(after: full) }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func start(_ item: PlexItem, part: PlexPart, fromStart: Bool) {
        guard let player else { return }
        let resume = fromStart || (item.progress ?? 0) > 0.95 ? 0 : Double(item.viewOffset ?? 0) / 1000
        player.set("start", resume > 5 ? String(format: "%.3f", resume) : "none")
        applyRememberedTracks(part.streams, to: player)

        position = resume
        duration = Double(item.duration ?? 0) / 1000
        started = false
        buffering = true
        tracksReconciled = false
        scrobbled = item.isWatched
        player.command(["loadfile", server.mediaURL(part.key).absoluteString, "replace"])
        startTimer()
        updateActivity()
    }

    /// Plex remembers an audio and subtitle choice per file. mpv numbers tracks per type in
    /// file order, so the choice can be applied before the file opens and nothing switches mid-playback.
    private func applyRememberedTracks(_ streams: [PlexStream], to player: MPVPlayer) {
        let byIndex: (PlexStream, PlexStream) -> Bool = { ($0.index ?? 0) < ($1.index ?? 0) }
        let audio = streams.filter { $0.kind == .audio }.sorted(by: byIndex)
        let embeddedSubs = streams.filter { $0.kind == .subtitle && !$0.isExternal }.sorted(by: byIndex)

        if let i = audio.firstIndex(where: \.selected) {
            player.set("aid", String(i + 1))
        } else {
            player.set("aid", "auto")
        }

        pendingExternalSubtitle = nil
        if let chosen = streams.first(where: { $0.kind == .subtitle && $0.selected }) {
            if chosen.isExternal {
                player.set("sid", "no")
                pendingExternalSubtitle = chosen
            } else if let i = embeddedSubs.firstIndex(of: chosen) {
                player.set("sid", String(i + 1))
            }
        } else {
            player.set("sid", "no")
        }
    }

    /// Double-checks the track choice against mpv's real track list once the file is open.
    private func reconcileTracks() {
        guard let player, !tracksReconciled, !mpvTracks.isEmpty, let streams = details?.streams else { return }
        tracksReconciled = true
        if let audio = streams.first(where: { $0.kind == .audio && $0.selected }),
           let track = mpvTracks.first(where: { $0.type == "audio" && !$0.external && $0.ffIndex == audio.index }),
           !track.selected {
            player.set("aid", String(track.id))
        }
        if let sub = streams.first(where: { $0.kind == .subtitle && $0.selected && !$0.isExternal }),
           let track = mpvTracks.first(where: { $0.type == "sub" && !$0.external && $0.ffIndex == sub.index }),
           !track.selected {
            player.set("sid", String(track.id))
        }
        if let external = pendingExternalSubtitle, let key = external.key {
            pendingExternalSubtitle = nil
            player.command(["sub-add", server.mediaURL(key).absoluteString, "select", external.displayTitle ?? "Subtitles"])
        }
    }

    private func findNextEpisode(after episode: PlexItem) async {
        guard let show = episode.grandparentRatingKey,
              let episodes = try? await server.allEpisodes(ofShow: show),
              let index = episodes.firstIndex(where: { $0.ratingKey == episode.ratingKey }),
              index + 1 < episodes.count,
              item.ratingKey == episode.ratingKey
        else { return }
        nextEpisode = episodes[index + 1]
    }

    // MARK: Events

    private func handle(_ events: [MPVEvent]) {
        guard !closed else { return }
        for event in events {
            switch event {
            case .duration(let value):
                if value > 0 { duration = value }
            case .paused(let value):
                paused = value
                report(value ? "paused" : "playing")
                updateActivity()
            case .buffering(let value):
                cacheStalled = value
            case .seeking(let value):
                seeking = value
            case .eof(let value):
                if value { reachedEnd() }
            case .volume(let value):
                volume = value
                UserDefaults.standard.set(value, forKey: Self.volumeKey)
            case .muted(let value):
                muted = value
            case .tracks(let tracks):
                mpvTracks = tracks
                reconcileTracks()
            case .fileLoaded:
                if let time = player?.double("time-pos") { position = time }
            case .playbackRestart:
                if !started, let player {
                    let codec = player.string("current-tracks/video/codec") ?? "no video"
                    let decoder = player.string("hwdec-current").flatMap { $0 == "no" ? nil : $0 } ?? "software"
                    Log.info("Playing \(item.ratingKey) direct from the file: \(codec), \(decoder) decoding, from \(Format.clock(position))")
                }
                started = true
            case .endFile(let error):
                if let error {
                    Log.error("Playback of \(item.ratingKey) failed: \(error)")
                    errorMessage = "The file couldn't be played (\(error))."
                }
            }
        }
        buffering = !started || cacheStalled || seeking
    }

    private func startTimer() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func tick() {
        guard let player, !closed else { return }
        if let time = player.double("time-pos"), abs(time - position) > 0.05 { position = time }
        if !paused, started, Date().timeIntervalSince(lastReport) >= 10 { report("playing") }
        if !scrobbled, duration > 0, position / duration >= 0.9 {
            scrobbled = true
            let key = item.ratingKey
            Task { try? await server.setWatched(key, true) }
        }
        updateUpNext()
    }

    @discardableResult
    private func report(_ state: String) -> Task<Void, Never>? {
        guard duration > 0 else { return nil }
        lastReport = Date()
        let server = server, key = item.ratingKey, id = sessionID
        let time = Int(position * 1000), total = Int(duration * 1000)
        return Task { await server.reportTimeline(ratingKey: key, state: state, timeMs: time, durationMs: total, sessionID: id) }
    }

    private func updateActivity() {
        if paused || closed {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        } else if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Playing video"
            )
        }
    }

    // MARK: Up next

    /// Credits start from Plex's marker when there is one, otherwise shortly before the end.
    private var creditsStart: Double? {
        guard nextEpisode != nil, duration > 0 else { return nil }
        if let credits = details?.markers.first(where: { $0.type == "credits" }), credits.start > duration / 2 {
            return credits.start
        }
        return duration - (duration > 600 ? 30 : 15)
    }

    private func updateUpNext() {
        guard let creditsStart, !upNextDismissed, position >= creditsStart else {
            if upNextCountdown != nil {
                upNextCountdown = nil
                upNextDeadline = nil
            }
            return
        }
        if paused {
            upNextDeadline = Date().addingTimeInterval(Double(upNextCountdown ?? 10))
            return
        }
        let deadline = upNextDeadline ?? Date().addingTimeInterval(10)
        upNextDeadline = deadline
        let remaining = Int(deadline.timeIntervalSinceNow.rounded(.up))
        if remaining <= 0 {
            playNext()
        } else if upNextCountdown != remaining {
            upNextCountdown = remaining
        }
    }

    func dismissUpNext() {
        upNextDismissed = true
        upNextCountdown = nil
        upNextDeadline = nil
    }

    func playNext() {
        guard let next = nextEpisode else { return }
        finishCurrent(movingOn: true)
        nextEpisode = nil
        upNextCountdown = nil
        upNextDeadline = nil
        upNextDismissed = false
        sessionID = UUID().uuidString
        details = nil
        item = next
        position = 0
        load(next, fromStart: false)
    }

    private func reachedEnd() {
        if nextEpisode != nil, !upNextDismissed {
            playNext()
        } else {
            onFinished?()
        }
    }

    // MARK: Controls

    func togglePause() {
        player?.set("pause", paused ? "no" : "yes")
    }

    func seek(by seconds: Double) {
        let target = min(max(position + seconds, 0), max(duration - 1, 0))
        seek(to: target)
    }

    func seek(to seconds: Double) {
        player?.command(["seek", String(format: "%.3f", seconds), "absolute"])
        position = seconds
        if paused { report("paused") }
    }

    func skipIntro() {
        if let intro = activeIntro { seek(to: intro.end) }
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 100)
        player?.set("volume", String(Int(clamped.rounded())))
        if muted, clamped > 0 { player?.set("mute", "no") }
    }

    func toggleMute() {
        player?.set("mute", muted ? "no" : "yes")
    }

    // MARK: Tracks

    var audioOptions: [TrackOption] {
        let streams = (details?.streams ?? []).filter { $0.kind == .audio }
        let tracks = mpvTracks.filter { $0.type == "audio" }
        let mapped = streams.map { stream in
            (stream, tracks.first { !$0.external && $0.ffIndex == stream.index })
        }
        let fullyMapped = !tracks.isEmpty && mapped.allSatisfy { $0.1 != nil }
        if !streams.isEmpty, tracks.isEmpty || fullyMapped {
            return mapped.map { stream, track in
                TrackOption(
                    id: "a\(stream.id)", kind: .audio,
                    title: stream.displayTitle ?? stream.language ?? "Audio",
                    detail: stream.title,
                    selected: track?.selected ?? stream.selected,
                    mpvID: track?.id, plexStreamID: stream.id, externalURL: nil
                )
            }
        }
        return tracks.map {
            TrackOption(id: "ma\($0.id)", kind: .audio, title: $0.label, detail: $0.codec?.uppercased(),
                        selected: $0.selected, mpvID: $0.id, plexStreamID: nil, externalURL: nil)
        }
    }

    var subtitleOptions: [TrackOption] {
        let streams = (details?.streams ?? []).filter { $0.kind == .subtitle }
        let tracks = mpvTracks.filter { $0.type == "sub" }
        let noneSelected = !tracks.contains(where: \.selected)
        let off = TrackOption(id: "s-off", kind: .subtitle, title: "Off", detail: nil,
                              selected: tracks.isEmpty ? !streams.contains(where: \.selected) : noneSelected,
                              mpvID: nil, plexStreamID: 0, externalURL: nil)

        let options: [TrackOption] = streams.compactMap { stream in
            let track: MPVTrack?
            if let key = stream.key {
                track = tracks.first { $0.external && ($0.externalFilename?.contains(key) ?? false) }
            } else {
                track = tracks.first { !$0.external && $0.ffIndex == stream.index }
                if track == nil, !tracks.isEmpty { return nil }
            }
            return TrackOption(
                id: "s\(stream.id)", kind: .subtitle,
                title: stream.displayTitle ?? stream.language ?? "Subtitles",
                detail: stream.title,
                selected: track?.selected ?? (tracks.isEmpty && stream.selected),
                mpvID: track?.id, plexStreamID: stream.id,
                externalURL: stream.key.map { server.mediaURL($0) }
            )
        }
        if !streams.isEmpty { return [off] + options }
        return [off] + tracks.map {
            TrackOption(id: "ms\($0.id)", kind: .subtitle, title: $0.label, detail: $0.codec?.uppercased(),
                        selected: $0.selected, mpvID: $0.id, plexStreamID: nil, externalURL: nil)
        }
    }

    func select(_ option: TrackOption) {
        guard let player else { return }
        let partID = details?.primaryPart?.id
        switch option.kind {
        case .audio:
            if let id = option.mpvID { player.set("aid", String(id)) }
            if let partID, let streamID = option.plexStreamID {
                Task { await server.selectStreams(partID: partID, audioStreamID: streamID) }
            }
        case .subtitle:
            if option.isOff {
                player.set("sid", "no")
            } else if let id = option.mpvID {
                player.set("sid", String(id))
            } else if let url = option.externalURL {
                player.command(["sub-add", url.absoluteString, "select", option.title])
            }
            if let partID, let streamID = option.plexStreamID {
                Task { await server.selectStreams(partID: partID, subtitleStreamID: streamID) }
            }
        }
    }

    // MARK: Ending

    private func finishCurrent(movingOn: Bool) {
        guard duration > 0 else { return }
        finalWrites = [report("stopped")].compactMap { $0 }
        let watched = scrobbled || movingOn || position / duration >= 0.9
        if watched, !scrobbled {
            scrobbled = true
            let key = item.ratingKey
            finalWrites.append(Task { try? await server.setWatched(key, true) })
        }
        onProgress?(PlaybackProgress(
            ratingKey: item.ratingKey,
            showRatingKey: item.grandparentRatingKey,
            viewOffsetMs: watched || position < 30 ? nil : Int(position * 1000),
            watched: watched
        ))
    }

    func close() {
        guard !closed else { return }
        finishCurrent(movingOn: false)
        closed = true
        loadTask?.cancel()
        pollTimer?.invalidate()
        pollTimer = nil
        updateActivity()
        videoView?.teardown()
        player?.destroy()
    }
}
