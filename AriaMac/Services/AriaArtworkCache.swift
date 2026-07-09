import AppKit
import Foundation

actor AriaArtworkCache {
    static let shared = AriaArtworkCache()

    private let cacheDuration: TimeInterval = 7 * 24 * 60 * 60
    private let cacheDirectory: URL
    private let fileManager = FileManager.default
    private let memoryCache = NSCache<NSURL, NSImage>()

    private init() {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = cachesDirectory.appendingPathComponent("AriaMacArtworkCache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func image(for url: URL) async -> NSImage? {
        if let memoryImage = memoryCache.object(forKey: url as NSURL) {
            return memoryImage
        }

        if let diskImage = cachedImage(for: url) {
            memoryCache.setObject(diskImage, forKey: url as NSURL)
            return diskImage
        }

        guard let downloadedImage = await downloadImage(from: url) else {
            return nil
        }

        memoryCache.setObject(downloadedImage, forKey: url as NSURL)
        return downloadedImage
    }

    func removeExpiredArtwork() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        for fileURL in files where isExpired(fileURL) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func cachedImage(for url: URL) -> NSImage? {
        let fileURL = cacheFileURL(for: url)
        guard !isExpired(fileURL) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        guard let image = NSImage(data: data) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }

        return image
    }

    private func downloadImage(from url: URL) async -> NSImage? {
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                guard 200..<300 ~= httpResponse.statusCode else {
                    return nil
                }
            }

            guard let image = NSImage(data: data) else {
                return nil
            }

            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cacheFileURL(for: url), options: [.atomic])
            return image
        } catch {
            return nil
        }
    }

    private func isExpired(_ fileURL: URL) -> Bool {
        guard
            fileManager.fileExists(atPath: fileURL.path),
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
            let modificationDate = attributes[.modificationDate] as? Date
        else {
            return false
        }

        return Date().timeIntervalSince(modificationDate) > cacheDuration
    }

    private func cacheFileURL(for url: URL) -> URL {
        cacheDirectory
            .appendingPathComponent(stableHash(for: url.absoluteString))
            .appendingPathExtension("image")
    }

    private func stableHash(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037

        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }

        return String(hash, radix: 16)
    }
}
