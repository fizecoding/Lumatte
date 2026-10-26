import SwiftUI
import LumatteCore

struct BluetoothCameraView: View {
    @StateObject private var bluetooth = LumixBluetoothController()
    @State private var joining = false

    var body: some View {
        List {
            Section {
                Text("相机进入「蓝牙 → 配对」后扫描。配对成功后，应用读取相机 Wi-Fi 信息；也可以在系统设置中手动加入相机热点。")
                    .font(.footnote)
                    .foregroundStyle(LumatteTheme.secondary)
                Button(bluetooth.isScanning ? "正在扫描…" : "扫描松下相机") {
                    if bluetooth.isScanning { bluetooth.stopScan() } else { bluetooth.startScan() }
                }
                if let status = bluetooth.statusMessage {
                    Text(status).font(.caption).foregroundStyle(LumatteTheme.secondary)
                }
            }
            Section("发现的相机") {
                ForEach(bluetooth.discoveredCameras) { camera in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(camera.name)
                            Text("信号 \(camera.rssi) dBm").font(.caption).foregroundStyle(LumatteTheme.secondary)
                        }
                        Spacer()
                        Button("配对") { bluetooth.pairAndReadWifi(camera: camera) }
                    }
                }
            }
            if let credentials = bluetooth.wifiCredentials {
                Section("传输 Wi-Fi") {
                    Text(credentials.ssid)
                    Button(joining ? "正在请求加入…" : "加入相机 Wi-Fi") {
                        joining = true
                        Task {
                            do {
                                try await bluetooth.joinCameraWifiOniOS(credentials)
                                bluetooth.reportStatus("已请求加入相机 Wi-Fi，返回首页后点击连接")
                            } catch {
                                bluetooth.reportStatus(error.localizedDescription)
                            }
                            joining = false
                        }
                    }.disabled(joining)
                }
            }
        }
        .navigationTitle("蓝牙连接")
    }
}
