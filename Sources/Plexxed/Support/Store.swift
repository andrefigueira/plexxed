import Foundation

enum AppPaths {
    static let support: URL = directory(
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plexxed", isDirectory: true)
    )
    static let caches: URL = directory(
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.plexxed", isDirectory: true)
    )
    static let images: URL = directory(caches.appendingPathComponent("images", isDirectory: true))
    static let responses: URL = directory(caches.appendingPathComponent("responses", isDirectory: true))

    private static func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct Credentials: Codable {
    var userToken: String
    var server: PlexServer?
}

/// The Plex token lives in a file only this user can read. Keychain needs a stable
/// signing identity, which an ad-hoc signed personal build doesn't have.
enum CredentialStore {
    private static let url = AppPaths.support.appendingPathComponent("credentials.json")

    static func load() -> Credentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.error("Saving credentials failed: \(error.localizedDescription)")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Raw server responses, kept so every screen can draw instantly from the last known state.
enum ResponseCache {
    private static let queue = DispatchQueue(label: "app.plexxed.responses", qos: .utility)

    static func read(_ key: String) -> Data? {
        try? Data(contentsOf: file(key))
    }

    static func write(_ data: Data, key: String) {
        let target = file(key)
        queue.async { try? data.write(to: target, options: .atomic) }
    }

    static func clear() {
        queue.async {
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: AppPaths.responses, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func file(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return AppPaths.responses.appendingPathComponent(safe + ".json")
    }
}
