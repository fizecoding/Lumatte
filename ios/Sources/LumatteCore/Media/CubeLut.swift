import Foundation
import CryptoKit
import CoreGraphics
import CLumatteNative

public struct NativeCubeData: Equatable, Sendable {
    public let oneSize: Int
    public let threeSize: Int
    public let one: [Float]
    public let three: [Float]
    public let bounds: [Float] // 13 floats: oneMin(3) + oneMax(3) + threeMin(3) + threeMax(3) + vltFlag(1)
}

public final class CubeLut: Equatable, Hashable, @unchecked Sendable {
    public let title: String
    public let oneSize: Int
    public let threeSize: Int
    public let one: [Float]
    public let three: [Float]
    public let oneMin: [Float]
    public let oneMax: [Float]
    public let threeMin: [Float]
    public let threeMax: [Float]
    public let vltGrid: Bool

    public lazy var nativeData: NativeCubeData = {
        var b: [Float] = []
        b.reserveCapacity(13)
        b.append(contentsOf: oneMin)
        b.append(contentsOf: oneMax)
        b.append(contentsOf: threeMin)
        b.append(contentsOf: threeMax)
        b.append(vltGrid ? 1.0 : 0.0)
        return NativeCubeData(oneSize: oneSize, threeSize: threeSize, one: one, three: three, bounds: b)
    }()

    public init(
        title: String,
        oneSize: Int,
        threeSize: Int,
        one: [Float],
        three: [Float],
        oneMin: [Float],
        oneMax: [Float],
        threeMin: [Float],
        threeMax: [Float],
        vltGrid: Bool = false
    ) {
        self.title = String(title.prefix(200))
        self.oneSize = oneSize
        self.threeSize = threeSize
        self.one = one
        self.three = three
        self.oneMin = oneMin
        self.oneMax = oneMax
        self.threeMin = threeMin
        self.threeMax = threeMax
        self.vltGrid = vltGrid
    }

    public static func == (lhs: CubeLut, rhs: CubeLut) -> Bool {
        lhs.title == rhs.title &&
        lhs.oneSize == rhs.oneSize &&
        lhs.threeSize == rhs.threeSize &&
        lhs.vltGrid == rhs.vltGrid &&
        lhs.oneMin == rhs.oneMin &&
        lhs.oneMax == rhs.oneMax &&
        lhs.threeMin == rhs.threeMin &&
        lhs.threeMax == rhs.threeMax &&
        lhs.one == rhs.one &&
        lhs.three == rhs.three
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(oneSize)
        hasher.combine(threeSize)
        hasher.combine(vltGrid)
        hasher.combine(one.count)
        hasher.combine(three.count)
        if let f = three.first, let l = three.last {
            hasher.combine(f)
            hasher.combine(l)
        }
    }

    public func named(_ name: String) -> CubeLut {
        CubeLut(
            title: String(name.prefix(200)),
            oneSize: oneSize,
            threeSize: threeSize,
            one: one,
            three: three,
            oneMin: oneMin,
            oneMax: oneMax,
            threeMin: threeMin,
            threeMax: threeMax,
            vltGrid: vltGrid
        )
    }

    private static func vltCoordinate(_ value: Float) -> Float {
        let input = min(max(value, 0), 1) * 4095.0
        return input <= 3840.0 ? (input / 256.0) : (15.0 + (input - 3840.0) / 255.0)
    }

    private static func coordinate(_ value: Float, minimum: Float, maximum: Float, size: Int) -> Float {
        let clamped = min(max((value - minimum) / (maximum - minimum), 0), 1)
        return clamped * Float(size - 1)
    }

    public func apply(_ input: [Float], result: inout [Float]) {
        precondition(input.count >= 3 && result.count >= 3)
        for channel in 0..<3 {
            let value = input[channel]
            if oneSize == 0 {
                result[channel] = value
            } else {
                let coord = Self.coordinate(value, minimum: oneMin[channel], maximum: oneMax[channel], size: oneSize)
                let lower = Int(floor(coord))
                let upper = min(lower + 1, oneSize - 1)
                let fraction = coord - Float(lower)
                result[channel] = one[lower * 3 + channel] * (1.0 - fraction) + one[upper * 3 + channel] * fraction
            }
        }
        guard threeSize > 0 else { return }
        func position(_ channel: Int) -> Float {
            if vltGrid {
                return Self.vltCoordinate(result[channel])
            } else {
                return Self.coordinate(result[channel], minimum: threeMin[channel], maximum: threeMax[channel], size: threeSize)
            }
        }
        let r = position(0), g = position(1), b = position(2)
        let r0 = Int(floor(r)), g0 = Int(floor(g)), b0 = Int(floor(b))
        let r1 = min(r0 + 1, threeSize - 1), g1 = min(g0 + 1, threeSize - 1), b1 = min(b0 + 1, threeSize - 1)
        let fr = r - Float(r0), fg = g - Float(g0), fb = b - Float(b0)
        func index(_ x: Int, _ y: Int, _ z: Int) -> Int {
            (x + threeSize * (y + threeSize * z)) * 3
        }
        let i000 = index(r0, g0, b0), i100 = index(r1, g0, b0)
        let i010 = index(r0, g1, b0), i110 = index(r1, g1, b0)
        let i001 = index(r0, g0, b1), i101 = index(r1, g0, b1)
        let i011 = index(r0, g1, b1), i111 = index(r1, g1, b1)
        for ch in 0..<3 {
            let low = (three[i000 + ch] * (1.0 - fr) + three[i100 + ch] * fr) * (1.0 - fg) +
                (three[i010 + ch] * (1.0 - fr) + three[i110 + ch] * fr) * fg
            let high = (three[i001 + ch] * (1.0 - fr) + three[i101 + ch] * fr) * (1.0 - fg) +
                (three[i011 + ch] * (1.0 - fr) + three[i111 + ch] * fr) * fg
            result[ch] = low * (1.0 - fb) + high * fb
        }
    }

    // MARK: - Binary Cache Serialization

    public func writeData() -> Data {
        var out = Data()
        func appendInt32(_ v: Int32) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
        func appendFloat(_ v: Float) {
            var be = v.bitPattern.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
        appendInt32(2) // version 2
        let titleBytes = Array(String(title.prefix(200)).utf8)
        var lenBE = UInt16(titleBytes.count).bigEndian
        withUnsafeBytes(of: &lenBE) { out.append(contentsOf: $0) }
        out.append(contentsOf: titleBytes)
        appendInt32(Int32(oneSize))
        appendInt32(Int32(threeSize))
        out.append(vltGrid ? 1 : 0)
        for arr in [oneMin, oneMax, threeMin, threeMax, one, three] {
            for f in arr {
                appendFloat(f)
            }
        }
        return out
    }

    public static func readData(_ data: Data) throws -> CubeLut {
        var offset = 0
        func readBytes(_ count: Int) throws -> Data {
            guard offset + count <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let sub = data.subdata(in: offset..<(offset + count))
            offset += count
            return sub
        }
        func readInt32() throws -> Int {
            let sub = try readBytes(4)
            let v = sub.withUnsafeBytes { $0.load(as: Int32.self).bigEndian }
            return Int(v)
        }
        func readFloat() throws -> Float {
            let sub = try readBytes(4)
            let bits = sub.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let f = Float(bitPattern: bits)
            try requireArgument(f.isFinite, "LUT 缓存包含无效浮点")
            return f
        }
        func readFloatArray(_ count: Int) throws -> [Float] {
            var arr: [Float] = []
            arr.reserveCapacity(count)
            for _ in 0..<count {
                arr.append(try readFloat())
            }
            return arr
        }

        let version = try readInt32()
        try requireArgument((1...2).contains(version), "LUT 缓存版本不支持")
        let lenSub = try readBytes(2)
        let titleLen = Int(lenSub.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
        let titleData = try readBytes(titleLen)
        guard let title = String(data: titleData, encoding: .utf8) else {
            throw LumatteError.invalidArgument("LUT 标题编码无效")
        }
        let oneSize = try readInt32()
        let threeSize = try readInt32()
        let vltGrid: Bool
        if version >= 2 {
            let b = try readBytes(1)
            vltGrid = b[b.startIndex] != 0
        } else {
            vltGrid = false
        }
        try requireArgument(!vltGrid || (oneSize == 0 && threeSize == 17), "VLT 网格尺寸无效")
        try requireArgument(oneSize == 0 || (2...65536).contains(oneSize), "1D LUT 尺寸无效")
        try requireArgument(threeSize == 0 || (2...65).contains(threeSize), "3D LUT 尺寸无效")
        try requireArgument(oneSize > 0 || threeSize > 0, "LUT 缺少尺寸")

        let oneMin = try readFloatArray(3)
        let oneMax = try readFloatArray(3)
        let threeMin = try readFloatArray(3)
        let threeMax = try readFloatArray(3)
        for ch in 0..<3 {
            try requireArgument(oneMax[ch] > oneMin[ch] && threeMax[ch] > threeMin[ch], "LUT 输入范围无效")
        }
        let one = try readFloatArray(oneSize * 3)
        let three = try readFloatArray(threeSize * threeSize * threeSize * 3)
        try requireArgument(offset == data.count, "LUT 缓存包含多余数据")
        return CubeLut(
            title: title,
            oneSize: oneSize,
            threeSize: threeSize,
            one: one,
            three: three,
            oneMin: oneMin,
            oneMax: oneMax,
            threeMin: threeMin,
            threeMax: threeMax,
            vltGrid: vltGrid
        )
    }

    // MARK: - .cube and .vlt Parsing

    public static func parse(
        _ text: String,
        fallbackName: String,
        checkCancellation: () throws -> Void = {}
    ) throws -> CubeLut {
        try checkCancellation()
        var cleanText = text
        if cleanText.hasPrefix("\u{FEFF}") {
            cleanText.removeFirst()
        }
        let normalized = cleanText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var title = String(fallbackName.prefix(200))
        var oneSize = 0
        var threeSize = 0
        var data: [Float]? = nil
        var written = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var oneRange: (Float, Float)? = nil
        var threeRange: (Float, Float)? = nil
        var headers = Set<String>()

        for (idx, raw) in lines.enumerated() {
            let lineNumber = idx + 1
            if lineNumber % 128 == 0 {
                try checkCancellation()
            }
            try requireArgument(raw.count <= 4096, "LUT 第 \(lineNumber) 行过长")
            var quoted = false
            var commentStart: String.Index? = nil
            for i in raw.indices {
                let ch = raw[i]
                if ch == "\"" { quoted.toggle() }
                if ch == "#" && !quoted {
                    commentStart = i
                    break
                }
            }
            let uncommented = commentStart.map { String(raw[..<$0]) } ?? raw
            let line = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let header = fields[0]
            if let firstChar = header.first, firstChar.isLetter {
                try requireArgument(data == nil && headers.insert(header).inserted, "LUT 头部重复或位于数据之后：\(header)")
                func parseValues(_ count: Int) throws -> [Float] {
                    try requireArgument(fields.count == count + 1, "LUT 头部格式错误：\(header)")
                    var out: [Float] = []
                    for i in 0..<count {
                        guard let v = Float(fields[i + 1]), v.isFinite else {
                            throw LumatteError.invalidArgument("LUT 头部数值无效：\(header)")
                        }
                        out.append(v)
                    }
                    return out
                }
                switch header {
                case "TITLE":
                    var rawTitle = String(line.dropFirst(header.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if rawTitle.hasPrefix("\"") && rawTitle.hasSuffix("\"") && rawTitle.count >= 2 {
                        rawTitle = String(rawTitle.dropFirst().dropLast())
                    }
                    let resolved = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    title = String((resolved.isEmpty ? fallbackName : resolved).prefix(200))
                case "LUT_1D_SIZE":
                    try requireArgument(fields.count == 2, "LUT_1D_SIZE 格式错误")
                    guard let s = Int(fields[1]), (2...65536).contains(s) else {
                        throw LumatteError.invalidArgument("LUT_1D_SIZE 尺寸不支持")
                    }
                    oneSize = s
                case "LUT_3D_SIZE":
                    try requireArgument(fields.count == 2, "LUT_3D_SIZE 格式错误")
                    guard let s = Int(fields[1]), (2...65).contains(s) else {
                        throw LumatteError.invalidArgument("LUT_3D_SIZE 尺寸不支持")
                    }
                    threeSize = s
                case "DOMAIN_MIN":
                    domainMin = try parseValues(3)
                case "DOMAIN_MAX":
                    domainMax = try parseValues(3)
                case "LUT_1D_INPUT_RANGE":
                    let r = try parseValues(2)
                    oneRange = (r[0], r[1])
                case "LUT_3D_INPUT_RANGE":
                    let r = try parseValues(2)
                    threeRange = (r[0], r[1])
                default:
                    throw LumatteError.illegalState("不支持的 LUT 指令：\(header)")
                }
            } else {
                try requireArgument(oneSize > 0 || threeSize > 0, "LUT 缺少尺寸")
                if data == nil {
                    let totalFloats = (oneSize + threeSize * threeSize * threeSize) * 3
                    data = [Float](repeating: 0, count: totalFloats)
                }
                try requireArgument(fields.count == 3 && written + 3 <= data!.count, "LUT 数据行数量或格式错误")
                for f in fields {
                    guard let v = Float(f), v.isFinite else {
                        throw LumatteError.invalidArgument("LUT 数据行包含无效浮点")
                    }
                    data![written] = v
                    written += 1
                }
            }
        }

        guard let values = data else {
            throw LumatteError.invalidArgument("LUT 没有颜色数据")
        }
        try requireArgument(written == values.count, "LUT 颜色数据不完整")
        try requireArgument((0..<3).allSatisfy { domainMax[$0] > domainMin[$0] }, "LUT 输入范围无效")
        if let oneRange {
            try requireArgument(oneRange.1 > oneRange.0, "LUT_1D_INPUT_RANGE 无效")
        }
        if let threeRange {
            try requireArgument(threeRange.1 > threeRange.0, "LUT_3D_INPUT_RANGE 无效")
        }
        try requireArgument(
            (oneRange == nil && threeRange == nil) || (!headers.contains("DOMAIN_MIN") && !headers.contains("DOMAIN_MAX")),
            "LUT 同时声明两套输入范围，请使用单一范围格式"
        )
        try checkCancellation()
        let resolvedOneMin = oneRange.map { [$0.0, $0.0, $0.0] } ?? domainMin
        let resolvedOneMax = oneRange.map { [$0.1, $0.1, $0.1] } ?? domainMax
        let resolvedThreeMin = threeRange.map { [$0.0, $0.0, $0.0] } ?? domainMin
        let resolvedThreeMax = threeRange.map { [$0.1, $0.1, $0.1] } ?? domainMax
        return CubeLut(
            title: title,
            oneSize: oneSize,
            threeSize: threeSize,
            one: Array(values[0..<(oneSize * 3)]),
            three: Array(values[(oneSize * 3)..<values.count]),
            oneMin: resolvedOneMin,
            oneMax: resolvedOneMax,
            threeMin: resolvedThreeMin,
            threeMax: resolvedThreeMax,
            vltGrid: false
        )
    }

    public static func parseVlt(
        _ text: String,
        fallbackName: String,
        checkCancellation: () throws -> Void = {}
    ) throws -> CubeLut {
        try checkCancellation()
        var cleanText = text
        if cleanText.hasPrefix("\u{FEFF}") {
            cleanText.removeFirst()
        }
        let normalized = cleanText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var data = [Float](repeating: 0, count: 17 * 17 * 17 * 3)
        var written = 0
        var sizeSeen = false
        var versionSeen = false

        for (idx, raw) in lines.enumerated() {
            if (idx + 1) % 128 == 0 {
                try checkCancellation()
            }
            try requireArgument(raw.count <= 4096, "VLT 行过长")
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.lowercased().hasPrefix("# panasonic vlt file version") {
                try requireArgument(
                    !versionSeen && written == 0 && line.caseInsensitiveCompare("# panasonic vlt file version 1.0") == .orderedSame,
                    "VLT 版本不支持"
                )
                versionSeen = true
            }
            let content = (line.components(separatedBy: "#").first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            let fields = content.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if fields.first == "LUT_3D_SIZE" {
                try requireArgument(!sizeSeen && written == 0 && fields == ["LUT_3D_SIZE", "17"], "VLT 必须使用 17 点色表")
                sizeSeen = true
            } else {
                try requireArgument(sizeSeen && fields.count == 3 && written + 3 <= data.count, "VLT 数据数量或格式错误")
                for field in fields {
                    guard let value = Int(field), (0...4095).contains(value) else {
                        throw LumatteError.invalidArgument("VLT 输出必须是 0 至 4095 的整数")
                    }
                    data[written] = Float(value) / 4095.0
                    written += 1
                }
            }
        }
        try requireArgument(sizeSeen && written == data.count, "VLT 色表不完整，需要 4913 行")
        try checkCancellation()
        return CubeLut(
            title: String(fallbackName.prefix(200)),
            oneSize: 0,
            threeSize: 17,
            one: [],
            three: data,
            oneMin: [0, 0, 0],
            oneMax: [1, 1, 1],
            threeMin: [0, 0, 0],
            threeMax: [1, 1, 1],
            vltGrid: true
        )
    }
}

// MARK: - LUT Assets & Library

public struct LumixLabLutSource: Equatable, Hashable, Codable, Sendable {
    public let code: String
    public let creatorCode: String?
    public let creatorName: String?

    public init(code: String, creatorCode: String? = nil, creatorName: String? = nil) {
        self.code = code
        self.creatorCode = creatorCode
        self.creatorName = creatorName
    }
}

public struct LutAsset: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let builtin: Bool
    public let table: CubeLut
    public let photoStyle: String?
    public let lumixLabSource: LumixLabLutSource?

    public init(
        id: String,
        name: String,
        builtin: Bool,
        table: CubeLut,
        photoStyle: String? = nil,
        lumixLabSource: LumixLabLutSource? = nil
    ) {
        self.id = id
        self.name = name
        self.builtin = builtin
        self.table = table
        self.photoStyle = photoStyle
        self.lumixLabSource = lumixLabSource
    }
}

public struct LutRenderPlan: Equatable, Sendable {
    public let first: CubeLut?
    public let firstStrength: Float
    public let second: CubeLut?
    public let secondStrength: Float
    public let grain: Float
    public let dithering: Bool

    public init(
        first: CubeLut?,
        firstStrength: Float,
        second: CubeLut?,
        secondStrength: Float,
        grain: Float,
        dithering: Bool
    ) {
        self.first = first
        self.firstStrength = first != nil ? firstStrength : 0
        self.second = second
        self.secondStrength = second != nil ? secondStrength : 0
        self.grain = grain
        self.dithering = dithering
    }
}

public enum NativeLutRenderer {
    public static func renderRGBA8888(
        pixels: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        stride: Int,
        plan: LutRenderPlan,
        sourceSize: PixelSize,
        seed: Int32 = 0x51F2_A9C3
    ) throws {
        let firstData = plan.first?.nativeData
        let secondData = plan.second?.nativeData
        let dummyBounds: [Float] = [0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0]

        let fOne = firstData?.one ?? []
        let fThree = firstData?.three ?? []
        let fBounds = firstData?.bounds ?? dummyBounds
        let fOneSize = Int32(firstData?.oneSize ?? 0)
        let fThreeSize = Int32(firstData?.threeSize ?? 0)
        let fStrength = plan.first != nil ? plan.firstStrength : 0

        let sOne = secondData?.one ?? []
        let sThree = secondData?.three ?? []
        let sBounds = secondData?.bounds ?? dummyBounds
        let sOneSize = Int32(secondData?.oneSize ?? 0)
        let sThreeSize = Int32(secondData?.threeSize ?? 0)
        let sStrength = plan.second != nil ? plan.secondStrength : 0

        var errorBuf = [CChar](repeating: 0, count: 256)
        let rc = fOne.withUnsafeBufferPointer { fOnePtr in
            fThree.withUnsafeBufferPointer { fThreePtr in
                fBounds.withUnsafeBufferPointer { fBoundsPtr in
                    sOne.withUnsafeBufferPointer { sOnePtr in
                        sThree.withUnsafeBufferPointer { sThreePtr in
                            sBounds.withUnsafeBufferPointer { sBoundsPtr in
                                lumatte_render_lut_rgba8888(
                                    pixels,
                                    UInt32(width),
                                    UInt32(height),
                                    UInt32(stride),
                                    fOneSize,
                                    fThreeSize,
                                    fOnePtr.baseAddress,
                                    fThreePtr.baseAddress,
                                    fBoundsPtr.baseAddress,
                                    fStrength,
                                    sOneSize,
                                    sThreeSize,
                                    sOnePtr.baseAddress,
                                    sThreePtr.baseAddress,
                                    sBoundsPtr.baseAddress,
                                    sStrength,
                                    plan.grain,
                                    Int32(sourceSize.width),
                                    Int32(sourceSize.height),
                                    seed,
                                    plan.dithering,
                                    &errorBuf,
                                    errorBuf.count
                                )
                            }
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = String(cString: errorBuf)
            throw LumatteError.illegalState(msg)
        }
    }
}

public struct LutLibrarySnapshot: Sendable {
    public let assets: [LutAsset]
    public let problems: [String]
}

public final class LutLibrary: @unchecked Sendable {
    private struct BundledEntry {
        let id: String
        let name: String
        let style: String?
    }

    private static let bundledEntries: [BundledEntry] = [
        BundledEntry(id: "fresh-bright", name: "Fresh Bright", style: "STD"),
        BundledEntry(id: "kitaura", name: "Kitaura", style: "STD"),
        BundledEntry(id: "smoky-color-s", name: "Smoky Color-S", style: "STD"),
        BundledEntry(id: "teal-flat-s", name: "Teal Flat-S", style: "STD"),
        BundledEntry(id: "agfaphoto-lebox", name: "VOL 23 TXD AgfaPhoto LeBox", style: nil),
        BundledEntry(id: "millennium-cold", name: "千禧回声 cold", style: nil),
        BundledEntry(id: "millennium-warm", name: "千禧回声 warm", style: nil),
        BundledEntry(id: "backlight-n", name: "Backlight-N", style: "NAT"),
        BundledEntry(id: "clear-s", name: "Clear-S", style: "STD"),
        BundledEntry(id: "color-harmony", name: "Color Harmony", style: "STD"),
    ]

    public let rootDirectory: URL

    public init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.rootDirectory = appSupport.appendingPathComponent("Lumatte/lut-library", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    public func load() async -> LutLibrarySnapshot {
        var assets: [LutAsset] = []
        var problems: [String] = []
        for entry in Self.bundledEntries {
            do {
                let data = try AssetLocator.data(forAssetPath: "luts/\(entry.name).cube", maxBytes: 32 * 1024 * 1024)
                guard let text = String(data: data, encoding: .utf8) else {
                    problems.append("\(entry.name)：内置 LUT 编码无效")
                    continue
                }
                let table = try CubeLut.parse(text, fallbackName: entry.name).named(entry.name)
                assets.append(LutAsset(
                    id: "bundled-\(entry.id)",
                    name: entry.name,
                    builtin: true,
                    table: table,
                    photoStyle: entry.style
                ))
            } catch {
                problems.append("\(entry.name)：内置 LUT 读取失败")
            }
        }

        if let files = try? FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "lfmlut" {
                let id = file.deletingPathExtension().lastPathComponent
                do {
                    let data = try Data(contentsOf: file)
                    let table = try CubeLut.readData(data)
                    let metaURL = rootDirectory.appendingPathComponent("\(id).json")
                    var style: String? = nil
                    var source: LumixLabLutSource? = nil
                    if let metaData = try? Data(contentsOf: metaURL),
                       let metaObj = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
                        style = metaObj["photoStyle"] as? String
                        if let code = metaObj["code"] as? String {
                            source = LumixLabLutSource(
                                code: code,
                                creatorCode: metaObj["creatorCode"] as? String,
                                creatorName: metaObj["creatorName"] as? String
                            )
                        }
                    }
                    assets.append(LutAsset(id: id, name: table.title, builtin: false, table: table, photoStyle: style, lumixLabSource: source))
                } catch {
                    problems.append("\(id)：LUT 读取失败")
                }
            }
        }

        return LutLibrarySnapshot(assets: assets, problems: problems)
    }

    public func importFile(at url: URL) throws -> LutAsset {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let bytes = try Data(contentsOf: url)
        try requireArgument(bytes.count <= 32 * 1024 * 1024, "LUT 文件超过 32 MiB")
        guard let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes else {
            throw LumatteError.invalidArgument("LUT 文件不是有效 UTF-8 编码")
        }
        let rawName = url.lastPathComponent
        let cleanName = rawName.replacingOccurrences(of: "\\.(?i)(cube|vlt)$", with: "", options: .regularExpression)
        let isVlt = rawName.lowercased().hasSuffix(".vlt") ||
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("# panasonic vlt file version")
        let table = try (isVlt ? CubeLut.parseVlt(text, fallbackName: cleanName) : CubeLut.parse(text, fallbackName: cleanName))
            .named(cleanName)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let id = "local-\(digest)"
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let targetURL = rootDirectory.appendingPathComponent("\(id).lfmlut")
        try table.writeData().write(to: targetURL, options: .atomic)
        return LutAsset(id: id, name: table.title, builtin: false, table: table)
    }

    public func saveOfficialLut(detail: LumixLabLutDetail, cubeBytes: Data) throws -> LutAsset {
        guard let text = String(data: cubeBytes, encoding: .utf8) else {
            throw LumixLabProtocolException("官方 LUT 编码无效")
        }
        let table = try CubeLut.parse(text, fallbackName: detail.lut.title).named(detail.lut.title)
        let digest = SHA256.hash(data: cubeBytes).map { String(format: "%02x", $0) }.joined()
        let id = "official-\(detail.lut.code)-\(digest.prefix(16))"
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let targetURL = rootDirectory.appendingPathComponent("\(id).lfmlut")
        try table.writeData().write(to: targetURL, options: .atomic)
        let meta: [String: Any?] = [
            "code": detail.lut.code,
            "photoStyle": detail.photoStyle,
            "creatorCode": detail.lut.creator?.code,
            "creatorName": detail.lut.creator?.name
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta.compactMapValues { $0 })
        try metaData.write(to: rootDirectory.appendingPathComponent("\(id).json"), options: .atomic)
        let source = LumixLabLutSource(
            code: detail.lut.code,
            creatorCode: detail.lut.creator?.code,
            creatorName: detail.lut.creator?.name
        )
        return LutAsset(id: id, name: detail.lut.title, builtin: false, table: table, photoStyle: detail.photoStyle, lumixLabSource: source)
    }

    public func plan(recipe: LutRecipe, assets: [LutAsset]) throws -> LutRenderPlan {
        func resolve(_ id: String?) throws -> CubeLut? {
            guard let id else { return nil }
            guard let found = assets.first(where: { $0.id == id }) else {
                throw LumatteError.invalidArgument("所选 LUT 不可用，请重新选择；没有改用其他 LUT")
            }
            return found.table
        }
        return LutRenderPlan(
            first: try resolve(recipe.first.id),
            firstStrength: recipe.first.strength,
            second: try resolve(recipe.second.id),
            secondStrength: recipe.second.strength,
            grain: recipe.grainEnabled ? recipe.grain : 0,
            dithering: recipe.ditheringEnabled
        )
    }
}
