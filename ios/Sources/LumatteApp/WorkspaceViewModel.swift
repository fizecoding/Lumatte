import Foundation
import LumatteCore
import Photos
import PhotosUI
import SwiftUI
import CoreGraphics

public struct ExportBatchResult: Equatable, Sendable {
    public let exported: Int
    public let failures: [String]

    public init(exported: Int, failures: [String]) {
        self.exported = exported
        self.failures = failures
    }
}

@MainActor
public final class WorkspaceViewModel: ObservableObject {
    @Published public var photos: [SourceImage] = []
    @Published public var selectedId: PhotoId?
    @Published public var treatment: PhotoTreatment = .film
    @Published public var luts: [LutAsset] = []
    @Published public var films: [FilmPreset] = []
    @Published public var lutRecipe: LutRecipe = .default
    @Published public var exportOptions: BatchExportOptions = .init()
    @Published public var filmMode: FilmBatchMode = .firstPhoto
    @Published public var previewImage: CGImage?
    @Published public var busy = false
    @Published public var statusMessage: String?
    @Published public var exportResult: ExportBatchResult?
    @Published public var cameraMedia: [CameraMedia] = []
    @Published public var cameraConnected = false
    @Published public var cameraModel = ""
    @Published public var cameraSelection = Set<String>()

    public let processor = PhotoProcessor()
    private let importer = ImageImporter()
    private var parameters: [PhotoId: FilmParameters] = [:]
    private var seeds: [PhotoId: Int64] = [:]
    private var previewTask: Task<Void, Never>?
    private var cameraSession: LumixCameraSession?
    private let labClient = LumixLabCatalogueClient()

    public init() {
        let recovered = importer.recoverImports()
        photos = recovered
        selectedId = recovered.first?.id
        for source in recovered {
            parameters[source.id] = .default
            seeds[source.id] = Self.stableSeed(for: source.id)
        }
        reloadCatalogue()
    }

    private static func stableSeed(for id: PhotoId) -> Int64 {
        var hash = FNV1a.hash(id.value)
        if hash == 0 { hash = 1 }
        return Int64(bitPattern: hash)
    }

    private enum FNV1a {
        static func hash(_ value: String) -> UInt64 {
            var result: UInt64 = 14695981039346656037
            for byte in value.utf8 {
                result ^= UInt64(byte)
                result &*= 1099511628211
            }
            return result
        }
    }

    public var current: SourceImage? {
        photos.first(where: { $0.id == selectedId }) ?? photos.first
    }

    public var currentFilmParameters: FilmParameters {
        guard let current else { return .default }
        return parameters[current.id] ?? .default
    }

    public func reloadCatalogue() {
        Task { @MainActor in
            async let loadedLuts = processor.lutLibrary.load()
            let loadedFilms = (try? processor.filmCatalogue.load()) ?? []
            let snapshot = await loadedLuts
            luts = snapshot.assets
            films = loadedFilms
            if !snapshot.problems.isEmpty {
                statusMessage = snapshot.problems.joined(separator: "\n")
            }
            refreshPreview()
        }
    }

    public func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        busy = true
        statusMessage = "正在导入照片…"
        Task { @MainActor in
            var imported: [SourceImage] = []
            var errors: [String] = []
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw LumatteError.illegalState("无法读取所选照片")
                    }
                    let source = try importer.importData(data)
                    imported.append(source)
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
            append(imported)
            busy = false
            statusMessage = errors.isEmpty ? "已导入 \(imported.count) 张照片" : errors.joined(separator: "\n")
        }
    }

    public func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = true
        Task { @MainActor in
            var imported: [SourceImage] = []
            var errors: [String] = []
            for url in urls {
                do {
                    imported.append(try importer.importFile(at: url))
                } catch {
                    errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            append(imported)
            busy = false
            statusMessage = errors.isEmpty ? "已导入 \(imported.count) 个文件" : errors.joined(separator: "\n")
        }
    }

    private func append(_ sources: [SourceImage]) {
        for source in sources {
            if !photos.contains(where: { $0.id == source.id }) {
                photos.append(source)
                parameters[source.id] = .default
                seeds[source.id] = Self.stableSeed(for: source.id)
            }
        }
        if selectedId == nil { selectedId = sources.first?.id ?? photos.first?.id }
        refreshPreview()
    }

    public func select(_ id: PhotoId) {
        selectedId = id
        refreshPreview()
    }

    public func removeCurrent() {
        guard let current else { return }
        photos.removeAll(where: { $0.id == current.id })
        parameters.removeValue(forKey: current.id)
        seeds.removeValue(forKey: current.id)
        selectedId = photos.first?.id
        previewImage = nil
        refreshPreview()
    }

    public func setTreatment(_ value: PhotoTreatment) {
        treatment = value
        refreshPreview()
    }

    public func updateFilm(_ transform: (inout FilmParameters) -> Void) {
        guard let current else { return }
        var updated = currentFilmParameters
        transform(&updated)
        if (try? FilmParameters(
            presetId: updated.presetId,
            exposureEv: updated.exposureEv,
            diffusion: updated.diffusion,
            halationEnabled: updated.halationEnabled
        )) == nil { return }
        if filmMode == .firstPhoto, let reference = photos.first {
            parameters[reference.id] = updated
        } else {
            parameters[current.id] = updated
        }
        refreshPreview()
    }

    public func effectiveFilmParameters(for source: SourceImage) -> FilmParameters {
        if filmMode == .firstPhoto, let first = photos.first {
            return parameters[first.id] ?? .default
        }
        return parameters[source.id] ?? .default
    }

    public func recipe(for source: SourceImage) -> PhotoRecipe {
        switch treatment {
        case .original:
            return .original
        case .lut:
            return .lut(lutRecipe)
        case .film:
            return .film(parameters: effectiveFilmParameters(for: source), grainSeed: seeds[source.id] ?? 0)
        }
    }

    public func updateLUT(_ transform: (inout LutRecipe) -> Void) {
        var copy = lutRecipe
        transform(&copy)
        if let validated = try? LutRecipe(
            first: copy.first,
            second: copy.second,
            grain: copy.grain,
            grainEnabled: copy.grainEnabled,
            ditheringEnabled: copy.ditheringEnabled
        ) {
            lutRecipe = validated
            refreshPreview()
        }
    }

    public func updateExportOptions(_ transform: (inout BatchExportOptions) -> Void) {
        transform(&exportOptions)
        refreshPreview()
    }

    public func refreshPreview() {
        previewTask?.cancel()
        guard let source = current else {
            previewImage = nil
            return
        }
        let recipe = self.recipe(for: source)
        let assets = luts
        let presets = films
        let id = source.id
        let options = exportOptions
        previewTask = Task { @MainActor in
            do {
                let image: CGImage
                if options.frame.preset == .none {
                    image = try await processor.preview(source: source, recipe: recipe, assets: assets, films: presets, longEdge: 960)
                } else {
                    image = try await processor.previewExport(source: source, recipe: recipe, assets: assets, films: presets, options: options, longEdge: 960)
                }
                guard !Task.isCancelled, selectedId == id || current?.id == id else { return }
                previewImage = image
            } catch {
                guard !Task.isCancelled else { return }
                statusMessage = error.localizedDescription
            }
        }
    }

    public func importLUT(_ url: URL) {
        do {
            let asset = try processor.lutLibrary.importFile(at: url)
            reloadCatalogue()
            updateLUT { recipe in
                if recipe.first.id == nil {
                    recipe.first = try! LutSlot(id: asset.id, strength: recipe.first.strength)
                } else {
                    recipe.second = try! LutSlot(id: asset.id, strength: recipe.second.strength)
                }
            }
            statusMessage = "已导入 LUT：\(asset.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func labDetail(code: String) async throws -> LumixLabLutDetail {
        try await labClient.detail(code: code, language: "zh")
    }

    public func downloadLabLUT(_ detail: LumixLabLutDetail) async throws -> LutAsset {
        let bytes = try await labClient.downloadCube(detail: detail)
        let asset = try processor.lutLibrary.saveOfficialLut(detail: detail, cubeBytes: bytes)
        reloadCatalogue()
        return asset
    }

    public func exportBatch() async {
        guard !photos.isEmpty, !busy else { return }
        busy = true
        exportResult = nil
        statusMessage = "正在导出 \(photos.count) 张照片…"
        let snapshot = photos
        var failures: [String] = []
        var exported = 0
        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        for (index, source) in snapshot.enumerated() {
            do {
                statusMessage = "正在导出 \(index + 1) / \(snapshot.count)：\(source.name)"
                let data = try await processor.export(
                    source: source,
                    recipe: recipe(for: source),
                    assets: luts,
                    films: films,
                    options: exportOptions,
                    frameNumber: index + 1
                )
                try await saveToPhotoLibrary(data)
                exported += 1
            } catch {
                failures.append("\(source.name)：\(error.localizedDescription)")
            }
        }
        exportResult = ExportBatchResult(exported: exported, failures: failures)
        statusMessage = failures.isEmpty ? "已保存 \(exported) 张照片到系统相册" : "导出完成：\(exported) 成功，\(failures.count) 失败"
        busy = false
    }

    private func saveToPhotoLibrary(_ data: Data) async throws {
        let authorized = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorized == .authorized || authorized == .limited else {
            throw LumatteError.illegalState("请在系统设置中允许添加照片到相册")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    // MARK: - Camera

    public func connectCamera(host: String) async {
        guard !busy else { return }
        busy = true
        statusMessage = "正在连接相机…"
        do {
            let session = try await LumixCameraSession.connect(host: host) { [weak self] step in
                Task { @MainActor in self?.statusMessage = step.label }
            }
            cameraSession = session
            try await session.prepareBrowsing()
            let page = try await session.browseNewest(count: 50)
            cameraMedia = page.entries
            cameraConnected = true
            cameraModel = session.device.model
            statusMessage = "已连接 \(session.device.model)，读取到 \(page.totalMatches) 项媒体"
        } catch {
            cameraConnected = false
            statusMessage = error.localizedDescription
        }
        busy = false
    }

    public func cameraThumbnail(for media: CameraMedia) async -> Data? {
        guard let session = cameraSession, let resource = media.thumbnail else { return nil }
        return try? await session.thumbnail(for: resource)
    }

    public func importSelectedCameraMedia() async {
        guard let session = cameraSession else { return }
        let selected = cameraMedia.filter { cameraSelection.contains($0.id) }
        guard !selected.isEmpty else {
            statusMessage = "请先选择要传输的相机照片"
            return
        }
        busy = true
        var imported: [SourceImage] = []
        var errors: [String] = []
        for (index, media) in selected.enumerated() {
            do {
                guard let resource = media.editableResource else {
                    throw LumatteError.illegalState("此条目没有可编辑的照片资源")
                }
                statusMessage = "正在传输 \(index + 1) / \(selected.count)"
                let data = try await session.download(resource)
                imported.append(try importer.importData(data, displayName: media.title))
            } catch {
                errors.append("\(media.title)：\(error.localizedDescription)")
            }
        }
        append(imported)
        cameraSelection.removeAll()
        statusMessage = errors.isEmpty ? "已从相机传入 \(imported.count) 张照片" : errors.joined(separator: "\n")
        busy = false
    }

    public func disconnectCamera() {
        Task {
            await cameraSession?.close()
            cameraSession = nil
            cameraConnected = false
            cameraMedia = []
            cameraSelection.removeAll()
            cameraModel = ""
        }
    }
}
