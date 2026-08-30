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

    func palette(for url: URL, symbolName: String) async -> ArtworkPalette? {
        guard let image = await image(for: url) else {
            return nil
        }

        return image.ariaArtworkPalette(symbolName: symbolName)
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
