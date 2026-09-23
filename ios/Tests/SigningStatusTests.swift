import Foundation
import XCTest
#if canImport(NiceVideos)
@testable import NiceVideos
#else
@testable import SigningCore
#endif

final class SigningStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDERXMLProfileReadsActualExpirationNotInstallationTime() throws {
        let expiration = now.addingTimeInterval(54 * 3600)
        let profile = try SigningProfileReader.parse(cms(expiration: expiration), bundleIdentifier: "com.anxiong.nicevideos")
        XCTAssertEqual(profile.expirationDate, expiration)
        XCTAssertEqual(profile.identifier, "synthetic-test-profile")
        XCTAssertEqual(SigningCountdown.text(expiration: expiration, now: now), "2 天 6 小时")
    }

    func testBinaryPlistAndConstructedIndefiniteBER() throws {
        for binary in [false, true] {
            let profile = try SigningProfileReader.parse(cms(expiration: now, binary: binary, ber: true))
            XCTAssertEqual(profile.expirationDate, now)
        }
    }

    func testRejectsBareXMLAndXMLHiddenOutsideCMSPayload() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": now], format: .xml, options: 0)
        XCTAssertThrowsError(try SigningProfileReader.parse(xml))
        XCTAssertThrowsError(try SigningProfileReader.parse(Data([0x04, 0x01, 0x00]) + xml))
        XCTAssertThrowsError(try SigningProfileReader.parse(cms(expiration: now) + xml))
    }

    func testRejectsMissingAndStringExpiration() throws {
        for value in [nil, "2026-09-23" as Any?] {
            XCTAssertThrowsError(try SigningProfileReader.parse(cms(expiration: value)))
        }
    }

    func testRejectsImpossibleDates() throws {
        XCTAssertThrowsError(try SigningProfileReader.parse(cms(expiration: now, creation: now)))
        XCTAssertThrowsError(try SigningProfileReader.parse(cms(expiration: now, creation: now.addingTimeInterval(1))))
    }

    func testValidatesBundleIDIncludingWildcardProfiles() throws {
        for appID in ["TEAM.com.anxiong.nicevideos", "TEAM.com.anxiong.*", "TEAM.*"] {
            XCTAssertNoThrow(try SigningProfileReader.parse(cms(expiration: now, appID: appID),
                                                           bundleIdentifier: "com.anxiong.nicevideos"))
        }
        for appID in ["TEAM.com.other.app", "TEAM.com.anxiong.*", "invalid"] {
            XCTAssertThrowsError(try SigningProfileReader.parse(cms(expiration: now, appID: appID),
                                                               bundleIdentifier: "com.anxiongEVIL.nicevideos"))
        }
    }

    func testRejectsTruncatedLengthOversizeAndMalformedBER() throws {
        let valid = try cms(expiration: now)
        for size in [0, 1, 2, 8, valid.count - 1] {
            XCTAssertThrowsError(try SigningProfileReader.parse(Data(valid.prefix(size))))
        }
        for bytes: [UInt8] in [[0x30, 0x84, 0xff, 0xff, 0xff, 0xff],
                              [0x04, 0x80, 0, 0], [0x30, 0x80, 0x30, 0x80],
                              [0x30, 0x85, 0, 0, 0, 0, 0], [0x1f, 0x00]] {
            XCTAssertThrowsError(try SigningProfileReader.parse(Data(bytes)))
        }
        XCTAssertThrowsError(try SigningProfileReader.parse(Data(count: SigningProfileReader.maximumSize + 1)))
        var deep = Data([0x04, 0])
        for _ in 0..<30 { deep = tlv(0x30, deep) }
        XCTAssertThrowsError(try SigningProfileReader.parse(deep))
    }

    func testExpiredProfileIsRepresentedWithoutPreventingPlayback() throws {
        let expiration = now.addingTimeInterval(-10)
        let profile = try SigningProfileReader.parse(cms(expiration: expiration))
        XCTAssertEqual(SigningCountdown.text(expiration: profile.expirationDate, now: now), "已到期")
        XCTAssertEqual(SigningUrgency.resolve(expiration: expiration, now: now), .expired)
    }

    func testCountdownAndUrgencyBoundaries() {
        let cases: [(Double, String, SigningUrgency)] = [
            (-1, "已到期", .expired), (0, "已到期", .expired),
            (1, "不足 1 分钟", .urgent), (59, "不足 1 分钟", .urgent),
            (60, "1 分钟", .urgent), (3599, "59 分钟", .urgent),
            (3600, "1 小时 0 分钟", .urgent), (86399, "23 小时 59 分钟", .urgent),
            (86400, "1 天 0 小时", .urgent), (86401, "1 天 0 小时", .warning),
            (172800, "2 天 0 小时", .warning), (172801, "2 天 0 小时", .normal)
        ]
        for (seconds, text, urgency) in cases {
            let expiration = now.addingTimeInterval(seconds)
            XCTAssertEqual(SigningCountdown.text(expiration: expiration, now: now), text, "\(seconds)")
            XCTAssertEqual(SigningUrgency.resolve(expiration: expiration, now: now), urgency)
        }
    }

    func testMissingStatusDoesNotInventAnExpiration() {
        XCTAssertNil(SigningStatus.loading.expirationDate)
        XCTAssertNil(SigningStatus.unavailable("not present").expirationDate)
    }

    // Synthetic CMS envelopes only: no developer certificates, device UDIDs or
    // real signing profiles belong in test fixtures. Cryptographic validation is
    // intentionally outside the advisory metadata reader's responsibility.
    private func cms(expiration: Any?, creation: Date? = nil,
                     appID: String = "TEAM.com.anxiong.nicevideos", binary: Bool = false,
                     ber: Bool = false) throws -> Data {
        var plist: [String: Any] = ["UUID": "synthetic-test-profile",
                                    "Entitlements": ["application-identifier": appID]]
        plist["ExpirationDate"] = expiration
        if let creation { plist["CreationDate"] = creation }
        let payload = try PropertyListSerialization.data(fromPropertyList: plist,
                                                         format: binary ? .binary : .xml, options: 0)
        let oidPrefix = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 7])
        let octets: Data
        if ber {
            let middle = payload.count / 2
            octets = indefinite(0x24, tlv(0x04, Data(payload.prefix(middle))) +
                                tlv(0x04, Data(payload.dropFirst(middle))))
        } else { octets = tlv(0x04, payload) }
        let content = tlv(0x30, tlv(0x06, oidPrefix + Data([1])) + tlv(0xa0, octets))
        let signed = tlv(0x30, tlv(0x02, Data([1])) + tlv(0x31, Data()) + content + tlv(0x31, Data()))
        let body = tlv(0x06, oidPrefix + Data([2])) + tlv(0xa0, signed)
        return ber ? indefinite(0x30, body) : tlv(0x30, body)
    }

    private func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var length = content.count
        if length < 128 { return Data([tag, UInt8(length)]) + content }
        var bytes: [UInt8] = []
        while length > 0 { bytes.insert(UInt8(length & 0xff), at: 0); length >>= 8 }
        return Data([tag, 0x80 | UInt8(bytes.count)] + bytes) + content
    }

    private func indefinite(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag, 0x80]) + content + Data([0, 0])
    }
}
