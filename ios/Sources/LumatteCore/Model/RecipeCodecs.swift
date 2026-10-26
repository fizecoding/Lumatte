import Foundation

public enum PhotoRecipeCodec {
    public static func write(_ recipe: PhotoRecipe) throws -> String {
        var json: [String: Any] = ["version": 1]
        switch recipe {
        case .original:
            json["type"] = "ORIGINAL"
        case .lut(let parameters):
            json["type"] = "LUT"
            func slot(_ value: LutSlot) -> [String: Any] {
                ["id": value.id ?? NSNull(), "strength": value.strength]
            }
            json["first"] = slot(parameters.first)
            json["second"] = slot(parameters.second)
            json["grain"] = parameters.grain
            json["grainEnabled"] = parameters.grainEnabled
            json["ditheringEnabled"] = parameters.ditheringEnabled
        case .film(let parameters, let seed):
            json["type"] = "FILM"
            json["preset"] = parameters.presetId
            json["exposure"] = parameters.exposureEv
            json["halation"] = parameters.halationEnabled
            json["diffusion"] = parameters.diffusion.rawValue
            json["seed"] = seed
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return String(decoding: data, as: UTF8.self)
    }

    public static func read(_ text: String) throws -> PhotoRecipe {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              (json["version"] as? Int) == 1,
              let type = json["type"] as? String else {
            throw LumatteError.invalidArgument("导出配方版本不支持")
        }
        switch type {
        case "ORIGINAL":
            return .original
        case "LUT":
            func slot(_ name: String) throws -> LutSlot {
                guard let value = json[name] as? [String: Any],
                      let strength = (value["strength"] as? NSNumber)?.floatValue else {
                    throw LumatteError.invalidArgument("LUT 配方字段无效")
                }
                let id = value["id"] is NSNull ? nil : value["id"] as? String
                return try LutSlot(id: id, strength: strength)
            }
            guard let grain = (json["grain"] as? NSNumber)?.floatValue else {
                throw LumatteError.invalidArgument("LUT 颗粒字段无效")
            }
            return .lut(try LutRecipe(
                first: try slot("first"),
                second: try slot("second"),
                grain: grain,
                grainEnabled: json["grainEnabled"] as? Bool ?? true,
                ditheringEnabled: json["ditheringEnabled"] as? Bool ?? false
            ))
        case "FILM":
            guard let preset = json["preset"] as? String,
                  let exposure = (json["exposure"] as? NSNumber)?.floatValue,
                  let diffusionRaw = json["diffusion"] as? String,
                  let diffusion = DiffusionGrade(rawValue: diffusionRaw),
                  let halation = json["halation"] as? Bool,
                  let seed = (json["seed"] as? NSNumber)?.int64Value else {
                throw LumatteError.invalidArgument("胶片配方字段无效")
            }
            let parameters = try FilmParameters(
                presetId: FilmDefaults.currentPresetId(preset),
                exposureEv: exposure,
                diffusion: diffusion,
                halationEnabled: halation
            )
            return .film(parameters: parameters, grainSeed: seed)
        default:
            throw LumatteError.illegalState("导出配方类型不支持")
        }
    }
}

public enum FrameOptionsCodec {
    public static func write(_ frame: FrameOptions) throws -> String {
        var json: [String: Any] = [
            "version": 1,
            "preset": frame.preset.rawValue,
            "border": frame.borderFraction,
            "signature": frame.signature,
            "metadata": frame.showPhotoMetadata,
            "ratio": frame.ratio.rawValue,
            "showCamera": frame.showCamera,
            "showLens": frame.showLens,
            "showFocalLength": frame.showFocalLength,
            "showAperture": frame.showAperture,
            "showShutter": frame.showShutter,
            "showIso": frame.showIso,
            "showCapturedAt": frame.showCapturedAt,
            "mood": frame.mood.rawValue,
            "roll120": frame.roll120,
            "brand": frame.filmBrand,
            "film": frame.filmName,
            "notes": frame.filmNotes,
            "signatureFont": frame.signatureFont.rawValue
        ]
        let optional: [(String, Any?)] = [
            ("color", frame.fixedColorArgb),
            ("portrait", frame.portrait),
            ("bw", frame.filmBlackWhite),
            ("title", frame.title),
            ("subtitle", frame.subtitle),
            ("footer", frame.footer),
            ("titleFont", frame.titleFont?.rawValue),
            ("subtitleFont", frame.subtitleFont?.rawValue),
            ("footerFont", frame.footerFont?.rawValue),
            ("imageKey", frame.imageKey),
            ("titleFontKey", frame.titleFontKey),
            ("subtitleFontKey", frame.subtitleFontKey),
            ("footerFontKey", frame.footerFontKey),
            ("signatureFontKey", frame.signatureFontKey)
        ]
        for (key, value) in optional {
            json[key] = value ?? NSNull()
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    public static func read(_ text: String) throws -> FrameOptions {
        guard let j = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              (j["version"] as? Int) == 1,
              let presetRaw = j["preset"] as? String,
              let preset = FramePreset(rawValue: presetRaw),
              let border = (j["border"] as? NSNumber)?.floatValue,
              let signature = j["signature"] as? String,
              let metadata = j["metadata"] as? Bool,
              let ratioRaw = j["ratio"] as? String,
              let ratio = FrameRatio(rawValue: ratioRaw),
              let signatureFontRaw = j["signatureFont"] as? String,
              let signatureFont = FrameFont(rawValue: signatureFontRaw),
              let brand = j["brand"] as? String,
              let film = j["film"] as? String,
              let notes = j["notes"] as? String,
              let roll120 = j["roll120"] as? Bool,
              let moodRaw = j["mood"] as? String,
              let mood = FrameMood(rawValue: moodRaw) else {
            throw LumatteError.invalidArgument("画框配置版本不支持")
        }
        func optionalString(_ key: String) -> String? {
            j[key] is NSNull ? nil : j[key] as? String
        }
        return try FrameOptions(
            preset: preset,
            borderFraction: border,
            signature: signature,
            showPhotoMetadata: metadata,
            fixedColorArgb: (j["color"] as? NSNumber)?.int32Value,
            ratio: ratio,
            title: optionalString("title"),
            subtitle: optionalString("subtitle"),
            footer: optionalString("footer"),
            titleFont: optionalString("titleFont").flatMap(FrameFont.init(rawValue:)),
            subtitleFont: optionalString("subtitleFont").flatMap(FrameFont.init(rawValue:)),
            footerFont: optionalString("footerFont").flatMap(FrameFont.init(rawValue:)),
            signatureFont: signatureFont,
            filmBrand: brand,
            filmName: film,
            filmNotes: notes,
            roll120: roll120,
            mood: mood,
            filmBlackWhite: j["bw"] as? Bool,
            portrait: j["portrait"] as? Bool,
            imageKey: optionalString("imageKey"),
            titleFontKey: optionalString("titleFontKey"),
            subtitleFontKey: optionalString("subtitleFontKey"),
            footerFontKey: optionalString("footerFontKey"),
            signatureFontKey: optionalString("signatureFontKey"),
            showCamera: j["showCamera"] as? Bool ?? true,
            showLens: j["showLens"] as? Bool ?? true,
            showFocalLength: j["showFocalLength"] as? Bool ?? true,
            showAperture: j["showAperture"] as? Bool ?? true,
            showShutter: j["showShutter"] as? Bool ?? true,
            showIso: j["showIso"] as? Bool ?? true,
            showCapturedAt: j["showCapturedAt"] as? Bool ?? false
        )
    }
}

public enum FilmBatchCodec {
    public static func write(_ batch: FilmBatch) throws -> String {
        let photos: [[String: Any]] = batch.photos.map { photo in
            [
                "id": photo.id.value,
                "seed": photo.grainSeed,
                "preset": photo.parameters.presetId,
                "exposure": photo.parameters.exposureEv,
                "halation": photo.parameters.halationEnabled,
                "diffusion": photo.parameters.diffusion.rawValue
            ]
        }
        let json: [String: Any] = [
            "version": 1,
            "reference": batch.referenceId.value,
            "mode": batch.mode.rawValue,
            "photos": photos
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    public static func read(_ text: String) throws -> FilmBatch {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              (json["version"] as? Int) == 1,
              let array = json["photos"] as? [[String: Any]],
              let reference = json["reference"] as? String,
              let modeRaw = json["mode"] as? String,
              let mode = FilmBatchMode(rawValue: modeRaw) else {
            throw LumatteError.invalidArgument("胶片配方版本不支持")
        }
        let photos = try array.map { value in
            guard let id = value["id"] as? String,
                  let seed = (value["seed"] as? NSNumber)?.int64Value,
                  let preset = value["preset"] as? String,
                  let exposure = (value["exposure"] as? NSNumber)?.floatValue,
                  let halation = value["halation"] as? Bool,
                  let diffusionRaw = value["diffusion"] as? String,
                  let diffusion = DiffusionGrade(rawValue: diffusionRaw) else {
                throw LumatteError.invalidArgument("胶片配方照片字段无效")
            }
            return try BatchPhoto(
                id: PhotoId(id),
                parameters: FilmParameters(
                    presetId: FilmDefaults.currentPresetId(preset),
                    exposureEv: exposure,
                    diffusion: diffusion,
                    halationEnabled: halation
                ),
                grainSeed: seed
            )
        }
        return try FilmBatch(photos: photos, referenceId: PhotoId(reference), mode: mode)
    }
}
