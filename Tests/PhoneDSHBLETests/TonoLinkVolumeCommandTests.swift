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

    // MARK: - Firmware gate and the exact requests of one volume command

    /// Old firmware omits `hid.consumer_control`. The consumer must stop before any HID request
    /// and tell the user to update the Link firmware (tonolink-board.md §2.1); it must not send a
    /// batch the old parser would reject, and must not fall back to screen taps.
    @MainActor func testMissingConsumerControlFailsBeforeAnyHIDRequest() async throws {
        let http = StatusHTTP()
        http.status = ["hid": ["keyboard": true, "absolute": true, "input_mode": true]]
        let hands = TonoLinkPhoneHands(http: http)
        do {
            try await hands.adjustOutputVolume(.up)
            XCTFail("a board without hid.consumer_control must not accept a volume step")
        } catch {
            XCTAssertTrue("\(error)".contains("固件还不支持语音调音量"), "unexpected error: \(error)")
        }
        XCTAssertEqual(http.paths, ["/v1/phone/status"],
                       "the consumer probed status and must stop before enabling HID or sending a batch")
    }

    /// One command = status, exactly one consumer batch, then the HID detach. The batch step is
    /// compared with the shared golden, so the device test and the fixture describe the same bytes.
    @MainActor func testOneVolumeCommandSendsGoldenStepThenDetach() async throws {
        let fixture = try golden()
        let up = try XCTUnwrap((fixture["valid"] as? [[String: Any]])?.first { ($0["name"] as? String) == "volume_up" })
        let step = try XCTUnwrap(up["step"] as? [String: Any])
        let http = StatusHTTP()
        http.status = ["hid": ["keyboard": true, "absolute": true, "input_mode": true, "consumer_control": true]]
        let hands = TonoLinkPhoneHands(http: http)

        try await hands.adjustOutputVolume(.up)
        try await hands.disableHID()

        XCTAssertEqual(http.paths, ["/v1/phone/status", "/v1/hid/batch", "/v1/hid/enable"])
        let batch = try XCTUnwrap(http.requests.first { $0.0.url?.path == "/v1/hid/batch" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(batch.1)) as? [String: Any])
        let steps = try XCTUnwrap(body["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 1, "exactly one relative step per command: \(body)")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: try XCTUnwrap(steps.first), options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: step, options: [.sortedKeys]))
        let detach = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(detach.1)) as? [String: Bool], ["on": false])
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

/// Answers the board's HTTP routes from memory so the consumer's request sequence can be asserted
/// without a board. `paths` is the recorded request order.
@MainActor final class StatusHTTP: TonoLinkHTTP {
    var requests: [(URLRequest, Data?)] = []
    var paths: [String] { requests.compactMap { $0.0.url?.path } }
    var status: [String: Any] = [:]
    var batchReply: (status: Int, body: Data) = (200, Data("{\"ok\":true,\"accepted\":true,\"steps\":1}".utf8))

    func send(_ request: URLRequest, body: Data?, progress: ((Double) -> Void)?) async throws -> (status: Int, body: Data) {
        requests.append((request, body))
        switch request.url?.path {
        case "/v1/phone/status":
            return (200, try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]))
        case "/v1/hid/batch":
            return batchReply
        default:
            return (200, Data("{}".utf8))
        }
    }
}

/// Models the board state we reproduced on the phone: a `{"on":true}` that lands immediately after
/// a hide is coalesced by the host, so the service is enabled (`input_mode:true`) but the host never
/// re-reads the Report Map and no subscription comes back. Only a later hide→show restores it, and
/// a repeated enable while already enabled is a no-op in the firmware.
@MainActor final class CoalescedShowHTTP: TonoLinkHTTP {
    private(set) var requests: [(URLRequest, Data?)] = []
    private(set) var shows = 0
    private(set) var sawHideThenShow = false
    private var enabled = false
    private var mapped = false

    var paths: [String] { requests.compactMap { $0.0.url?.path } }

    func send(_ request: URLRequest, body: Data?, progress: ((Double) -> Void)?) async throws -> (status: Int, body: Data) {
        requests.append((request, body))
        switch request.url?.path {
        case "/v1/phone/status":
            let hid: [String: Any] = ["enabled": enabled, "input_mode": enabled, "keyboard": enabled && mapped,
                                      "absolute": enabled && mapped, "consumer_control": enabled && mapped,
                                      "mouse": enabled && mapped]
            return (200, try JSONSerialization.data(withJSONObject: ["hid": hid], options: [.sortedKeys]))
        case "/v1/hid/enable":
            let on = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            if (on?["on"] as? Bool) == true {
                if !enabled {
                    enabled = true
                    shows += 1
                    if shows > 1 { sawHideThenShow = true; mapped = true }
                }
            } else {
                enabled = false
                mapped = false
            }
            return (200, Data(#"{"ok":true}"#.utf8))
        default:
            return (200, Data("{}".utf8))
        }
    }
}

@MainActor final class TonoLinkVolumeRecoveryTests: XCTestCase {
    /// After a hide, an immediate show can stick. The consumer must not sit on a no-op enable for
    /// the whole timeout: one visibility cycle recovers the subscription. The cycle is only a
    /// desired-state call (`on:false`/`on:true`); it replays no HID step.
    func testEnsureVolumeHIDForcesOneVisibilityCycleWhenTheShowIsCoalesced() async throws {
        let http = CoalescedShowHTTP()
        let hands = TonoLinkPhoneHands(http: http)
        let clock = ContinuousClock(), start = clock.now
        try await hands.ensureVolumeHID(timeout: .seconds(8))
        XCTAssertTrue(http.sawHideThenShow, "recovery must come from a real hide→show cycle: \(http.paths)")
        XCTAssertEqual(http.paths.filter { $0 == "/v1/hid/batch" }.count, 0, "no HID step is sent by ensure")
        let elapsed = clock.now - start
        XCTAssertLessThan(elapsed, .seconds(8), "recovery took \(elapsed)")
        let hides = try http.requests.enumerated().filter { $0.element.0.url?.path == "/v1/hid/enable" }
            .filter { (try? JSONSerialization.jsonObject(with: $0.element.1 ?? Data())) as? [String: Bool]? == ["on": false] }
        XCTAssertEqual(hides.count, 1, "exactly one forced hide: \(http.paths)")
    }
}
