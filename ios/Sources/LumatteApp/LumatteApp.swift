import SwiftUI
import LumatteCore
import PhotosUI

@main
struct LumatteApp: App {
    @StateObject private var workspace = WorkspaceViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(workspace)
                .tint(LumatteTheme.amber)
        }
    }
}

enum LumatteTheme {
    static let background = Color(red: 0.949, green: 0.918, blue: 0.859)
    static let paper = Color(red: 0.980, green: 0.953, blue: 0.906)
    static let highlight = Color(red: 1.0, green: 0.992, blue: 0.965)
    static let ink = Color(red: 0.161, green: 0.149, blue: 0.145)
    static let secondary = Color(red: 0.408, green: 0.408, blue: 0.373)
    static let amber = Color(red: 0.537, green: 0.349, blue: 0.110)
    static let rim = Color(red: 0.824, green: 0.808, blue: 0.761)
}

struct RootView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var tab = 0
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showLUTImport = false

    var body: some View {
        TabView(selection: $tab) {
            HomeView(tab: $tab, showPhotos: $showPhotos, showFiles: $showFiles)
                .tabItem { Label("连接", systemImage: "camera") }.tag(0)
            FilmView(showPhotos: $showPhotos, tab: $tab)
                .tabItem { Label("Film", systemImage: "film") }.tag(1)
            LUTView(showImport: $showLUTImport, tab: $tab)
                .tabItem { Label("LUT", systemImage: "slider.horizontal.3") }.tag(2)
            FrameExportView(showPhotos: $showPhotos)
                .tabItem { Label("水印", systemImage: "photo.on.rectangle") }.tag(3)
        }
        .background(LumatteTheme.background.ignoresSafeArea())
        .photosPicker(isPresented: $showPhotos, selection: Binding(get: { [] }, set: { workspace.importPhotos($0) }), maxSelectionCount: 50, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.jpeg, .image, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { workspace.importFiles(urls) }
        }
        .fileImporter(isPresented: $showLUTImport, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { workspace.importLUT(url) }
        }
        .overlay(alignment: .bottom) {
            if let message = workspace.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(LumatteTheme.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(LumatteTheme.highlight.opacity(0.97), in: Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 62)
                    .multilineTextAlignment(.center)
                    .onTapGesture { workspace.statusMessage = nil }
            }
        }
    }
}

struct PaperCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LumatteTheme.paper, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(LumatteTheme.rim.opacity(0.55)))
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String?
    init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 28, weight: .bold, design: .serif)).foregroundStyle(LumatteTheme.ink)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(LumatteTheme.secondary) }
        }
    }
}

struct PrimaryButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(LumatteTheme.amber)
        .clipShape(Capsule())
    }
}

struct HomeView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Binding var tab: Int
    @Binding var showPhotos: Bool
    @Binding var showFiles: Bool
    @State private var host = "192.168.54.1"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        SectionTitle("Lumatte", subtitle: "松映 · 你的随身数字暗房")
                        Spacer()
                        Image(systemName: "camera.aperture").font(.system(size: 34)).foregroundStyle(LumatteTheme.amber)
                    }
                    PaperCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("松下相机直传", systemImage: "wifi")
                                .font(.headline)
                            Text("相机开启 Wi-Fi 后，输入地址即可浏览和导入照片。默认热点地址为 192.168.54.1。")
                                .font(.subheadline).foregroundStyle(LumatteTheme.secondary)
                            HStack {
                                TextField("相机 IP", text: $host)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                Button(workspace.cameraConnected ? "已连接" : "连接") {
                                    Task { await workspace.connectCamera(host: host) }
                                }.disabled(workspace.busy)
                            }
                            if workspace.cameraConnected {
                                Text("\(workspace.cameraModel) · \(workspace.cameraMedia.count) 项已载入")
                                    .font(.caption).foregroundStyle(LumatteTheme.secondary)
                            }
                            NavigationLink("蓝牙配对并读取相机 Wi-Fi") { BluetoothCameraView() }
                            NavigationLink("打开相机相册") { CameraLibraryView() }
                                .disabled(!workspace.cameraConnected)
                        }
                    }
                    HStack(spacing: 14) {
                        Button { showPhotos = true } label: {
                            VStack(alignment: .leading) {
                                Image(systemName: "photo.on.rectangle.angled").font(.title2)
                                Text("手机相册").font(.headline).padding(.top, 8)
                                Text("多选 JPEG / RAW").font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        }.buttonStyle(.plain).background(LumatteTheme.paper, in: RoundedRectangle(cornerRadius: 22))
                        Button { showFiles = true } label: {
                            VStack(alignment: .leading) {
                                Image(systemName: "folder").font(.title2)
                                Text("从文件导入").font(.headline).padding(.top, 8)
                                Text("RAW 提取内嵌 JPEG").font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        }.buttonStyle(.plain).background(LumatteTheme.paper, in: RoundedRectangle(cornerRadius: 22))
                    }
                    if !workspace.photos.isEmpty {
                        PaperCard {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("当前批次").font(.headline)
                                    Text("\(workspace.photos.count) 张照片 · \(workspace.treatment.rawValue)").font(.caption).foregroundStyle(LumatteTheme.secondary)
                                }
                                Spacer()
                                Button("继续编辑") { tab = workspace.treatment == .lut ? 2 : 1 }
                            }
                        }
                    }
                    NavigationLink("浏览 Lumix Lab 官方 LUT") { LumixLabView() }
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(LumatteTheme.paper, in: RoundedRectangle(cornerRadius: 22))
                }
                .padding(20)
            }
            .background(LumatteTheme.background)
            .navigationBarHidden(true)
        }
    }
}

struct PhotoPreview: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let image = workspace.previewImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo").font(.largeTitle)
                        Text("还没有照片").font(.headline)
                        Text("从相册、文件或松下相机导入").font(.caption).foregroundStyle(LumatteTheme.secondary)
                    }
                    .foregroundStyle(LumatteTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            if let current = workspace.current {
                Text(current.rawNotice ?? current.name).font(.caption).foregroundStyle(LumatteTheme.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(workspace.photos) { photo in
                            Button(photo.name) { workspace.select(photo.id) }
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(photo.id == workspace.current?.id ? LumatteTheme.amber.opacity(0.2) : LumatteTheme.paper, in: Capsule())
                        }
                    }
                }
            }
        }
    }
}

struct FilmView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Binding var showPhotos: Bool
    @Binding var tab: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        SectionTitle("Film Stories", subtitle: "24 款胶片 · 三阶段色彩模型")
                        Spacer()
                        Button { showPhotos = true } label: { Image(systemName: "plus") }
                    }
                    PhotoPreview()
                    if !workspace.photos.isEmpty {
                        PaperCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Picker("处理", selection: Binding(get: { workspace.treatment }, set: { workspace.setTreatment($0) })) {
                                    Text("Film").tag(PhotoTreatment.film)
                                    Text("原图").tag(PhotoTreatment.original)
                                    Text("LUT").tag(PhotoTreatment.lut)
                                }.pickerStyle(.segmented)
                                if workspace.treatment == .film {
                                    Picker("批次模式", selection: $workspace.filmMode) {
                                        ForEach(FilmBatchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                                    }.pickerStyle(.segmented)
                                    Text("曝光 \(workspace.currentFilmParameters.exposureEv, specifier: "%.2f") EV")
                                    Slider(value: Binding(get: { Double(workspace.currentFilmParameters.exposureEv) }, set: { value in
                                        workspace.updateFilm { $0.exposureEv = Float(value) }
                                    }), in: -3...3, step: 0.05)
                                    Picker("黑柔", selection: Binding(get: { workspace.currentFilmParameters.diffusion }, set: { value in
                                        workspace.updateFilm { $0.diffusion = value }
                                    })) {
                                        ForEach(DiffusionGrade.allCases, id: \.self) { Text($0.label).tag($0) }
                                    }
                                    Toggle("Halation 光晕", isOn: Binding(get: { workspace.currentFilmParameters.halationEnabled }, set: { value in
                                        workspace.updateFilm { $0.halationEnabled = value }
                                    }))
                                }
                            }
                        }
                        ForEach(FilmCategory.allCases, id: \.self) { category in
                            let films = workspace.films.filter { $0.category == category }
                            if !films.isEmpty {
                                Text(category.label).font(.title3.bold())
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(films) { film in
                                            Button {
                                                workspace.setTreatment(.film)
                                                workspace.updateFilm { $0 = $0.withPreset(film.id) }
                                            } label: {
                                                VStack(alignment: .leading, spacing: 6) {
                                                    Text(film.name).font(.headline).lineLimit(2)
                                                    Text(category.subtitle).font(.caption2)
                                                    if workspace.currentFilmParameters.presetId == film.id {
                                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(LumatteTheme.amber)
                                                    }
                                                }
                                                .frame(width: 150, height: 90, alignment: .topLeading)
                                                .padding(14)
                                                .background(LumatteTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                        PrimaryButton(title: "选择画框与导出", systemImage: "arrow.right") { tab = 3 }
                    }
                }.padding(20)
            }.background(LumatteTheme.background).navigationBarHidden(true)
        }
    }
}

struct LUTView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Binding var showImport: Bool
    @Binding var tab: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        SectionTitle("LUT", subtitle: "双槽顺序调色 · 颗粒与减少色彩断层")
                        Spacer()
                        Button { showImport = true } label: { Image(systemName: "plus") }
                    }
                    PhotoPreview()
                    PaperCard {
                        VStack(spacing: 16) {
                            lutSlot(first: true)
                            Image(systemName: "arrow.down").foregroundStyle(LumatteTheme.secondary)
                            lutSlot(first: false)
                            Toggle("颗粒效果", isOn: Binding(get: { workspace.lutRecipe.grainEnabled }, set: { value in workspace.updateLUT { $0.grainEnabled = value } }))
                            if workspace.lutRecipe.grainEnabled {
                                Slider(value: Binding(get: { Double(workspace.lutRecipe.grain) }, set: { value in workspace.updateLUT { $0.grain = Float(value) } }))
                            }
                            Toggle("减少色彩断层（Bayer 抖动）", isOn: Binding(get: { workspace.lutRecipe.ditheringEnabled }, set: { value in workspace.updateLUT { $0.ditheringEnabled = value } }))
                            Button("交换两槽顺序") {
                                workspace.updateLUT { recipe in
                                    let first = recipe.first
                                    recipe.first = recipe.second
                                    recipe.second = first
                                }
                            }
                        }
                    }
                    NavigationLink("Lumix Lab 官方社区") { LumixLabView() }
                        .frame(maxWidth: .infinity).padding(16).background(LumatteTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                    PrimaryButton(title: "选择画框与导出", systemImage: "arrow.right") { tab = 3 }
                        .disabled(workspace.photos.isEmpty)
                }.padding(20)
            }.background(LumatteTheme.background).navigationBarHidden(true)
        }
    }

    @ViewBuilder private func lutSlot(first: Bool) -> some View {
        let slot = first ? workspace.lutRecipe.first : workspace.lutRecipe.second
        VStack(alignment: .leading) {
            Text(first ? "LUT 1" : "LUT 2").font(.headline)
            Picker(first ? "LUT 1" : "LUT 2", selection: Binding(get: { slot.id }, set: { id in
                workspace.updateLUT { recipe in
                    let newSlot = try! LutSlot(id: id, strength: slot.strength)
                    if first { recipe.first = newSlot } else { recipe.second = newSlot }
                }
            })) {
                Text("不使用").tag(String?.none)
                ForEach(workspace.luts) { asset in Text(asset.name).tag(String?.some(asset.id)) }
            }
            HStack {
                Text("强度")
                Slider(value: Binding(get: { Double(slot.strength) }, set: { value in
                    workspace.updateLUT { recipe in
                        let newSlot = try! LutSlot(id: slot.id, strength: Float(value))
                        if first { recipe.first = newSlot } else { recipe.second = newSlot }
                    }
                }))
                Text("\(Int(slot.strength * 100))%").frame(width: 42)
            }
        }
    }
}

struct FrameExportView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Binding var showPhotos: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        SectionTitle("画框与导出", subtitle: "整批共享画框 · 原图像素不被画框压缩")
                        Spacer()
                        Button { showPhotos = true } label: { Image(systemName: "plus") }
                    }
                    PhotoPreview()
                    PaperCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("画框", selection: Binding(get: { workspace.exportOptions.frame.preset }, set: { value in workspace.updateExportOptions { $0.frame.preset = value } })) {
                                ForEach(FramePreset.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            Picker("画布比例", selection: Binding(get: { workspace.exportOptions.frame.ratio }, set: { value in workspace.updateExportOptions { $0.frame.ratio = value } })) {
                                ForEach(FrameRatio.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            HStack {
                                Text("纸边")
                                Slider(value: Binding(get: { Double(workspace.exportOptions.frame.borderFraction) }, set: { value in workspace.updateExportOptions { $0.frame.borderFraction = Float(value) } }), in: 0.02...0.12)
                            }
                            TextField("签名 / 水印文字", text: Binding(get: { workspace.exportOptions.frame.signature }, set: { value in workspace.updateExportOptions { $0.frame.signature = String(value.prefix(240)) } }), axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                            Toggle("显示照片 EXIF", isOn: Binding(get: { workspace.exportOptions.frame.showPhotoMetadata }, set: { value in workspace.updateExportOptions { $0.frame.showPhotoMetadata = value } }))
                        }
                    }
                    PaperCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("格式", selection: Binding(get: { workspace.exportOptions.jpeg.format }, set: { value in workspace.updateExportOptions { $0.jpeg.format = value } })) {
                                ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                            Stepper("照片尺寸 \(workspace.exportOptions.jpeg.dimensionPercent)%", value: Binding(get: { workspace.exportOptions.jpeg.dimensionPercent }, set: { value in workspace.updateExportOptions { $0.jpeg.dimensionPercent = value } }), in: 1...100)
                            Stepper("JPEG 质量 \(workspace.exportOptions.jpeg.compressionQuality)", value: Binding(get: { workspace.exportOptions.jpeg.compressionQuality }, set: { value in workspace.updateExportOptions { $0.jpeg.compressionQuality = value } }), in: 1...100)
                            if let result = workspace.exportResult {
                                Text("成功 \(result.exported) 张" + (result.failures.isEmpty ? "" : "，失败 \(result.failures.count) 张"))
                                    .foregroundStyle(result.failures.isEmpty ? .green : .orange)
                            }
                        }
                    }
                    PrimaryButton(title: workspace.busy ? "正在处理…" : "导出本批 · \(workspace.photos.count) 张", systemImage: "square.and.arrow.down") {
                        Task { await workspace.exportBatch() }
                    }.disabled(workspace.photos.isEmpty || workspace.busy)
                }.padding(20)
            }.background(LumatteTheme.background).navigationBarHidden(true)
        }
    }
}

struct CameraLibraryView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(workspace.cameraMedia) { media in
                    CameraMediaCell(media: media)
                }
            }.padding(16)
        }
        .navigationTitle("相机相册")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("传入选中 · \(workspace.cameraSelection.count) 项") {
                    Task { await workspace.importSelectedCameraMedia() }
                }.disabled(workspace.cameraSelection.isEmpty || workspace.busy)
            }
        }
    }
}

struct CameraMediaCell: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let media: CameraMedia
    @State private var thumbnail: Data?

    var body: some View {
        Button {
            if workspace.cameraSelection.contains(media.id) {
                workspace.cameraSelection.remove(media.id)
            } else {
                workspace.cameraSelection.insert(media.id)
            }
        } label: {
            VStack {
                Group {
                    if let thumbnail, let image = UIImage(data: thumbnail) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: media.isVideo ? "video" : "photo").font(.largeTitle)
                    }
                }
                .frame(height: 130).frame(maxWidth: .infinity).clipped()
                .background(LumatteTheme.paper)
                Text(media.title).font(.caption).lineLimit(1)
            }
            .padding(8)
            .background(LumatteTheme.paper, in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                if workspace.cameraSelection.contains(media.id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(LumatteTheme.amber).padding(14)
                }
            }
        }.buttonStyle(.plain)
        .task {
            if thumbnail == nil { thumbnail = await workspace.cameraThumbnail(for: media) }
        }
    }
}

struct LumixLabView: View {
    @State private var items: [LumixLabLut] = []
    @State private var offset = 0
    @State private var loading = false
    @State private var message: String?
    private let client = LumixLabCatalogueClient()

    var body: some View {
        List {
            ForEach(items) { item in
                NavigationLink(item.title) { LumixLabDetailView(code: item.code, title: item.title) }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if !items.isEmpty {
                Button("加载更多") { Task { await load() } }.disabled(loading)
            }
        }
        .navigationTitle("Lumix Lab")
        .task { if items.isEmpty { await load() } }
        .overlay { if let message { Text(message).padding() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let page = try await client.luts(query: LumixLabLutQuery(language: "zh", offset: offset, limit: 32))
            items.append(contentsOf: page.items)
            offset = page.nextOffset ?? offset
        } catch {
            message = error.localizedDescription
        }
    }
}

struct LumixLabDetailView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let code: String
    let title: String
    @State private var detail: LumixLabLutDetail?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.largeTitle.bold())
                if let detail {
                    if let creator = detail.lut.creator?.name { Label(creator, systemImage: "person") }
                    if let style = detail.photoStyle { Text("输入照片风格：\(style)") }
                    Text(detail.overview ?? "").foregroundStyle(LumatteTheme.secondary)
                    PrimaryButton(title: "下载并加入我的 LUT", systemImage: "arrow.down.circle") {
                        Task {
                            do {
                                let asset = try await workspace.downloadLabLUT(detail)
                                workspace.updateLUT { $0.first = try! LutSlot(id: asset.id, strength: $0.first.strength) }
                                message = "已加入我的 LUT"
                            } catch { message = error.localizedDescription }
                        }
                    }
                } else {
                    ProgressView()
                }
                if let message { Text(message) }
            }.padding(20)
        }.navigationTitle("LUT 详情")
        .task {
            do { detail = try await workspace.labDetail(code: code) }
            catch { message = error.localizedDescription }
        }
    }
}
