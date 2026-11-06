import Cmpv
import Foundation

struct MPVTrack: Identifiable, Hashable {
    let id: Int
    let type: String
    let title: String?
    let lang: String?
    let codec: String?
    let selected: Bool
    let ffIndex: Int?
    let external: Bool
    let externalFilename: String?
    let channels: Int?

    var label: String {
        let language = lang.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        return [title, language].compactMap { $0 }.first ?? "Track \(id)"
    }
}

enum MPVEvent {
    case duration(Double)
    case paused(Bool)
    case buffering(Bool)
    case seeking(Bool)
    case eof(Bool)
    case volume(Double)
    case muted(Bool)
    case tracks([MPVTrack])
    case fileLoaded
    case playbackRestart
    case endFile(error: String?)
}

/// A thin, thread-safe wrapper around one libmpv instance.
/// Events are drained on a private queue and delivered to the main thread in batches.
final class MPVPlayer: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "app.plexxed.mpv.events", qos: .userInitiated)

    /// Runs on the main thread.
    var onEvents: (([MPVEvent]) -> Void)?

    init?(httpHeaders: [String: String], volume: Double) {
        guard let mpv = mpv_create() else { return nil }
        handle = mpv
        let headerList = httpHeaders.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        let options: [(String, String)] = [
            ("vo", "libmpv"),
            // Hardware decoding: HEVC, H.264, AV1 and 10-bit HDR decode on the media engine, not the CPU.
            ("hwdec", "videotoolbox"),
            ("idle", "yes"),
            ("keep-open", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            // A deep read-ahead buffer smooths over a slow NAS disk or busy Wi-Fi.
            ("cache", "yes"),
            ("demuxer-max-bytes", "256MiB"),
            ("demuxer-max-back-bytes", "64MiB"),
            ("demuxer-readahead-secs", "45"),
            ("network-timeout", "20"),
            ("user-agent", "Plexxed/\(PlexClient.version)"),
            ("http-header-fields", headerList),
            ("sub-auto", "no"),
            ("audio-file-auto", "no"),
            ("sub-font-size", "44"),
            ("sub-border-size", "2.4"),
            ("sub-margin-y", "36"),
            ("volume", String(Int(volume))),
            ("volume-max", "100"),
        ]
        for (name, value) in options {
            mpv_set_option_string(mpv, name, value)
        }
        mpv_request_log_messages(mpv, "error")
        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            handle = nil
            return nil
        }
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("paused-for-cache", MPV_FORMAT_FLAG)
        observe("seeking", MPV_FORMAT_FLAG)
        observe("eof-reached", MPV_FORMAT_FLAG)
        observe("volume", MPV_FORMAT_DOUBLE)
        observe("mute", MPV_FORMAT_FLAG)
        observe("track-list", MPV_FORMAT_NONE)

        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let player = Unmanaged<MPVPlayer>.fromOpaque(context).takeUnretainedValue()
            player.eventQueue.async { player.drain() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Control

    func command(_ args: [String]) {
        guard let handle else { return }
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        cArgs.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                let status = mpv_command(handle, pointer)
                if status < 0 {
                    Log.error("mpv command \(args.first ?? "") failed: \(String(cString: mpv_error_string(status)))")
                }
            }
        }
    }

    func set(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    func double(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func string(_ name: String) -> String? {
        guard let handle, let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    func destroy() {
        guard let mpv = handle else { return }
        onEvents = nil
        // Serialised with event draining, so no callback can touch a freed handle.
        eventQueue.async { [self] in
            mpv_set_wakeup_callback(mpv, nil, nil)
            handle = nil
            mpv_terminate_destroy(mpv)
        }
    }

    // MARK: Events

    private func observe(_ name: String, _ format: mpv_format) {
        guard let handle else { return }
        mpv_observe_property(handle, 0, name, format)
    }

    private func drain() {
        guard let mpv = handle else { return }
        var events: [MPVEvent] = []
        var tracksChanged = false

        loop: while true {
            guard let event = mpv_wait_event(mpv, 0) else { break }
            switch event.pointee.event_id {
            case MPV_EVENT_NONE:
                break loop
            case MPV_EVENT_SHUTDOWN:
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.pointee.data else { continue }
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                switch String(cString: property.name) {
                case "track-list": tracksChanged = true
                case "duration": if let v = property.doubleValue { events.append(.duration(v)) }
                case "pause": if let v = property.flagValue { events.append(.paused(v)) }
                case "paused-for-cache": if let v = property.flagValue { events.append(.buffering(v)) }
                case "seeking": if let v = property.flagValue { events.append(.seeking(v)) }
                case "eof-reached": if let v = property.flagValue { events.append(.eof(v)) }
                case "volume": if let v = property.doubleValue { events.append(.volume(v)) }
                case "mute": if let v = property.flagValue { events.append(.muted(v)) }
                default: break
                }
            case MPV_EVENT_FILE_LOADED:
                events.append(.fileLoaded)
                tracksChanged = true
            case MPV_EVENT_PLAYBACK_RESTART:
                events.append(.playbackRestart)
            case MPV_EVENT_END_FILE:
                guard let data = event.pointee.data else { continue }
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    events.append(.endFile(error: String(cString: mpv_error_string(end.error))))
                } else {
                    events.append(.endFile(error: nil))
                }
            case MPV_EVENT_LOG_MESSAGE:
                guard let data = event.pointee.data else { continue }
                let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                let text = String(cString: message.text).trimmingCharacters(in: .whitespacesAndNewlines)
                Log.error("mpv[\(String(cString: message.prefix))] \(text)")
            default:
                break
            }
        }

        if tracksChanged { events.append(.tracks(readTracks(mpv))) }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onEvents?(events) }
    }

    private func readTracks(_ mpv: OpaquePointer) -> [MPVTrack] {
        var node = mpv_node()
        guard mpv_get_property(mpv, "track-list", MPV_FORMAT_NODE, &node) >= 0 else { return [] }
        defer { mpv_free_node_contents(&node) }
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list?.pointee else { return [] }

        var tracks: [MPVTrack] = []
        for i in 0..<Int(list.num) {
            let entry = list.values[i]
            guard entry.format == MPV_FORMAT_NODE_MAP, let map = entry.u.list?.pointee else { continue }
            var fields: [String: Any] = [:]
            for j in 0..<Int(map.num) {
                guard let rawKey = map.keys[j] else { continue }
                let value = map.values[j]
                let key = String(cString: rawKey)
                switch value.format {
                case MPV_FORMAT_STRING: fields[key] = String(cString: value.u.string)
                case MPV_FORMAT_FLAG: fields[key] = value.u.flag != 0
                case MPV_FORMAT_INT64: fields[key] = Int(value.u.int64)
                case MPV_FORMAT_DOUBLE: fields[key] = value.u.double_
                default: break
                }
            }
            guard let id = fields["id"] as? Int, let type = fields["type"] as? String else { continue }
            tracks.append(MPVTrack(
                id: id,
                type: type,
                title: fields["title"] as? String,
                lang: fields["lang"] as? String,
                codec: fields["codec"] as? String,
                selected: fields["selected"] as? Bool ?? false,
                ffIndex: fields["ff-index"] as? Int,
                external: fields["external"] as? Bool ?? false,
                externalFilename: fields["external-filename"] as? String,
                channels: fields["demux-channel-count"] as? Int
            ))
        }
        return tracks
    }
}

private extension mpv_event_property {
    var doubleValue: Double? {
        guard format == MPV_FORMAT_DOUBLE, let data else { return nil }
        return data.assumingMemoryBound(to: Double.self).pointee
    }

    var flagValue: Bool? {
        guard format == MPV_FORMAT_FLAG, let data else { return nil }
        return data.assumingMemoryBound(to: Int32.self).pointee != 0
    }
}
