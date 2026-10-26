import Foundation

public enum AssetLocator {
    /// Repository root resolved at compile/test time via `#filePath`, used as fallback when running outside an app bundle.
    private static let repoRoot: URL = {
        // #filePath is Lumatte/ios/Sources/LumatteCore/Media/AssetLocator.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// Resolves a relative path inside `core/media/src/main/assets` or `app/src/main/assets` or `Bundle.main`.
    public static func url(forAssetPath relativePath: String) throws -> URL {
        let fm = FileManager.default
        if let bundleBase = Bundle.main.resourceURL {
            let candidate1 = bundleBase.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: candidate1.path) {
                return candidate1
            }
            let candidate2 = bundleBase.appendingPathComponent("media-assets").appendingPathComponent(relativePath)
            if fm.fileExists(atPath: candidate2.path) {
                return candidate2
            }
            let candidate3 = bundleBase.appendingPathComponent("app-assets").appendingPathComponent(relativePath)
            if fm.fileExists(atPath: candidate3.path) {
                return candidate3
            }
            let fileName = (relativePath as NSString).lastPathComponent
            let candidateFlat = bundleBase.appendingPathComponent(fileName)
            if fm.fileExists(atPath: candidateFlat.path) {
                return candidateFlat
            }
        }

        let mediaCandidate = repoRoot
            .appendingPathComponent("core/media/src/main/assets")
            .appendingPathComponent(relativePath)
        if fm.fileExists(atPath: mediaCandidate.path) {
            return mediaCandidate
        }

        let appCandidate = repoRoot
            .appendingPathComponent("app/src/main/assets")
            .appendingPathComponent(relativePath)
        if fm.fileExists(atPath: appCandidate.path) {
            return appCandidate
        }

        throw LumatteError.illegalState("找不到内置资源：\(relativePath)")
    }

    public static func data(forAssetPath relativePath: String, maxBytes: Int? = nil) throws -> Data {
        let fileURL = try url(forAssetPath: relativePath)
        let data = try Data(contentsOf: fileURL)
        if let maxBytes {
            try requireArgument(data.count <= maxBytes, "内置资源过大：\(relativePath)")
        }
        return data
    }

    public static func cartridgeURL(forStockId stockId: String) -> URL? {
        guard let fileName = FilmCartridgeArtwork.fileName(for: stockId) else {
            return nil
        }
        let fm = FileManager.default
        if let bundleBase = Bundle.main.resourceURL {
            for candidate in [
                bundleBase.appendingPathComponent("cartridges/\(fileName)"),
                bundleBase.appendingPathComponent("drawable-nodpi/\(fileName)"),
                bundleBase.appendingPathComponent(fileName)
            ] {
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        let repoCandidate = repoRoot
            .appendingPathComponent("core/media/src/main/res/drawable-nodpi")
            .appendingPathComponent(fileName)
        if fm.fileExists(atPath: repoCandidate.path) {
            return repoCandidate
        }
        return nil
    }
}

public enum FilmCartridgeArtwork {
    public static func fileName(for stockId: String) -> String? {
        var base = stockId
        if base.hasSuffix("_push1") { base = String(base.dropLast(6)) }
        if base.hasSuffix("_push2") { base = String(base.dropLast(6)) }
        switch base {
        case "kodak_gold_200": return "cartridge_gold_200_v2.png"
        case "fujifilm_c200": return "cartridge_c200_v1.png"
        case "fujifilm_velvia_100": return "cartridge_velvia_100_v2.png"
        case "kodak_vision3_500t": return "cartridge_vision3_500t_v2.png"
        case "lfm_silver_neutral": return "cartridge_silver_neutral_v1.png"
        case "lfm_silver_contrast": return "cartridge_silver_contrast_v1.png"
        case "fujifilm_pro_400h": return "cartridge_fujifilm_pro_400h_v1.png"
        case "fujifilm_provia_100f": return "cartridge_fujifilm_provia_100f_v1.png"
        case "fujifilm_xtra_400": return "cartridge_fujifilm_xtra_400_v1.png"
        case "kodak_ektachrome_100": return "cartridge_kodak_ektachrome_100_v1.png"
        case "kodak_ektar_100": return "cartridge_kodak_ektar_100_v1.png"
        case "kodak_kodachrome_64": return "cartridge_kodak_kodachrome_64_v1.png"
        case "kodak_portra_160": return "cartridge_kodak_portra_160_v1.png"
        case "kodak_portra_400": return "cartridge_kodak_portra_400_v1.png"
        case "kodak_portra_800": return "cartridge_kodak_portra_800_v1.png"
        case "kodak_ultramax_400": return "cartridge_kodak_ultramax_400_v1.png"
        case "kodak_verita_200d": return "cartridge_kodak_verita_200d_v1.png"
        case "kodak_vision3_200t": return "cartridge_kodak_vision3_200t_v1.png"
        case "kodak_vision3_250d": return "cartridge_kodak_vision3_250d_v1.png"
        case "kodak_vision3_50d": return "cartridge_kodak_vision3_50d_v1.png"
        case "cinestill_800t": return "cartridge_cinestill_800t_v1.png"
        case "cinestill_400d": return "cartridge_cinestill_400d_v1.png"
        case "fujifilm_acros_100_ii": return "cartridge_fujifilm_acros_100_ii_v1.png"
        case "kodak_tri_x_400": return "cartridge_kodak_tri_x_400_v1.png"
        case "ilford_hp5_plus_400": return "cartridge_ilford_hp5_plus_400_v1.png"
        case "ilford_delta_3200": return "cartridge_ilford_delta_3200_v1.png"
        default: return nil
        }
    }
}
