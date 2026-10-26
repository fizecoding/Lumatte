import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
#if canImport(NetworkExtension) && os(iOS)
import NetworkExtension
#endif

public enum ConnectionStep: String, Sendable {
    case requestingWifi = "REQUESTING_WIFI"
    case discovering = "DISCOVERING"
    case readingDevice = "READING_DEVICE"
    case requestingAccess = "REQUESTING_ACCESS"
    case waitingForCameraApproval = "WAITING_FOR_CAMERA_APPROVAL"
    case ready = "READY"

    public var label: String {
        switch self {
        case .requestingWifi: return "正在连接相机 Wi-Fi…"
        case .discovering: return "正在查找相机…"
        case .readingDevice: return "正在读取相机信息…"
        case .requestingAccess: return "正在请求相机访问…"
        case .waitingForCameraApproval: return "请在相机屏幕上确认连接请求…"
        case .ready: return "已连接相机"
        }
    }
}

public struct DownloadProgress: Equatable, Sendable {
    public let receivedBytes: Int64
    public let totalBytes: Int64?

    public init(receivedBytes: Int64, totalBytes: Int64?) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}

// MARK: - CameraHttp

public final class CameraHttp: @unchecked Sendable {
    public let host: String
    public let endpoint: CameraAddress.Literal
    private let session: URLSession
    private let lock = NSLock()
    private var sessionId: String?
    private var closed = false

    public init(host: String) throws {
        self.host = host
        self.endpoint = try CameraAddress.literal(host)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: config)
    }

    public func setSession(_ value: String?) throws {
        if let v = value {
            try requireArgument(v.count <= 1024 && !v.contains("\r") && !v.contains("\n"), "会话 ID 格式无效")
        }
        lock.lock()
        defer { lock.unlock() }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionId = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public func validate(_ url: URL) throws {
        try CameraAddress.requireDescription(url)
        guard let targetHost = url.host else {
            throw LumatteError.invalidArgument("缺少相机地址")
        }
        let target = try CameraAddress.literal(targetHost)
        try requireArgument(target.bytes == endpoint.bytes, "相机资源地址不属于当前相机")
    }

    private func makeRequest(for url: URL) throws -> URLRequest {
        lock.lock()
        let isClosed = closed
        let currentSession = sessionId
        lock.unlock()
        try checkState(!isClosed, "相机会话已关闭，请重新连接")
        try validate(url)
        let resolvedURL = try CameraAddress.withAuthority(url, host: endpoint.httpHost)
        var req = URLRequest(url: resolvedURL)
        req.setValue("Panasonic MIL DLNA CP UPnP/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let currentSession {
            req.setValue(currentSession, forHTTPHeaderField: "X-SESSION_ID")
        }
        return req
    }

    public func text(_ url: URL, body: String? = nil, headers: [String: String] = [:]) async throws -> String {
        var req = try makeRequest(for: url)
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let body {
            req.httpMethod = "POST"
            req.httpBody = Data(body.utf8)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CameraProtocolException("HTTP -1")
        }
        guard (200...299).contains(http.statusCode) else {
            throw CameraProtocolException("HTTP \(http.statusCode)")
        }
        try requireArgument(data.count <= 16 * 1024 * 1024, "相机 XML 响应过大")
        return String(decoding: data, as: UTF8.self)
    }

    public func thumbnailBytes(_ url: URL, limit: Int = 4 * 1024 * 1024) async throws -> Data {
        let req = try makeRequest(for: url)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CameraProtocolException("HTTP \(code)")
        }
        try requireArgument(!data.isEmpty && data.count <= limit, "缩略图响应过大或为空")
        return data
    }

    public func downloadBytes(_ url: URL, expectedBytes: Int64? = nil, onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> Data {
        var req = try makeRequest(for: url)
        req.timeoutInterval = 120
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CameraProtocolException("下载 HTTP \(code)")
        }
        if let expectedBytes, expectedBytes > 0 {
            try requireArgument(Int64(data.count) == expectedBytes, "下载文件不完整")
        }
        onProgress?(DownloadProgress(receivedBytes: Int64(data.count), totalBytes: expectedBytes ?? Int64(data.count)))
        return data
    }

    public func command(_ mode: String, _ fields: (String, String)...) async throws -> String {
        let allFields = [("mode", mode)] + fields
        let query = allFields.map { key, value in
            "\(key)=\(Self.encode(value))"
        }.joined(separator: "&")
        guard let url = URL(string: "http://\(endpoint.httpHost)/cam.cgi?\(query)") else {
            throw LumatteError.invalidArgument("无效的相机指令地址")
        }
        return try await text(url)
    }

    public func close() {
        lock.lock()
        closed = true
        sessionId = nil
        lock.unlock()
        session.invalidateAndCancel()
    }

    public static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// req_acc_e wire encoding: padded UTF-16 code units, challenge XOR, little-endian hex.
    public static func challengeEncode(_ value: String, challenge: Int32) -> String {
        var units = Array(value.utf16)
        let targetLen = ((units.count + 3) / 4) * 4
        while units.count < targetLen {
            units.append(0x00FF)
        }
        let resolvedChallenge: Int32 = challenge == 0 ? -1875740628 : challenge
        let key = UInt32(bitPattern: resolvedChallenge)
        var result = ""
        for chunkStart in stride(from: 0, to: units.count, by: 4) {
            var word: UInt32 = 0
            for i in 0..<4 {
                word = (word << 8) | UInt32(units[chunkStart + i] & 0xFF)
            }
            word ^= key
            let swapped = ((word & 0xFF) << 24) |
                ((word & 0xFF00) << 8) |
                ((word >> 8) & 0xFF00) |
                ((word >> 24) & 0xFF)
            result += String(format: "%08x", swapped)
        }
        return result
    }
}

// MARK: - LumixCameraSession

public actor LumixCameraSession {
    public nonisolated let device: CameraDevice
    public nonisolated let accessMode: CameraAccessMode
    private let http: CameraHttp
    private var incomingDirectory: CameraIncomingDirectory?

    public init(device: CameraDevice, http: CameraHttp, accessMode: CameraAccessMode) {
        self.device = device
        self.http = http
        self.accessMode = accessMode
    }

    public static func newClientId() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        return "4D454930-0100-1000-8001-\(suffix)"
    }

    public static func connect(
        host: String = "192.168.54.1",
        clientId: String = LumixCameraSession.newClientId(),
        clientName: String = "Lumix Film Mirror",
        descriptionURL: URL? = nil,
        compactLegacyIdentity: Bool = false,
        onStep: (@Sendable (ConnectionStep) -> Void)? = nil
    ) async throws -> LumixCameraSession {
        let resolvedDescription = try descriptionURL ?? CameraAddress.description(host)
        try CameraAddress.requireDescription(resolvedDescription)
        guard let descHost = resolvedDescription.host else {
            throw LumatteError.invalidArgument("缺少相机描述地址")
        }
        let descriptionBytes = try CameraAddress.literal(descHost).bytes
        let cameraBytes = try CameraAddress.literal(host).bytes
        try requireArgument(descriptionBytes == cameraBytes, "描述地址与相机地址不一致")
        try requireArgument(
            !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "客户端标识不能为空"
        )

        let http = try CameraHttp(host: host)
        var established = false
        defer {
            if !established { http.close() }
        }

        onStep?(.readingDevice)
        let descXml = try await http.text(resolvedDescription)
        let device = try CameraXml.device(descXml, description: resolvedDescription)
        try http.validate(device.contentDirectory)

        onStep?(.requestingAccess)
        var identity = clientId
        var name = clientName
        let compactIdentity = !device.requiresChallenge &&
            (compactLegacyIdentity || device.model.caseInsensitiveCompare("DC-S5") == .orderedSame)
        if compactIdentity, let uuid = UUID(uuidString: clientId) {
            identity = uuid.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        }

        if device.requiresChallenge {
            let challengeReply = try await http.command("accctrl", ("type", "req_acc_g"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: ",")
            guard challengeReply.first == "ok" else {
                throw CameraProtocolException(challengeReply.first ?? "")
            }
            guard challengeReply.count > 1,
                  let challengeVal = UInt32(challengeReply[1].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
                throw LumatteError.invalidArgument("相机握手缺少挑战值")
            }
            let challengeInt = Int32(bitPattern: challengeVal)
            identity = CameraHttp.challengeEncode(identity, challenge: challengeInt)
            name = CameraHttp.challengeEncode(name, challenge: challengeInt)
        }

        let deadline = Date().addingTimeInterval(120)
        while true {
            try Task.checkCancellation()
            try checkState(Date() < deadline, "等待相机确认超时，请在相机屏幕确认连接后重试")
            let accType = device.requiresChallenge ? "req_acc_e" : "req_acc"
            let reply = try await http.command("accctrl", ("type", accType), ("value", identity), ("value2", name))
            let fields = try Self.accessFields(reply: reply, friendlyName: device.friendlyName)
            let status = fields.first ?? ""
            switch status {
            case "ok_under_research", "ok_under_research_no_msg":
                onStep?(.waitingForCameraApproval)
                try await Task.sleep(nanoseconds: 1_000_000_000)
            case "err_busy":
                try await Task.sleep(nanoseconds: 1_000_000_000)
            case "ok", "upload_bt", "transfer":
                try requireArgument(fields.count >= 4, "相机会话响应不完整")
                let sessionToken = fields.count > 4 ? fields[4].trimmingCharacters(in: .whitespacesAndNewlines) : nil
                try http.setSession(sessionToken)
                onStep?(.ready)
                let mode = try CameraAccessMode.fromReply(status)
                established = true
                return LumixCameraSession(device: device, http: http, accessMode: mode)
            default:
                throw CameraProtocolException(status)
            }
        }
    }

    private static func accessFields(reply: String, friendlyName: String) throws -> [String] {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            return [try CameraXml.result(trimmed)]
        }
        let fields = trimmed.components(separatedBy: ",")
        if fields.count < 4 || fields[1].caseInsensitiveCompare(friendlyName) == .orderedSame {
            return fields
        }
        if fields.count >= 5 {
            for end in 2..<(fields.count - 2) {
                let candidate = fields[1...end].joined(separator: ",")
                if candidate.caseInsensitiveCompare(friendlyName) == .orderedSame {
                    return [fields[0], candidate] + Array(fields[(end + 1)...])
                }
            }
        }
        return fields
    }

    public func prepareBrowsing(includeRaw: Bool = true) async throws {
        try checkState(accessMode == .browsing, "相机当前处于待发送模式，请结束该模式后重新连接以浏览")
        let playback = try await commandStatus("camcmd", ("value", "playmode"))
        if playback != "ok" {
            throw CameraProtocolException(playback)
        }
        try await prepareRawResources(includeRaw: includeRaw)
    }

    private func prepareRawResources(includeRaw: Bool) async throws {
        let status = try await commandStatus("setsetting", ("type", "raw_img_send"), ("value", includeRaw ? "enable" : "disable"))
        if !["ok", "err_non_support", "err_param"].contains(status) {
            throw CameraProtocolException(status)
        }
    }

    public func browse(objectId: String = "0", offset: Int = 0, count: Int = 50) async throws -> CameraMediaPage {
        try await browseLocked(objectId: objectId, offset: offset, count: count)
    }

    public func browseNewest(objectId: String = "0", beforeOffset: Int? = nil, count: Int = 50) async throws -> CameraMediaPage {
        try checkState(accessMode == .browsing, "待发送模式不支持普通浏览")
        try requireArgument((1...100).contains(count) && (beforeOffset == nil || beforeOffset! > 0), "分页参数无效")
        let summary = try await browseLocked(objectId: objectId, offset: 0, count: 1)
        let end = beforeOffset ?? summary.totalMatches
        try requireArgument(end <= summary.totalMatches, "相机照片列表已更新，请刷新后重新选择")
        if end == 0 {
            return CameraMediaPage(
                entries: summary.entries,
                offset: summary.offset,
                numberReturned: summary.numberReturned,
                totalMatches: summary.totalMatches,
                updateId: summary.updateId,
                newestFirst: true
            )
        }
        let start = max(0, end - count)
        let page = try await browseLocked(objectId: objectId, offset: start, count: end - start)
        try requireArgument(
            page.updateId == summary.updateId &&
            page.totalMatches == summary.totalMatches &&
            page.numberReturned == (end - start),
            "相机照片列表已更新，请刷新后重新选择"
        )
        return CameraMediaPage(
            entries: page.entries.reversed(),
            offset: page.offset,
            numberReturned: page.numberReturned,
            totalMatches: page.totalMatches,
            updateId: page.updateId,
            newestFirst: true
        )
    }

    private func browseLocked(objectId: String, offset: Int, count: Int) async throws -> CameraMediaPage {
        try requireArgument(offset >= 0 && (1...100).contains(count), "分页参数无效")
        let soap = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1" xmlns:pana="urn:schemas-panasonic-com:pana">
        <ObjectID>\(CameraXml.escape(objectId))</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>
        <Filter>*</Filter><StartingIndex>\(offset)</StartingIndex><RequestedCount>\(count)</RequestedCount>
        <SortCriteria></SortCriteria><pana:X_FromCP>LumixLink2.0</pana:X_FromCP>
        </u:Browse></s:Body></s:Envelope>
        """
        let response = try await http.text(
            device.contentDirectory,
            body: soap,
            headers: [
                "Content-Type": "text/xml; charset=\"utf-8\"",
                "SOAPAction": "urn:schemas-upnp-org:service:ContentDirectory:1#Browse"
            ]
        )
        return try CameraXml.browse(response, offset: offset, base: device.contentDirectory)
    }

    public func thumbnail(for resource: CameraResource) async throws -> Data {
        try checkState(accessMode == .browsing, "待发送模式不请求缩略图")
        try requireArgument(resource.kind == .thumbnail, "此资源不是相机缩略图")
        let limit = 4 * 1024 * 1024
        if let bytes = resource.bytes {
            try requireArgument((1...Int64(limit)).contains(bytes), "缩略图尺寸超出限制")
        }
        return try await http.thumbnailBytes(resource.url, limit: limit)
    }

    public func download(_ resource: CameraResource, onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> Data {
        try await http.downloadBytes(resource.url, expectedBytes: resource.bytes, onProgress: onProgress)
    }

    public func keepAlive() async throws {
        let reply = try await http.command("getstate", ("type", "keep_alive"))
        let status = try CameraXml.result(reply)
        if status != "ok" && status != "err_busy" {
            throw CameraProtocolException(status)
        }
    }

    public func close() {
        http.close()
    }

    private func commandStatus(_ mode: String, _ fields: (String, String)...) async throws -> String {
        for attempt in 0..<5 {
            let allFields = [("mode", mode)] + fields
            let query = allFields.map { k, v in "\(k)=\(CameraHttp.encode(v))" }.joined(separator: "&")
            guard let url = URL(string: "http://\(http.endpoint.httpHost)/cam.cgi?\(query)") else {
                throw LumatteError.invalidArgument("无效相机指令")
            }
            let reply = try await http.text(url)
            let status = try CameraXml.result(reply)
            if status != "err_busy" || attempt == 4 {
                return status
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LumatteError.illegalState("无法读取相机状态")
    }
}

// MARK: - Discovered Bluetooth Camera

public struct DiscoveredBleCamera: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int

    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

public struct CameraWifiCredentials: Equatable, Sendable {
    public let ssid: String
    public let password: String
    public let host: String

    public init(ssid: String, password: String, host: String = "192.168.54.1") {
        self.ssid = ssid
        self.password = password
        self.host = host
    }
}

#if canImport(CoreBluetooth)
@MainActor
public final class LumixBluetoothController: NSObject, ObservableObject, @unchecked Sendable {
    @Published public private(set) var isScanning = false
    @Published public private(set) var bluetoothStateDescription = "就绪"
    @Published public private(set) var discoveredCameras: [DiscoveredBleCamera] = []
    @Published public private(set) var wifiCredentials: CameraWifiCredentials?
    @Published public private(set) var statusMessage: String?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var currentChallenge: Int32 = 0
    private var rawSsidBytes: [UInt8]?
    private var rawPasswordBytes: [UInt8]?

    public override init() {
        super.init()
    }

    public func reportStatus(_ message: String) {
        statusMessage = message
    }

    public func startScan() {
        discoveredCameras.removeAll()
        statusMessage = "正在扫描附近的松下相机蓝牙…"
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            isScanning = true
            central?.scanForPeripherals(
                withServices: [CBUUID(string: LumixBleProtocol.serviceUUID)],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    public func stopScan() {
        central?.stopScan()
        isScanning = false
    }

    public func pairAndReadWifi(camera: DiscoveredBleCamera) {
        guard let peripheral = peripherals[camera.id] else {
            statusMessage = "未找到相机蓝牙外设，请重新扫描"
            return
        }
        stopScan()
        activePeripheral = peripheral
        peripheral.delegate = self
        statusMessage = "正在通过蓝牙连接 \(camera.name)…"
        central?.connect(peripheral, options: nil)
    }

    public func joinCameraWifiOniOS(_ credentials: CameraWifiCredentials) async throws {
        #if canImport(NetworkExtension) && os(iOS)
        let config = NEHotspotConfiguration(ssid: credentials.ssid, passphrase: credentials.password, isWEP: false)
        config.joinOnce = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(config) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
        #endif
    }
}

extension LumixBluetoothController: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                bluetoothStateDescription = "蓝牙已开启"
                isScanning = true
                central.scanForPeripherals(
                    withServices: [CBUUID(string: LumixBleProtocol.serviceUUID)],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
            case .poweredOff:
                bluetoothStateDescription = "请开启系统蓝牙"
                isScanning = false
            case .unauthorized:
                bluetoothStateDescription = "请在系统设置中允许蓝牙权限"
                isScanning = false
            default:
                bluetoothStateDescription = "蓝牙状态不可用"
                isScanning = false
            }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "LUMIX Camera"
        let rssiValue = RSSI.intValue
        nonisolated(unsafe) let p = peripheral
        Task { @MainActor in
            peripherals[id] = p
            let entry = DiscoveredBleCamera(id: id, name: name, rssi: rssiValue)
            if let idx = discoveredCameras.firstIndex(where: { $0.id == id }) {
                discoveredCameras[idx] = entry
            } else {
                discoveredCameras.append(entry)
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let p = peripheral
        Task { @MainActor in
            statusMessage = "已连接蓝牙，正在读取 Wi-Fi 传输信息…"
            p.discoverServices([
                CBUUID(string: LumixBleProtocol.serviceUUID),
                CBUUID(string: LumixBleProtocol.wifiServiceUUID)
            ])
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for ch in chars {
            let uuidStr = ch.uuid.uuidString.lowercased()
            if uuidStr == LumixBleProtocol.challengeUUID ||
               uuidStr == LumixBleProtocol.ssidUUID ||
               uuidStr == LumixBleProtocol.passwordUUID {
                peripheral.readValue(for: ch)
            } else if uuidStr == LumixBleProtocol.friendlyNameUUID {
                let data = Data(LumixBleProtocol.appName)
                peripheral.writeValue(data, for: ch, type: .withResponse)
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = Array(data)
        let uuidStr = characteristic.uuid.uuidString.lowercased()
        Task { @MainActor in
            if uuidStr == LumixBleProtocol.challengeUUID {
                if let c = try? LumixBleProtocol.challenge(bytes) {
                    currentChallenge = c
                }
            } else if uuidStr == LumixBleProtocol.ssidUUID {
                rawSsidBytes = bytes
            } else if uuidStr == LumixBleProtocol.passwordUUID {
                rawPasswordBytes = bytes
            }
            if let ssidBytes = rawSsidBytes,
               let pwdBytes = rawPasswordBytes,
               let ssid = try? LumixBleProtocol.decodeSsid(ssidBytes),
               let pwd = try? LumixBleProtocol.decodePassword(pwdBytes, challenge: currentChallenge) {
                wifiCredentials = CameraWifiCredentials(ssid: ssid, password: pwd, host: "192.168.54.1")
                statusMessage = "已获取相机 Wi-Fi：\(ssid)"
            }
        }
    }
}
#endif
