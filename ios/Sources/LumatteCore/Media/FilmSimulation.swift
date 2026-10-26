import Foundation
import CryptoKit
import CLumatteNative

public enum FilmCategory: String, CaseIterable, Codable, Sendable {
    case negative = "NEGATIVE"
    case cinema = "CINEMA"
    case reversal = "REVERSAL"
    case monochrome = "MONOCHROME"

    public var label: String {
        switch self {
        case .negative: return "负片"
        case .cinema: return "电影卷"
        case .reversal: return "反转片"
        case .monochrome: return "黑白卷"
        }
    }

    public var subtitle: String {
        switch self {
        case .negative: return "Color Negative"
        case .cinema: return "Motion Picture"
        case .reversal: return "Reversal Film"
        case .monochrome: return "Black & White"
        }
    }
}

public struct FilmPreset: Equatable, Hashable, Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let category: FilmCategory
    public let printId: String
    public let positive: Bool
    public let description: String?

    public init(
        id: String,
        name: String,
        category: FilmCategory,
        printId: String,
        positive: Bool,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.printId = printId
        self.positive = positive
        self.description = description
    }
}

public struct FilmRenderPlan: Equatable, Sendable {
    public let parameters: FilmParameters
    public let preset: FilmPreset
    public let grainSeed: Int64

    public init(parameters: FilmParameters, preset: FilmPreset, grainSeed: Int64) {
        self.parameters = parameters
        self.preset = preset
        self.grainSeed = grainSeed
    }
}

public final class FilmCatalogue: Sendable {
    public static let legacySilver: [FilmPreset] = [
        FilmPreset(id: "lfm_silver_neutral", name: "Silver · Neutral", category: .monochrome, printId: "lfm_silver_paper", positive: false),
        FilmPreset(id: "lfm_silver_contrast", name: "Silver · Contrast", category: .monochrome, printId: "lfm_silver_paper", positive: false),
    ]

    public init() {}

    public func load() throws -> [FilmPreset] {
        var presets: [FilmPreset] = []
        for path in ["film/catalogue.json", "film/mobile-fotufilm-v1/catalogue.json"] {
            let data = try AssetLocator.data(forAssetPath: path, maxBytes: 256 * 1024)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stocks = root["stocks"] as? [[String: Any]] else {
                throw LumatteError.illegalState("胶片目录格式无效：\(path)")
            }
            for info in stocks {
                guard let id = info["id"] as? String,
                      let name = info["name"] as? String,
                      let catRaw = info["category"] as? String,
                      let category = FilmCategory(rawValue: catRaw),
                      let printId = info["printId"] as? String,
                      let positive = info["positive"] as? Bool else {
                    throw LumatteError.illegalState("胶片目录条目无效")
                }
                let desc = (info["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                presets.append(FilmPreset(
                    id: id,
                    name: name,
                    category: category,
                    printId: printId,
                    positive: positive,
                    description: (desc?.isEmpty == false) ? desc : nil
                ))
            }
        }
        try requireArgument(Set(presets.map(\.id)).count == presets.count, "胶片目录含重复标识")
        let catOrder: [FilmCategory: Int] = [.negative: 0, .cinema: 1, .reversal: 2, .monochrome: 3]
        return presets.sorted { a, b in
            let aGold = a.id != "kodak_gold_200"
            let bGold = b.id != "kodak_gold_200"
            if aGold != bGold { return !aGold }
            let ca = catOrder[a.category] ?? 99
            let cb = catOrder[b.category] ?? 99
            if ca != cb { return ca < cb }
            return a.name < b.name
        }
    }

    public func plan(parameters: FilmParameters, presets: [FilmPreset], grainSeed: Int64) throws -> FilmRenderPlan {
        let resolvedId = FilmDefaults.currentPresetId(parameters.presetId)
        var current = parameters
        current.presetId = resolvedId
        guard let preset = presets.first(where: { $0.id == resolvedId })
                ?? Self.legacySilver.first(where: { $0.id == resolvedId }) else {
            throw LumatteError.invalidArgument("所选胶卷模型不可用，请重新选卷")
        }
        return FilmRenderPlan(parameters: current, preset: preset, grainSeed: grainSeed)
    }
}

// MARK: - MobileFilmModel & Library

public enum FilmModelOrigin: String, Sendable {
    case spektrafilm = "SPEKTRAFILM"
    case projectMonochrome = "PROJECT_MONOCHROME"
    case fotufilmMobile = "FOTUFILM_MOBILE"
}

public struct MobileFilmModelInfo: Equatable, Sendable {
    public let stockId: String
    public let printId: String
    public let positive: Bool
    public let modelVersion: String
    public let sourceCommit: String?
    public let tableBytes: Int64
    public let origin: FilmModelOrigin
}

public struct FilmStageTable: Sendable {
    public let size: Int
    public let minimum: [Float]
    public let maximum: [Float]
    public let values: [Float]

    public var bytes: Int64 { Int64(values.count * MemoryLayout<Float>.size) }
}

public struct FotufilmHalationKernel: Sendable {
    public let sigmaMm: [Float]   // 3 floats
    public let weights: [Float]   // 9 floats
    public let matrix: [Float]    // 9 floats
}

public struct MobileFilmEffects: Sendable {
    public let grainActive: Bool
    public let particleAreaUm2: Float
    public let particleScale: [Float]
    public let densityFloor: [Float]
    public let grainUniformity: [Float]
    public let densityMaximum: [Float]
    public let halationStrength: [Float]
    public let halationSigmaUm: [Float]
    public let filmFormatMm: Float
    public let halationBounces: Int
    public let halationDecay: Float
    public let grainSpacingUm: Float
    public let scatterAmount: Float
    public let scatterCoreUm: [Float]
    public let scatterTailUm: [Float]
    public let scatterTailWeight: [Float]
    public let fotufilmHalation: FotufilmHalationKernel?
}

public struct MobileFilmModel: Sendable {
    public let info: MobileFilmModelInfo
    public let response: FilmStageTable
    public let development: FilmStageTable
    public let scan: FilmStageTable
    public let effects: MobileFilmEffects
}

public actor MobileFilmModelLibrary {
    private struct Entry {
        let info: MobileFilmModelInfo
        let manifestSha256: String
        let root: String
    }

    private static let spectralRoot = "film/mobile-v1"
    private static let sourceCommit = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
    private static let modelVersion = "sf-3bb2c2d-three-stage-v1"

    private static let monoRoot = "film/mobile-monochrome-v1"
    private static let monoVersion = "lfm-silver-three-stage-v1"
    private static let monoStocks: Set<String> = ["lfm_silver_neutral", "lfm_silver_contrast"]

    private static let fotuRoot = "film/mobile-fotufilm-v1"
    private static let fotuVersion = "lfm-fotufilm-public-three-stage-v1"
    private static let fotuCommit = "12c8efea259e4cea70ec22166e504634d401a0cd"
    private static let fotuStocks: Set<String> = [
        "cinestill_800t", "cinestill_400d", "fujifilm_acros_100_ii",
        "kodak_tri_x_400", "ilford_hp5_plus_400", "ilford_delta_3200"
    ]

    private var entries: [String: Entry]?
    private var cacheOrder: [String] = []
    private var cache: [String: MobileFilmModel] = [:]
    private var cachedBytes: Int64 = 0
    private let maxCacheBytes: Int64 = 12 * 1024 * 1024
    private let maxCacheModels = 2

    public init() {}

    public func clear() {
        cacheOrder.removeAll()
        cache.removeAll()
        cachedBytes = 0
    }

    public func allModelsInfo() throws -> [MobileFilmModelInfo] {
        try loadIndex().values.map(\.info)
    }

    public func load(preset: FilmPreset) throws -> MobileFilmModel {
        let idx = try loadIndex()
        guard let entry = idx[preset.id] else {
            throw LumatteError.invalidArgument("所选胶卷尚无移动模型数据")
        }
        try requireArgument(
            entry.info.printId == preset.printId && entry.info.positive == preset.positive,
            "移动胶片模型与所选胶卷／相纸不符"
        )
        if let cached = cache[preset.id] {
            return cached
        }

        let manifestBytes = try AssetLocator.data(forAssetPath: "\(entry.root)/\(preset.id)/model.json", maxBytes: 256 * 1024)
        try requireArgument(Self.sha256Hex(manifestBytes) == entry.manifestSha256, "胶片模型说明哈希不符")
        guard let manifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              let tables = manifest["tables"] as? [String: Any],
              let responseDesc = tables["response"] as? [String: Any],
              let devDesc = tables["development"] as? [String: Any],
              let scanDesc = tables["scan"] as? [String: Any] else {
            throw LumatteError.illegalState("胶片模型说明格式无效")
        }

        try requireArgument(
            (manifest["schema"] as? Int) == 1 &&
            (manifest["modelVersion"] as? String) == entry.info.modelVersion &&
            (manifest["stockId"] as? String) == preset.id &&
            (manifest["printId"] as? String) == preset.printId &&
            (manifest["positive"] as? Bool) == preset.positive &&
            (manifest["storage"] as? String) == "float32_le_rgb_x_fastest" &&
            (manifest["spatialEffectsBaked"] as? Bool) == false &&
            (manifest["grainBaked"] as? Bool) == false,
            "不支持此胶片模型来源／阶段格式"
        )

        let response = try Self.readTable(root: entry.root, stock: preset.id, name: "response", json: responseDesc, inputSpace: "srgb_encoded", outputSpace: "film_raw_linear")
        let development = try Self.readTable(root: entry.root, stock: preset.id, name: "development", json: devDesc, inputSpace: "film_log10_exposure", outputSpace: "film_cmy_density")
        let scan = try Self.readTable(root: entry.root, stock: preset.id, name: "scan", json: scanDesc, inputSpace: "film_cmy_density", outputSpace: "srgb_encoded")
        let effects = try Self.readEffects(manifest: manifest, scan: scanDesc)

        let count = response.bytes + development.bytes + scan.bytes
        try requireArgument(count == entry.info.tableBytes, "胶片模型总大小不符")

        let model = MobileFilmModel(info: entry.info, response: response, development: development, scan: scan, effects: effects)
        if count <= maxCacheBytes {
            while !cacheOrder.isEmpty && (cacheOrder.count >= maxCacheModels || cachedBytes + count > maxCacheBytes) {
                let oldestKey = cacheOrder.removeFirst()
                if let old = cache.removeValue(forKey: oldestKey) {
                    cachedBytes -= old.info.tableBytes
                }
            }
            cacheOrder.append(preset.id)
            cache[preset.id] = model
            cachedBytes += count
        }
        return model
    }

    private func loadIndex() throws -> [String: Entry] {
        if let entries { return entries }
        let spectral = try Self.readIndex(root: Self.spectralRoot, expectedVersion: Self.modelVersion, origin: .spektrafilm)
        let monochrome = try Self.readIndex(root: Self.monoRoot, expectedVersion: Self.monoVersion, origin: .projectMonochrome)
        let fotufilm = try Self.readIndex(root: Self.fotuRoot, expectedVersion: Self.fotuVersion, origin: .fotufilmMobile)
        var merged: [String: Entry] = [:]
        for dict in [spectral, monochrome, fotufilm] {
            for (k, v) in dict {
                try requireArgument(merged[k] == nil, "移动胶片目录标识重复")
                merged[k] = v
            }
        }
        self.entries = merged
        return merged
    }

    private static func readIndex(root: String, expectedVersion: String, origin: FilmModelOrigin) throws -> [String: Entry] {
        let data = try AssetLocator.data(forAssetPath: "\(root)/index.json", maxBytes: 256 * 1024)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["schema"] as? Int) == 1,
              (json["modelVersion"] as? String) == expectedVersion,
              let models = json["models"] as? [[String: Any]],
              (1...128).contains(models.count) else {
            throw LumatteError.illegalState("不支持此移动胶片目录版本")
        }
        var result: [String: Entry] = [:]
        for item in models {
            guard let id = item["stockId"] as? String,
                  let printId = item["printId"] as? String,
                  let version = item["modelVersion"] as? String,
                  let tableBytes = (item["tableBytes"] as? NSNumber)?.int64Value,
                  let digest = item["manifestSha256"] as? String,
                  let positive = item["positive"] as? Bool,
                  version == expectedVersion else {
                throw LumatteError.illegalState("移动胶片目录条目无效")
            }
            if origin == .projectMonochrome {
                try requireArgument(monoStocks.contains(id) && printId == "lfm_silver_paper" && !positive, "自有黑白目录条目无效")
            }
            if origin == .fotufilmMobile {
                try requireArgument(fotuStocks.contains(id) && printId == "fotu_fixed_print" && !positive, "Fotufilm 移动目录条目无效")
            }
            let commit: String? = {
                switch origin {
                case .spektrafilm: return sourceCommit
                case .fotufilmMobile: return fotuCommit
                case .projectMonochrome: return nil
                }
            }()
            result[id] = Entry(
                info: MobileFilmModelInfo(
                    stockId: id,
                    printId: printId,
                    positive: positive,
                    modelVersion: version,
                    sourceCommit: commit,
                    tableBytes: tableBytes,
                    origin: origin
                ),
                manifestSha256: digest,
                root: root
            )
        }
        return result
    }

    private static func readTable(
        root: String,
        stock: String,
        name: String,
        json: [String: Any],
        inputSpace: String,
        outputSpace: String
    ) throws -> FilmStageTable {
        guard let size = json["size"] as? Int,
              (2...65).contains(size),
              (json["file"] as? String) == "\(name).f32",
              (json["shaper"] as? String) == "linear",
              (json["inputSpace"] as? String) == inputSpace,
              (json["outputSpace"] as? String) == outputSpace,
              let expectedBytes = (json["bytes"] as? NSNumber)?.int64Value,
              let expectedHash = json["sha256"] as? String else {
            throw LumatteError.illegalState("胶片阶段表格式无效")
        }
        let count = size * size * size * 3
        try requireArgument(expectedBytes == Int64(count * 4), "胶片阶段表大小无效")

        func parseAxis(_ key: String) throws -> [Float] {
            guard let arr = json[key] as? [NSNumber], arr.count == 3 else {
                throw LumatteError.illegalState("胶片采样轴数量无效")
            }
            return try arr.map { num in
                let f = num.floatValue
                try requireArgument(f.isFinite, "胶片采样轴不是有限值")
                return f
            }
        }
        let low = try parseAxis("minimum")
        let high = try parseAxis("maximum")
        for c in 0..<3 {
            try requireArgument(high[c] > low[c] && (high[c] - low[c]).isFinite, "胶片采样轴范围无效")
        }

        let rawBytes = try AssetLocator.data(forAssetPath: "\(root)/\(stock)/\(name).f32")
        try requireArgument(rawBytes.count == count * 4, "胶片阶段表大小不符")
        try requireArgument(sha256Hex(rawBytes) == expectedHash, "胶片阶段表哈希不符")

        var values = [Float](repeating: 0, count: count)
        try rawBytes.withUnsafeBytes { rawBuf in
            let uint32Ptr = rawBuf.bindMemory(to: UInt32.self)
            for i in 0..<count {
                let f = Float(bitPattern: UInt32(littleEndian: uint32Ptr[i]))
                if !f.isFinite {
                    throw LumatteError.illegalState("胶片阶段表包含无效数值")
                }
                values[i] = f
            }
        }
        return FilmStageTable(size: size, minimum: low, maximum: high, values: values)
    }

    private static func readEffects(manifest: [String: Any], scan: [String: Any]) throws -> MobileFilmEffects {
        guard let grain = manifest["grainReference"] as? [String: Any],
              let halation = manifest["halationReference"] as? [String: Any],
              let settings = manifest["settingsSnapshot"] as? [String: Any],
              let camera = settings["camera"] as? [String: Any],
              let stockId = manifest["stockId"] as? String else {
            throw LumatteError.illegalState("胶片效果参数缺失")
        }

        func scalar(_ dict: [String: Any], _ key: String, low: Float, high: Float) throws -> Float {
            guard let num = dict[key] as? NSNumber else {
                throw LumatteError.illegalState("胶片效果参数缺失：\(key)")
            }
            let f = num.floatValue
            try requireArgument(f.isFinite && (low...high).contains(f), "胶片效果参数无效：\(key)")
            return f
        }

        func triple(_ dict: [String: Any], _ key: String, low: Float, high: Float) throws -> [Float] {
            guard let arr = dict[key] as? [NSNumber], arr.count == 3 else {
                throw LumatteError.illegalState("胶片效果通道数无效：\(key)")
            }
            return try arr.map { num in
                let f = num.floatValue
                try requireArgument(f.isFinite && (low...high).contains(f), "胶片效果参数无效：\(key)")
                return f
            }
        }

        var maximum = try triple(scan, "maximum", low: 0.21, high: 10.0)
        for c in 0..<3 { maximum[c] -= 0.2 }

        func scatter(_ key: String, fallback: [Float], high: Float) throws -> [Float] {
            if halation[key] != nil {
                return try triple(halation, key, low: 0, high: high)
            }
            return fallback
        }

        let cineStill = stockId == "cinestill_800t" || stockId == "cinestill_400d"
        let physical: FotufilmHalationKernel?
        if cineStill {
            guard let kernel = halation["fotufilm_kernel"] as? [String: Any],
                  (kernel["algorithm"] as? String) == "fotufilm-legacy-physical-v1",
                  (kernel["analysis_long_edge"] as? Int) == 1536 else {
                throw LumatteError.illegalState("不支持的 CineStill 光晕求解")
            }
            func rows(_ key: String, high: Float, unitSum: Bool) throws -> [Float] {
                guard let outer = kernel[key] as? [[NSNumber]], outer.count == 3 else {
                    throw LumatteError.illegalState("CineStill 光晕矩阵无效")
                }
                var out: [Float] = []
                out.reserveCapacity(9)
                for r in 0..<3 {
                    let row = outer[r]
                    try requireArgument(row.count == 3, "CineStill 光晕矩阵行无效")
                    var rowSum: Double = 0
                    for c in 0..<3 {
                        let f = row[c].floatValue
                        try requireArgument(f.isFinite && f >= -1e-6 && f <= high, "CineStill 光晕矩阵数值越界")
                        out.append(f)
                        rowSum += Double(f)
                    }
                    if unitSum {
                        try requireArgument(abs(rowSum - 1.0) < 1e-5, "CineStill 光晕权重未归一化")
                    } else {
                        try requireArgument((0.0...1.0).contains(rowSum), "CineStill 光晕混音矩阵越界")
                    }
                }
                return out
            }
            physical = FotufilmHalationKernel(
                sigmaMm: try triple(kernel, "sigma_mm", low: 0.000001, high: 2.0),
                weights: try rows("weights", high: 1.0, unitSum: true),
                matrix: try rows("mix_matrix", high: 1.0, unitSum: false)
            )
        } else {
            physical = nil
        }

        let grainActive = (grain["active"] as? Bool) ?? false
        let bounces = (halation["halation_n_bounces"] as? Int) ?? 3
        let decay = (halation["halation_bounce_decay"] as? NSNumber)?.floatValue ?? 0.5
        let spacing = (grain["spacing_um"] as? NSNumber)?.floatValue ?? 0.0
        let scatterAmount = (halation["scatter_amount"] as? NSNumber)?.floatValue ?? 1.0

        return MobileFilmEffects(
            grainActive: grainActive,
            particleAreaUm2: try scalar(grain, "particle_area_um2", low: 0.0001, high: 10.0),
            particleScale: try triple(grain, "particle_scale", low: 0.0001, high: 20.0),
            densityFloor: try triple(grain, "density_min", low: 0, high: 1.0),
            grainUniformity: try triple(grain, "uniformity", low: 0, high: 1.0),
            densityMaximum: maximum,
            halationStrength: try triple(halation, "halation_strength", low: 0, high: 2.0),
            halationSigmaUm: try triple(halation, "halation_first_sigma_um", low: 0, high: 1000.0),
            filmFormatMm: try scalar(camera, "film_format_mm", low: 10.0, high: 100.0),
            halationBounces: bounces,
            halationDecay: decay,
            grainSpacingUm: spacing,
            scatterAmount: scatterAmount,
            scatterCoreUm: try scatter("scatter_core_um", fallback: [2.2, 2.0, 1.6], high: 1000.0),
            scatterTailUm: try scatter("scatter_tail_um", fallback: [9.3, 9.7, 9.1], high: 1000.0),
            scatterTailWeight: try scatter("scatter_tail_weight", fallback: [0.78, 0.65, 0.67], high: 1.0),
            fotufilmHalation: physical
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Native Mobile Film Renderer

public enum NativeMobileFilmRenderer {
    public static func renderRGBA8888(
        pixels: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        stride: Int,
        model: MobileFilmModel,
        plan: FilmRenderPlan,
        effectiveInput: PixelSize
    ) throws {
        var bounds18: [Float] = []
        bounds18.reserveCapacity(18)
        for stage in [model.response, model.development, model.scan] {
            bounds18.append(contentsOf: stage.minimum)
            bounds18.append(contentsOf: stage.maximum)
        }

        let effect = model.effects
        let cineStill = plan.preset.id == "cinestill_800t" || plan.preset.id == "cinestill_400d"
        let physical = effect.fotufilmHalation
        try requireArgument(!cineStill || physical != nil, "CineStill 缺少原始光晕求解参数")

        var controls: [Float] = []
        controls.reserveCapacity(60)
        controls.append(plan.parameters.diffusion.strength)                     // [0]
        controls.append(plan.parameters.halationEnabled ? 1.0 : 0.0)            // [1]
        controls.append(plan.parameters.exposureEv)                             // [2]
        controls.append(effect.grainActive ? 1.0 : 0.0)                         // [3]
        controls.append(effect.particleAreaUm2)                                 // [4]
        controls.append(contentsOf: effect.particleScale)                       // [5..7]
        controls.append(contentsOf: effect.densityFloor)                        // [8..10]
        controls.append(contentsOf: effect.grainUniformity)                     // [11..13]
        controls.append(contentsOf: effect.densityMaximum)                      // [14..16]
        controls.append(contentsOf: effect.halationStrength)                    // [17..19]
        controls.append(contentsOf: effect.halationSigmaUm)                     // [20..22]
        controls.append(effect.filmFormatMm)                                    // [23]
        controls.append(cineStill ? 1.0 : 0.0)                                  // [24]
        controls.append(Float(effect.halationBounces))                          // [25]
        controls.append(effect.halationDecay)                                   // [26]
        controls.append(effect.grainSpacingUm)                                  // [27]
        controls.append(effect.scatterAmount)                                   // [28]
        controls.append(contentsOf: effect.scatterCoreUm)                       // [29..31]
        controls.append(contentsOf: effect.scatterTailUm)                       // [32..34]
        controls.append(contentsOf: effect.scatterTailWeight)                   // [35..37]
        controls.append(contentsOf: physical?.sigmaMm ?? [0, 0, 0])             // [38..40]
        controls.append(contentsOf: physical?.weights ?? [Float](repeating: 0, count: 9)) // [41..49]
        controls.append(contentsOf: physical?.matrix ?? [Float](repeating: 0, count: 9))  // [50..58]
        let remjetLook: Float = {
            switch plan.preset.id {
            case "cinestill_800t": return 1.4
            case "cinestill_400d": return 1.0
            default: return 0.0
            }
        }()
        controls.append(remjetLook)                                             // [59]
        precondition(controls.count == 60)

        var errorBuf = [CChar](repeating: 0, count: 256)
        let rc = model.response.values.withUnsafeBufferPointer { respPtr in
            model.development.values.withUnsafeBufferPointer { devPtr in
                model.scan.values.withUnsafeBufferPointer { scanPtr in
                    bounds18.withUnsafeBufferPointer { boundsPtr in
                        controls.withUnsafeBufferPointer { ctrlPtr in
                            lumatte_render_film_rgba8888(
                                pixels,
                                UInt32(width),
                                UInt32(height),
                                UInt32(stride),
                                respPtr.baseAddress,
                                Int32(model.response.size),
                                devPtr.baseAddress,
                                Int32(model.development.size),
                                scanPtr.baseAddress,
                                Int32(model.scan.size),
                                boundsPtr.baseAddress,
                                ctrlPtr.baseAddress,
                                Int32(effectiveInput.width),
                                Int32(effectiveInput.height),
                                UInt64(bitPattern: plan.grainSeed),
                                &errorBuf,
                                errorBuf.count
                            )
                        }
                    }
                }
            }
        }
        if rc != 0 {
            throw LumatteError.illegalState(String(cString: errorBuf))
        }
    }
}

// MARK: - FilmEditorialLibrary

public struct FilmEditorial: Equatable, Sendable {
    public let tagline: String
    public let story: String
    public let tags: [String]
    public let colour: String
    public let grain: String
    public let contrast: String
    public let use: String
    public let balance: String
    public let process: String
    public let accentHex: UInt32
    public let source: String?
    public let note: String
}

public enum FilmEditorialLibrary {
    private static let kodak = "https://www.kodak.com/en/still-film/product/"
    private static let portra = "https://www.kodakprofessional.com/photographers/film/color/"
    private static let fuji = "https://www.fujifilm.com/in/en/consumer/support/films/negative-and-reversal"
    private static let cinema = "https://www.kodak.com/en/motion/products/camera-films/"

    private static let entries: [String: FilmEditorial] = [
        "kodak_ektar_100": FilmEditorial(
            tagline: "把细节与色彩，都留得鲜明。",
            story: "Ektar 100 将低感光度、细腻颗粒和高饱和色彩放在一起。它的重点是清晰的轮廓与鲜明的颜色：日光下的建筑、山野、旅行与静物，很适合用它观察材质和细节。相较以肤色为核心的 Portra，它更适合让画面中的色块成为主角。",
            tags: ["鲜明", "细腻", "日光", "风景"], colour: "高饱和色彩", grain: "细腻颗粒", contrast: "清晰轮廓", use: "风景与静物", balance: "日光平衡", process: "C-41", accentHex: 0xFFE76228, source: kodak + "professional/ektar-100-film/", note: ""
        ),
        "kodak_ultramax_400": FilmEditorial(
            tagline: "为变化中的光线，留一点余地。",
            story: "Ultramax 400 是面向日常拍摄的高速彩色负片。ISO 400 让它能应对室内、阴天和动作场景，色彩鲜活，颗粒也是画面质感的一部分。与细腻、低感的 Ektar 不同，这一卷强调的是随手记录的灵活性：街头、朋友与旅行中稍纵即逝的时刻。",
            tags: ["日常", "鲜活", "街头", "动感"], colour: "鲜活色彩", grain: "可见纹理", contrast: "清晰层次", use: "街拍与生活", balance: "日光平衡", process: "C-41", accentHex: 0xFFE7B83F, source: kodak + "consumer/ultramax-400-film/", note: ""
        ),
        "kodak_gold_200": FilmEditorial(
            tagline: "一卷熟悉的、温暖的日常。",
            story: "Gold 200 的暖色与饱满颜色，让日光下的街道、旅行和家人有一种熟悉的相册气息。中等感光度与较宽的曝光余量，兼顾日常使用和细节。试着把阳光照亮的肤色、浅色墙面与天空放在同一幅画面里，观察暖色和蓝色如何相互衬托。",
            tags: ["温暖", "日常", "自然", "旅行"], colour: "温暖色调", grain: "细颗粒", contrast: "均衡反差", use: "生活与旅行", balance: "日光平衡", process: "C-41", accentHex: 0xFFF5BE46, source: kodak + "consumer/gold-200-film/", note: ""
        ),
        "kodak_portra_160": FilmEditorial(
            tagline: "让肤色与细节，慢慢展开。",
            story: "Portra 160 把平滑、自然的肤色与细腻颗粒放在首位。它适合光线充足的肖像、婚礼和安静的静物，不急于把每一种颜色推得很浓。与 Portra 400 和 800 相比，这一卷更适合从容安排光线，保留皮肤、衣料和明亮背景之间细微的过渡。",
            tags: ["肤色", "柔和", "细腻", "肖像"], colour: "自然肤色", grain: "细腻纹理", contrast: "柔和过渡", use: "肖像与静物", balance: "日光平衡", process: "C-41", accentHex: 0xFFC4AA7E, source: portra + "kodak-professional-portra-160-film/529", note: ""
        ),
        "kodak_portra_400": FilmEditorial(
            tagline: "从室内到街头，保持自然的肤色。",
            story: "Portra 400 保留 Portra 家族自然的肤色表现，同时给变化中的拍摄条件更多余地。它在肖像、婚礼和旅行中兼顾速度、颗粒与色彩。可以先从窗边人像或阴天街拍开始，比较明亮肤色与暗部环境的过渡，而不必依赖夸张的色彩来建立画面。",
            tags: ["自然", "人像", "旅行", "均衡"], colour: "自然肤色", grain: "细致颗粒", contrast: "平滑层次", use: "人像与旅行", balance: "日光平衡", process: "C-41", accentHex: 0xFFD0B284, source: portra + "kodak-professional-portra-400-film/516", note: ""
        ),
        "kodak_portra_800": FilmEditorial(
            tagline: "把黄昏和室内，也留进故事。",
            story: "Portra 800 面向较弱的光线，在高速负片的纹理中保留自然肤色。室内、黄昏或需要抓住动作的场景，是它与低感 Portra 不同的使用方向。颗粒不必完全退到背景里；让它与光线一起成为氛围，同时观察暗部细节和高光的关系。",
            tags: ["弱光", "肤色", "黄昏", "纹理"], colour: "自然色彩", grain: "高速纹理", contrast: "暗部余量", use: "室内与黄昏", balance: "日光平衡", process: "C-41", accentHex: 0xFFB292C0, source: portra + "kodak-professional-portra-800-film/528", note: ""
        ),
        "fujifilm_c200": FilmEditorial(
            tagline: "轻松记录，日光里的颜色。",
            story: "C200 是面向日常摄影的日光型彩色负片。中等感光度、平衡的颜色与细节，适合把街道、旅途和生活放在同一卷里。它不以强烈风格压过内容；可以从树荫、晴天街景和浅色物体开始，寻找颜色之间清楚而自然的关系。",
            tags: ["日常", "日光", "均衡", "旅行"], colour: "平衡色彩", grain: "细致纹理", contrast: "均衡层次", use: "生活与街景", balance: "日光平衡", process: "C-41", accentHex: 0xFF93B868, source: fuji, note: ""
        ),
        "fujifilm_pro_400h": FilmEditorial(
            tagline: "在复杂光线里，照顾好肤色。",
            story: "Pro 400H 是以人像表现为重点的专业高速彩色负片，采用第四感色层技术以改善复杂光线中的色彩再现。柔和的颜色关系和自然肤色，适合婚礼、环境肖像与有浅色背景的场景。把人物放回环境中，观察脸部、衣服和背景之间的层次。",
            tags: ["人像", "柔和", "环境", "肤色"], colour: "柔和色彩", grain: "细颗粒", contrast: "平滑过渡", use: "环境肖像", balance: "日光平衡", process: "C-41", accentHex: 0xFF8DAA93, source: fuji, note: ""
        ),
        "fujifilm_xtra_400": FilmEditorial(
            tagline: "一卷应对日常变化的高速负片。",
            story: "Superia X-Tra 400 面向日常快照，兼顾高速感光度、细致颗粒与鲜明的色彩。它适合旅行、街头和家人活动，遇到阴天或室内时仍有使用空间。相较 C200，它的方向更偏灵活记录；相较 Pro 400H，则更强调普通生活场景中的颜色与活力。",
            tags: ["快照", "鲜明", "街头", "生活"], colour: "鲜明色彩", grain: "细致颗粒", contrast: "清晰层次", use: "活动与快照", balance: "日光平衡", process: "C-41", accentHex: 0xFF8DB45D, source: fuji, note: ""
        ),
        "fujifilm_provia_100f": FilmEditorial(
            tagline: "以均衡的色彩，看见细小变化。",
            story: "Provia 100F 是日光型反转片，重视细颗粒、清晰度与较均衡的色彩再现。它比 Velvia 更适合不希望颜色过分浓烈的画面：风景、产品或人物都可尝试。反转片的高光过渡与负片不同，适合观察天空、白衣和暗部之间如何分配层次。",
            tags: ["均衡", "反转片", "细腻", "风景"], colour: "均衡颜色", grain: "细腻颗粒", contrast: "明确层次", use: "风景与产品", balance: "日光平衡", process: "E-6", accentHex: 0xFF5D88B6, source: fuji, note: ""
        ),
        "fujifilm_velvia_100": FilmEditorial(
            tagline: "让山林、天空与色彩成为主角。",
            story: "Velvia 100 以饱满颜色和鲜明反差见长，是很有辨识度的日光型反转片。绿植、花朵、山野与季节色彩，适合用它表达。它与以均衡再现为重点的 Provia 不同：强烈色块更容易吸引视线，因此画面里的明暗和颜色需要一起考虑。",
            tags: ["饱和", "风景", "鲜明", "季节"], colour: "浓郁色彩", grain: "细腻纹理", contrast: "鲜明反差", use: "山野与自然", balance: "日光平衡", process: "E-6", accentHex: 0xFF66A48D, source: fuji, note: ""
        ),
        "kodak_ektachrome_100": FilmEditorial(
            tagline: "清晰、干净的反转片色彩。",
            story: "Ektachrome E100 是日光型彩色反转片，强调细颗粒、清晰度和中性的颜色再现。它适合风景、时尚与静物，也适合用光线建立明确的画面层次。与浓郁的 Velvia 比较时，可以关注白色物体与肤色：它追求的是清晰和干净，而不只是提高饱和度。",
            tags: ["中性", "干净", "细腻", "反转片"], colour: "中性颜色", grain: "细颗粒", contrast: "清晰层次", use: "风景与时尚", balance: "日光平衡", process: "E-6", accentHex: 0xFF7892B5, source: portra + "kodak-professional-ektachrome-film-e100/531", note: ""
        ),
        "kodak_kodachrome_64": FilmEditorial(
            tagline: "在旧日的色彩语言里，寻找新的画面。",
            story: "Kodachrome 64 是历史上的彩色反转片，具有独特的染料形成与 K-14 工艺。本应用保留这一历史胶卷资料对应的模拟，适合尝试旅行、建筑和有清楚色块的画面。这里的数字模拟不等于重新提供实体胶卷冲洗，也不把不同扫描与年代的成片归结为一种固定滤镜。",
            tags: ["历史", "反转片", "旅行", "色块"], colour: "历史色彩", grain: "低感纹理", contrast: "明确反差", use: "建筑与旅行", balance: "日光平衡", process: "K-14", accentHex: 0xFFB6774E, source: "https://125px.com/docs/film/kodak/e88-2002_03.pdf", note: "基于历史胶卷资料的数字模拟。"
        ),
        "kodak_vision3_50d": FilmEditorial(
            tagline: "把明亮日光中的细节，留得更细致。",
            story: "Vision3 50D 是日光平衡的低感电影负片，突出细颗粒与丰富细节。它适合明亮的外景、建筑和有精细材质的画面。与 250D 相比，它更偏向充足光线；与钨丝灯型 200T 和 500T 不同，50D 的原始色彩基准就是日光。",
            tags: ["日光", "细腻", "外景", "电影"], colour: "日光颜色", grain: "低感细颗粒", contrast: "高光层次", use: "明亮外景", balance: "日光 5500K", process: "ECN-2", accentHex: 0xFFE3AF68, source: cinema, note: ""
        ),
        "kodak_vision3_250d": FilmEditorial(
            tagline: "从明亮外景，到渐暗的日光。",
            story: "Vision3 250D 在日光平衡与中等速度之间取得平衡，适合外景和光线变化中的拍摄。它比 50D 多一点灵活性，又保留电影负片对高光和暗部层次的关注。可以从阴天街景、树荫和傍晚外景开始，观察明亮区域与人物之间的过渡。",
            tags: ["外景", "日光", "层次", "均衡"], colour: "日光平衡", grain: "细致纹理", contrast: "宽阔层次", use: "阴天与外景", balance: "日光 5500K", process: "ECN-2", accentHex: 0xFFCB995E, source: cinema, note: ""
        ),
        "kodak_vision3_200t": FilmEditorial(
            tagline: "为室内光线，保留清楚的颜色。",
            story: "Vision3 200T 是钨丝灯平衡的电影负片，适合受控室内光线和布光场景。与 500T 相比，较低感光度更偏向细腻的纹理；与日光型 250D 则有不同的色彩基准。预览时可以关注灯光照亮的肤色、暗部与窗外光线如何共同构成画面。",
            tags: ["室内", "钨丝灯", "细腻", "电影"], colour: "钨丝灯平衡", grain: "细腻纹理", contrast: "高光余量", use: "布光与室内", balance: "钨丝灯 3200K", process: "ECN-2", accentHex: 0xFF7997B0, source: cinema, note: ""
        ),
        "kodak_vision3_500t": FilmEditorial(
            tagline: "让夜色与光源，都有自己的层次。",
            story: "Vision3 500T 面向较弱光线与钨丝灯环境，是高速电影负片。它在夜景、室内和混合光中保留细节与颜色，颗粒也更容易成为气氛的一部分。它不是去除防光晕层的 CineStill 800T；亮点周围的光晕还会受到本应用 Halation 设置和原图高光的影响。",
            tags: ["夜景", "弱光", "钨丝灯", "电影"], colour: "钨丝灯平衡", grain: "高速纹理", contrast: "暗部层次", use: "室内与夜景", balance: "钨丝灯 3200K", process: "ECN-2", accentHex: 0xFF5E8DB4, source: cinema, note: ""
        ),
        "kodak_verita_200d": FilmEditorial(
            tagline: "浓郁颜色、暖肤色与深沉的黑。",
            story: "Verita 200D 是日光平衡的电影负片，强调浓郁颜色、温暖肤色与深沉黑位。它与追求细腻层次的 Vision3 各卷有不同的视觉方向，适合有明确光影和色块的外景。让人物与环境的颜色同时进入画面，观察暖肤色和较深暗部带来的电影感。",
            tags: ["暖肤色", "浓郁", "深黑", "外景"], colour: "浓郁暖色", grain: "电影纹理", contrast: "深沉黑位", use: "外景与人物", balance: "日光 5500K", process: "ECN-2", accentHex: 0xFFB37B52, source: cinema, note: ""
        ),
        "cinestill_800t": FilmEditorial(
            tagline: "让夜里的灯，留下红橙色的回声。",
            story: "以钨丝灯夜景为核心的彩色负片风格。光源周围的局部红橙光晕与冷色暗部形成对照，明亮灯芯仍是画面焦点。光晕默认开启，黑柔独立控制。",
            tags: ["夜景", "钨丝灯", "红橙光晕"], colour: "冷暖对照", grain: "高速颗粒", contrast: "亮部过渡", use: "夜间灯光", balance: "钨丝灯风格", process: "彩色负片", accentHex: 0xFFC95136, source: "https://github.com/DhaliwalX/fotufilm-engine", note: "移动风格模拟；光晕效果取决于原图中的高光。"
        ),
        "cinestill_400d": FilmEditorial(
            tagline: "把日光留下，再让高光轻轻扩散。",
            story: "面向日光和日常场景的彩色负片风格。温暖返光比 800T 克制，保留照片主体的色彩与层次。光晕默认开启，可以关闭；黑柔仍是独立选项。",
            tags: ["日光", "日常", "暖色返光"], colour: "日光彩色", grain: "中速颗粒", contrast: "平顺过渡", use: "旅行与日常", balance: "日光风格", process: "彩色负片", accentHex: 0xFFCE9C45, source: "https://github.com/DhaliwalX/fotufilm-engine", note: "移动风格模拟；与 800T 使用独立色彩和返光参数。"
        ),
        "fujifilm_acros_100_ii": FilmEditorial(
            tagline: "细腻的灰阶，也能装下丰富的光。",
            story: "以细颗粒和连续灰阶为方向，适合建筑、静物与日常光影。色彩被转为黑白时仍通过这款胶片自己的感光响应区分明暗。",
            tags: ["细腻", "灰阶", "建筑"], colour: "中性黑白", grain: "细颗粒", contrast: "平顺灰阶", use: "建筑与静物", balance: "黑白", process: "银盐风格", accentHex: 0xFF7B968A, source: "https://github.com/DhaliwalX/fotufilm-engine", note: "光晕默认关闭，可手动开启。"
        ),
        "kodak_tri_x_400": FilmEditorial(
            tagline: "让街头的黑与白，更有分量。",
            story: "鲜明层次与可见颗粒共同构成纪实感。适合街头、人物和形状明确的光影，与细腻黑白呈现不同的纹理和明暗关系。",
            tags: ["纪实", "鲜明", "纹理"], colour: "纪实黑白", grain: "可见颗粒", contrast: "鲜明层次", use: "街头与人物", balance: "黑白", process: "银盐风格", accentHex: 0xFFC9AF59, source: "https://github.com/DhaliwalX/fotufilm-engine", note: "光晕默认关闭，可手动开启。"
        ),
        "ilford_hp5_plus_400": FilmEditorial(
            tagline: "在黑与白之间，留一些温和的余地。",
            story: "以宽容的中间调和柔和过渡为方向，适合人像和日常。颗粒、感光曲线与其他黑白卷分别配置，保留自己的灰阶性格。",
            tags: ["柔和", "中间调", "人像"], colour: "柔和黑白", grain: "中等颗粒", contrast: "宽容灰阶", use: "人像与日常", balance: "黑白", process: "银盐风格", accentHex: 0xFF7B8D69, source: "https://github.com/DhaliwalX/fotufilm-engine", note: "光晕默认关闭，可手动开启。"
        ),
        "ilford_delta_3200": FilmEditorial(
            tagline: "让颗粒成为夜晚的一部分。",
            story: "以低照度气氛和明显颗粒为方向，适合夜间、舞台和室内。粗颗粒的空间尺度与强度独立设置，保留与低感光度黑白卷不同的质感。",
            tags: ["夜间", "粗颗粒", "气氛"], colour: "高速黑白", grain: "明显粗颗粒", contrast: "低照度层次", use: "夜间与室内", balance: "黑白", process: "银盐风格", accentHex: 0xFF9287A3, source: "https://github.com/DhaliwalX/fotufilm-engine", note: "光晕默认关闭；选择胶卷不会改变原照片的拍摄感光度。"
        ),
        "lfm_silver_neutral": FilmEditorial(
            tagline: "先看明暗，再看光线如何连接它们。",
            story: "Silver Neutral 是本项目自有黑白风格，以中性的亮度响应、柔和的反差和连续灰阶表现形状。适合阴天街景、环境肖像与需要保留中间调的画面。",
            tags: ["中性", "灰阶", "柔和", "自有"], colour: "中性灰阶", grain: "密度颗粒", contrast: "柔和反差", use: "街景与肖像", balance: "中性响应", process: "银盐近似", accentHex: 0xFF9CA7AA, source: nil, note: "项目自有艺术风格；非品牌胶卷实测模型。"
        ),
        "lfm_silver_contrast": FilmEditorial(
            tagline: "用更明确的黑与白，建立画面秩序。",
            story: "Silver Contrast 是本项目自有高反差黑白风格。相较 Neutral，它使用更陡的明暗响应和更强的颗粒比例，让阴影、亮面与轮廓更有分量。",
            tags: ["高反差", "轮廓", "硬光", "自有"], colour: "银盐灰阶", grain: "更强纹理", contrast: "鲜明反差", use: "建筑与硬光", balance: "中性响应", process: "银盐近似", accentHex: 0xFF8F969B, source: nil, note: "项目自有艺术风格；非品牌胶卷实测模型。"
        ),
    ]

    public static func forFilm(_ film: FilmPreset) -> FilmEditorial {
        entries[film.id] ?? FilmEditorial(
            tagline: film.name,
            story: film.description ?? "该卷的资料正在整理。",
            tags: [],
            colour: "资料待补",
            grain: "资料待补",
            contrast: "资料待补",
            use: "查看实际预览",
            balance: "未标注",
            process: "未标注",
            accentHex: 0xFFC4AA7E,
            source: nil,
            note: ""
        )
    }
}
