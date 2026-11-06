import Foundation
import os

/// Writes to the unified log and to ~/Library/Logs/Plexxed.log. Never pass tokens in here.
enum Log {
    private static let logger = Logger(subsystem: "app.plexxed", category: "app")
    private static let queue = DispatchQueue(label: "app.plexxed.log", qos: .utility)
    private static let maxBytes = 2 * 1024 * 1024

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Plexxed.log")
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    /// Starts a fresh file when the old one has grown past the cap.
    static func rotateIfNeeded() {
        queue.async {
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            if size > maxBytes { try? FileManager.default.removeItem(at: fileURL) }
        }
    }

    private static func write(_ level: String, _ message: String) {
        let stamp = Date().formatted(.iso8601)
        let line = "\(stamp) [\(level)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
