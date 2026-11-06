import CryptoKit
import Foundation
import ImageIO
import SwiftUI

struct ImageRequest: Hashable, Sendable {
    let url: URL
    let token: String?
    let cacheKey: String
    let maxPixel: Int
}

/// Memory cache, then disk cache, then network. Decodes off the main thread at display size,
/// and cancels a download when every view waiting on it has scrolled away.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private struct Inflight {
        let task: Task<CGImage?, Never>
        var waiters: Int
    }

    private let memory: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()
    private let lock = NSLock()
    private var inflight: [String: Inflight] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func cached(_ key: String) -> CGImage? {
        memory.object(forKey: key as NSString)?.image
    }

    func image(for request: ImageRequest) async -> CGImage? {
        if let hit = cached(request.cacheKey) { return hit }
        let key = request.cacheKey
        let task: Task<CGImage?, Never> = lock.withLock {
            if var existing = inflight[key] {
                existing.waiters += 1
                inflight[key] = existing
                return existing.task
            }
            let task = Task.detached(priority: .userInitiated) { [self] in await self.fetch(request) }
            inflight[key] = Inflight(task: task, waiters: 1)
            return task
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            self.release(key)
        }
        lock.withLock {
            if inflight[key]?.task == task, !task.isCancelled { inflight[key] = nil }
        }
        return result
    }

    private func release(_ key: String) {
        lock.withLock {
            guard var entry = inflight[key] else { return }
            entry.waiters -= 1
            if entry.waiters <= 0 {
                entry.task.cancel()
                inflight[key] = nil
            } else {
                inflight[key] = entry
            }
        }
    }

    private func fetch(_ request: ImageRequest) async -> CGImage? {
        let file = AppPaths.images.appendingPathComponent(Self.hash(request.cacheKey))
        if let data = try? Data(contentsOf: file), let image = decode(data, maxPixel: request.maxPixel) {
            store(image, key: request.cacheKey)
            return image
        }
        if Task.isCancelled { return nil }

        var urlRequest = URLRequest(url: request.url)
        if let token = request.token {
            for (name, value) in PlexClient.headers(token: token) { urlRequest.setValue(value, forHTTPHeaderField: name) }
        }
        urlRequest.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: urlRequest),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = decode(data, maxPixel: request.maxPixel)
        else { return nil }
        try? data.write(to: file, options: .atomic)
        store(image, key: request.cacheKey)
        return image
    }

    private func store(_ image: CGImage, key: String) {
        memory.setObject(Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    private func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Disk housekeeping

    func diskUsage() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: AppPaths.images, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clearAll() {
        memory.removeAllObjects()
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: AppPaths.images, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    /// Keeps the disk cache under a cap by dropping the least recently written files.
    func trimDisk(limit: Int64 = 1_000_000_000) {
        DispatchQueue.global(qos: .background).async {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: AppPaths.images, includingPropertiesForKeys: keys)) ?? []
            var files = urls.compactMap { url -> (URL, Int64, Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
            }
            var total = files.reduce(0) { $0 + $1.1 }
            guard total > limit else { return }
            files.sort { $0.2 < $1.2 }
            for file in files where total > limit * 3 / 4 {
                try? FileManager.default.removeItem(at: file.0)
                total -= file.1
            }
        }
    }
}

/// Plex artwork with a solid placeholder while it loads.
struct PlexImage: View {
    let request: ImageRequest?
    var contentMode: ContentMode = .fill
    var placeholder: Color = Theme.surface

    @State private var image: CGImage?

    init(_ request: ImageRequest?, contentMode: ContentMode = .fill, placeholder: Color = Theme.surface) {
        self.request = request
        self.contentMode = contentMode
        self.placeholder = placeholder
        _image = State(initialValue: request.flatMap { ImagePipeline.shared.cached($0.cacheKey) })
    }

    var body: some View {
        placeholder
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: request?.cacheKey) {
                guard let request else {
                    image = nil
                    return
                }
                if let hit = ImagePipeline.shared.cached(request.cacheKey) {
                    image = hit
                    return
                }
                image = nil
                let loaded = await ImagePipeline.shared.image(for: request)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}
