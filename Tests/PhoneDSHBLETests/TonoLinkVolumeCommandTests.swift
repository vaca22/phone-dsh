// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHBLE

final class TonoLinkVolumeCommandTests: XCTestCase {
    private func golden() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/device/v1/golden/tonolink-hid-consumer-control.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testIntentMatcherOnlyAcceptsStandaloneRelativeVolumeCommands() {
        XCTAssertEqual(TonoLinkVolumeIntent.direction(for: "调大音量"), .up)
        XCTAssertEqual(TonoLinkVolumeIntent.direction(for: "你好小智，声音大一点！"), .up)
        XCTAssertEqual(TonoLinkVolumeIntent.direction(for: "Turn up the volume."), .up)
        XCTAssertEqual(TonoLinkVolumeIntent.direction(for: "把音量调小"), .down)
        XCTAssertEqual(TonoLinkVolumeIntent.direction(for: "volume down"), .down)
        XCTAssertNil(TonoLinkVolumeIntent.direction(for: "把音量调到 30%"))
        XCTAssertNil(TonoLinkVolumeIntent.direction(for: "静音"))
        XCTAssertNil(TonoLinkVolumeIntent.direction(for: "打开小红书然后调大音量"))
    }

    func testRequestStepsMatchSharedGolden() throws {
        let fixture = try golden()
        let valid = try XCTUnwrap(fixture["valid"] as? [[String: Any]])
        XCTAssertEqual(valid.count, 2)
        for item in valid {
            let name = try XCTUnwrap(item["name"] as? String)
            let expected = try XCTUnwrap(item["step"] as? [String: Any])
            let direction: TonoLinkVolumeDirection = name == "volume_up" ? .up : .down
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: TonoLinkPhoneHands.consumerVolumeStep(direction), options: [.sortedKeys]),
                           try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
        }
        let report = try XCTUnwrap(fixture["report"] as? [String: Any])
        XCTAssertEqual(report["id"] as? Int, 4)
        XCTAssertEqual(report["volume_increment_usage"] as? Int, 0xE9)
        XCTAssertEqual(report["volume_decrement_usage"] as? Int, 0xEA)
    }

    func testOldFirmwareAndUnknownOutcomeAreNeverRetriedAsVolumeSteps() {
        XCTAssertFalse(TonoLinkPhoneHands.isBusy(TonoLinkHandsError("板子 /v1/hid/batch HTTP 400：unknown op")))
        XCTAssertFalse(TonoLinkPhoneHands.isBusy(TonoLinkHandsError("板子 /v1/hid/batch HTTP 504：outcome unknown")))
        XCTAssertTrue(TonoLinkPhoneHands.isBusy(TonoLinkHandsError("板子 /v1/hid/batch HTTP 503：busy_exec")))
    }

    func testHandsErrorsExposeTheActionableLocalizedDescription() {
        let error = TonoLinkHandsError("小智 Link 固件还不支持语音调音量")
        XCTAssertEqual(error.localizedDescription, "小智 Link 固件还不支持语音调音量")
    }

    @MainActor func testHIDDetachRequestMatchesSharedLifecycleFixture() async throws {
        let fixture = try golden()
        let lifecycle = try XCTUnwrap(fixture["input_mode_lifecycle"] as? [String: Any])
        let detach = try XCTUnwrap(lifecycle["detach_after_task"] as? [String: Any])
        let http = RecordingHTTP()
        let hands = TonoLinkPhoneHands(http: http)

        try await hands.disableHID()

        let (request, body) = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, detach["method"] as? String)
        XCTAssertEqual(request.url?.path, detach["path"] as? String)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Bool],
                       detach["body"] as? [String: Bool])
    }
}
