import Foundation
import ImageIO
import CoreGraphics

public enum FrameCameraNames {
    private static let lumixModelRegex = try! NSRegularExpression(
        pattern: "^(?:(?:Panasonic(?: Corporation)?|Lumix)\\s+)*(?:DC-|DMC-|Lumix\\s+)([A-Z0-9][A-Z0-9._-]*)$",
        options: [.caseInsensitive]
    )

    public static func format(_ exifCamera: String) -> String {
        let camera = exifCamera
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let range = NSRange(camera.startIndex..<camera.endIndex, in: camera)
        guard let match = lumixModelRegex.firstMatch(in: camera, options: [], range: range),
              let modelRange = Range(match.range(at: 1), in: camera) else {
            return camera
        }
        return "Lumix \(camera[modelRange].uppercased())"
    }
}

public struct PhotoMetadata: Equatable, Hashable, Codable, Sendable {
    public var camera: String
    public var lens: String
    public var capturedAt: String
    public var iso: String
    public var aperture: String
    public var shutter: String
    public var focalLength: String

    public init(
        camera: String = "",
        lens: String = "",
        capturedAt: String = "",
        iso: String = "",
        aperture: String = "",
        shutter: String = "",
        focalLength: String = ""
    ) {
        self.camera = camera
        self.lens = lens
        self.capturedAt = capturedAt
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
        self.focalLength = focalLength
    }

    public var frameCameraName: String {
        FrameCameraNames.format(camera)
    }

    public var detail: String {
        [lens, focalLength, aperture, shutter, iso]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "  ·  ")
    }

    public func frameDetail(options: FrameOptions) -> String {
        var parts: [String] = []
        if options.showLens && !lens.isEmpty { parts.append(lens) }
        if options.showFocalLength && !focalLength.isEmpty { parts.append(focalLength) }
        if options.showAperture && !aperture.isEmpty { parts.append(aperture) }
        if options.showShutter && !shutter.isEmpty { parts.append(shutter) }
        if options.showIso && !iso.isEmpty { parts.append(iso) }
        if options.showCapturedAt && !capturedAt.isEmpty { parts.append(capturedAt) }
        return parts.joined(separator: "  ·  ")
    }
}

public struct SourceImage: Equatable, Identifiable, Codable, Sendable {
    public let id: PhotoId
    public let name: String
    public let jpegURL: URL
    public let size: PixelSize
    public let orientation: Int
    public let origin: InputOrigin
    public let metadata: PhotoMetadata

    public init(
        id: PhotoId,
        name: String,
        jpegURL: URL,
        size: PixelSize,
        orientation: Int,
        origin: InputOrigin,
        metadata: PhotoMetadata
    ) {
        self.id = id
        self.name = name
        self.jpegURL = jpegURL
        self.size = size
        self.orientation = orientation
        self.origin = origin
        self.metadata = metadata
    }

    public var rawNotice: String? {
        if case .rawEmbeddedJpeg = origin {
            return "使用 RAW 内嵌 JPEG · \(size.width) × \(size.height) · 输出尺寸以预览图为准"
        }
        return nil
    }
}

// MARK: - RawJpegExtractor

public enum RawJpegExtractor {
    public static let maxPreviewBytes: Int = 64 * 1024 * 1024

    public struct ByteRange: Equatable, Hashable, Sendable {
        public let offset: Int
        public let length: Int

        public init(offset: Int, length: Int) {
            self.offset = offset
            self.length = length
        }
    }

    /// Scans TIFF / Panasonic RW2 IFDs for embedded JPEG previews (`0x002e` or `0x0201`/`0x0202`).
    public static func candidates(in data: Data) -> [ByteRange] {
        guard data.count >= 8 else { return [] }
        let first = (UInt16(data[0]) << 8) | UInt16(data[1])
        let little: Bool
        switch first {
        case 0x4949: little = true
        case 0x4D4D: little = false
        default: return []
        }

        func readUInt16(at pos: Int) -> Int {
            let a = Int(data[pos])
            let b = Int(data[pos + 1])
            return little ? (a | (b << 8)) : ((a << 8) | b)
        }

        func readUInt32(at pos: Int) -> Int {
            let a = readUInt16(at: pos)
            let b = readUInt16(at: pos + 2)
            return little ? (a | (b << 16)) : ((a << 16) | b)
        }

        func valid(offset: Int, count: Int) -> Bool {
            offset >= 0 && count > 0 && offset <= data.count - count
        }

        let magic = readUInt16(at: 2)
        guard magic == 42 || magic == 85 else { return [] } // TIFF or Panasonic RW2 (85 = 0x0055)

        var queue: [Int] = [readUInt32(at: 4)]
        var visited = Set<Int>()
        var found: [ByteRange] = []

        func values(type: Int, count: Int, fieldPos: Int) -> [Int] {
            guard (1...32).contains(count), [3, 4, 13].contains(type) else { return [] }
            let elemSize = (type == 3) ? 2 : 4
            let bytesCount = count * elemSize
            let position: Int
            if bytesCount <= 4 {
                position = fieldPos
            } else {
                guard valid(offset: fieldPos, count: 4) else { return [] }
                position = readUInt32(at: fieldPos)
            }
            guard valid(offset: position, count: bytesCount) else { return [] }
            return (0..<count).map { i in
                let p = position + i * elemSize
                return (type == 3) ? readUInt16(at: p) : readUInt32(at: p)
            }
        }

        while !queue.isEmpty && visited.count < 64 {
            let offset = queue.removeFirst()
            if offset == 0 || !visited.insert(offset).inserted || !valid(offset: offset, count: 2) {
                continue
            }
            let count = readUInt16(at: offset)
            if !valid(offset: offset + 2, count: count * 12 + 4) {
                continue
            }
            var jpegOffset: Int? = nil
            var jpegLength: Int? = nil

            for i in 0..<count {
                let entry = offset + 2 + i * 12
                let tag = readUInt16(at: entry)
                let type = readUInt16(at: entry + 2)
                let amount = readUInt32(at: entry + 4)
                let field = entry + 8
                switch tag {
                case 0x002E: // Panasonic RW2 JpgFromRaw
                    if type == 7 || type == 1 {
                        let start = (amount <= 4) ? field : readUInt32(at: field)
                        if valid(offset: start, count: amount) {
                            found.append(ByteRange(offset: start, length: amount))
                        }
                    }
                case 0x0201:
                    jpegOffset = values(type: type, count: amount, fieldPos: field).first
                case 0x0202:
                    jpegLength = values(type: type, count: amount, fieldPos: field).first
                case 0x014A: // SubIFDs
                    queue.append(contentsOf: values(type: type, count: amount, fieldPos: field))
                default:
                    break
                }
            }
            if let jOff = jpegOffset, let jLen = jpegLength, valid(offset: jOff, count: jLen) {
                found.append(ByteRange(offset: jOff, length: jLen))
            }
            let next = readUInt32(at: offset + 2 + count * 12)
            if next != 0 {
                queue.append(next)
            }
        }

        var unique: [ByteRange] = []
        for range in found where !unique.contains(range) {
            if (4...maxPreviewBytes).contains(range.length),
               valid(offset: range.offset, count: range.length),
               data[range.offset] == 0xFF && data[range.offset + 1] == 0xD8 {
                unique.append(range)
            }
        }
        return unique
    }

    public static func extractLargestJpeg(from rawData: Data) -> Data? {
        let ranges = candidates(in: rawData)
        var bestData: Data? = nil
        var bestPixels: Int64 = 0
        for r in ranges {
            let sub = rawData.subdata(in: r.offset..<(r.offset + r.length))
            if let size = ImageImporter.jpegDimensions(of: sub) {
                let px = Int64(size.width) * Int64(size.height)
                if px > bestPixels {
                    bestPixels = px
                    bestData = sub
                }
            }
        }
        return bestData
    }
}

// MARK: - ImageImporter

public final class ImageImporter: @unchecked Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.rootDirectory = appSupport.appendingPathComponent("Lumatte/source-jpegs", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    public func importData(
        _ data: Data,
        displayName: String = "照片",
        rawEmbeddedPreview: Bool = false,
        photoId: PhotoId? = nil
    ) throws -> SourceImage {
        let id = photoId ?? PhotoId(UUID().uuidString.lowercased())
        let dir = rootDirectory.appendingPathComponent(id.value, isDirectory: true)
        if let existing = try? readManifest(in: dir, id: id) {
            return existing
        }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            let isJpeg = data.count >= 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
            let jpegData: Data
            if isJpeg {
                jpegData = data
            } else {
                guard let extracted = RawJpegExtractor.extractLargestJpeg(from: data) else {
                    throw LumatteError.illegalState("未找到可用的内嵌 JPEG，请导入相机 JPEG 成片")
                }
                jpegData = extracted
            }

            guard let encodedSize = Self.jpegDimensions(of: jpegData) else {
                throw LumatteError.illegalState("JPEG 数据无法读取")
            }

            let jpegURL = dir.appendingPathComponent("source.jpg")
            try jpegData.write(to: jpegURL, options: .atomic)

            let embeddedProps = Self.imageProperties(of: jpegData)
            let originalProps = isJpeg ? embeddedProps : Self.imageProperties(of: data)
            let orientation = Self.extractOrientation(from: embeddedProps)
                ?? Self.extractOrientation(from: originalProps)
                ?? 1
            let rotated = [5, 6, 7, 8].contains(orientation)
            let logicalSize = rotated
                ? PixelSize(uncheckedWidth: encodedSize.height, height: encodedSize.width)
                : encodedSize
            let metadata = Self.extractMetadata(from: originalProps ?? embeddedProps)
            let origin: InputOrigin = (isJpeg && !rawEmbeddedPreview) ? .jpeg : .rawEmbeddedJpeg(dimensions: logicalSize)

            let source = SourceImage(
                id: id,
                name: displayName,
                jpegURL: jpegURL,
                size: logicalSize,
                orientation: orientation,
                origin: origin,
                metadata: metadata
            )
            try writeManifest(source, in: dir)
            return source
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    public func importFile(at url: URL, displayName: String? = nil) throws -> SourceImage {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try importData(data, displayName: displayName ?? url.lastPathComponent)
    }

    public func recoverImports() -> [SourceImage] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var results: [SourceImage] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = PhotoId(dir.lastPathComponent)
            if let img = try? readManifest(in: dir, id: id) {
                results.append(img)
            }
        }
        return results
    }

    private func writeManifest(_ image: SourceImage, in dir: URL) throws {
        let data = try JSONEncoder().encode(image)
        try data.write(to: dir.appendingPathComponent("source.json"), options: .atomic)
    }

    private func readManifest(in dir: URL, id: PhotoId) throws -> SourceImage? {
        let manifestURL = dir.appendingPathComponent("source.json")
        let jpegURL = dir.appendingPathComponent("source.jpg")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              FileManager.default.fileExists(atPath: jpegURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: manifestURL)
        let decoded = try JSONDecoder().decode(SourceImage.self, from: data)
        return SourceImage(
            id: id,
            name: decoded.name,
            jpegURL: jpegURL,
            size: decoded.size,
            orientation: decoded.orientation,
            origin: decoded.origin,
            metadata: decoded.metadata
        )
    }

    public static func jpegDimensions(of data: Data) -> PixelSize? {
        guard data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else {
            return nil
        }
        return PixelSize(uncheckedWidth: w, height: h)
    }

    private static func imageProperties(of data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    private static func extractOrientation(from props: [CFString: Any]?) -> Int? {
        if let top = props?[kCGImagePropertyOrientation] as? Int, (1...8).contains(top) {
            return top
        }
        if let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let orient = tiff[kCGImagePropertyTIFFOrientation] as? Int,
           (1...8).contains(orient) {
            return orient
        }
        return nil
    }

    private static func extractMetadata(from props: [CFString: Any]?) -> PhotoMetadata {
        guard let props else { return PhotoMetadata() }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]

        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let camera = [make, model].filter { !$0.isEmpty }.joined(separator: " ")

        let lens = (exif?[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let capturedAt = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let iso: String = {
            if let ratings = exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = ratings.first {
                return "ISO \(first.intValue)"
            }
            if let num = exif?[kCGImagePropertyExifISOSpeedRatings] as? NSNumber {
                return "ISO \(num.intValue)"
            }
            return ""
        }()

        let aperture: String = {
            if let fNum = (exif?[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue, fNum > 0 {
                return String(format: "f/%.1f", fNum)
            }
            return ""
        }()

        let shutter: String = {
            if let exp = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, exp > 0 {
                if exp < 1.0 {
                    return "1/\(Int((1.0 / exp).rounded())) s"
                } else {
                    return String(format: "%.1f s", exp)
                }
            }
            return ""
        }()

        let focalLength: String = {
            if let focal = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue, focal > 0 {
                return String(format: "%.0f mm", focal)
            }
            return ""
        }()

        return PhotoMetadata(
            camera: camera,
            lens: lens,
            capturedAt: capturedAt,
            iso: iso,
            aperture: aperture,
            shutter: shutter,
            focalLength: focalLength
        )
    }
}
