import Foundation

public enum LumatteError: Error, LocalizedError, Equatable {
    case invalidArgument(String)
    case illegalState(String)
    case protocolError(String)
    case httpError(Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let msg), .illegalState(let msg), .protocolError(let msg):
            return msg
        case .httpError(let code):
            return "HTTP \(code)"
        case .cancelled:
            return "操作已取消"
        }
    }
}

@inlinable
internal func requireArgument(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "参数无效") throws {
    if !condition() {
        throw LumatteError.invalidArgument(message())
    }
}

@inlinable
internal func checkState(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "状态无效") throws {
    if !condition() {
        throw LumatteError.illegalState(message())
    }
}

// MARK: - Core Value Types

public struct PhotoId: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String { value }
}

public struct PixelSize: Equatable, Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        try requireArgument(width > 0 && height > 0, "像素尺寸必须大于 0")
        self.width = width
        self.height = height
    }

    public init(uncheckedWidth width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
    }
}

public struct FloatBox: Equatable, Hashable, Codable, Sendable {
    public let left: Float
    public let top: Float
    public let right: Float
    public let bottom: Float

    public init(left: Float, top: Float, right: Float, bottom: Float) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var width: Float { right - left }
    public var height: Float { bottom - top }
}

public enum VideoContainer: String, Codable, Sendable {
    case mov = "MOV"
    case mp4 = "MP4"
    case mpegTs = "MPEG_TS"
}

// MARK: - LUT Recipe

public struct LutSlot: Equatable, Hashable, Codable, Sendable {
    public var id: String?
    public var strength: Float

    public init(id: String? = nil, strength: Float = 1.0) throws {
        try requireArgument(strength.isFinite && (0...1).contains(strength), "LUT 强度需在 0...1 之间")
        self.id = id
        self.strength = strength
    }

    public static let empty = try! LutSlot(id: nil, strength: 1.0)
}

public struct LutRecipe: Equatable, Hashable, Codable, Sendable {
    public var first: LutSlot
    public var second: LutSlot
    public var grain: Float
    public var grainEnabled: Bool
    public var ditheringEnabled: Bool

    public init(
        first: LutSlot = .empty,
        second: LutSlot = .empty,
        grain: Float = 0,
        grainEnabled: Bool = true,
        ditheringEnabled: Bool = true
    ) throws {
        try requireArgument(grain.isFinite && (0...1).contains(grain), "LUT 颗粒强度需在 0...1 之间")
        self.first = first
        self.second = second
        self.grain = grain
        self.grainEnabled = grainEnabled
        self.ditheringEnabled = ditheringEnabled
    }

    public static let `default` = try! LutRecipe()
}

// MARK: - Film Parameters & Batch

public enum FilmBatchMode: String, CaseIterable, Codable, Sendable {
    case individual = "INDIVIDUAL"
    case firstPhoto = "FIRST_PHOTO"

    public var title: String {
        switch self {
        case .individual: return "逐张独立"
        case .firstPhoto: return "继承首张"
        }
    }
}

public enum DiffusionGrade: String, CaseIterable, Codable, Sendable {
    case off = "OFF"
    case eighth = "EIGHTH"
    case quarter = "QUARTER"
    case half = "HALF"

    public var strength: Float {
        switch self {
        case .off: return 0
        case .eighth: return 0.125
        case .quarter: return 0.25
        case .half: return 0.5
        }
    }

    public var label: String {
        switch self {
        case .off: return "关闭"
        case .eighth: return "1/8"
        case .quarter: return "1/4"
        case .half: return "1/2"
        }
    }
}

public enum PhotoTreatment: String, CaseIterable, Codable, Sendable {
    case lut = "LUT"
    case film = "FILM"
    case original = "ORIGINAL"
}

public enum FilmDefaults {
    public static func currentPresetId(_ id: String) -> String {
        switch id {
        case "kodak_portra_800_push1", "kodak_portra_800_push2":
            return "kodak_portra_800"
        default:
            return id
        }
    }

    public static func halationEnabled(presetId: String) -> Bool {
        presetId == "cinestill_800t" || presetId == "cinestill_400d"
    }
}

public struct FilmParameters: Equatable, Hashable, Codable, Sendable {
    public var presetId: String
    public var exposureEv: Float
    public var diffusion: DiffusionGrade
    public var halationEnabled: Bool

    public init(
        presetId: String = "kodak_gold_200",
        exposureEv: Float = 0,
        diffusion: DiffusionGrade = .off,
        halationEnabled: Bool? = nil
    ) throws {
        try requireArgument(exposureEv.isFinite && (-3.0...3.0).contains(exposureEv), "曝光补偿需在 -3.0...+3.0 EV 之间")
        self.presetId = presetId
        self.exposureEv = exposureEv
        self.diffusion = diffusion
        self.halationEnabled = halationEnabled ?? FilmDefaults.halationEnabled(presetId: presetId)
    }

    public static let `default` = try! FilmParameters()

    public func withPreset(_ id: String) -> FilmParameters {
        var copy = self
        copy.presetId = id
        copy.halationEnabled = FilmDefaults.halationEnabled(presetId: id)
        return copy
    }
}

public struct BatchPhoto: Equatable, Hashable, Codable, Sendable {
    public let id: PhotoId
    public var parameters: FilmParameters
    public var grainSeed: Int64

    public init(id: PhotoId, parameters: FilmParameters, grainSeed: Int64) {
        self.id = id
        self.parameters = parameters
        self.grainSeed = grainSeed
    }
}

public struct FilmBatch: Equatable, Codable, Sendable {
    public var photos: [BatchPhoto]
    public var referenceId: PhotoId
    public var mode: FilmBatchMode

    public init(
        photos: [BatchPhoto],
        referenceId: PhotoId,
        mode: FilmBatchMode = .firstPhoto
    ) throws {
        try requireArgument(!photos.isEmpty, "批次照片不能为空")
        let uniqueIds = Set(photos.map(\.id))
        try requireArgument(uniqueIds.count == photos.count, "批次含重复照片 ID")
        try requireArgument(uniqueIds.contains(referenceId), "参考照片不在当前批次中")
        self.photos = photos
        self.referenceId = referenceId
        self.mode = mode
    }

    public func effectiveParameters(for id: PhotoId) throws -> FilmParameters {
        guard let photo = photos.first(where: { $0.id == id }) else {
            throw LumatteError.invalidArgument("找不到照片 \(id)")
        }
        switch mode {
        case .individual:
            return photo.parameters
        case .firstPhoto:
            guard let ref = photos.first(where: { $0.id == referenceId }) else {
                throw LumatteError.invalidArgument("找不到参考照片 \(referenceId)")
            }
            return ref.parameters
        }
    }

    public func updateParameters(id: PhotoId, parameters: FilmParameters) throws -> FilmBatch {
        try requireArgument(mode == .individual || id == referenceId, "继承首张模式下仅可编辑首张参考照片")
        try requireArgument(photos.contains(where: { $0.id == id }), "找不到照片 \(id)")
        let updated = photos.map { item -> BatchPhoto in
            if item.id == id {
                return BatchPhoto(id: item.id, parameters: parameters, grainSeed: item.grainSeed)
            }
            return item
        }
        return try FilmBatch(photos: updated, referenceId: referenceId, mode: mode)
    }

    public func copyReferenceToAll() throws -> FilmBatch {
        guard let ref = photos.first(where: { $0.id == referenceId }) else {
            throw LumatteError.invalidArgument("找不到参考照片")
        }
        let updated = photos.map { BatchPhoto(id: $0.id, parameters: ref.parameters, grainSeed: $0.grainSeed) }
        return try FilmBatch(photos: updated, referenceId: referenceId, mode: mode)
    }
}

// MARK: - Photo Recipe

public enum PhotoRecipe: Equatable, Hashable, Codable, Sendable {
    case original
    case lut(LutRecipe)
    case film(parameters: FilmParameters, grainSeed: Int64)
}

public enum PhotoProcessingStage: String, CaseIterable, Codable, Sendable {
    case preparing = "PREPARING"
    case rendering = "RENDERING"
    case framing = "FRAMING"
    case encoding = "ENCODING"
    case publishing = "PUBLISHING"

    public var title: String {
        switch self {
        case .preparing: return "准备照片"
        case .rendering: return "胶片 / LUT 渲染"
        case .framing: return "画框合成"
        case .encoding: return "编码输出"
        case .publishing: return "保存到相册"
        }
    }
}

// MARK: - Frame Layout & Export Options

public enum FramePreset: String, CaseIterable, Codable, Sendable {
    case none = "NONE"
    case paper = "PAPER"
    case black = "BLACK"
    case film = "FILM"
    case ticket = "TICKET"
    case instant = "INSTANT"
    case dusk = "DUSK"
    case mist = "MIST"
    case palette = "PALETTE"
    case museum = "MUSEUM"
    case slide = "SLIDE"

    public var title: String {
        switch self {
        case .none: return "无边框"
        case .paper: return "白色相纸"
        case .black: return "黑色画廊"
        case .film: return "胶片暗盒"
        case .ticket: return "记忆票根"
        case .instant: return "拍立得"
        case .dusk: return "暮色"
        case .mist: return "雾面"
        case .palette: return "取色相框"
        case .museum: return "典藏纸框"
        case .slide: return "幻灯片夹"
        }
    }
}

public enum FrameRatio: String, CaseIterable, Codable, Sendable {
    case original = "ORIGINAL"
    case square = "SQUARE"
    case threeTwo = "THREE_TWO"
    case fourThree = "FOUR_THREE"
    case sevenSix = "SEVEN_SIX"
    case fiveFour = "FIVE_FOUR"
    case fifteenNine = "FIFTEEN_NINE"
    case twoOne = "TWO_ONE"

    public var title: String {
        switch self {
        case .original: return "原比例"
        case .square: return "1:1"
        case .threeTwo: return "3:2"
        case .fourThree: return "4:3"
        case .sevenSix: return "7:6"
        case .fiveFour: return "5:4"
        case .fifteenNine: return "15:9"
        case .twoOne: return "2:1"
        }
    }

    public var landscape: Float? {
        switch self {
        case .original: return nil
        case .square: return 1.0
        case .threeTwo: return 1.5
        case .fourThree: return 4.0 / 3.0
        case .sevenSix: return 7.0 / 6.0
        case .fiveFour: return 1.25
        case .fifteenNine: return 15.0 / 9.0
        case .twoOne: return 2.0
        }
    }
}

public enum FrameFont: String, CaseIterable, Codable, Sendable {
    case sans = "SANS"
    case typewriter = "TYPEWRITER"
    case script = "SCRIPT"
    case serif = "SERIF"
    case display = "DISPLAY"
    case spaced = "SPACED"
    case greatVibes = "GREAT_VIBES"

    public var title: String {
        switch self {
        case .sans: return "清晰无衬线"
        case .typewriter: return "Cutive Mono"
        case .script: return "Dancing Script"
        case .serif: return "Playfair"
        case .display: return "Abril"
        case .spaced: return "Julius"
        case .greatVibes: return "Great Vibes"
        }
    }

    public var bundledFileName: String {
        switch self {
        case .sans: return "film_sans_regular.otf"
        case .typewriter: return "print_typewriter.ttf"
        case .script: return "print_script.ttf"
        case .serif: return "print_serif.ttf"
        case .display: return "print_display.ttf"
        case .spaced: return "print_spaced.ttf"
        case .greatVibes: return "print_great_vibes.ttf"
        }
    }
}

public enum FrameMood: String, CaseIterable, Codable, Sendable {
    case vibrant = "VIBRANT"
    case lightVibrant = "LIGHT_VIBRANT"
    case darkVibrant = "DARK_VIBRANT"
    case muted = "MUTED"
    case lightMuted = "LIGHT_MUTED"
    case darkMuted = "DARK_MUTED"

    public var title: String {
        switch self {
        case .vibrant: return "炽烈"
        case .lightVibrant: return "清曜"
        case .darkVibrant: return "棠梨"
        case .muted: return "尘霭"
        case .lightMuted: return "霜月"
        case .darkMuted: return "侘寂"
        }
    }
}

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"

    public var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG · 透明底"
        }
    }
}

public struct JpegOutput: Equatable, Hashable, Codable, Sendable {
    public var dimensionPercent: Int
    public var compressionQuality: Int
    public var format: ExportFormat

    public init(
        dimensionPercent: Int = 100,
        compressionQuality: Int = 95,
        format: ExportFormat = .jpeg
    ) throws {
        try requireArgument((1...100).contains(dimensionPercent), "输出尺寸比例需在 1...100 之间")
        try requireArgument((1...100).contains(compressionQuality), "JPEG 压缩质量需在 1...100 之间")
        self.dimensionPercent = dimensionPercent
        self.compressionQuality = compressionQuality
        self.format = format
    }

    public static let `default` = try! JpegOutput()

    public func contentSize(for input: PixelSize) -> PixelSize {
        let w = max(1, Int((Double(input.width) * Double(dimensionPercent) / 100.0).rounded()))
        let h = max(1, Int((Double(input.height) * Double(dimensionPercent) / 100.0).rounded()))
        return PixelSize(uncheckedWidth: w, height: h)
    }
}

public struct FrameOptions: Equatable, Hashable, Codable, Sendable {
    public var preset: FramePreset
    public var borderFraction: Float
    public var signature: String
    public var showPhotoMetadata: Bool
    public var fixedColorArgb: Int32?
    public var ratio: FrameRatio
    public var title: String?
    public var subtitle: String?
    public var footer: String?
    public var titleFont: FrameFont?
    public var subtitleFont: FrameFont?
    public var footerFont: FrameFont?
    public var signatureFont: FrameFont
    public var filmBrand: String
    public var filmName: String
    public var filmNotes: String
    public var roll120: Bool
    public var mood: FrameMood
    public var filmBlackWhite: Bool?
    public var portrait: Bool?
    public var imageKey: String?
    public var titleFontKey: String?
    public var subtitleFontKey: String?
    public var footerFontKey: String?
    public var signatureFontKey: String?
    public var showCamera: Bool
    public var showLens: Bool
    public var showFocalLength: Bool
    public var showAperture: Bool
    public var showShutter: Bool
    public var showIso: Bool
    public var showCapturedAt: Bool

    private static let pngKeyPattern = try! NSRegularExpression(pattern: "^[a-f0-9]{64}\\.png$")
    private static let fontKeyPattern = try! NSRegularExpression(pattern: "^[a-f0-9]{64}\\.font$")

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    public init(
        preset: FramePreset = .none,
        borderFraction: Float = 0.045,
        signature: String = "",
        showPhotoMetadata: Bool = true,
        fixedColorArgb: Int32? = nil,
        ratio: FrameRatio = .original,
        title: String? = nil,
        subtitle: String? = nil,
        footer: String? = nil,
        titleFont: FrameFont? = nil,
        subtitleFont: FrameFont? = nil,
        footerFont: FrameFont? = nil,
        signatureFont: FrameFont = .script,
        filmBrand: String = "",
        filmName: String = "",
        filmNotes: String = "NOTES",
        roll120: Bool = false,
        mood: FrameMood = .vibrant,
        filmBlackWhite: Bool? = nil,
        portrait: Bool? = nil,
        imageKey: String? = nil,
        titleFontKey: String? = nil,
        subtitleFontKey: String? = nil,
        footerFontKey: String? = nil,
        signatureFontKey: String? = nil,
        showCamera: Bool = true,
        showLens: Bool = true,
        showFocalLength: Bool = true,
        showAperture: Bool = true,
        showShutter: Bool = true,
        showIso: Bool = true,
        showCapturedAt: Bool = false
    ) throws {
        try requireArgument(borderFraction.isFinite && (0.02...0.12).contains(borderFraction), "画框边距需在 2%...12% 之间")
        try requireArgument([signature, title, subtitle, footer].allSatisfy { ($0?.count ?? 0) <= 240 }, "画框文字不能超过 240 字")
        try requireArgument(filmBrand.count <= 60 && filmName.count <= 80 && filmNotes.count <= 60, "暗盒标签过长")
        if let imageKey {
            try requireArgument(Self.matches(Self.pngKeyPattern, imageKey), "装饰图键名无效")
        }
        for key in [titleFontKey, subtitleFontKey, footerFontKey, signatureFontKey].compactMap({ $0 }) {
            try requireArgument(Self.matches(Self.fontKeyPattern, key), "自定义字体键名无效")
        }
        self.preset = preset
        self.borderFraction = borderFraction
        self.signature = signature
        self.showPhotoMetadata = showPhotoMetadata
        self.fixedColorArgb = fixedColorArgb
        self.ratio = ratio
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.titleFont = titleFont
        self.subtitleFont = subtitleFont
        self.footerFont = footerFont
        self.signatureFont = signatureFont
        self.filmBrand = filmBrand
        self.filmName = filmName
        self.filmNotes = filmNotes
        self.roll120 = roll120
        self.mood = mood
        self.filmBlackWhite = filmBlackWhite
        self.portrait = portrait
        self.imageKey = imageKey
        self.titleFontKey = titleFontKey
        self.subtitleFontKey = subtitleFontKey
        self.footerFontKey = footerFontKey
        self.signatureFontKey = signatureFontKey
        self.showCamera = showCamera
        self.showLens = showLens
        self.showFocalLength = showFocalLength
        self.showAperture = showAperture
        self.showShutter = showShutter
        self.showIso = showIso
        self.showCapturedAt = showCapturedAt
    }

    public static let `default` = try! FrameOptions()
}

public struct BatchExportOptions: Equatable, Hashable, Codable, Sendable {
    public var jpeg: JpegOutput
    public var frame: FrameOptions

    public init(jpeg: JpegOutput = .default, frame: FrameOptions = .default) {
        self.jpeg = jpeg
        self.frame = frame
    }
}

public enum InputOrigin: Equatable, Hashable, Codable, Sendable {
    case jpeg
    case rawEmbeddedJpeg(dimensions: PixelSize)
}

public struct FrameLayout: Equatable, Hashable, Codable, Sendable {
    public let canvas: PixelSize
    public let photo: FloatBox
    public let caption: FloatBox
    public let cartridge: FloatBox?

    public init(canvas: PixelSize, photo: FloatBox, caption: FloatBox, cartridge: FloatBox?) {
        self.canvas = canvas
        self.photo = photo
        self.caption = caption
        self.cartridge = cartridge
    }
}

public enum FrameLayouts {
    public static func plan(content: PixelSize, frame: FrameOptions, stockArtwork: Bool = false) -> FrameLayout {
        let pw = Float(content.width)
        let ph = Float(content.height)
        if frame.preset == .none {
            return FrameLayout(
                canvas: content,
                photo: FloatBox(left: 0, top: 0, right: pw, bottom: ph),
                caption: FloatBox(left: 0, top: ph, right: pw, bottom: ph),
                cartridge: nil
            )
        }
        let short = min(pw, ph)
        let clampedBorder = min(max(frame.borderFraction, 0.02), 0.12)
        let minPresetPad: Float = {
            switch frame.preset {
            case .museum: return 0.07
            case .slide: return 0.12
            default: return 0
            }
        }()
        let pad = short * max(clampedBorder, minPresetPad)
        let film = frame.preset == .film
        let roll120 = frame.roll120 && !stockArtwork
        let header: Float = {
            switch frame.preset {
            case .ticket: return short * 0.23
            case .film: return ph * 0.44
            case .museum: return short * 0.105
            case .slide: return short * 0.13
            default: return pad
            }
        }()
        let textVisible = frame.showPhotoMetadata || !frame.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let footerFactor: Float = {
            switch frame.preset {
            case .ticket: return 0.4
            case .instant: return 0.23
            case .film: return ph / short * 0.26
            case .palette: return 0.25
            case .museum: return textVisible ? 0.24 : 0.105
            case .slide: return textVisible ? 0.21 : 0.13
            default: return textVisible ? 0.17 : clampedBorder
            }
        }()
        let footer = short * footerFactor
        let sidebar: Float = film ? ph * (roll120 ? 0.48 : 0.95) : 0
        let tail: Float = film ? pw * 0.6 : 0
        var width = pw + pad * 2 + sidebar + tail
        var height = ph + header + footer
        if let landscape = frame.ratio.landscape {
            let isPortrait = frame.portrait ?? (pw < ph)
            let ratio = isPortrait ? (1.0 / landscape) : landscape
            if width / height < ratio {
                width = height * ratio
            } else {
                height = width / ratio
            }
        }
        let canvas = PixelSize(
            uncheckedWidth: Int(ceil(Double(width))),
            height: Int(ceil(Double(height)))
        )
        let x = round(pad + sidebar + (Float(canvas.width) - pad * 2 - sidebar - tail - pw) / 2.0)
        let y = round(header + (Float(canvas.height) - header - footer - ph) / 2.0)
        let photo = FloatBox(left: x, top: y, right: x + pw, bottom: y + ph)
        let unit = Float(min(canvas.width, canvas.height)) / 1000.0
        let caption: FloatBox = {
            if film {
                return FloatBox(
                    left: photo.right + unit * 18,
                    top: photo.top + ph * 0.46,
                    right: photo.right + tail - unit * 18,
                    bottom: photo.bottom - unit * 12
                )
            } else {
                let ticketExtra: Float = frame.preset == .ticket
                    ? Float(min(canvas.width, canvas.height)) * 0.025 + Float(canvas.width) * 0.014
                    : 0
                return FloatBox(
                    left: pad + unit * 12,
                    top: photo.bottom + unit * 10,
                    right: Float(canvas.width) - pad - unit * 12,
                    bottom: Float(canvas.height) - pad * 0.35 - unit * 10 - ticketExtra
                )
            }
        }()
        let cartridge: FloatBox? = {
            guard film else { return nil }
            let scale = ph * 1.28 / 338.0
            let top = y - ph * 0.14 - 71.0 * scale
            let bottom = top + 430.0 * scale
            let cw: Float = roll120 ? 120.0 : 240.0
            let bodyRight: Float = roll120 ? 112.0 : 235.0
            let right = x + (cw - bodyRight) * scale
            return FloatBox(left: right - cw * scale, top: top, right: right, bottom: bottom)
        }()
        return FrameLayout(canvas: canvas, photo: photo, caption: caption, cartridge: cartridge)
    }

    public static func preview(layout: FrameLayout, longEdge: Int) throws -> FrameLayout {
        try requireArgument(longEdge > 0, "预览长边必须大于 0")
        let scale = min(1.0, Double(longEdge) / Double(max(layout.canvas.width, layout.canvas.height)))
        let canvas = PixelSize(
            uncheckedWidth: max(1, Int(Double(layout.canvas.width) * scale)),
            height: max(1, Int(Double(layout.canvas.height) * scale))
        )
        let sx = Float(canvas.width) / Float(layout.canvas.width)
        let sy = Float(canvas.height) / Float(layout.canvas.height)
        func scaled(_ box: FloatBox) -> FloatBox {
            FloatBox(left: box.left * sx, top: box.top * sy, right: box.right * sx, bottom: box.bottom * sy)
        }
        return FrameLayout(
            canvas: canvas,
            photo: scaled(layout.photo),
            caption: scaled(layout.caption),
            cartridge: layout.cartridge.map(scaled)
        )
    }
}
