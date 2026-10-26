// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumatteKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "LumatteCore",
            targets: ["LumatteCore"]
        )
    ],
    targets: [
        .target(
            name: "CLumatteNative",
            path: "ios/Sources/CLumatteNative",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../../native/mobile-film"),
                .unsafeFlags(["-O3"])
            ]
        ),
        .target(
            name: "LumatteCore",
            dependencies: ["CLumatteNative"],
            path: "ios/Sources/LumatteCore"
        ),
        .testTarget(
            name: "LumatteCoreTests",
            dependencies: ["LumatteCore"],
            path: "ios/Tests/LumatteCoreTests"
        )
    ],
    cxxLanguageStandard: .cxx20
)
