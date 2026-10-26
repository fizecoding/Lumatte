import Foundation
import CoreGraphics
import CoreImage
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
public final class FrameRenderer {
    public static let shared = FrameRenderer()
    private var registeredFonts = Set<String>()

    public init() {}

    private func cgColor(_ argb: Int32, alpha: CGFloat? = nil) -> CGColor {
        let value = UInt32(bitPattern: argb)
        let a = alpha ?? CGFloat((value >> 24) & 0xFF) / 255.0
        return CGColor(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: a
        )
    }

    private func contrasting(_ argb: Int32) -> Int32 {
        let v = UInt32(bitPattern: argb)
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.35 ? Int32(bitPattern: 0xFF141615) : Int32(bitPattern: 0xFFFAF8EE)
    }

    private func font(for face: FrameFont, size: CGFloat, customKey: String? = nil) -> PlatformFont {
        if let customKey {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Lumatte/frame-assets")
            let url = root.appendingPathComponent(customKey)
            if let data = try? Data(contentsOf: url),
               let provider = CGDataProvider(data: data as CFData),
               let cg = CGFont(provider) {
                return CTFontCreateWithGraphicsFont(cg, size, nil, nil) as PlatformFont
            }
        }
        if !registeredFonts.contains(face.rawValue) {
            if let url = try? AssetLocator.url(forAssetPath: "frames/fonts/\(face.bundledFileName)") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
            registeredFonts.insert(face.rawValue)
        }
        if let url = try? AssetLocator.url(forAssetPath: "frames/fonts/\(face.bundledFileName)"),
           let data = try? Data(contentsOf: url),
           let provider = CGDataProvider(data: data as CFData),
           let cg = CGFont(provider) {
            return CTFontCreateWithGraphicsFont(cg, size, nil, nil) as PlatformFont
        }
        return PlatformFont.systemFont(ofSize: size)
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        size requestedSize: CGFloat,
        face: FrameFont,
        color: Int32,
        context: CGContext,
        align: FrameTextAlignment = .center,
        spacing: CGFloat = 0,
        customKey: String? = nil
    ) {
        let lines = String(text.prefix(240)).components(separatedBy: "\n").prefix(3)
        guard !lines.isEmpty, rect.width > 0, rect.height > 0, requestedSize > 0 else { return }
        var size = min(requestedSize, rect.height / (CGFloat(lines.count) * 1.35))
        func makeAttributes(_ fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
            return [
                .font: font(for: face, size: fontSize, customKey: customKey),
                .foregroundColor: PlatformColor(cgColor: cgColor(color)),
                .kern: spacing
            ]
        }
        func width(_ fontSize: CGFloat) -> CGFloat {
            let attrs = makeAttributes(fontSize)
            return lines.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 0
        }
        let widest = width(size)
        if widest > rect.width && widest > 0 {
            size *= rect.width / widest
        }
        let attrs = makeAttributes(size)
        let lineHeight = size * 1.35
        var y = rect.midY - CGFloat(lines.count) * lineHeight / 2
        for line in lines {
            let lineWidth = (line as NSString).size(withAttributes: attrs).width
            let lineX = align == .center ? rect.midX - lineWidth / 2 : rect.minX
            (line as NSString).draw(in: CGRect(x: lineX, y: y, width: lineWidth, height: lineHeight), withAttributes: attrs)
            y += lineHeight
        }
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext, alpha: CGFloat = 1) {
        context.saveGState()
        context.setAlpha(alpha)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private func paletteAccent(photo: CGImage, mood: FrameMood) -> Int32 {
        guard let small = try? ImagePipeline.resized(photo, to: PixelSize(uncheckedWidth: 32, height: 32)),
              let rgba = try? RGBAImage(cgImage: small) else {
            return Int32(bitPattern: 0xFF636760)
        }
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: rgba.bytes.count, by: 4) {
            let r = Int(rgba.bytes[i]), g = Int(rgba.bytes[i + 1]), b = Int(rgba.bytes[i + 2])
            let key = ((r / 32) << 6) | ((g / 32) << 3) | (b / 32)
            let old = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }), best.count > 0 else {
            return Int32(bitPattern: 0xFF636760)
        }
        var r = best.r / best.count, g = best.g / best.count, b = best.b / best.count
        switch mood {
        case .lightVibrant, .lightMuted:
            r = min(255, r + 45); g = min(255, g + 45); b = min(255, b + 45)
        case .darkVibrant, .darkMuted:
            r = max(0, r - 35); g = max(0, g - 35); b = max(0, b - 35)
        default:
            break
        }
        if mood == .muted || mood == .lightMuted || mood == .darkMuted {
            let mean = (r + g + b) / 3
            r = (r + mean) / 2; g = (g + mean) / 2; b = (b + mean) / 2
        }
        let argb = 0xFF00_0000 | UInt32(r << 16) | UInt32(g << 8) | UInt32(b)
        return Int32(bitPattern: argb)
    }

    public func render(
        photo: CGImage,
        source: SourceImage,
        options: FrameOptions,
        layout: FrameLayout,
        stock: FilmPreset? = nil,
        frameNumber: Int = 1,
        transparentBackground: Bool = false
    ) throws -> CGImage {
        try requireArgument(frameNumber > 0, "片号必须大于 0")
        if options.preset == .none { return photo }
        let width = layout.canvas.width
        let height = layout.canvas.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw LumatteError.illegalState("无法创建画框画布")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        #elseif canImport(AppKit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        #endif
        let transparent = transparentBackground && (options.preset == .film || options.preset == .ticket)
        let accent = options.fixedColorArgb ?? paletteAccent(photo: photo, mood: options.mood)
        let identity = FrameIdentity(source: source, options: options, stock: stock, color: accent)
        let background: Int32
        switch options.preset {
        case .black, .film: background = Int32(bitPattern: 0xFF000000)
        case .dusk: background = Int32(bitPattern: 0xFF3C3E40)
        case .mist: background = Int32(bitPattern: 0xFFCCCBC6)
        case .palette: background = accent
        default: background = Int32(bitPattern: 0xFFFAF8F0)
        }
        if !transparent {
            context.setFillColor(cgColor(background))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let ink = contrasting(background)
        let unit = CGFloat(min(width, height)) / 1000.0
        let imageRect = layout.photo.cgRect

        if options.preset == .museum || options.preset == .slide {
            if let paperURL = try? AssetLocator.url(forAssetPath: "frames/art/print_cotton_paper.png"),
               let data = try? Data(contentsOf: paperURL),
               let paper = try? ImagePipeline.decodeJPEG(data) {
                context.saveGState()
                context.setAlpha(0.70)
                context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
                let tile = paper.width > 0 ? CGFloat(paper.width) * unit * 0.75 / 8 : 200
                let tileH = paper.height > 0 ? CGFloat(paper.height) * unit * 0.75 / 8 : 200
                var y: CGFloat = 0
                while y < CGFloat(height) {
                    var x: CGFloat = 0
                    while x < CGFloat(width) {
                        drawImage(paper, in: CGRect(x: x, y: y, width: max(20, tile), height: max(20, tileH)), context: context)
                        x += max(20, tile)
                    }
                    y += max(20, tileH)
                }
                context.restoreGState()
            }
            let aperture = imageRect.insetBy(dx: -unit * 3, dy: -unit * 3)
            context.setFillColor(cgColor(Int32(bitPattern: 0xFFC5BFAF)))
            context.fill(aperture)
            context.setStrokeColor(cgColor(Int32(bitPattern: 0xFFFFFFFF)))
            context.setLineWidth(unit * 1.4)
            context.stroke(CGRect(x: aperture.minX, y: aperture.minY, width: aperture.width, height: aperture.height))
            if options.preset == .slide {
                context.setStrokeColor(cgColor(Int32(bitPattern: 0xFFB9B4A8)))
                context.setLineWidth(unit * 1.8)
                let path = CGPath(roundedRect: CGRect(x: unit * 9, y: unit * 9, width: CGFloat(width) - unit * 18, height: CGFloat(height) - unit * 18), cornerWidth: unit * 10, cornerHeight: unit * 10, transform: nil)
                context.addPath(path)
                context.strokePath()
                context.setFillColor(cgColor(Int32(bitPattern: 0xFFA59B88)))
                for x in [unit * 23, CGFloat(width) - unit * 23] {
                    context.fillEllipse(in: CGRect(x: x - unit * 2, y: unit * 21, width: unit * 4, height: unit * 4))
                }
            }
        }

        if options.preset == .dusk || options.preset == .mist {
            if let blurred = blurredBackground(photo: photo, width: width, height: height) {
                drawImage(blurred, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
            }
            let overlay = options.preset == .dusk ? Int32(bitPattern: 0xA3181B1D) : Int32(bitPattern: 0x99F1F0EB)
            context.setFillColor(cgColor(overlay))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if options.preset == .mist {
                context.setFillColor(cgColor(Int32(bitPattern: 0xFFFFFFFF)))
                let rim = max(1.5, unit * 1.5)
                context.fill(imageRect.insetBy(dx: -rim, dy: -rim))
            }
        }

        if options.preset == .ticket {
            drawTicket(context: context, layout: layout, transparent: transparent)
        }
        if options.preset == .instant {
            context.setStrokeColor(cgColor(Int32(bitPattern: 0xFFCFC9BB)))
            context.setLineWidth(unit)
            context.stroke(CGRect(x: unit * 7, y: unit * 7, width: CGFloat(width) - unit * 14, height: CGFloat(height) - unit * 14))
            context.setStrokeColor(cgColor(Int32(bitPattern: 0x16A99F83)))
            for i in 0...42 {
                let y = CGFloat((i * 71 % 997)) / 1000.0 * CGFloat(height)
                context.move(to: CGPoint(x: unit * 5, y: y))
                context.addLine(to: CGPoint(x: CGFloat(width) - unit * 5, y: y + unit * 1.3))
            }
            context.strokePath()
        }

        if options.preset == .film {
            drawFilmStrip(context: context, layout: layout, identity: identity, number: frameNumber, transparent: transparent)
        }
        drawImage(photo, in: imageRect, context: context)
        if options.preset == .film, let cartridge = layout.cartridge {
            drawCartridge(context: context, rect: cartridge.cgRect, identity: identity)
        }
        drawCaption(context: context, options: options, layout: layout, identity: identity, ink: ink, unit: unit)
        guard let output = context.makeImage() else {
            throw LumatteError.illegalState("画框合成失败")
        }
        return output
    }

    private func blurredBackground(photo: CGImage, width: Int, height: Int) -> CGImage? {
        let ci = CIImage(cgImage: photo)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(12.0, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: ci.extent) else { return nil }
        let scale = max(CGFloat(width) / CGFloat(photo.width), CGFloat(height) / CGFloat(photo.height))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: nil)
        return context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func drawTicket(context: CGContext, layout: FrameLayout, transparent: Bool) {
        let width = CGFloat(layout.canvas.width), height = CGFloat(layout.canvas.height)
        let edge = min(width, height) * 0.025
        let radius = width * 0.014
        let paper = CGRect(x: edge, y: edge, width: width - edge * 2, height: height - edge * 2)
        context.setFillColor(cgColor(Int32(bitPattern: transparent ? 0xFFFAF8F0 : 0xFF777A79)))
        if !transparent {
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.setFillColor(cgColor(Int32(bitPattern: 0xFFFAF8F0)))
        context.fill(paper)
        context.saveGState()
        if transparent { context.setBlendMode(.clear) } else { context.setFillColor(cgColor(Int32(bitPattern: 0xFF777A79))) }
        var x = edge + radius
        while x < width - edge {
            for y in [edge, height - edge] {
                context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
            x += radius * 2.65
        }
        let holeY = layout.photo.cgRect.minY * 0.36
        let holeR = radius * 0.8
        context.fillEllipse(in: CGRect(x: width / 2 - holeR, y: holeY - holeR, width: holeR * 2, height: holeR * 2))
        context.restoreGState()
    }

    private func drawFilmStrip(context: CGContext, layout: FrameLayout, identity: FrameIdentity, number: Int, transparent: Bool) {
        let imageBox = layout.photo.cgRect
        let overlap = CGFloat(min(layout.canvas.width, layout.canvas.height)) / 1000.0 * 6
        let rail = imageBox.height * 0.14
        let stripRect = CGRect(
            x: imageBox.minX - overlap,
            y: imageBox.minY - rail,
            width: imageBox.width + imageBox.width * 0.6 + overlap,
            height: imageBox.height + rail * 2
        )
        context.setFillColor(cgColor(Int32(bitPattern: 0xFF060606)))
        context.fill(stripRect)
        let pitch = imageBox.width / 8
        if (!identity.roll120 || identity.stockId != nil) && pitch > 0 {
            if transparent { context.setBlendMode(.clear) } else { context.setFillColor(cgColor(Int32(bitPattern: 0xFFFFFFFF))) }
            var x = stripRect.minX + pitch * 0.18
            while x + pitch * 0.52 <= stripRect.maxX {
                for y in [stripRect.minY + rail * 0.34, stripRect.maxY - rail * 0.69] {
                    let hole = CGRect(x: x, y: y, width: pitch * 0.52, height: rail * 0.42)
                    let path = CGPath(roundedRect: hole, cornerWidth: pitch * 0.12, cornerHeight: pitch * 0.12, transform: nil)
                    context.addPath(path)
                    context.fillPath()
                }
                x += pitch
            }
            context.setBlendMode(.normal)
        }
        let ink = identity.blackWhite ? Int32(bitPattern: 0xFFEBEADF) : Int32(bitPattern: 0xFFED9039)
        drawText("\(number)", in: CGRect(x: stripRect.minX + imageBox.width * 0.003, y: stripRect.minY, width: imageBox.width * 0.18, height: rail * 0.28), size: rail * 0.26, face: .typewriter, color: ink, context: context, align: .left)
        drawText(identity.film.uppercased(), in: CGRect(x: stripRect.minX + imageBox.width * 0.22, y: stripRect.minY, width: imageBox.width * 0.77, height: rail * 0.28), size: rail * 0.26, face: .typewriter, color: ink, context: context, align: .left)
        drawText("\(number)", in: CGRect(x: stripRect.minX + imageBox.width * 0.34, y: stripRect.maxY - rail * 0.27, width: imageBox.width * 0.11, height: rail * 0.27), size: rail * 0.24, face: .typewriter, color: ink, context: context)
        drawText("\(number)A", in: CGRect(x: stripRect.minX + imageBox.width * 0.82, y: stripRect.maxY - rail * 0.27, width: imageBox.width * 0.18, height: rail * 0.27), size: rail * 0.24, face: .typewriter, color: ink, context: context)
    }

    private func drawCartridge(context: CGContext, rect: CGRect, identity: FrameIdentity) {
        if let stockId = identity.stockId,
           let url = AssetLocator.cartridgeURL(forStockId: stockId),
           let data = try? Data(contentsOf: url),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            drawImage(image, in: CGRect(x: rect.maxX - w, y: rect.midY - h / 2, width: w, height: h), context: context)
            return
        }
        context.setFillColor(cgColor(Int32(bitPattern: 0xFF272A27)))
        context.fill(rect)
        context.setFillColor(cgColor(identity.color))
        context.fill(CGRect(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.2, width: rect.width * 0.55, height: rect.height * 0.65))
        drawText(identity.brand.uppercased(), in: CGRect(x: rect.minX, y: rect.minY + rect.height * 0.08, width: rect.width, height: rect.height * 0.12), size: rect.width * 0.08, face: .sans, color: Int32(bitPattern: 0xFFFFFFFF), context: context)
        drawText(identity.film, in: CGRect(x: rect.minX + rect.width * 0.08, y: rect.midY - rect.height * 0.08, width: rect.width * 0.84, height: rect.height * 0.16), size: rect.width * 0.12, face: .spaced, color: contrasting(identity.color), context: context)
    }

    private func drawCaption(context: CGContext, options: FrameOptions, layout: FrameLayout, identity: FrameIdentity, ink: Int32, unit: CGFloat) {
        guard options.showPhotoMetadata || !options.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || options.preset == .palette else { return }
        let ticket = options.preset == .ticket
        let face = options.titleFont ?? {
            switch options.preset {
            case .film, .slide: return .typewriter
            case .ticket: return .greatVibes
            case .museum: return .serif
            default: return .spaced
            }
        }()
        let textUnit = options.preset == .film ? CGFloat(layout.canvas.width) / 1250.0 : unit
        struct Line {
            let text: String
            let size: CGFloat
            let face: FrameFont
            let spacing: CGFloat
            let custom: String?
        }
        var lines: [Line] = []
        if options.showPhotoMetadata {
            let title = options.title ?? (ticket ? "Where the light lingers" : identity.camera)
            lines.append(Line(text: title, size: textUnit * (ticket ? 35 : 24), face: face, spacing: face == .spaced ? textUnit * 1.2 : 0, custom: options.titleFontKey))
            let subtitleFont = options.subtitleFont ?? (ticket ? FrameFont.spaced : face)
            let defaultSubtitle = ticket
                ? [identity.camera, "\(identity.brand) \(identity.film)"].filter { !$0.isEmpty }.joined(separator: "  /  ")
                : "\(identity.brand) \(identity.film)"
            lines.append(Line(text: options.subtitle ?? defaultSubtitle, size: textUnit * 18, face: subtitleFont, spacing: textUnit * 0.6, custom: options.subtitleFontKey))
            let footer = options.footer ?? (ticket ? "A moment, kept in light." : identity.exposureMetadata)
            lines.append(Line(text: footer, size: textUnit * 14, face: options.footerFont ?? (ticket ? .typewriter : .sans), spacing: 0, custom: options.footerFontKey))
        }
        if !options.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(Line(text: options.signature, size: textUnit * 20, face: options.signatureFont, spacing: 0, custom: options.signatureFontKey))
        }
        let visible = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !visible.isEmpty else { return }
        let area = layout.caption.cgRect
        let gap = textUnit * 8
        var naturalHeight: CGFloat = 0
        for line in visible {
            let lineCount = min(3, line.text.components(separatedBy: "\n").count)
            naturalHeight += line.size * 1.5 * CGFloat(lineCount)
        }
        naturalHeight += gap * CGFloat(max(0, visible.count - 1))
        let scale = naturalHeight > 0 ? min(1, max(0, area.height) / naturalHeight) : 1
        var y = area.midY - naturalHeight * scale / 2
        for line in visible {
            let height = line.size * 1.5 * scale
            drawText(line.text, in: CGRect(x: area.minX, y: y, width: area.width, height: height), size: line.size * scale, face: line.face, color: ink, context: context, spacing: line.spacing * scale, customKey: line.custom)
            y += height + gap * scale
        }
    }
}

private enum FrameTextAlignment {
    case left
    case center
}

private struct FrameIdentity {
    let camera: String
    let brand: String
    let film: String
    let stockId: String?
    let blackWhite: Bool
    let notes: String
    let color: Int32
    let roll120: Bool
    let exposureMetadata: String

    init(source: SourceImage, options: FrameOptions, stock: FilmPreset?, color: Int32) {
        self.camera = options.showCamera ? source.metadata.frameCameraName : ""
        self.brand = options.filmBrand.isEmpty ? (stock?.name.components(separatedBy: " ").first ?? "LUMIX") : options.filmBrand
        let stockFilm = stock?.name.components(separatedBy: " ").dropFirst().joined(separator: " ") ?? "FILM MIRROR"
        self.film = options.filmName.isEmpty ? stockFilm : options.filmName
        self.stockId = stock?.id
        self.blackWhite = options.filmBlackWhite ?? (stock?.category == .monochrome)
        self.notes = options.filmNotes
        self.color = color
        self.roll120 = options.roll120
        self.exposureMetadata = source.metadata.frameDetail(options: options)
    }
}

private extension FloatBox {
    var cgRect: CGRect {
        CGRect(x: CGFloat(left), y: CGFloat(top), width: CGFloat(width), height: CGFloat(height))
    }
}
