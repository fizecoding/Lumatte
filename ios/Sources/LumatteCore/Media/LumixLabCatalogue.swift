import Foundation
import Compression
import CoreGraphics

public struct LumixLabProtocolException: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct LumixLabHttpException: Error, LocalizedError, Equatable, Sendable {
    public let statusCode: Int

    public init(statusCode: Int) {
        self.statusCode = statusCode
    }

    public var errorDescription: String? {
        "Lumix Lab 请求失败（HTTP \(statusCode)）"
    }
}

public struct LumixLabImageRef: Equatable, Hashable, Codable, Sendable {
    public let path: String
    public let originalPath: String?
    public let width: Int?
    public let height: Int?

    public init(path: String, originalPath: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.path = path
        self.originalPath = originalPath
        self.width = width
        self.height = height
    }
}

public struct LumixLabCreator: Equatable, Hashable, Codable, Sendable {
    public let code: String?
    public let name: String?
    public let icon: LumixLabImageRef?

    public init(code: String?, name: String?, icon: LumixLabImageRef?) {
        self.code = code
        self.name = name
        self.icon = icon
    }
}

public struct LumixLabGenreTop: Equatable, Hashable, Codable, Sendable {
    public let region: String?
    public let thumbnail: LumixLabImageRef?

    public init(region: String?, thumbnail: LumixLabImageRef?) {
        self.region = region
        self.thumbnail = thumbnail
    }
}

public struct LumixLabGenre: Equatable, Hashable, Identifiable, Codable, Sendable {
    public var id: String { code }
    public let code: String
    public let title: String
    public let thumbnail: LumixLabImageRef?
    public let top: [LumixLabGenreTop]

    public init(code: String, title: String, thumbnail: LumixLabImageRef?, top: [LumixLabGenreTop]) {
        self.code = code
        self.title = title
        self.thumbnail = thumbnail
        self.top = top
    }
}

public struct LumixLabLut: Equatable, Hashable, Identifiable, Codable, Sendable {
    public var id: String { code }
    public let code: String
    public let title: String
    public let creator: LumixLabCreator?
    public let thumbnail: LumixLabImageRef?
    public let downloadCount: Int?

    public init(
        code: String,
        title: String,
        creator: LumixLabCreator?,
        thumbnail: LumixLabImageRef?,
        downloadCount: Int?
    ) {
        self.code = code
        self.title = title
        self.creator = creator
        self.thumbnail = thumbnail
        self.downloadCount = downloadCount
    }
}

public struct LumixLabLutDetail: Equatable, Sendable {
    public let lut: LumixLabLut
    public let overview: String?
    public let photoStyle: String?
    public let locale: String?
    public let grid17: String?
    public let grid33: String?

    public init(
        lut: LumixLabLut,
        overview: String?,
        photoStyle: String?,
        locale: String?,
        grid17: String?,
        grid33: String?
    ) {
        self.lut = lut
        self.overview = overview
        self.photoStyle = photoStyle
        self.locale = locale
        self.grid17 = grid17
        self.grid33 = grid33
    }
}

public struct LumixLabLutQuery: Equatable, Sendable {
    public let language: String
    public let offset: Int
    public let limit: Int
    public let genreCode: String?
    public let creatorCode: String?
    public let countries: [String]

    public init(
        language: String = "zh",
        offset: Int = 0,
        limit: Int = 20,
        genreCode: String? = nil,
        creatorCode: String? = nil,
        countries: [String] = []
    ) {
        self.language = language
        self.offset = offset
        self.limit = limit
        self.genreCode = genreCode
        self.creatorCode = creatorCode
        self.countries = countries
    }
}

public struct LumixLabLutPage: Equatable, Sendable {
    public let items: [LumixLabLut]
    public let offset: Int
    public let requestedLimit: Int
    public let nextOffset: Int?

    public init(items: [LumixLabLut], offset: Int, requestedLimit: Int, nextOffset: Int?) {
        self.items = items
        self.offset = offset
        self.requestedLimit = requestedLimit
        self.nextOffset = nextOffset
    }
}

// MARK: - LumixLabJson

public enum LumixLabJson {
    private static func invalid() throws -> Never {
        throw LumixLabProtocolException("Lumix Lab 目录字段不符合已知格式")
    }

    public static func genres(_ jsonData: Data) throws -> [LumixLabGenre] {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            try invalid()
        }
        return try genres(root)
    }

    public static func genres(_ root: [String: Any]) throws -> [LumixLabGenre] {
        let arr = try array(in: root, key: "genres", maximum: 256)
        return try objects(arr).map { genre in
            let code = try required(in: genre, key: "code", limit: 256)
            let rawTitle = try text(in: genre, key: "title", limit: 1024)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle: String
            if let rawTitle, !rawTitle.isEmpty {
                resolvedTitle = rawTitle
            } else {
                switch code {
                case "movie": resolvedTitle = "电影"
                case "still": resolvedTitle = "摄影"
                default: resolvedTitle = code
                }
            }
            let topArr = try optionalArray(in: genre, key: "top", maximum: 64)
            let topItems: [LumixLabGenreTop]
            if let topArr {
                topItems = try objects(topArr).map { top in
                    LumixLabGenreTop(
                        region: try text(in: top, key: "region", limit: 256),
                        thumbnail: try image(in: top, key: "thumbnail")
                    )
                }
            } else {
                topItems = []
            }
            return LumixLabGenre(
                code: code,
                title: resolvedTitle,
                thumbnail: try image(in: genre, key: "thumbnail"),
                top: topItems
            )
        }
    }

    public static func luts(_ jsonData: Data) throws -> [LumixLabLut] {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            try invalid()
        }
        return try luts(root)
    }

    public static func luts(_ root: [String: Any]) throws -> [LumixLabLut] {
        let arr = try array(in: root, key: "filter", maximum: 256)
        return try objects(arr).map(parseLut)
    }

    public static func detail(_ jsonData: Data) throws -> LumixLabLutDetail {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            try invalid()
        }
        return try detail(root)
    }

    public static func detail(_ root: [String: Any]) throws -> LumixLabLutDetail {
        let files = try obj(in: root, key: "file")
        return LumixLabLutDetail(
            lut: try parseLut(root),
            overview: try text(in: root, key: "overview", limit: 32 * 1024),
            photoStyle: try text(in: root, key: "photo_style", limit: 256),
            locale: try text(in: root, key: "_locale", limit: 256),
            grid17: try files.flatMap { try text(in: $0, key: "grid17", limit: 4096) },
            grid33: try files.flatMap { try text(in: $0, key: "grid33", limit: 4096) }
        )
    }

    private static func parseLut(_ value: [String: Any]) throws -> LumixLabLut {
        let creatorObj = try obj(in: value, key: "creator")
        let creator: LumixLabCreator?
        if let creatorObj {
            creator = LumixLabCreator(
                code: try text(in: creatorObj, key: "code", limit: 256),
                name: try text(in: creatorObj, key: "name", limit: 1024),
                icon: try image(in: creatorObj, key: "icon")
            )
        } else {
            creator = nil
        }
        return LumixLabLut(
            code: try required(in: value, key: "code", limit: 256),
            title: try required(in: value, key: "title", limit: 1024),
            creator: creator,
            thumbnail: try image(in: value, key: "thumbnail"),
            downloadCount: try number(in: value, key: "download_number")
        )
    }

    private static func image(in dict: [String: Any], key: String) throws -> LumixLabImageRef? {
        guard let img = try obj(in: dict, key: key) else { return nil }
        guard let path = try text(in: img, key: "path", limit: 4096),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let w = try number(in: img, key: "width")
        let h = try number(in: img, key: "height")
        return LumixLabImageRef(
            path: path,
            originalPath: try text(in: img, key: "path_original", limit: 4096),
            width: (w != nil && w! > 0) ? w : nil,
            height: (h != nil && h! > 0) ? h : nil
        )
    }

    private static func required(in dict: [String: Any], key: String, limit: Int) throws -> String {
        guard let val = try text(in: dict, key: key, limit: limit),
              !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try invalid()
        }
        return val
    }

    private static func text(in dict: [String: Any], key: String, limit: Int) throws -> String? {
        guard let raw = dict[key], !(raw is NSNull) else { return nil }
        guard let str = raw as? String, str.count <= limit else {
            try invalid()
        }
        return str
    }

    private static func number(in dict: [String: Any], key: String) throws -> Int? {
        guard let raw = dict[key], !(raw is NSNull) else { return nil }
        let value: Int
        if let n = raw as? NSNumber {
            // Reject Bool masquerading as NSNumber
            if CFGetTypeID(n) == CFBooleanGetTypeID() { try invalid() }
            let int64 = n.int64Value
            guard (0...Int64(Int.max)).contains(int64) else { try invalid() }
            value = Int(int64)
        } else if let s = raw as? String, let parsed = Int(s), parsed >= 0 {
            value = parsed
        } else {
            try invalid()
        }
        return value
    }

    private static func obj(in dict: [String: Any], key: String) throws -> [String: Any]? {
        guard let raw = dict[key], !(raw is NSNull) else { return nil }
        guard let sub = raw as? [String: Any] else { try invalid() }
        return sub
    }

    private static func optionalArray(in dict: [String: Any], key: String, maximum: Int) throws -> [Any]? {
        guard let raw = dict[key], !(raw is NSNull) else { return nil }
        guard let arr = raw as? [Any], arr.count <= maximum else { try invalid() }
        return arr
    }

    private static func array(in dict: [String: Any], key: String, maximum: Int) throws -> [Any] {
        guard let arr = try optionalArray(in: dict, key: key, maximum: maximum) else {
            try invalid()
        }
        return arr
    }

    private static func objects(_ array: [Any]) throws -> [[String: Any]] {
        try array.map { item in
            guard let dict = item as? [String: Any] else { try invalid() }
            return dict
        }
    }
}

// MARK: - LumixLabZip

public enum LumixLabZip {
    /// Extracts the single `.cube` entry from an in-memory ZIP archive, validating path safety and size bounds.
    public static func cube(_ bytes: Data, checkCancellation: () throws -> Void = {}) throws -> Data {
        guard bytes.count >= 4,
              bytes[bytes.startIndex] == 0x50,
              bytes[bytes.startIndex + 1] == 0x4B,
              bytes[bytes.startIndex + 2] == 0x03,
              bytes[bytes.startIndex + 3] == 0x04 else {
            throw LumixLabProtocolException("Lumix Lab 未返回受支持的 ZIP 文件")
        }

        func readUInt16(_ offset: Int) throws -> UInt16 {
            guard offset + 2 <= bytes.count else {
                throw LumixLabProtocolException("ZIP 结构不完整")
            }
            return UInt16(bytes[bytes.startIndex + offset]) | (UInt16(bytes[bytes.startIndex + offset + 1]) << 8)
        }

        func readUInt32(_ offset: Int) throws -> UInt32 {
            guard offset + 4 <= bytes.count else {
                throw LumixLabProtocolException("ZIP 结构不完整")
            }
            return UInt32(bytes[bytes.startIndex + offset]) |
                (UInt32(bytes[bytes.startIndex + offset + 1]) << 8) |
                (UInt32(bytes[bytes.startIndex + offset + 2]) << 16) |
                (UInt32(bytes[bytes.startIndex + offset + 3]) << 24)
        }

        var cursor = 0
        var members = 0
        var totalUncompressed: Int64 = 0
        var cubeData: Data? = nil

        while cursor + 4 <= bytes.count {
            try checkCancellation()
            let sig = try readUInt32(cursor)
            if sig == 0x0201_4B50 || sig == 0x0605_4B50 {
                // Central directory or end of central directory
                break
            }
            guard sig == 0x0403_4B50 else {
                throw LumixLabProtocolException("ZIP 条目头无效")
            }
            members += 1
            if members > 64 {
                throw LumixLabProtocolException("LUT ZIP 成员过多")
            }
            guard cursor + 30 <= bytes.count else {
                throw LumixLabProtocolException("ZIP 本地头不完整")
            }
            let flags = try readUInt16(cursor + 6)
            let method = try readUInt16(cursor + 8)
            let compressedSize = Int(try readUInt32(cursor + 18))
            let uncompressedSize = Int(try readUInt32(cursor + 22))
            let nameLen = Int(try readUInt16(cursor + 26))
            let extraLen = Int(try readUInt16(cursor + 28))
            guard (flags & 0x08) == 0 else {
                throw LumixLabProtocolException("不支持带数据描述符的流式 ZIP")
            }
            let nameStart = cursor + 30
            let dataStart = nameStart + nameLen + extraLen
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= bytes.count else {
                throw LumixLabProtocolException("ZIP 条目数据越界")
            }
            let nameData = bytes.subdata(in: (bytes.startIndex + nameStart)..<(bytes.startIndex + nameStart + nameLen))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw LumixLabProtocolException("LUT ZIP 成员名称编码无效")
            }
            let segments = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                name.count > 1024 ||
                name.hasPrefix("/") ||
                name.contains("\\") ||
                name.contains(":") ||
                name.unicodeScalars.contains(where: { $0.value < 32 }) ||
                segments.contains("..") ||
                segments.contains(".") {
                throw LumixLabProtocolException("LUT ZIP 成员名称无效")
            }

            let isDirectory = name.hasSuffix("/")
            let isCube = !isDirectory && name.lowercased().hasSuffix(".cube")
            if isCube && cubeData != nil {
                throw LumixLabProtocolException("LUT ZIP 含多个 cube，无法明确选择")
            }

            let payload = bytes.subdata(in: (bytes.startIndex + dataStart)..<(bytes.startIndex + dataEnd))
            let inflated: Data
            if method == 0 {
                inflated = payload
            } else if method == 8 {
                let targetCap = max(uncompressedSize, min(16 * 1024 * 1024, max(4096, payload.count * 8)))
                guard targetCap <= 16 * 1024 * 1024 else {
                    throw LumixLabProtocolException("LUT ZIP 解压数据过大")
                }
                if uncompressedSize == 0 && payload.count <= 2 {
                    inflated = Data()
                } else {
                    var outBuf = Data(count: targetCap)
                    let decodedBytes = outBuf.withUnsafeMutableBytes { dstPtr -> Int in
                        payload.withUnsafeBytes { srcPtr -> Int in
                            guard let dstBase = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                  let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                                return 0
                            }
                            return compression_decode_buffer(
                                dstBase,
                                targetCap,
                                srcBase,
                                payload.count,
                                nil,
                                COMPRESSION_ZLIB
                            )
                        }
                    }
                    guard decodedBytes > 0 || uncompressedSize == 0 else {
                        throw LumixLabProtocolException("ZIP 解压失败")
                    }
                    outBuf.count = decodedBytes
                    inflated = outBuf
                }
            } else {
                throw LumixLabProtocolException("不支持的 ZIP 压缩方式：\(method)")
            }

            totalUncompressed += Int64(inflated.count)
            if totalUncompressed > 16 * 1024 * 1024 {
                throw LumixLabProtocolException("LUT ZIP 解压数据过大")
            }
            if isCube {
                if inflated.count > 4 * 1024 * 1024 {
                    throw LumixLabProtocolException("下载的 cube 文件过大")
                }
                if inflated.isEmpty {
                    throw LumixLabProtocolException("下载的 cube 文件为空")
                }
                cubeData = inflated
            }
            cursor = dataEnd
        }

        try checkCancellation()
        guard let result = cubeData else {
            throw LumixLabProtocolException("LUT ZIP 未含 cube 文件；尚不支持 VLT")
        }
        return result
    }

    /// Helper for creating test ZIP archives in memory (method 0 stored).
    public static func makeStoredZip(entries: [(String, Data)]) -> Data {
        var out = Data()
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        for (name, content) in entries {
            let nameBytes = Data(name.utf8)
            appendUInt32(0x0403_4B50)
            appendUInt16(20) // version needed
            appendUInt16(0)  // flags
            appendUInt16(0)  // method 0 = stored
            appendUInt16(0)  // mod time
            appendUInt16(0)  // mod date
            appendUInt32(0)  // crc32
            appendUInt32(UInt32(content.count))
            appendUInt32(UInt32(content.count))
            appendUInt16(UInt16(nameBytes.count))
            appendUInt16(0)  // extra len
            out.append(nameBytes)
            out.append(content)
        }
        appendUInt32(0x0605_4B50)
        appendUInt16(0)
        appendUInt16(0)
        appendUInt16(UInt16(entries.count))
        appendUInt16(UInt16(entries.count))
        appendUInt32(0)
        appendUInt32(UInt32(out.count - 4))
        appendUInt16(0)
        return out
    }
}

// MARK: - LUT Colour Analysis & Recommendations

public enum LutColourOrigin: String, Codable, Sendable {
    case photoPreview = "PHOTO_PREVIEW"
    case userExample = "USER_EXAMPLE"
    case creatorExample = "CREATOR_EXAMPLE"
}

public enum LutColourFamily: String, CaseIterable, Codable, Sendable {
    case red = "RED"
    case orange = "ORANGE"
    case yellow = "YELLOW"
    case green = "GREEN"
    case cyan = "CYAN"
    case blue = "BLUE"
    case purple = "PURPLE"
    case pink = "PINK"
    case neutral = "NEUTRAL"
}

public enum LutExampleColourMode: String, Codable, Sendable {
    case colour = "COLOUR"
    case nearMonochrome = "NEAR_MONOCHROME"
    case unknown = "UNKNOWN"
}

public struct LutColourSwatch: Equatable, Sendable {
    public let argb: Int32
    public let weight: Float
    public let family: LutColourFamily
    public let titleTextArgb: Int32
    public let bodyTextArgb: Int32

    public init(argb: Int32, weight: Float, family: LutColourFamily, titleTextArgb: Int32, bodyTextArgb: Int32) {
        self.argb = argb
        self.weight = weight
        self.family = family
        self.titleTextArgb = titleTextArgb
        self.bodyTextArgb = bodyTextArgb
    }
}

public struct LutExampleColours: Equatable, Sendable {
    public let origin: LutColourOrigin
    public let exampleIdentity: String
    public let dominantArgb: Int32?
    public let swatches: [LutColourSwatch]
    public let familyWeights: [LutColourFamily: Float]
    public let mode: LutExampleColourMode

    public init(
        origin: LutColourOrigin,
        exampleIdentity: String,
        dominantArgb: Int32?,
        swatches: [LutColourSwatch],
        familyWeights: [LutColourFamily: Float],
        mode: LutExampleColourMode
    ) {
        self.origin = origin
        self.exampleIdentity = exampleIdentity
        self.dominantArgb = dominantArgb
        self.swatches = swatches
        self.familyWeights = familyWeights
        self.mode = mode
    }
}

public enum LutRecommendationStyle: String, CaseIterable, Codable, Sendable {
    case natural = "NATURAL"
    case warm = "WARM"
    case cool = "COOL"
    case monochrome = "MONOCHROME"

    public var title: String {
        switch self {
        case .natural: return "自然"
        case .warm: return "暖调"
        case .cool: return "冷调"
        case .monochrome: return "黑白"
        }
    }
}

public enum LutExampleSimilarity {
    public static func distance(_ a: LutExampleColours, _ b: LutExampleColours) throws -> Double {
        try requireArgument(
            a.familyWeights.values.allSatisfy { $0.isFinite && $0 >= 0 } &&
            b.familyWeights.values.allSatisfy { $0.isFinite && $0 >= 0 },
            "色彩权重无效"
        )
        let at = a.familyWeights.values.reduce(0.0) { $0 + Double($1) }
        let bt = b.familyWeights.values.reduce(0.0) { $0 + Double($1) }
        if at <= 0 || bt <= 0 {
            return .infinity
        }
        var sum = 0.0
        for family in LutColourFamily.allCases {
            let aw = Double(a.familyWeights[family] ?? 0) / at
            let bw = Double(b.familyWeights[family] ?? 0) / bt
            let delta = sqrt(aw) - sqrt(bw)
            sum += delta * delta
        }
        return sum / 2.0
    }

    public static func style(_ c: LutExampleColours) -> LutRecommendationStyle {
        if c.mode == .nearMonochrome {
            return .monochrome
        }
        func weight(_ families: LutColourFamily...) -> Double {
            families.reduce(0.0) { $0 + Double(c.familyWeights[$1] ?? 0) }
        }
        let warmth = weight(.red, .orange, .yellow) - weight(.cyan, .blue)
        if abs(warmth) < 0.18 {
            return .natural
        }
        return warmth > 0 ? .warm : .cool
    }
}

// MARK: - Official Discovery & Explorer

public struct OfficialLutSuggestion: Equatable, Sendable {
    public let lut: LumixLabLut
    public let style: LutRecommendationStyle
    public let reasons: [String]
    public let warnings: [String]

    public init(lut: LumixLabLut, style: LutRecommendationStyle, reasons: [String], warnings: [String]) {
        self.lut = lut
        self.style = style
        self.reasons = reasons
        self.warnings = warnings
    }
}

public struct OfficialLutSuggestions: Equatable, Sendable {
    public let suggestions: [OfficialLutSuggestion]
    public let catalogueCandidates: Int
    public let analysedExamples: Int
    public let problems: [String]
    public let method: String

    public init(
        suggestions: [OfficialLutSuggestion],
        catalogueCandidates: Int,
        analysedExamples: Int,
        problems: [String],
        method: String = "creator-example-discovery-v1"
    ) {
        self.suggestions = suggestions
        self.catalogueCandidates = catalogueCandidates
        self.analysedExamples = analysedExamples
        self.problems = problems
        self.method = method
    }
}

public protocol OfficialDiscoverySource: Sendable {
    func luts(query: LumixLabLutQuery) async throws -> [LumixLabLut]
    func genres() async throws -> [LumixLabGenre]
    func colours(lut: LumixLabLut) async throws -> LutExampleColours
}

public actor OfficialLutRecommender {
    private let source: OfficialDiscoverySource
    private struct Snapshot {
        let language: String
        let at: Date
        let items: [LumixLabLut]
    }
    private var snapshot: Snapshot?
    private var coloursCache: [String: LutExampleColours] = [:]

    public init(source: OfficialDiscoverySource) {
        self.source = source
    }

    public func recommend(
        photo: LutExampleColours,
        language: String,
        styles: Set<LutRecommendationStyle>,
        excludedCodes: Set<String>,
        refresh: Bool = false
    ) async throws -> OfficialLutSuggestions {
        try requireArgument(!styles.isEmpty, "推荐风格不能为空")
        try Task.checkCancellation()
        var problems: [String] = []
        let now = Date()
        var items: [LumixLabLut]? = nil
        if !refresh, let snap = snapshot, snap.language == language, now.timeIntervalSince(snap.at) <= 1800 {
            items = snap.items
        }
        if items == nil {
            var collectedOrder: [String] = []
            var collectedMap: [String: LumixLabLut] = [:]
            func fetchPage(genre: String?, limit: Int) async throws {
                do {
                    let pageItems = try await source.luts(query: LumixLabLutQuery(language: language, limit: limit, genreCode: genre))
                    for item in pageItems {
                        if collectedMap[item.code] == nil {
                            collectedOrder.append(item.code)
                            collectedMap[item.code] = item
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let err as LumatteError where err == .cancelled {
                    throw CancellationError()
                } catch {
                    problems.append("部分官方目录暂时无法读取")
                }
            }
            try await fetchPage(genre: nil, limit: 32)
            let genres: [LumixLabGenre]
            do {
                genres = Array(try await source.genres().prefix(8))
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as LumatteError where err == .cancelled {
                throw CancellationError()
            } catch {
                problems.append("官方分类暂时无法读取")
                genres = []
            }
            for genre in genres {
                try await fetchPage(genre: genre.code, limit: 8)
            }
            let resolved = Array(collectedOrder.compactMap { collectedMap[$0] }.prefix(96))
            items = resolved
            if !resolved.isEmpty {
                snapshot = Snapshot(language: language, at: now, items: resolved)
            }
        }

        let resolvedItems = items ?? []
        let candidates = resolvedItems.filter { !excludedCodes.contains($0.code) && $0.thumbnail != nil }
        let positions: [Int] = {
            if candidates.count <= 12 {
                return Array(candidates.indices)
            } else {
                return (0..<12).map { $0 * (candidates.count - 1) / 11 }
            }
        }()

        var suggestions: [(OfficialLutSuggestion, Double)] = []
        var analysed = 0
        for pos in positions {
            try Task.checkCancellation()
            let lut = candidates[pos]
            let key = "\(lut.code):\(lut.thumbnail?.path ?? "")"
            let example: LutExampleColours
            if let cached = coloursCache[key] {
                example = cached
            } else {
                do {
                    let fetched = try await source.colours(lut: lut)
                    coloursCache[key] = fetched
                    example = fetched
                } catch is CancellationError {
                    throw CancellationError()
                } catch let err as LumatteError where err == .cancelled {
                    throw CancellationError()
                } catch {
                    problems.append("部分创作者例图暂时无法读取")
                    continue
                }
            }
            analysed += 1
            let style = LutExampleSimilarity.style(example)
            guard styles.contains(style) else { continue }
            let dist = try LutExampleSimilarity.distance(photo, example)
            guard dist.isFinite else { continue }
            let suggestion = OfficialLutSuggestion(
                lut: lut,
                style: style,
                reasons: ["创作者例图的色彩分布与这张照片相近"],
                warnings: ["尚未下载：依据例图发现风格，不能代表实际试套效果；使用前会检查输入照片风格"]
            )
            suggestions.append((suggestion, dist))
        }

        let sorted = suggestions.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            return a.0.lut.code < b.0.lut.code
        }.prefix(5).map(\.0)

        var uniqueProblems: [String] = []
        for p in problems where !uniqueProblems.contains(p) {
            uniqueProblems.append(p)
        }
        return OfficialLutSuggestions(
            suggestions: Array(sorted),
            catalogueCandidates: resolvedItems.count,
            analysedExamples: analysed,
            problems: uniqueProblems
        )
    }
}

public struct OfficialLutIndex: Equatable, Sendable {
    public let items: [LumixLabLut]
    public let complete: Bool
    public let problem: String?

    public init(items: [LumixLabLut], complete: Bool, problem: String? = nil) {
        self.items = items
        self.complete = complete
        self.problem = problem
    }
}

public protocol OfficialLutExplorerSource: Sendable {
    func page(query: LumixLabLutQuery) async throws -> LumixLabLutPage
    func colours(lut: LumixLabLut) async throws -> LutExampleColours
}

public actor OfficialLutExplorer {
    private let source: OfficialLutExplorerSource
    private var language: String?
    private var created: Date = .distantPast
    private var offset: Int = 0
    private var complete: Bool = false
    private var itemOrder: [String] = []
    private var itemMap: [String: LumixLabLut] = [:]
    private var seenPages: Set<[String]> = []
    private var coloursCache: [String: LutExampleColours] = [:]

    public init(source: OfficialLutExplorerSource) {
        self.source = source
    }

    private func orderedItems() -> [LumixLabLut] {
        itemOrder.compactMap { itemMap[$0] }
    }

    public func index(
        locale: String,
        onPage: (@Sendable (OfficialLutIndex) async throws -> Void)? = nil
    ) async throws -> OfficialLutIndex {
        let now = Date()
        if language != locale || now.timeIntervalSince(created) > 1800 {
            language = locale
            created = now
            offset = 0
            complete = false
            itemOrder.removeAll()
            itemMap.removeAll()
            seenPages.removeAll()
        }
        if !itemMap.isEmpty || complete {
            try await onPage?(OfficialLutIndex(items: orderedItems(), complete: complete))
        }
        while !complete {
            try Task.checkCancellation()
            let page: LumixLabLutPage
            do {
                page = try await source.page(query: LumixLabLutQuery(language: locale, offset: offset, limit: 32))
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as LumatteError where err == .cancelled {
                throw CancellationError()
            } catch {
                return OfficialLutIndex(
                    items: orderedItems(),
                    complete: false,
                    problem: "Lab 目录暂时无法继续读取，可重试；当前结果未覆盖全库。"
                )
            }

            if !page.items.isEmpty {
                let signature = page.items.map(\.code).sorted()
                if !seenPages.insert(signature).inserted {
                    return OfficialLutIndex(
                        items: orderedItems(),
                        complete: false,
                        problem: "Lab 返回重复分页，已停止继续请求；当前结果未覆盖全库。"
                    )
                }
            }
            for item in page.items {
                if itemMap[item.code] == nil {
                    itemOrder.append(item.code)
                }
                itemMap[item.code] = item
            }
            if page.items.isEmpty || page.nextOffset == nil {
                complete = true
            } else if let next = page.nextOffset, next <= offset {
                return OfficialLutIndex(
                    items: orderedItems(),
                    complete: false,
                    problem: "Lab 分页位置未前进，请稍后重试。"
                )
            } else if let next = page.nextOffset {
                offset = next
            }
            try await onPage?(OfficialLutIndex(items: orderedItems(), complete: complete))
        }
        return OfficialLutIndex(items: orderedItems(), complete: true)
    }

    public func colours(lut: LumixLabLut) async throws -> LutExampleColours {
        try Task.checkCancellation()
        let key = "\(lut.code):\(lut.thumbnail?.path ?? "")"
        if let cached = coloursCache[key] {
            return cached
        }
        let result = try await source.colours(lut: lut)
        try Task.checkCancellation()
        coloursCache[key] = result
        return result
    }
}

// MARK: - LumixLabCatalogueClient

public final class LumixLabCatalogueClient: @unchecked Sendable {
    public static let host = "lumix-base.jpn.panasonic.com"
    public static let baseURL = "https://\(host)/lutapi/v2/"
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    public func genres() async throws -> [LumixLabGenre] {
        let data = try await post(path: "community/genres", body: nil)
        return try LumixLabJson.genres(data)
    }

    public func luts(query: LumixLabLutQuery) async throws -> LumixLabLutPage {
        try requireArgument(query.offset >= 0 && (1...64).contains(query.limit), "目录分页参数无效")
        try requireArgument(query.countries.count <= 64, "地区筛选过多")
        var body: [String: Any] = [
            "language": try field(query.language),
            "offset": String(query.offset),
            "limit": String(query.limit),
            "order": ["key": "created", "order": "desc"]
        ]
        if let genre = query.genreCode {
            body["genre_code"] = try field(genre)
        }
        if let creator = query.creatorCode {
            body["creator_code"] = try field(creator)
        }
        if !query.countries.isEmpty {
            body["countries"] = try query.countries.map(field)
        }
        let data = try await post(path: "community/luts/filter", body: body)
        let items = try LumixLabJson.luts(data)
        let next = (!items.isEmpty && Int64(query.offset) + Int64(items.count) <= Int64(Int.max))
            ? (query.offset + items.count)
            : nil
        return LumixLabLutPage(items: items, offset: query.offset, requestedLimit: query.limit, nextOffset: next)
    }

    public func detail(code: String, language: String = "zh") async throws -> LumixLabLutDetail {
        let requested = try field(code)
        let body: [String: Any] = [
            "code": requested,
            "language": try field(language)
        ]
        let data = try await post(path: "community/lut", body: body)
        let detail = try LumixLabJson.detail(data)
        if detail.lut.code != requested {
            throw LumixLabProtocolException("Lumix Lab 返回的 LUT 编号不一致")
        }
        return detail
    }

    public func downloadCube(detail: LumixLabLutDetail) async throws -> Data {
        guard let g17 = detail.grid17, !g17.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LumixLabProtocolException("该 LUT 没有已确认可用的 grid17 文件")
        }
        let body: [String: Any] = [
            "code": try field(detail.lut.code),
            "key": "grid17"
        ]
        let zipBytes = try await requestBytes(
            path: "community/luts/download",
            body: body,
            accept: "application/zip",
            maxBytes: 8 * 1024 * 1024
        )
        return try LumixLabZip.cube(zipBytes) {
            try Task.checkCancellation()
        }
    }

    public func thumbnailURL(for ref: LumixLabImageRef?) -> URL? {
        guard let path = ref?.path, !path.isEmpty else { return nil }
        if path.hasPrefix("https://\(Self.host)/") {
            return URL(string: path)
        }
        if path.hasPrefix("/") {
            return URL(string: "https://\(Self.host)\(path)")
        }
        return nil
    }

    private func field(_ value: String) throws -> String {
        try requireArgument(
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.count <= 256 &&
            !value.unicodeScalars.contains(where: { $0.value < 32 }),
            "目录筛选值无效"
        )
        return value
    }

    private func post(path: String, body: [String: Any]?) async throws -> Data {
        try await requestBytes(path: path, body: body, accept: "application/json", maxBytes: 2 * 1024 * 1024)
    }

    private func requestBytes(path: String, body: [String: Any]?, accept: String, maxBytes: Int) async throws -> Data {
        try requireArgument(
            ["community/genres", "community/luts/filter", "community/lut", "community/luts/download"].contains(path),
            "未知 Lumix Lab 路径"
        )
        guard let url = URL(string: Self.baseURL + path) else {
            throw LumixLabProtocolException("无效请求地址")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("111", forHTTPHeaderField: "lutapp-api-key")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            req.httpBody = Data()
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LumixLabProtocolException("Lumix Lab 返回无效响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw LumixLabHttpException(statusCode: http.statusCode)
        }
        guard !data.isEmpty && data.count <= maxBytes else {
            throw LumixLabProtocolException("Lumix Lab 响应为空或过大")
        }
        return data
    }
}
