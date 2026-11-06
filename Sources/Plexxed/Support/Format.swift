import Foundation

enum Format {
    /// "2 h 14 min", "48 min". Takes milliseconds, as Plex reports them.
    static func runtime(ms: Int?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let minutes = Int((Double(ms) / 60_000).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "38 min left", "1 h 5 min left".
    static func remaining(ms: Int) -> String {
        let text = runtime(ms: max(ms, 60_000)) ?? "1 min"
        return "\(text) left"
    }

    /// Player clock: "42:10", "1:02:13".
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(seconds, 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func airDate(_ iso: String?) -> String? {
        guard let iso, let date = isoDay.date(from: iso) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
