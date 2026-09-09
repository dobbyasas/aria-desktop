import AppKit
import Foundation
import ImageIO

actor AriaArtworkCache {
    static let shared = AriaArtworkCache()

    private let cacheDuration: TimeInterval = 7 * 24 * 60 * 60
    private let cacheDirectory: URL
    private let fileManager = FileManager.default
    private let memoryCache = NSCache<NSString, NSImage>()
    private var pendingImages: [String: Task<NSImage?, Never>] = [:]
    private var pendingDownloads: [URL: Task<Data?, Never>] = [:]

    private init() {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = cachesDirectory.appendingPathComponent("AriaMacArtworkCache", isDirectory: true)
        memoryCache.totalCostLimit = 24 * 1_024 * 1_024
        memoryCache.countLimit = 256
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Share a few Retina-sized variants instead of retaining full-resolution covers for rows.
    nonisolated static func pixelSize(for requestedSize: CGFloat) -> Int {
        [96, 256, 512, 1_024].first { CGFloat($0) >= requestedSize } ?? 1_024
    }

    func image(for url: URL, maxPixelSize: Int = 512) async -> NSImage? {
        let pixels = Self.pixelSize(for: CGFloat(maxPixelSize))
        let key = "\(url.absoluteString)|\(pixels)"
        if let image = memoryCache.object(forKey: key as NSString) { return image }
        if let pending = pendingImages[key] { return await pending.value }

        let task = Task { await loadImage(for: url, pixels: pixels) }
        pendingImages[key] = task
        let image = await task.value
        pendingImages[key] = nil
        if let image {
            let cost = Int(image.size.width) * Int(image.size.height) * 4
            memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }

    func palette(for url: URL, symbolName: String) async -> ArtworkPalette? {
        guard let image = await image(for: url, maxPixelSize: 96) else { return nil }
        return image.ariaArtworkPalette(symbolName: symbolName)
    }

    func removeExpiredArtwork() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for fileURL in files where isExpired(fileURL) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func loadImage(for url: URL, pixels: Int) async -> NSImage? {
        let fileURL = cacheFileURL(for: url)
        if isExpired(fileURL) { try? fileManager.removeItem(at: fileURL) }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if fileManager.fileExists(atPath: fileURL.path),
           let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions),
           let image = Self.thumbnail(source, pixels: pixels) {
            return image
        }
        guard let data = await imageData(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return Self.thumbnail(source, pixels: pixels)
    }

    private static func thumbnail(_ source: CGImageSource, pixels: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func imageData(from url: URL) async -> Data? {
        // A row, record label and palette can request the same cover concurrently.
        if let pending = pendingDownloads[url] { return await pending.value }
        let task = Task<Data?, Never> {
            do {
                if url.isFileURL { return try Data(contentsOf: url) }
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      CGImageSourceCreateWithData(data as CFData, nil) != nil else { return nil }
                try? data.write(to: cacheFileURL(for: url), options: [.atomic])
                return data
            } catch { return nil }
        }
        pendingDownloads[url] = task
        let data = await task.value
        pendingDownloads[url] = nil
        return data
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

private extension NSImage {
    func ariaArtworkPalette(symbolName: String) -> ArtworkPalette {
        ArtworkPalette(
            topHex: averageHexColor(in: CGRect(x: 0, y: 0, width: 1, height: 0.56)),
            bottomHex: averageHexColor(in: CGRect(x: 0, y: 0.44, width: 1, height: 0.56)),
            symbolName: symbolName
        )
    }

    private func averageHexColor(in normalizedRect: CGRect) -> String {
        var imageRect = CGRect(origin: .zero, size: size)
        guard let cgImage = cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else {
            return "#2D3142"
        }

        let width = 18
        let height = 18
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return "#2D3142"
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let startX = max(Int(normalizedRect.minX * CGFloat(width)), 0)
        let endX = min(max(Int(normalizedRect.maxX * CGFloat(width)), startX + 1), width)
        let startY = max(Int(normalizedRect.minY * CGFloat(height)), 0)
        let endY = min(max(Int(normalizedRect.maxY * CGFloat(height)), startY + 1), height)

        var redTotal: Double = 0
        var greenTotal: Double = 0
        var blueTotal: Double = 0
        var sampleCount: Double = 0

        for y in startY..<endY {
            for x in startX..<endX {
                let index = (y * width + x) * bytesPerPixel
                redTotal += Double(pixels[index])
                greenTotal += Double(pixels[index + 1])
                blueTotal += Double(pixels[index + 2])
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return "#2D3142"
        }

        return NSColor(
            red: redTotal / sampleCount / 255,
            green: greenTotal / sampleCount / 255,
            blue: blueTotal / sampleCount / 255,
            alpha: 1
        ).ariaBoostedHex
    }
}

private extension NSColor {
    var ariaBoostedHex: String {
        guard let rgbColor = usingColorSpace(.deviceRGB) else {
            return "#2D3142"
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let boostedColor = NSColor(
            hue: hue,
            saturation: min(max(saturation * 1.24, 0.34), 0.86),
            brightness: min(max(brightness * 1.08, 0.26), 0.82),
            alpha: alpha
        )

        guard let boostedRGB = boostedColor.usingColorSpace(.deviceRGB) else {
            return "#2D3142"
        }

        return String(
            format: "#%02X%02X%02X",
            Int(boostedRGB.redComponent * 255),
            Int(boostedRGB.greenComponent * 255),
            Int(boostedRGB.blueComponent * 255)
        )
    }
}
