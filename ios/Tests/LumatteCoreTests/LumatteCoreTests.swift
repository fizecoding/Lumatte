import XCTest
import CoreGraphics
@testable import LumatteCore

final class BatchContractTests: XCTestCase {
    func testInheritedReferenceDoesNotFollowReorderingOrOverwriteDrafts() throws {
        let first = BatchPhoto(id: PhotoId("first"), parameters: try FilmParameters(exposureEv: 1), grainSeed: 11)
        let other = BatchPhoto(id: PhotoId("other"), parameters: try FilmParameters(exposureEv: -1), grainSeed: 22)
        let batch = try FilmBatch(photos: [other, first], referenceId: first.id)
        XCTAssertEqual(try batch.effectiveParameters(for: other.id), first.parameters)
        var individual = batch
        individual.mode = .individual
        XCTAssertEqual(try individual.effectiveParameters(for: other.id), other.parameters)
        XCTAssertEqual(try batch.copyReferenceToAll().photos.first?.grainSeed, 22)
    }

    func testFirstPhotoModeRejectsEditingOtherPhoto() throws {
        let p = BatchPhoto(id: PhotoId("a"), parameters: .default, grainSeed: 0)
        let q = BatchPhoto(id: PhotoId("b"), parameters: .default, grainSeed: 0)
        let batch = try FilmBatch(photos: [p, q], referenceId: p.id)
        XCTAssertThrowsError(try batch.updateParameters(id: q.id, parameters: try FilmParameters(exposureEv: 2)))
    }

    func testDimensionPercentageIsIndependentOfCompression() throws {
        let input = PixelSize(uncheckedWidth: 6000, height: 4000)
        XCTAssertEqual(try JpegOutput(compressionQuality: 1).contentSize(for: input), input)
        XCTAssertEqual(try JpegOutput(dimensionPercent: 50, compressionQuality: 100).contentSize(for: input), PixelSize(uncheckedWidth: 3000, height: 2000))
    }

    func testFrameDoesNotShrinkRequestedPhotoAcrossRatiosAndOrientations() throws {
        for size in [PixelSize(uncheckedWidth: 6000, height: 4000), PixelSize(uncheckedWidth: 4000, height: 6000)] {
            for preset in FramePreset.allCases {
                for ratio in FrameRatio.allCases {
                    let options = try FrameOptions(preset: preset, ratio: ratio)
                    let layout = FrameLayouts.plan(content: size, frame: options)
                    XCTAssertEqual(layout.photo.width, Float(size.width), accuracy: 0.01)
                    XCTAssertEqual(layout.photo.height, Float(size.height), accuracy: 0.01)
                    XCTAssertGreaterThanOrEqual(layout.photo.left, 0)
                    XCTAssertGreaterThanOrEqual(layout.photo.top, 0)
                    XCTAssertLessThanOrEqual(layout.photo.right, Float(layout.canvas.width))
                    XCTAssertLessThanOrEqual(layout.photo.bottom, Float(layout.canvas.height))
                }
            }
        }
    }

    func testSpecialHalationDefaultsDoNotSpreadToOtherStocks() throws {
        XCTAssertTrue(try FilmParameters(presetId: "cinestill_800t").halationEnabled)
        XCTAssertTrue(try FilmParameters(presetId: "cinestill_400d").halationEnabled)
        XCTAssertFalse(try FilmParameters(presetId: "kodak_gold_200").halationEnabled)
        XCTAssertFalse(try FilmParameters(presetId: "kodak_vision3_500t").halationEnabled)
        XCTAssertFalse(try FilmParameters(presetId: "cinestill_800t").withPreset("kodak_gold_200").halationEnabled)
    }

    func testRecipeCodecsRoundTrip() throws {
        let recipes: [PhotoRecipe] = [
            .original,
            .film(parameters: try FilmParameters(presetId: "cinestill_800t", exposureEv: -0.75, diffusion: .quarter, halationEnabled: true), grainSeed: Int64.min),
            .lut(try LutRecipe(first: LutSlot(id: "first", strength: 0.37), second: LutSlot(id: "second", strength: 0.8), grain: 0.25, grainEnabled: false, ditheringEnabled: true))
        ]
        for recipe in recipes {
            XCTAssertEqual(try PhotoRecipeCodec.read(PhotoRecipeCodec.write(recipe)), recipe)
        }
        let old = try PhotoRecipe.FilmParametersLiteral.pushRecipe()
        let migrated = try PhotoRecipeCodec.read(old)
        guard case .film(let parameters, let seed) = migrated else { return XCTFail() }
        XCTAssertEqual(parameters.presetId, "kodak_portra_800")
        XCTAssertEqual(parameters.exposureEv, 1.2)
        XCTAssertEqual(seed, 55)
    }
}

private extension PhotoRecipe {
    enum FilmParametersLiteral {
        static func pushRecipe() throws -> String {
            let parameters = try FilmParameters(presetId: "kodak_portra_800_push1", exposureEv: 1.2)
            return try PhotoRecipeCodec.write(.film(parameters: parameters, grainSeed: 55))
        }
    }
}

final class PersistenceContractTests: XCTestCase {
    func testAllSharedFramePresetsPreserveSettingsAndCustomAssets() throws {
        for preset in FramePreset.allCases {
            let frame = try FrameOptions(
                preset: preset,
                signature: "© name",
                fixedColorArgb: Int32(bitPattern: 0xFF123456),
                title: "中文 title",
                filmBlackWhite: false,
                portrait: true,
                imageKey: String(repeating: "a", count: 64) + ".png",
                titleFontKey: String(repeating: "b", count: 64) + ".font",
                showCamera: false,
                showCapturedAt: true
            )
            XCTAssertEqual(try FrameOptionsCodec.read(FrameOptionsCodec.write(frame)), frame)
        }
    }

    func testFutureVersionsAndInvalidValuesCannotSilentlyChangeExports() throws {
        let text = try PhotoRecipeCodec.write(.original)
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return XCTFail() }
        var future = obj
        future["version"] = 99
        let futureText = String(decoding: try JSONSerialization.data(withJSONObject: future), as: UTF8.self)
        XCTAssertThrowsError(try PhotoRecipeCodec.read(futureText))
        let frameText = try FrameOptionsCodec.write(.default)
        guard let frameObj = try JSONSerialization.jsonObject(with: Data(frameText.utf8)) as? [String: Any] else { return XCTFail() }
        var bad = frameObj
        bad["border"] = 0.9
        let badText = String(decoding: try JSONSerialization.data(withJSONObject: bad), as: UTF8.self)
        XCTAssertThrowsError(try FrameOptionsCodec.read(badText))
    }
}

final class CameraProtocolTests: XCTestCase {
    func testCameraAddressesRejectInternetAndHostnames() {
        for host in ["example.com", "8.8.8.8", "127.0.0.1", "0.0.0.0", "224.0.0.1", "::1", "2001:4860::8888", "192.168.1.999"] {
            XCTAssertThrowsError(try CameraAddress.literal(host), host)
        }
        for host in ["192.168.54.1", "10.0.0.2", "172.16.0.2", "169.254.2.3", "fc00::1", "fe80::1"] {
            XCTAssertNoThrow(try CameraAddress.literal(host), host)
        }
    }

    func testDescriptionCannotCarryCredentialsOrChangeScheme() throws {
        for string in ["https://192.168.1.1/x", "http://user@192.168.1.1/x", "http://192.168.1.1/x#secret"] {
            XCTAssertThrowsError(try CameraAddress.requireDescription(URL(string: string)!))
        }
        let original = URL(string: "http://192.168.1.1:60606/a%20b?q=%2F")!
        let changed = try CameraAddress.withAuthority(original, host: "192.168.1.2")
        XCTAssertEqual(changed.path, "/a b")
        XCTAssertEqual(URLComponents(url: changed, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "q=%2F")
    }

    func testSsidsPreserveSpacesAndUnicodeButRejectTruncation() throws {
        for ssid in [" S5-C70616 ", "相机 WiFi", "LUMIX-123"] {
            XCTAssertEqual(try LumixBleProtocol.decodeSsid(Array(ssid.utf8) + [0, 0]), ssid)
        }
        for ssid in [String(repeating: "相", count: 11), "bad\nname", " "] {
            XCTAssertThrowsError(try CameraRouterSsid.parse(ssid))
        }
        XCTAssertThrowsError(try LumixBleProtocol.decodeSsid([0xC3]))
    }

    func testBluetoothChallengeEncodingHandlesZeroKeyAndBounds() throws {
        for key in [Int32(0), Int32(0x12345678), Int32(-1)] {
            let encoded = try LumixBleProtocol.encode(Array("password123".utf8), challenge: key)
            XCTAssertEqual(encoded.count, 20)
            XCTAssertEqual(try LumixBleProtocol.decodePassword(encoded, challenge: key), "password123")
        }
        XCTAssertThrowsError(try LumixBleProtocol.encode([UInt8](repeating: 0, count: 20), challenge: 1))
        XCTAssertThrowsError(try LumixBleProtocol.challenge([0, 1, 2]))
    }

    func testProtocolInfoKeepsQuotedFilenameSeparators() {
        let info = CameraProtocolInfo.parse("http-get:*:image/jpeg:PANASONIC.COM_PN=CAM_ORG;OriginalFileName=\"a;b:c.jpg\"")
        XCTAssertEqual(info.mimeType, "image/jpeg")
        XCTAssertEqual(info.profile, "CAM_ORG")
        XCTAssertEqual(info.originalName, "a;b:c.jpg")
        XCTAssertEqual(CameraProtocolInfo.parse("http-get:*:image/x-panasonic-rw2;PANASONIC.COM_PN=CAM_RAW").profile, "CAM_RAW")
    }

    func testTransferModesDoNotBecomeOrdinaryBrowsing() throws {
        XCTAssertFalse(try CameraAccessMode.fromReply("ok").incoming)
        XCTAssertTrue(try CameraAccessMode.fromReply("upload_bt").incoming)
        XCTAssertThrowsError(try CameraIncomingDirectory(mode: .browsing, objectId: "0"))
        XCTAssertThrowsError(try CameraIncomingDirectory(mode: .markedTransfer, objectId: "0"))
    }
}

final class MediaBackendTests: XCTestCase {
    private let identity = "LUT_3D_SIZE 2\n" + (0...1).flatMap { b in
        (0...1).flatMap { g in (0...1).map { r in "\(r) \(g) \(b)" } }
    }.joined(separator: "\n")

    func testCubeUsesRedFastestAndInterpolatesAllAxes() throws {
        let lut = try CubeLut.parse(identity, fallbackName: "identity")
        for sample in [[Float(0.13), 0.71, 0.39], [0, 1, 0.5]] {
            var result = [Float](repeating: 0, count: 3)
            lut.apply(sample, result: &result)
            XCTAssertEqual(result[0], sample[0], accuracy: 0.000001)
            XCTAssertEqual(result[1], sample[1], accuracy: 0.000001)
            XCTAssertEqual(result[2], sample[2], accuracy: 0.000001)
        }
    }

    func testCubeCacheRoundTripRejectsTrailingAndTruncatedBytes() throws {
        let bytes = try CubeLut.parse(identity, fallbackName: "identity").writeData()
        let lut = try CubeLut.readData(bytes)
        var result = [Float](repeating: 0, count: 3)
        lut.apply([0.2, 0.4, 0.9], result: &result)
        XCTAssertEqual(result[0], 0.2, accuracy: 0.000001)
        XCTAssertEqual(result[1], 0.4, accuracy: 0.000001)
        XCTAssertEqual(result[2], 0.9, accuracy: 0.000001)
        XCTAssertThrowsError(try CubeLut.readData(bytes + Data([1])))
        XCTAssertThrowsError(try CubeLut.readData(bytes.dropLast()))
    }

    func testInvalidCubeNeverBecomesSilentIdentity() {
        for text in ["LUT_3D_SIZE 66", identity.replacingOccurrences(of: "0 0 0", with: "NaN 0 0"), "LUT_1D_SIZE 2\n0 0 0", "DOMAIN_MIN 1 0 0\nDOMAIN_MAX 0 1 1\n\(identity)"] {
            XCTAssertThrowsError(try CubeLut.parse(text, fallbackName: "bad"))
        }
    }

    func testOfficialZipSelectsOneCubeAndRejectsAmbiguousOrUnsafeMembers() throws {
        let compressed = Data(base64Encoded: "UEsDBBQAAAAIAI5dWl1sIG/TKQAAAD0AAAAJAAAAdGVzdC5jdWJl8wkNiTd2iQ/2jHJVMOIyUABCLkMwaaBgCGYbgtlAHljcECxuCBY3BABQSwECFAMUAAAACACOXVpdbCBv0ykAAAA9AAAACQAAAAAAAAAAAAAAgAEAAAAAdGVzdC5jdWJlUEsFBgAAAAABAAEANwAAAFAAAAAAAA==")!
        XCTAssertEqual(try LumixLabZip.cube(compressed), Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1".utf8))
        let zip = LumixLabZip.makeStoredZip(entries: [("folder/test.cube", Data(identity.utf8)), ("readme.txt", Data("notice".utf8))])
        XCTAssertEqual(try LumixLabZip.cube(zip), Data(identity.utf8))
        for entries in [
            [("../test.cube", Data(identity.utf8))],
            [("a.cube", Data(identity.utf8)), ("b.CUBE", Data(identity.utf8))],
            [("readme.txt", Data("none".utf8))],
            [("empty.cube", Data())],
            [("/root.cube", Data(identity.utf8))]
        ] {
            XCTAssertThrowsError(try LumixLabZip.cube(LumixLabZip.makeStoredZip(entries: entries)))
        }
    }

    func testCatalogueRequiresKnownTypesAndPreservesMetadata() throws {
        let list = try LumixLabJson.luts(Data("{\"filter\":[{\"code\":\"abc\",\"title\":\"Film\",\"thumbnail\":{\"path\":\"/example.jpg\",\"width\":\"320\",\"height\":240}}]}".utf8))
        XCTAssertEqual(list.single?.code, "abc")
        XCTAssertEqual(list.single?.thumbnail?.width, 320)
        for text in ["{}", "{\"filter\":{}}", "{\"filter\":[null]}", "{\"filter\":[{\"code\":42,\"title\":\"bad\"}]}"] {
            XCTAssertThrowsError(try LumixLabJson.luts(Data(text.utf8)))
        }
        XCTAssertTrue(try LumixLabJson.luts(Data("{\"filter\":[]}".utf8)).isEmpty)
    }

    func testRemoteRankingUsesExampleColoursWithoutALutDownload() throws {
        let warm = LutExampleColours(origin: .creatorExample, exampleIdentity: "sample", dominantArgb: nil, swatches: [], familyWeights: [.orange: 0.8, .neutral: 0.2], mode: .colour)
        let cool = LutExampleColours(origin: .creatorExample, exampleIdentity: "sample", dominantArgb: nil, swatches: [], familyWeights: [.blue: 0.8, .neutral: 0.2], mode: .colour)
        XCTAssertEqual(try LutExampleSimilarity.distance(warm, warm), 0, accuracy: 0.000000001)
        XCTAssertGreaterThan(try LutExampleSimilarity.distance(warm, cool), 0.5)
        XCTAssertEqual(LutExampleSimilarity.style(warm), .warm)
        XCTAssertEqual(LutExampleSimilarity.style(cool), .cool)
        XCTAssertTrue(try LutExampleSimilarity.distance(warm, LutExampleColours(origin: .creatorExample, exampleIdentity: "empty", dominantArgb: nil, swatches: [], familyWeights: [:], mode: .unknown)).isInfinite)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

final class RenderingTests: XCTestCase {
    func testBundledFilmCatalogueAndNativeRendering() async throws {
        let catalogue = FilmCatalogue()
        let films = try catalogue.load()
        XCTAssertEqual(films.count, 24)
        guard let preset = films.first(where: { $0.id == "kodak_gold_200" }) else { return XCTFail() }
        let model = try await MobileFilmModelLibrary().load(preset: preset)
        var rgba = try RGBAImage(width: 8, height: 8, bytes: [UInt8](repeating: 0, count: 8 * 8 * 4).enumerated().map { index, _ in
            index % 4 == 3 ? 255 : UInt8((index * 17) % 256)
        })
        let original = rgba.bytes
        let plan = try catalogue.plan(parameters: .default, presets: films, grainSeed: 42)
        try rgba.applyFilm(model: model, plan: plan, sourceSize: PixelSize(uncheckedWidth: 8, height: 8))
        XCTAssertNotEqual(rgba.bytes, original)
        let image = try rgba.makeCGImage()
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 8)
    }

    func testNativeDualLutRendering() throws {
        let lut = try CubeLut.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1", fallbackName: "identity")
        let plan = LutRenderPlan(first: lut, firstStrength: 1, second: nil, secondStrength: 0, grain: 0, dithering: false)
        let bytes: [UInt8] = [32, 64, 128, 255, 200, 100, 50, 255]
        var rgba = try RGBAImage(width: 2, height: 1, bytes: bytes)
        try rgba.applyLUT(plan, sourceSize: PixelSize(uncheckedWidth: 2, height: 1))
        XCTAssertEqual(rgba.bytes, bytes)
    }

    @MainActor
    func testFrameRendererProducesExpectedCanvas() throws {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let photo = context.makeImage()!
        let source = SourceImage(id: PhotoId("test"), name: "test.jpg", jpegURL: URL(fileURLWithPath: "/tmp/test.jpg"), size: PixelSize(uncheckedWidth: 8, height: 8), orientation: 1, origin: .jpeg, metadata: PhotoMetadata(camera: "DC-S5"))
        let options = try FrameOptions(preset: .paper, signature: "test")
        let layout = FrameLayouts.plan(content: source.size, frame: options)
        let output = try FrameRenderer.shared.render(photo: photo, source: source, options: options, layout: layout)
        XCTAssertEqual(output.width, layout.canvas.width)
        XCTAssertEqual(output.height, layout.canvas.height)
    }
}
