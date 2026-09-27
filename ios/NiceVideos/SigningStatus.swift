import Foundation

/// Advisory metadata only. This does not verify a CMS signature, certificate
/// revocation, or whether iOS will allow the app to launch.
struct SigningProfile: Equatable, Sendable {
    let expirationDate: Date
    let creationDate: Date?
    let identifier: String?
}

enum SigningStatus: Equatable, Sendable {
    case loading
    case available(SigningProfile)
    case unavailable(String)

    var expirationDate: Date? {
        guard case let .available(profile) = self else { return nil }
        return profile.expirationDate
    }
}

enum SigningUrgency: Equatable {
    case normal, warning, urgent, expired

    static func resolve(expiration: Date, now: Date) -> SigningUrgency {
        let remaining = expiration.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining <= 24 * 3600 { return .urgent }
        if remaining <= 48 * 3600 { return .warning }
        return .normal
    }
}

enum SigningCountdown {
    static func text(expiration: Date, now: Date) -> String {
        let seconds = expiration.timeIntervalSince(now)
        guard seconds.isFinite else { return "无法确定" }
        guard seconds > 0 else { return "已到期" }
        if seconds < 60 { return "不足 1 分钟" }
        // Round down, not up: never suggest more usable time than remains.
        let minutes = Int(min(seconds / 60, Double(Int.max / 2)))
        if minutes >= 24 * 60 {
            return "\(minutes / (24 * 60)) 天 \((minutes / 60) % 24) 小时"
        }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }
}

enum SigningProfileError: Error, Equatable {
    case tooLarge, malformedCMS, missingExpiration, invalidDates, wrongApplication
}

/// A bounded BER/DER reader for CMS encapsulated content, not an XML substring
/// search. Accepts definite and indefinite constructed OCTET STRINGs. Unsupported
/// profile formats fail closed to "unknown"; they never become an expiry guess.
private struct SigningASN1Reader {
    struct Node {
        let tag: UInt8
        let content: Range<Int>
        let children: [Node]
    }
    let bytes: [UInt8]
    var nodes = 0

    mutating func read(_ offset: inout Int, end: Int, depth: Int = 0) throws -> Node {
        guard depth < 24, nodes < 20_000, offset < end else {
            throw SigningProfileError.malformedCMS
        }
        nodes += 1
        let tag = bytes[offset]
        offset += 1
        // No high-tag-number values are needed by this CMS envelope.
        guard tag != 0, tag & 0x1f != 0x1f, offset < end else {
            throw SigningProfileError.malformedCMS
        }
        let firstLength = bytes[offset]
        offset += 1
        let constructed = tag & 0x20 != 0
        var children: [Node] = []
        if firstLength == 0x80 {
            guard constructed else { throw SigningProfileError.malformedCMS }
            let start = offset
            while offset + 1 < end {
                if bytes[offset] == 0 && bytes[offset + 1] == 0 {
                    let contentEnd = offset
                    offset += 2
                    return Node(tag: tag, content: start..<contentEnd, children: children)
                }
                children.append(try read(&offset, end: end, depth: depth + 1))
            }
            throw SigningProfileError.malformedCMS
        }
        var length = Int(firstLength)
        if firstLength & 0x80 != 0 {
            let count = Int(firstLength & 0x7f)
            guard count > 0, count <= 4, count <= end - offset else {
                throw SigningProfileError.malformedCMS
            }
            length = 0
            for _ in 0..<count {
                length = length * 256 + Int(bytes[offset])
                offset += 1
            }
        }
        guard length <= end - offset else { throw SigningProfileError.malformedCMS }
        let start = offset
        let stop = offset + length
        if constructed {
            while offset < stop {
                children.append(try read(&offset, end: stop, depth: depth + 1))
            }
        } else { offset = stop }
        return Node(tag: tag, content: start..<stop, children: children)
    }

    func octets(_ node: Node) throws -> Data {
        if node.tag == 0x04 { return Data(bytes[node.content]) }
        guard node.tag == 0x24 else { throw SigningProfileError.malformedCMS }
        var result = Data()
        for child in node.children { result.append(try octets(child)) }
        return result
    }
}

enum SigningProfileReader {
    static let maximumSize = 4 * 1024 * 1024

    static func readInstalledProfile() -> SigningStatus {
        #if targetEnvironment(simulator)
        return .unavailable("模拟器没有设备签名描述文件，请在真机上查看。")
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return .unavailable("未找到签名描述文件，无法确定到期时间；这不代表已过期或永久有效。")
        }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maximumSize else { throw SigningProfileError.tooLarge }
            let data = try Data(contentsOf: url)
            let profile = try parse(data, bundleIdentifier: Bundle.main.bundleIdentifier)
            return .available(profile)
        } catch {
            // Never log a profile: it can contain device IDs and team metadata.
            return .unavailable("无法读取签名到期时间，请通过 Xcode 检查签名。不会影响本地视频播放。")
        }
        #endif
    }

    static func parse(_ data: Data, bundleIdentifier: String? = nil) throws -> SigningProfile {
        guard data.count <= maximumSize else { throw SigningProfileError.tooLarge }
        var reader = SigningASN1Reader(bytes: Array(data))
        var offset = 0
        let root = try reader.read(&offset, end: data.count)
        let signedDataOID: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02]
        let dataOID: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01]
        guard offset == data.count, root.tag == 0x30, root.children.count == 2,
              root.children[0].tag == 0x06,
              Array(reader.bytes[root.children[0].content]) == signedDataOID,
              root.children[1].tag == 0xa0, root.children[1].children.count == 1 else {
            throw SigningProfileError.malformedCMS
        }
        let signed = root.children[1].children[0]
        guard signed.tag == 0x30, signed.children.count >= 4,
              signed.children[0].tag == 0x02, signed.children[1].tag == 0x31,
              signed.children.last?.tag == 0x31 else { throw SigningProfileError.malformedCMS }
        let encapsulated = signed.children[2]
        guard encapsulated.tag == 0x30, encapsulated.children.count == 2,
              encapsulated.children[0].tag == 0x06,
              Array(reader.bytes[encapsulated.children[0].content]) == dataOID,
              encapsulated.children[1].tag == 0xa0,
              encapsulated.children[1].children.count == 1 else { throw SigningProfileError.malformedCMS }
        let plistData = try reader.octets(encapsulated.children[1].children[0])
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let expiration = plist["ExpirationDate"] as? Date,
              expiration.timeIntervalSince1970.isFinite else { throw SigningProfileError.missingExpiration }
        let creation = plist["CreationDate"] as? Date
        if let creation, !creation.timeIntervalSince1970.isFinite || creation >= expiration {
            throw SigningProfileError.invalidDates
        }
        if let bundleIdentifier,
           let entitlements = plist["Entitlements"] as? [String: Any],
           let appID = entitlements["application-identifier"] as? String {
            guard let dot = appID.firstIndex(of: ".") else { throw SigningProfileError.wrongApplication }
            let pattern = String(appID[appID.index(after: dot)...])
            let matches = pattern == bundleIdentifier || pattern == "*" ||
                (pattern.hasSuffix(".*") && bundleIdentifier.hasPrefix(String(pattern.dropLast())))
            guard matches else { throw SigningProfileError.wrongApplication }
        }
        return SigningProfile(expirationDate: expiration, creationDate: creation,
                              identifier: plist["UUID"] as? String)
    }
}
