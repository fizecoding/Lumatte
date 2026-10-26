import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import CoreText
#if canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#endif

public struct RGBAImage: @unchecked Sendable {
    public private(set) var bytes: [UInt8]
    public let width: Int
    public let height: Int
    public let stride: Int

    public init(width: Int, height: Int, bytes: [UInt8]? = nil) throws {
        try requireArgument(width > 0 && height > 0, "图像尺寸无效")
        self.width = width
        self.height = height
        self.stride = width * 4
        let required = stride * height
        if let bytes {
            try requireArgument(bytes.count >= required, "像素数据长度不足")
            self.bytes = bytes
        } else {
            self.bytes = [UInt8](repeating: 255, count: required)
        }
    }

    public init(cgImage: CGImage) throws {
        let width = cgImage.width
        let height = cgImage.height
        try self.init(width: width, height: height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: stride,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw LumatteError.illegalState("无法创建 RGBA 图像缓冲区")
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    public func makeCGImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LumatteError.illegalState("无法读取渲染后的图像")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw LumatteError.illegalState("无法生成渲染后的图像")
        }
        return image
    }

    public mutating func applyLUT(_ plan: LutRenderPlan, sourceSize: PixelSize) throws {
        try bytes.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            try NativeLutRenderer.renderRGBA8888(
                pixels: base,
                width: width,
                height: height,
                stride: stride,
                plan: plan,
                sourceSize: sourceSize
            )
        }
    }

    public mutating func applyFilm(model: MobileFilmModel, plan: FilmRenderPlan, sourceSize: PixelSize) throws {
        try bytes.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            try NativeMobileFilmRenderer.renderRGBA8888(
                pixels: base,
                width: width,
                height: height,
                stride: stride,
                model: model,
                plan: plan,
                effectiveInput: sourceSize
            )
        }
    }
}

public enum ImagePipeline {
    public static func decodeJPEG(_ data: Data, orientation: Int = 1) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LumatteError.illegalState("JPEG 数据无法解码")
        }
        return try applyingOrientation(image, orientation: orientation)
    }

    public static func applyingOrientation(_ image: CGImage, orientation: Int) throws -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        let sourceWidth = image.width
        let sourceHeight = image.height
        let rotated = [5, 6, 7, 8].contains(orientation)
        let width = rotated ? sourceHeight : sourceWidth
        let height = rotated ? sourceWidth : sourceHeight
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
            throw LumatteError.illegalState("无法校正照片方向")
        }
        var transform = CGAffineTransform.identity
        switch orientation {
        case 2:
            transform = CGAffineTransform(translationX: CGFloat(sourceWidth), y: 0).scaledBy(x: -1, y: 1)
        case 3:
            transform = CGAffineTransform(translationX: CGFloat(sourceWidth), y: CGFloat(sourceHeight)).rotated(by: .pi)
        case 4:
            transform = CGAffineTransform(translationX: 0, y: CGFloat(sourceHeight)).scaledBy(x: 1, y: -1)
        case 5:
            transform = CGAffineTransform(translationX: 0, y: CGFloat(sourceWidth))
                .rotated(by: -.pi / 2).scaledBy(x: -1, y: 1)
        case 6:
            transform = CGAffineTransform(translationX: CGFloat(sourceHeight), y: 0).rotated(by: .pi / 2)
        case 7:
            transform = CGAffineTransform(translationX: CGFloat(sourceHeight), y: CGFloat(sourceWidth))
                .rotated(by: .pi / 2).scaledBy(x: 1, y: -1)
        case 8:
            transform = CGAffineTransform(translationX: 0, y: CGFloat(sourceWidth)).rotated(by: -.pi / 2)
        default:
            break
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        guard let output = context.makeImage() else {
            throw LumatteError.illegalState("无法校正照片方向")
        }
        return output
    }

    public static func resized(_ image: CGImage, to size: PixelSize) throws -> CGImage {
        if image.width == size.width && image.height == size.height { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bytesPerRow: size.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw LumatteError.illegalState("无法调整照片尺寸")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let output = context.makeImage() else {
            throw LumatteError.illegalState("无法调整照片尺寸")
        }
        return output
    }

    public static func encoded(_ image: CGImage, format: ExportFormat, quality: Int, metadata: [CFString: Any]? = nil) throws -> Data {
        let output = NSMutableData()
        let type = format == .png ? "public.png" : "public.jpeg"
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
            throw LumatteError.illegalState("无法创建图像输出")
        }
        var properties: [CFString: Any] = metadata ?? [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = Float(quality) / 100.0
        }
        properties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LumatteError.illegalState("图像编码失败")
        }
        return output as Data
    }

    public static func exifProperties(from data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }
}

public final class PhotoProcessor: @unchecked Sendable {
    public let lutLibrary: LutLibrary
    public let filmCatalogue: FilmCatalogue
    public let filmModels: MobileFilmModelLibrary

    public init() {
        self.lutLibrary = LutLibrary()
        self.filmCatalogue = FilmCatalogue()
        self.filmModels = MobileFilmModelLibrary()
    }

    public func preview(
        source: SourceImage,
        recipe: PhotoRecipe,
        assets: [LutAsset],
        films: [FilmPreset],
        longEdge: Int = 960
    ) async throws -> CGImage {
        let data = try Data(contentsOf: source.jpegURL)
        let decoded = try ImagePipeline.decodeJPEG(data, orientation: source.orientation)
        let scale = min(1.0, Double(longEdge) / Double(max(source.size.width, source.size.height)))
        let size = PixelSize(
            uncheckedWidth: max(1, Int(Double(source.size.width) * scale)),
            height: max(1, Int(Double(source.size.height) * scale))
        )
        let resized = try ImagePipeline.resized(decoded, to: size)
        var rgba = try RGBAImage(cgImage: resized)
        switch recipe {
        case .original:
            break
        case .lut(let recipe):
            let plan = try lutLibrary.plan(recipe: recipe, assets: assets)
            try rgba.applyLUT(plan, sourceSize: source.size)
        case .film(let parameters, let seed):
            let plan = try filmCatalogue.plan(parameters: parameters, presets: films, grainSeed: seed)
            let model = try await filmModels.load(preset: plan.preset)
            try rgba.applyFilm(model: model, plan: plan, sourceSize: source.size)
        }
        return try rgba.makeCGImage()
    }

    public func previewExport(
        source: SourceImage,
        recipe: PhotoRecipe,
        assets: [LutAsset],
        films: [FilmPreset],
        options: BatchExportOptions,
        longEdge: Int = 960,
        frameNumber: Int = 1
    ) async throws -> CGImage {
        let data = try Data(contentsOf: source.jpegURL)
        let decoded = try ImagePipeline.decodeJPEG(data, orientation: source.orientation)
        let requestedContent = options.jpeg.contentSize(for: source.size)
        let stock: FilmPreset?
        if case .film(let parameters, let seed) = recipe {
            stock = try filmCatalogue.plan(parameters: parameters, presets: films, grainSeed: seed).preset
        } else {
            stock = nil
        }
        let fullLayout = FrameLayouts.plan(content: requestedContent, frame: options.frame, stockArtwork: stock != nil)
        let layout = try FrameLayouts.preview(layout: fullLayout, longEdge: longEdge)
        let photoSize = PixelSize(
            uncheckedWidth: max(1, Int(layout.photo.width.rounded())),
            height: max(1, Int(layout.photo.height.rounded()))
        )
        let resized = try ImagePipeline.resized(decoded, to: photoSize)
        var rgba = try RGBAImage(cgImage: resized)
        switch recipe {
        case .original:
            break
        case .lut(let recipe):
            try rgba.applyLUT(try lutLibrary.plan(recipe: recipe, assets: assets), sourceSize: source.size)
        case .film(let parameters, let seed):
            let plan = try filmCatalogue.plan(parameters: parameters, presets: films, grainSeed: seed)
            let model = try await filmModels.load(preset: plan.preset)
            try rgba.applyFilm(model: model, plan: plan, sourceSize: source.size)
        }
        let processed = try rgba.makeCGImage()
        guard options.frame.preset != .none else { return processed }
        return try await MainActor.run {
            try FrameRenderer.shared.render(
                photo: processed,
                source: source,
                options: options.frame,
                layout: layout,
                stock: stock,
                frameNumber: frameNumber,
                transparentBackground: options.jpeg.format == .png
            )
        }
    }

    public func export(
        source: SourceImage,
        recipe: PhotoRecipe,
        assets: [LutAsset],
        films: [FilmPreset],
        options: BatchExportOptions,
        frameNumber: Int = 1,
        onStage: (@Sendable (PhotoProcessingStage) -> Void)? = nil
    ) async throws -> Data {
        onStage?(.preparing)
        let originalData = try Data(contentsOf: source.jpegURL)
        let contentSize = options.jpeg.contentSize(for: source.size)
        let decoded = try ImagePipeline.decodeJPEG(originalData, orientation: source.orientation)
        let resized = try ImagePipeline.resized(decoded, to: contentSize)
        onStage?(.rendering)
        var rgba = try RGBAImage(cgImage: resized)
        var stock: FilmPreset? = nil
        switch recipe {
        case .original:
            break
        case .lut(let recipe):
            let plan = try lutLibrary.plan(recipe: recipe, assets: assets)
            try rgba.applyLUT(plan, sourceSize: source.size)
        case .film(let parameters, let seed):
            let plan = try filmCatalogue.plan(parameters: parameters, presets: films, grainSeed: seed)
            stock = plan.preset
            let model = try await filmModels.load(preset: plan.preset)
            try rgba.applyFilm(model: model, plan: plan, sourceSize: source.size)
        }
        let renderedImage = try rgba.makeCGImage()
        let processedStock = stock
        var finalImage = renderedImage
        if options.frame.preset != .none {
            onStage?(.framing)
            let layout = FrameLayouts.plan(content: contentSize, frame: options.frame, stockArtwork: processedStock != nil)
            finalImage = try await MainActor.run {
                try FrameRenderer.shared.render(
                    photo: renderedImage,
                    source: source,
                    options: options.frame,
                    layout: layout,
                    stock: processedStock,
                    frameNumber: frameNumber,
                    transparentBackground: options.jpeg.format == .png
                )
            }
        }
        onStage?(.encoding)
        let metadata = options.jpeg.format == .jpeg ? ImagePipeline.exifProperties(from: originalData) : nil
        return try ImagePipeline.encoded(
            finalImage,
            format: options.jpeg.format,
            quality: options.jpeg.compressionQuality,
            metadata: metadata
        )
    }
}
