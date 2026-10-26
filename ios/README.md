# Lumatte iOS

这是从 Android 版 Lumatte 移植的原生 iOS 应用与 Swift Package。图像模型、LUT 文件、字体和画框素材沿用上游仓库；应用代码继续遵循 GPLv3，第三方素材保留原许可与署名。

## 工程

- `Package.swift`：构建 `LumatteCore` 和原生 C++20 目标 `CLumatteNative`。
- `ios/Sources/LumatteCore`：相机连接、媒体浏览、RAW 内嵌 JPEG 提取、胶片/LUT 处理、画框与导出。
- `ios/Sources/LumatteApp`：SwiftUI iOS 应用。
- `ios/project.yml`：XcodeGen 工程配置。
- `ios/Tests`：协议、模型与图像处理测试。

## 构建

```sh
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Lumatte.xcodeproj -scheme Lumatte \
  -destination 'generic/platform=iOS Simulator' build
```

Swift Package 测试：

```sh
swift test
```

首次连接相机前，需要在 iPhone 上加入相机 Wi-Fi；默认地址是 `192.168.54.1`。iOS 的蓝牙和本地网络权限在首次使用时请求。真机运行需在 Xcode 中选择开发团队；本项目不附带签名身份。

## 功能边界

- 胶片引擎直接编译上游 `mobile_film_core.hpp`，使用同一套三阶段模型、空间效果与颗粒算法。
- RAW 仅提取内嵌 JPEG，不做 RAW 显影。
- 相机功能为连接、浏览和传输，不包含实时取景或遥控拍摄。
- 官方 LUT 只在用户主动选择时下载，不上传照片。
