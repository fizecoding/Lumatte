import Foundation

public struct CameraProtocolException: Error, LocalizedError, Equatable, Sendable {
    public let status: String

    public init(_ status: String) {
        self.status = status
    }

    public var errorDescription: String? {
        "相机返回：\(status)"
    }

    public var requiresReconnect: Bool {
        ["HTTP 401", "HTTP 403", "下载 HTTP 401", "下载 HTTP 403",
         "err_reject", "err_user_refused", "err_not_connected", "err_session"].contains(status)
    }
}

// MARK: - CameraAddress

public enum CameraAddress {
    public struct Literal: Equatable, Sendable {
        public let bytes: [UInt8]
        public let scope: String?

        public init(bytes: [UInt8], scope: String? = nil) {
            self.bytes = bytes
            self.scope = scope
        }

        public var ipv6: Bool { bytes.count == 16 }

        public var linkLocal: Bool {
            ipv6 && bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
        }

        public var numeric: String {
            if ipv6 {
                return (0..<8).map { index in
                    let word = (UInt16(bytes[index * 2]) << 8) | UInt16(bytes[index * 2 + 1])
                    return String(word, radix: 16)
                }.joined(separator: ":")
            } else {
                return bytes.map { String($0) }.joined(separator: ".")
            }
        }

        public var httpHost: String {
            ipv6 ? "[\(numeric)]" : numeric
        }
    }

    public static func literal(_ host: String) throws -> Literal {
        try requireArgument((1...128).contains(host.count), "相机地址长度无效")
        let bracketed = host.hasPrefix("[")
        try requireArgument(bracketed == host.hasSuffix("]"), "相机地址括号无效")
        let text = bracketed ? String(host.dropFirst().dropLast()) : host
        if !text.contains(":") {
            let fields = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            try requireArgument(
                fields.count == 4 && fields.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } },
                "相机地址必须是局域网 IP 字面量"
            )
            var bytes: [UInt8] = []
            for f in fields {
                guard let val = Int(f), (0...255).contains(val) else {
                    throw LumatteError.invalidArgument("相机地址必须是局域网 IP 字面量")
                }
                bytes.append(UInt8(val))
            }
            let isSiteLocal = (bytes[0] == 10) ||
                (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168)
            let isLinkLocal = (bytes[0] == 169 && bytes[1] == 254)
            try requireArgument(isSiteLocal || isLinkLocal, "相机地址不在局域网内")
            return Literal(bytes: bytes)
        }

        let ip: String
        let scope: String?
        if let pctIndex = text.firstIndex(of: "%") {
            ip = String(text[..<pctIndex])
            let suffix = String(text[pctIndex...])
            let rawScope: String
            if bracketed && suffix.hasPrefix("%25") {
                rawScope = String(suffix.dropFirst(3))
            } else {
                rawScope = String(suffix.dropFirst(1))
            }
            try requireArgument(
                !rawScope.isEmpty && rawScope.count <= 64 && rawScope.allSatisfy { ch in
                    guard let ascii = ch.asciiValue else { return false }
                    return ch.isLetter || ch.isNumber || ascii == UInt8(ascii: "_") || ascii == UInt8(ascii: ".") || ascii == UInt8(ascii: "-")
                },
                "相机 IPv6 接口标识无效"
            )
            scope = rawScope
        } else {
            ip = text
            scope = nil
        }

        let halves = ip.components(separatedBy: "::")
        try requireArgument((1...2).contains(halves.count), "相机 IPv6 地址无效")
        func parseGroups(_ value: String) throws -> [UInt16] {
            if value.isEmpty { return [] }
            let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            var out: [UInt16] = []
            for group in parts {
                try requireArgument((1...4).contains(group.count), "相机 IPv6 地址无效")
                guard let val = UInt16(group, radix: 16) else {
                    throw LumatteError.invalidArgument("相机 IPv6 地址无效")
                }
                out.append(val)
            }
            return out
        }
        let left = try parseGroups(halves[0])
        let right = halves.count == 2 ? try parseGroups(halves[1]) : []
        let count = left.count + right.count
        try requireArgument(halves.count == 2 ? count < 8 : count == 8, "相机 IPv6 地址无效")
        let words = left + Array(repeating: UInt16(0), count: 8 - count) + right
        var bytes: [UInt8] = []
        for w in words {
            bytes.append(UInt8(w >> 8))
            bytes.append(UInt8(w & 0xFF))
        }
        let isULA = (bytes[0] & 0xFE) == 0xFC
        let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
        try requireArgument(isULA || isLinkLocal, "相机 IPv6 地址必须是 ULA 或链路本地地址")
        return Literal(bytes: bytes, scope: scope)
    }

    public static func requireDescription(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LumatteError.invalidArgument("相机描述地址无效")
        }
        try requireArgument(
            components.scheme == "http" && components.user == nil && components.password == nil && components.fragment == nil,
            "相机描述地址无效"
        )
        guard let host = components.host, !host.isEmpty else {
            throw LumatteError.invalidArgument("缺少相机地址")
        }
        _ = try literal(host)
        if let port = components.port {
            try requireArgument((1...65535).contains(port), "相机端口无效")
        }
    }

    public static func description(_ host: String) throws -> URL {
        let value = try literal(host)
        let scopeSuffix = value.scope.map { "%25\($0)" } ?? ""
        let authority = value.ipv6 ? "[\(value.numeric)\(scopeSuffix)]" : value.numeric
        guard let url = URL(string: "http://\(authority):60606/Lumix/Server0/ddd") else {
            throw LumatteError.invalidArgument("相机描述地址无效")
        }
        return url
    }

    public static func withAuthority(_ url: URL, host: String) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LumatteError.invalidArgument("地址无效")
        }
        let portPart = components.port.map { ":\($0)" } ?? ""
        let rawPath = components.percentEncodedPath
        let rawQuery = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        guard let rebuilt = URL(string: "http://\(host)\(portPart)\(rawPath)\(rawQuery)") else {
            throw LumatteError.invalidArgument("地址无效")
        }
        return rebuilt
    }
}

// MARK: - CameraRouterSsid & CameraSsidCodec

public struct CameraRouterSsid: Equatable, Sendable {
    public let value: String

    public static func parse(_ value: String) throws -> CameraRouterSsid {
        try CameraSsidCodec.validate(value)
        return CameraRouterSsid(value: value)
    }

    public func bluetoothBytes() throws -> [UInt8] {
        let bytes = try CameraSsidCodec.encode(value)
        let utf16Count = value.utf16.count
        let padCount = max(0, 32 - utf16Count)
        return bytes + Array(repeating: 0, count: padCount)
    }
}

public enum CameraSsidCodec {
    public static func validate(_ value: String) throws {
        try requireArgument(
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Wi-Fi 名称不能为空或含换行等控制字符，请按原名称输入"
        )
        for codeUnit in value.utf16 {
            if (0xD800...0xDFFF).contains(codeUnit) {
                throw LumatteError.invalidArgument("Wi-Fi 名称含不完整字符，请重新输入")
            }
        }
        for scalar in value.unicodeScalars {
            if scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value) {
                throw LumatteError.invalidArgument("Wi-Fi 名称不能为空或含换行等控制字符，请按原名称输入")
            }
        }
        try requireArgument(value.utf16.count <= 32, "Wi-Fi 名称最多 32 字节，请勿缩短或截断原名称")
        let encoded = try encode(value)
        try requireArgument((1...32).contains(encoded.count), "Wi-Fi 名称最多 32 字节；中文等字符会占多个字节，请勿缩短或截断原名称")
    }

    public static func encode(_ value: String) throws -> [UInt8] {
        for codeUnit in value.utf16 {
            if (0xD800...0xDFFF).contains(codeUnit) {
                throw LumatteError.invalidArgument("Wi-Fi 名称含不完整字符，请重新输入")
            }
        }
        return Array(value.utf8)
    }

    public static func decode(_ bytes: [UInt8]) throws -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        try requireArgument((1...32).contains(end), "相机返回的 Wi-Fi 名称长度暂不支持")
        let slice = Array(bytes[0..<end])
        guard let decoded = String(bytes: slice, encoding: .utf8) else {
            throw LumatteError.invalidArgument("相机返回的 Wi-Fi 名称不是完整 UTF-8，请使用手动连接入口")
        }
        // Reject UTF-8 replacement character if invalid bytes somehow mapped
        try requireArgument(Array(decoded.utf8) == slice, "相机返回的 Wi-Fi 名称不是完整 UTF-8，请使用手动连接入口")
        try validate(decoded)
        return decoded
    }
}

// MARK: - LumixBleProtocol

public struct CameraConnectionAddress: Equatable, Sendable {
    public let value: String
    public init(_ value: String) {
        self.value = value
    }
}

public enum LumixBleProtocol {
    public static let serviceUUID = "054ac620-3214-11e6-ac0d-0002a5d5c51b"
    public static let clientIdUUID = "8d08a420-3213-11e6-8aca-0002a5d5c51b"
    public static let friendlyNameUUID = "cd7a71a0-3213-11e6-8f56-0002a5d5c51b"
    public static let apsClientIdUUID = "bb5d2a8c-5d3b-43ad-bfc3-470cad55c1ca"
    public static let apsFriendlyNameUUID = "7b61774f-efb4-44c6-a66d-c69e3b384c4a"
    public static let challengeUUID = "03e23a31-a54c-40fa-a668-de9acdc910bb"
    public static let ssidUUID = "e206a5c0-3214-11e6-afe4-0002a5d5c51b"
    public static let passwordUUID = "c97cf1a5-3c03-4290-8c1b-9e74b9500f54"
    public static let wifiServiceUUID = "5ae57260-3214-11e6-979e-0002a5d5c51b"
    public static let wifiConnectionTypeUUID = "0d6f1880-3217-11e6-a4cb-0002a5d5c51b"
    public static let wifiChoiceReplyUUID = "18345be1-3217-11e6-b56c-0002a5d5c51b"
    public static let routerSsidUUID = "18345be0-3217-11e6-b56c-0002a5d5c51b"
    public static let connectionModeUUID = "e182ec40-3213-11e6-ab07-0002a5d5c51b"
    public static let connectionStatusUUID = "e182ec41-3213-11e6-ab07-0002a5d5c51b"
    public static let sendingServiceUUID = "6b005f20-3214-11e6-a5ac-0002a5d5c51b"
    public static let connectionAddressUUID = "e1392720-3215-11e6-a035-0002a5d5c51b"
    public static let imageTransferEventUUID = "48669da0-3217-11e6-b08d-0002a5d5c51b"
    public static let sendingModeEventUUID = "e182ec43-3213-11e6-ab07-0002a5d5c51b"

    public static let appName: [UInt8] = Array("Lumix FilmMirror".utf8)

    public static func identity(_ id: String) throws -> [UInt8] {
        guard let uuid = UUID(uuidString: id) else {
            throw LumatteError.invalidArgument("无效的客户端标识 UUID")
        }
        return withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    public static func challenge(_ bytes: [UInt8]) throws -> Int32 {
        try requireArgument(bytes.count >= 4, "相机返回的蓝牙连接资料不完整")
        let word = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return Int32(bitPattern: word)
    }

    private static func key(_ challenge: Int32) -> UInt32 {
        let resolved: Int32 = challenge == 0 ? -1875740628 : challenge
        return UInt32(bitPattern: resolved)
    }

    public static func encode(_ bytes: [UInt8], challenge: Int32) throws -> [UInt8] {
        try requireArgument(bytes.count <= 19, "蓝牙编码数据过长")
        var plain = [UInt8](repeating: 0xFF, count: 20)
        plain[0] = UInt8(bytes.count)
        for (i, b) in bytes.enumerated() {
            plain[1 + i] = b
        }
        let k = key(challenge)
        var output: [UInt8] = []
        output.reserveCapacity(20)
        for wordIndex in 0..<5 {
            let base = wordIndex * 4
            let leWord = UInt32(plain[base]) |
                (UInt32(plain[base + 1]) << 8) |
                (UInt32(plain[base + 2]) << 16) |
                (UInt32(plain[base + 3]) << 24)
            let xored = leWord ^ k
            // Write big-endian (matching ByteBuffer.allocate(20).putInt(...))
            output.append(UInt8((xored >> 24) & 0xFF))
            output.append(UInt8((xored >> 16) & 0xFF))
            output.append(UInt8((xored >> 8) & 0xFF))
            output.append(UInt8(xored & 0xFF))
        }
        return output
    }

    public static func decodePassword(_ bytes: [UInt8], challenge: Int32) throws -> String {
        try requireArgument(!bytes.isEmpty && bytes.count <= 512 && bytes.count % 4 == 0, "相机返回的 Wi-Fi 资料格式暂不支持")
        let k = key(challenge)
        var decoded = [UInt8](repeating: 0, count: bytes.count)
        for wordIndex in 0..<(bytes.count / 4) {
            let base = wordIndex * 4
            let beWord = (UInt32(bytes[base]) << 24) |
                (UInt32(bytes[base + 1]) << 16) |
                (UInt32(bytes[base + 2]) << 8) |
                UInt32(bytes[base + 3])
            let xored = beWord ^ k
            decoded[base] = UInt8(xored & 0xFF)
            decoded[base + 1] = UInt8((xored >> 8) & 0xFF)
            decoded[base + 2] = UInt8((xored >> 16) & 0xFF)
            decoded[base + 3] = UInt8((xored >> 24) & 0xFF)
        }
        let end = (1..<decoded.count).first(where: { decoded[$0] == 0xFF }) ?? decoded.count
        var chars = ""
        for idx in 1..<end {
            chars.append(Character(UnicodeScalar(decoded[idx])))
        }
        return javaTrim(chars)
    }

    public static func decodeSsid(_ bytes: [UInt8]) throws -> String {
        try CameraSsidCodec.decode(bytes)
    }

    public static func routerSsid(_ value: CameraRouterSsid) throws -> [UInt8] {
        try value.bluetoothBytes()
    }

    public static func decodeConnectionAddress(_ bytes: [UInt8]) throws -> CameraConnectionAddress {
        try requireArgument(!bytes.isEmpty && bytes.count <= 64 && bytes.allSatisfy { $0 <= 127 }, "相机返回的连接地址格式暂不支持")
        let str = String(decoding: bytes, as: UTF8.self)
        return CameraConnectionAddress(javaTrim(str))
    }

    private static func javaTrim(_ str: String) -> String {
        var scalars = Array(str.unicodeScalars)
        while let first = scalars.first, first.value <= 0x20 {
            scalars.removeFirst()
        }
        while let last = scalars.last, last.value <= 0x20 {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

// MARK: - CameraProtocolInfo

public struct CameraResourceDescription: Equatable, Sendable {
    public let mimeType: String
    public let profile: String?
    public let originalName: String?

    public init(mimeType: String, profile: String?, originalName: String?) {
        self.mimeType = mimeType
        self.profile = profile
        self.originalName = originalName
    }
}

public enum CameraProtocolInfo {
    public static func parse(_ value: String) -> CameraResourceDescription {
        let parsedFields = fields(value)
        if parsedFields.count < 3 {
            return CameraResourceDescription(mimeType: "", profile: nil, originalName: nil)
        }
        let mime: String
        let attributes: String
        if parsedFields.count == 4 {
            mime = parsedFields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            attributes = parsedFields[3]
        } else {
            let tail = parsedFields[2].split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            mime = tail[0].trimmingCharacters(in: .whitespacesAndNewlines)
            attributes = tail.count > 1 ? tail[1] : ""
        }
        let props = properties(attributes)
        return CameraResourceDescription(
            mimeType: mime,
            profile: props["PANASONIC.COM_PN"],
            originalName: props["ORIGINALFILENAME"]
        )
    }

    private static func fields(_ value: String) -> [String] {
        let chars = Array(value)
        var result: [String] = []
        var start = 0
        var quote: Character? = nil
        var previous: Character? = nil
        for index in chars.indices {
            let ch = chars[index]
            if let q = quote {
                if ch == q {
                    var next = index + 1
                    while next < chars.count && chars[next].isWhitespace { next += 1 }
                    if next == chars.count || chars[next] == ";" || chars[next] == ":" {
                        quote = nil
                    }
                }
            } else if (ch == "'" || ch == "\"") && previous == "=" {
                quote = ch
            } else if ch == ":" {
                result.append(String(chars[start..<index]))
                start = index + 1
                if result.count == 3 { break }
            }
            if !ch.isWhitespace {
                previous = ch
            }
        }
        result.append(String(chars[start...]))
        return result
    }

    private static func properties(_ value: String) -> [String: String] {
        let chars = Array(value)
        var result: [String: String] = [:]
        var offset = 0
        while offset < chars.count {
            while offset < chars.count && (chars[offset].isWhitespace || chars[offset] == ";") { offset += 1 }
            let keyStart = offset
            while offset < chars.count && chars[offset] != "=" && chars[offset] != ";" { offset += 1 }
            if offset == chars.count { break }
            if chars[offset] == ";" { offset += 1; continue }
            let key = String(chars[keyStart..<offset]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            offset += 1
            while offset < chars.count && chars[offset].isWhitespace { offset += 1 }
            let start = offset
            let quote: Character? = (start < chars.count && (chars[start] == "'" || chars[start] == "\"")) ? chars[start] : nil
            var end = start
            var quotedEnd: Int? = nil
            if let q = quote {
                end += 1
                while end < chars.count {
                    if chars[end] == q {
                        var next = end + 1
                        while next < chars.count && chars[next].isWhitespace { next += 1 }
                        if next == chars.count || chars[next] == ";" {
                            quotedEnd = end
                            break
                        }
                    }
                    end += 1
                }
            }
            if let qEnd = quotedEnd {
                result[key] = String(chars[(start + 1)..<qEnd])
                offset = qEnd + 1
            } else if quote != nil {
                result[key] = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                offset = chars.count
            } else {
                if let semi = chars[start...].firstIndex(of: ";") {
                    end = semi
                } else {
                    end = chars.count
                }
                result[key] = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                offset = end
            }
        }
        return result
    }
}

// MARK: - CameraAccessMode & CameraIncomingDirectory

public enum CameraAccessMode: String, CaseIterable, Codable, Sendable {
    case browsing = "ok"
    case autoUpload = "upload_bt"
    case markedTransfer = "transfer"

    public var incoming: Bool { self != .browsing }

    public static func fromReply(_ reply: String) throws -> CameraAccessMode {
        guard let mode = allCases.first(where: { $0.rawValue == reply }) else {
            throw CameraProtocolException(reply)
        }
        return mode
    }
}

public struct CameraIncomingDirectory: Equatable, Sendable {
    public static let markedObjectId = "dir_id_mark_list"

    public let mode: CameraAccessMode
    public let objectId: String

    public init(mode: CameraAccessMode, objectId: String) throws {
        let trimmed = objectId.trimmingCharacters(in: .whitespacesAndNewlines)
        try requireArgument(mode.incoming && !trimmed.isEmpty && trimmed != "0", "待发送目录无效")
        try requireArgument(mode != .markedTransfer || objectId == Self.markedObjectId, "相机选定发送目录必须为 dir_id_mark_list")
        self.mode = mode
        self.objectId = objectId
    }
}

// MARK: - CameraMedia

public struct CameraDevice: Equatable, Sendable {
    public let descriptionURL: URL
    public let friendlyName: String
    public let model: String
    public let firmware: String
    public let udn: String
    public let requiresChallenge: Bool
    public let contentDirectory: URL

    public init(
        descriptionURL: URL,
        friendlyName: String,
        model: String,
        firmware: String,
        udn: String,
        requiresChallenge: Bool,
        contentDirectory: URL
    ) {
        self.descriptionURL = descriptionURL
        self.friendlyName = friendlyName
        self.model = model
        self.firmware = firmware
        self.udn = udn
        self.requiresChallenge = requiresChallenge
        self.contentDirectory = contentDirectory
    }
}

public enum CameraResourceKind: String, Codable, Sendable {
    case originalJpeg
    case rawPreviewJpeg
    case thumbnail
    case raw
    case video
    case unknown
}

public struct CameraResource: Equatable, Sendable {
    public let url: URL
    public let mimeType: String
    public let profile: String?
    public let originalName: String?
    public let bytes: Int64?

    public init(url: URL, mimeType: String, profile: String?, originalName: String?, bytes: Int64?) {
        self.url = url
        self.mimeType = mimeType
        self.profile = profile
        self.originalName = originalName
        self.bytes = bytes
    }

    private var profileName: String? {
        profile?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var contentType: String {
        mimeType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public var kind: CameraResourceKind {
        let name = profileName
        let ct = contentType.lowercased()
        if (name == "CAM_ORG" && ct == "image/jpeg") || name == "CAM_HSP_JPG" {
            return .originalJpeg
        }
        if name == "CAM_RAW_JPG" || name == "CAM_HSP_RAW_JPG" {
            return .rawPreviewJpeg
        }
        if name == "CAM_TN" || name == "CAM_LRGTN" {
            return .thumbnail
        }
        if name == "CAM_RAW" || name == "CAM_HSP_RAW" {
            return .raw
        }
        if ct.hasPrefix("video/") || name?.hasPrefix("CAM_AVC_") == true || name == "CAM_FOCUS_SELECT_MP4" ||
            (ct == "application/octet-stream" && name?.contains("IFRAME") == true) {
            return .video
        }
        return .unknown
    }

    public var videoContainer: VideoContainer? {
        guard kind == .video else { return nil }
        let name = profileName
        if name?.contains("IFRAME") == true { return nil }
        let ct = contentType.lowercased()
        if name?.hasPrefix("CAM_AVC_MOV_") == true { return .mov }
        if name?.hasPrefix("CAM_AVC_TS_HP_") == true { return .mpegTs }
        if name?.hasPrefix("CAM_AVC_MP4_") == true || name == "CAM_FOCUS_SELECT_MP4" { return .mp4 }
        if ct == "video/quicktime" { return .mov }
        if ct == "video/mp4" { return .mp4 }
        if ct == "video/mp2t" || ct == "video/vnd.dlna.mpeg-tts" { return .mpegTs }
        return nil
    }
}

public struct CameraMedia: Equatable, Identifiable, Sendable {
    public let id: String
    public let parentId: String
    public let title: String
    public let isFolder: Bool
    public let resources: [CameraResource]
    public let mediaClass: String?

    public init(
        id: String,
        parentId: String,
        title: String,
        isFolder: Bool,
        resources: [CameraResource],
        mediaClass: String? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.title = title
        self.isFolder = isFolder
        self.resources = resources
        self.mediaClass = mediaClass
    }

    public var isVideo: Bool {
        let declared = (mediaClass ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return declared == "object.item.videoitem" ||
            declared.hasPrefix("object.item.videoitem.") ||
            resources.contains(where: { $0.kind == .video })
    }

    public var editableResource: CameraResource? {
        guard !isVideo else { return nil }
        return resources.first(where: { $0.kind == .originalJpeg })
            ?? resources.first(where: { $0.kind == .rawPreviewJpeg })
            ?? resources.first(where: { $0.kind == .raw })
    }

    public var thumbnailResources: [CameraResource] {
        var result: [CameraResource] = []
        if let lrg = resources.first(where: { $0.profile?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("CAM_LRGTN") == .orderedSame }) {
            result.append(lrg)
        }
        if let tn = resources.first(where: { $0.profile?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("CAM_TN") == .orderedSame }),
           !result.contains(where: { $0.url == tn.url }) {
            result.append(tn)
        }
        return result
    }

    public var thumbnail: CameraResource? { thumbnailResources.first }

    public var videoResource: CameraResource? {
        resources.first(where: { $0.videoContainer != nil && $0.profile?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasSuffix("_ORG") == true })
            ?? resources.first(where: { $0.videoContainer != nil })
    }

    public var transferResource: CameraResource? {
        isVideo ? videoResource : editableResource
    }
}

public struct CameraMediaPage: Equatable, Sendable {
    public let entries: [CameraMedia]
    public let offset: Int
    public let numberReturned: Int
    public let totalMatches: Int
    public let updateId: String?
    public let newestFirst: Bool

    public init(
        entries: [CameraMedia],
        offset: Int,
        numberReturned: Int,
        totalMatches: Int,
        updateId: String?,
        newestFirst: Bool = false
    ) {
        self.entries = entries
        self.offset = offset
        self.numberReturned = numberReturned
        self.totalMatches = totalMatches
        self.updateId = updateId
        self.newestFirst = newestFirst
    }

    public var nextOffset: Int? {
        if newestFirst {
            return offset > 0 ? offset : nil
        } else {
            return (numberReturned > 0 && (offset + numberReturned) < totalMatches) ? (offset + numberReturned) : nil
        }
    }
}

// MARK: - CameraXml

public enum CameraXml {
    private static func ensureNoDoctype(_ xml: String) throws {
        try requireArgument(!xml.localizedCaseInsensitiveContains("<!DOCTYPE"), "不支持带外部声明的相机 XML")
    }

    public static func result(_ xml: String) throws -> String {
        let trimmed = xml.drop(while: { $0.isWhitespace })
        if !trimmed.hasPrefix("<") {
            return String(trimmed.prefix(while: { $0 != "," })).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try ensureNoDoctype(xml)
        let collector = SimpleTagCollector(targetTags: ["result"])
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        parser.parse()
        guard let res = collector.values["result"] else {
            throw CameraProtocolException("响应缺少 result")
        }
        return res.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func requireOk(_ xml: String) throws {
        let status = try result(xml)
        if status != "ok" {
            throw CameraProtocolException(status)
        }
    }

    public static func contentCount(_ xml: String) throws -> Int {
        try requireOk(xml)
        let trimmed = xml.drop(while: { $0.isWhitespace })
        try requireArgument(trimmed.hasPrefix("<"), "待发送数量响应格式尚不支持")
        try ensureNoDoctype(xml)
        let collector = ContentCountCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        parser.parse()
        if let err = collector.error { throw err }
        guard let count = collector.count else {
            throw LumatteError.invalidArgument("响应缺少待发送数量")
        }
        if count == 0xFFFF_FFFF {
            throw CameraProtocolException("err_busy")
        }
        try requireArgument((0...Int64(Int.max)).contains(count), "待发送数量超出范围")
        return Int(count)
    }

    public static func device(_ xml: String, description: URL) throws -> CameraDevice {
        try ensureNoDoctype(xml)
        let collector = DeviceXmlCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        parser.parse()

        let modelRegex = try! NSRegularExpression(pattern: "^(?:DC|DMC)-[A-Za-z0-9-]{1,24}$", options: [.caseInsensitive])
        let modelNumber = collector.values["modelNumber"] ?? ""
        let matchesModelNumber = modelRegex.firstMatch(
            in: modelNumber,
            options: [],
            range: NSRange(modelNumber.startIndex..<modelNumber.endIndex, in: modelNumber)
        ) != nil
        let model = matchesModelNumber ? modelNumber : (collector.values["modelName"] ?? "")
        try requireArgument(!model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "未读取到相机型号")

        let manufacturer = collector.values["manufacturer"] ?? ""
        let isPanasonic = manufacturer.localizedCaseInsensitiveContains("Panasonic") &&
            (collector.values["X_CamCapability"] != nil ||
             collector.values["X_CamCategory"] != nil ||
             model.lowercased().hasPrefix("dc-") ||
             model.lowercased().hasPrefix("dmc-") ||
             description.path.hasPrefix("/Lumix/"))
        try requireArgument(isPanasonic, "发现的设备不是松下相机")

        let base = collector.urlBase ?? description
        let controlPath = collector.contentUrl ?? "/Server0/CDS_control"
        guard let contentDirectory = URL(string: controlPath, relativeTo: base)?.absoluteURL else {
            throw LumatteError.invalidArgument("无法解析相机内容目录地址")
        }
        return CameraDevice(
            descriptionURL: description,
            friendlyName: collector.values["friendlyName"] ?? "",
            model: model,
            firmware: collector.values["X_FirmVersion"] ?? "",
            udn: collector.values["UDN"] ?? "",
            requiresChallenge: collector.values["X_CamCapability"]?.hasSuffix("1") == true,
            contentDirectory: contentDirectory
        )
    }

    public static func browse(_ xml: String, offset: Int, base: URL) throws -> CameraMediaPage {
        try ensureNoDoctype(xml)
        let collector = SimpleTagCollector(targetTags: ["Result", "NumberReturned", "TotalMatches", "UpdateID", "faultstring"])
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        parser.parse()

        if let fault = collector.values["faultstring"] {
            throw CameraProtocolException(fault)
        }
        guard let returnedStr = collector.values["NumberReturned"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let returned = Int(returnedStr) else {
            throw LumatteError.invalidArgument("缺少浏览数量")
        }
        guard let totalStr = collector.values["TotalMatches"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let total = Int(totalStr) else {
            throw LumatteError.invalidArgument("缺少媒体总数")
        }
        try requireArgument(returned >= 0 && total >= 0, "浏览数量无效")
        let entries = try didl(collector.values["Result"] ?? "", base: base)
        try requireArgument(entries.count == returned, "媒体列表与返回数量不一致")
        return CameraMediaPage(
            entries: entries,
            offset: offset,
            numberReturned: returned,
            totalMatches: total,
            updateId: collector.values["UpdateID"]
        )
    }

    private static func didl(_ xml: String, base: URL) throws -> [CameraMedia] {
        if xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        try ensureNoDoctype(xml)
        let collector = DidlCollector(base: base)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        parser.parse()
        if let err = collector.error { throw err }
        return collector.items
    }

    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - XML Delegates

private final class SimpleTagCollector: NSObject, XMLParserDelegate {
    let targetTags: Set<String>
    var values: [String: String] = [:]
    private var currentTag: String?
    private var currentText = ""

    init(targetTags: Set<String>) {
        self.targetTags = targetTags
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if targetTags.contains(local) {
            currentTag = local
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentTag != nil {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if let tag = currentTag, tag == local {
            values[tag] = currentText
            currentTag = nil
        }
    }
}

private final class ContentCountCollector: NSObject, XMLParserDelegate {
    var count: Int64?
    var error: Error?
    private var inTarget = false
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName.caseInsensitiveCompare("total_content_number") == .orderedSame {
            if count != nil {
                error = LumatteError.invalidArgument("待发送数量响应重复")
                parser.abortParsing()
                return
            }
            inTarget = true
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTarget { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if inTarget && elementName.caseInsensitiveCompare("total_content_number") == .orderedSame {
            inTarget = false
            guard let parsed = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                error = LumatteError.invalidArgument("待发送数量无效")
                parser.abortParsing()
                return
            }
            count = parsed
        }
    }
}

private final class DeviceXmlCollector: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    var contentUrl: String?
    var urlBase: URL?
    private var currentService: [String: String]?
    private var currentTag: String?
    private var currentText = ""

    private let trackedKeys: Set<String> = [
        "manufacturer", "friendlyName", "modelName", "modelNumber",
        "X_FirmVersion", "UDN", "X_CamCapability", "X_CamCategory",
        "serviceType", "controlURL", "URLBase"
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "service" {
            currentService = [:]
        } else if trackedKeys.contains(local) {
            currentTag = local
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentTag != nil { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "service" {
            if currentService?["serviceType"] == "urn:schemas-upnp-org:service:ContentDirectory:1" {
                contentUrl = currentService?["controlURL"]
            }
            currentService = nil
        } else if let tag = currentTag, tag == local {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag == "serviceType" || tag == "controlURL" {
                currentService?[tag] = trimmed
            } else if tag == "URLBase" {
                urlBase = URL(string: trimmed)
            } else if values[tag] == nil {
                values[tag] = trimmed
            }
            currentTag = nil
        }
    }
}

private final class DidlCollector: NSObject, XMLParserDelegate {
    let base: URL
    var items: [CameraMedia] = []
    var error: Error?

    private var currentId: String?
    private var currentParent = ""
    private var currentFolder = false
    private var currentTitle = ""
    private var currentClass: String?
    private var currentResources: [CameraResource] = []

    private var activeElement: String?
    private var activeNamespace: String?
    private var activeProtocolInfo: String = ""
    private var activeSize: Int64?
    private var activeText = ""

    init(base: URL) {
        self.base = base
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        switch local {
        case "item", "container":
            guard let id = attributeDict["id"] else {
                error = LumatteError.invalidArgument("媒体条目缺少 id")
                parser.abortParsing()
                return
            }
            currentId = id
            currentParent = attributeDict["parentID"] ?? ""
            currentFolder = (local == "container")
            currentTitle = ""
            currentClass = nil
            currentResources = []
        case "title", "class", "res":
            if currentId != nil {
                activeElement = local
                activeNamespace = namespaceURI
                activeText = ""
                if local == "res" {
                    activeProtocolInfo = attributeDict["protocolInfo"] ?? ""
                    if let s = attributeDict["size"], let v = Int64(s), v >= 0 {
                        activeSize = v
                    } else {
                        activeSize = nil
                    }
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeElement != nil {
            activeText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if local == "item" || local == "container" {
            if let id = currentId {
                items.append(CameraMedia(
                    id: id,
                    parentId: currentParent,
                    title: currentTitle,
                    isFolder: currentFolder,
                    resources: currentResources,
                    mediaClass: currentClass
                ))
            }
            currentId = nil
        } else if let active = activeElement, active == local {
            switch active {
            case "title":
                currentTitle = activeText
            case "class":
                if activeNamespace == "urn:schemas-upnp-org:metadata-1-0/upnp/" {
                    let trimmed = activeText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { currentClass = trimmed }
                }
            case "res":
                let info = CameraProtocolInfo.parse(activeProtocolInfo)
                let uriStr = activeText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let resourceUrl = URL(string: uriStr, relativeTo: base)?.absoluteURL {
                    currentResources.append(CameraResource(
                        url: resourceUrl,
                        mimeType: info.mimeType,
                        profile: info.profile,
                        originalName: info.originalName,
                        bytes: activeSize
                    ))
                }
            default:
                break
            }
            activeElement = nil
        }
    }
}
