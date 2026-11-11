// SPDX-License-Identifier: MIT
// Physical-device proof for the local voice volume command: the board's Consumer Control
// volume key must change the iPhone's real output volume, and the voice turn must report
// what it observed. TEST-ONLY: this bundle is hosted by the probe app, so it drives the
// app's own HID HTTP client and `TonoLinkVoiceHost` rather than a simulator stand-in.
import AVFoundation
import Foundation
import XCTest
@testable import PhoneDSHBLE
import ProbeKit
@testable import PhoneDSHProbe

/// Collects KVO notifications from an arbitrary thread; the polling readback below runs on
/// the main actor.
private final class VolumeKeyWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []

    func record(_ value: Float) {
        lock.lock(); storage.append(value); lock.unlock()
    }

    var values: [Float] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

@MainActor
final class TonoLinkVolumeDeviceTests: XCTestCase {
    private static let noObservedChangeReply = "音量键已发送，但系统音量没有可观察到的变化；我没有重复发送。"

    // MARK: - Fixture gate

    /// Both spellings are checked: `xcodebuild test TEST_RUNNER_X=1` reaches the test-runner
    /// process as `TEST_RUNNER_X` here, and the simulator fallback exports the bare name.
    private func requireVolumeFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        let enabled = environment["TEST_RUNNER_PDSH_TONOLINK_VOLUME_TEST"] ?? environment["PDSH_TONOLINK_VOLUME_TEST"]
        guard enabled == "1" else {
            throw XCTSkip("TonoLink volume fixture not supplied: pass TEST_RUNNER_PDSH_TONOLINK_VOLUME_TEST=1")
        }
    }

    // MARK: - HID consumer step → real output volume

    func testConsumerVolumeKeyChangesOutputVolume() async throws {
        try requireVolumeFixture()
        let session = AVAudioSession.sharedInstance()
        let watcher = VolumeKeyWatcher()
        // KVO makes a stale readback visible: every change iOS reports is logged below.
        let observation = session.observe(\.outputVolume, options: [.new]) { _, change in
            watcher.record(change.newValue ?? -1)
        }
        defer { observation.invalidate() }

        // The production voice turn holds this lease for the whole turn, so the audio session
        // is active while `answerVolumeCommand` reads outputVolume. Mirror that here.
        var lease: PhoneAudioSessionLease.SpeakerToken?
        do {
            lease = try PhoneAudioSessionLease.acquireSpeakerOutput()
            print("PDSH-VOLUME speaker_lease=held outputs=\(PhoneAudioSessionLease.outputPorts)")
        } catch {
            print("PDSH-VOLUME speaker_lease_error=\(error.localizedDescription)")
        }
        defer { if let lease { PhoneAudioSessionLease.releaseSpeakerOutput(lease) } }

        let hands = TonoLinkPhoneHands()
        var report: [String] = []
        let start = session.outputVolume
        report.append("start=\(start)")
        print("PDSH-VOLUME start=\(start)")
        do {
            try await hands.ensureVolumeHID()
            report.append("ensureVolumeHID=ok")

            let beforeDown = session.outputVolume
            try await hands.adjustOutputVolume(.down)
            let down = await sampleOutputVolume(session, seconds: 3)
            let downChanges = describeChanges(down)
            print("PDSH-VOLUME step=down before=\(beforeDown) trajectory=[\(downChanges)]")
            report.append("down before=\(beforeDown) trajectory=[\(downChanges)]")

            let beforeUp = session.outputVolume
            try await hands.adjustOutputVolume(.up)
            let up = await sampleOutputVolume(session, seconds: 3)
            let upChanges = describeChanges(up)
            print("PDSH-VOLUME step=up before=\(beforeUp) trajectory=[\(upChanges)]")
            report.append("up before=\(beforeUp) trajectory=[\(upChanges)]")

            let downChanged = down.contains { $0 < beforeDown - 0.005 }
            let upChanged = up.contains { $0 > beforeUp + 0.005 }
            let downAtMinimum = beforeDown <= 0.001
            let upAtMaximum = beforeUp >= 0.999
            let kvo = watcher.values.map { String(format: "%.4f", $0) }.joined(separator: ",")
            print("PDSH-VOLUME result down_changed=\(downChanged) up_changed=\(upChanged) "
                + "down_at_minimum=\(downAtMinimum) up_at_maximum=\(upAtMaximum) kvo=[\(kvo)]")
            report.append("result down_changed=\(downChanged) up_changed=\(upChanged) "
                + "down_at_minimum=\(downAtMinimum) up_at_maximum=\(upAtMaximum) kvo=[\(kvo)]")
            print("PDSH-VOLUME hid_consumer_control accepted both steps")

            // A key step changes the level by roughly 1/16. If neither direction moved and the
            // level was not already pinned at a limit, the HID report did not reach the system
            // output volume (or outputVolume cannot see it) — that is a failure, not a pass.
            XCTAssertTrue(downChanged || upChanged || downAtMinimum || upAtMaximum,
                          "No observed outputVolume change in either direction and the level was not at a limit. "
                              + "PDSH-VOLUME " + report.joined(separator: "; "))
        } catch {
            try? await hands.disableHID()
            XCTFail("The HID consumer volume step failed: \(error.localizedDescription). PDSH-VOLUME "
                + report.joined(separator: "; "))
            throw error
        }
        // Best effort, exactly as a voice turn detaches the external keyboard afterwards.
        try? await hands.disableHID()

        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "tonolink-volume-trajectories"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Local voice command reports the truth

    func testLocalVoiceVolumeCommandReportsTruthfully() async throws {
        try requireVolumeFixture()
        // `beginTurn` acquires this lease before `runTurn`, so a real voice turn reads
        // outputVolume with an active session. Mirror it instead of reading in a different
        // audio-session state than production.
        var lease: PhoneAudioSessionLease.SpeakerToken?
        do {
            lease = try PhoneAudioSessionLease.acquireSpeakerOutput()
            print("PDSH-VOLUME voice_report speaker_lease=held outputs=\(PhoneAudioSessionLease.outputPorts)")
        } catch {
            print("PDSH-VOLUME voice_report speaker_lease_error=\(error.localizedDescription)")
        }
        defer { if let lease { PhoneAudioSessionLease.releaseSpeakerOutput(lease) } }

        let host = TonoLinkVoiceHost.shared
        for (phrase, direction) in [("调大音量", "up"), ("调小音量", "down")] {
            let routed = TonoLinkVolumeIntent.direction(for: phrase)
            XCTAssertEqual(routed == .up ? "up" : routed == .down ? "down" : "none", direction,
                           "The intent matcher did not route \(phrase) to the local volume path")
            guard routed != nil else { continue }

            let result = await host.debugAnswer(phrase)
            print("PDSH-VOLUME debug_answer phrase=\(phrase) result=\(result)")

            let turn = try XCTUnwrap(result["last_turn"] as? [String: Any],
                                     "debugAnswer(\(phrase)) did not run a turn: \(result)")
            let volume = try XCTUnwrap(turn["volume"] as? [String: Any],
                                       "debugAnswer(\(phrase)) did not take the local volume path: \(turn)")
            XCTAssertEqual(turn["heard"] as? String, phrase)
            XCTAssertEqual(volume["direction"] as? String, direction)
            let before = try XCTUnwrap(volume["before"] as? NSNumber, "before is not numeric: \(volume)").doubleValue
            let after = try XCTUnwrap(volume["after"] as? NSNumber, "after is not numeric: \(volume)").doubleValue
            let changed = try XCTUnwrap(volume["changed"] as? Bool, "changed is not a boolean: \(volume)")
            let atLimit = (volume["at_limit"] as? Bool) == true
            let reply = try XCTUnwrap(turn["reply"] as? String, "the turn has no reply: \(turn)")
            print("PDSH-VOLUME voice_report phrase=\(phrase) before=\(before) after=\(after) "
                + "changed=\(changed) at_limit=\(atLimit) reply=\(reply)")

            let allowed = direction == "up"
                ? ["手机媒体音量已调高。", "手机媒体音量已经最大。", Self.noObservedChangeReply]
                : ["手机媒体音量已调低。", "手机媒体音量已经最小。", Self.noObservedChangeReply]
            XCTAssertTrue(allowed.contains(reply), "Unexpected reply for \(phrase): \(reply)")

            let truthful = changed
                ? (direction == "up" ? "手机媒体音量已调高。" : "手机媒体音量已调低。")
                : atLimit
                    ? (direction == "up" ? "手机媒体音量已经最大。" : "手机媒体音量已经最小。")
                    : Self.noObservedChangeReply
            XCTAssertEqual(reply, truthful,
                           "The reply does not match the observed level: before=\(before) after=\(after) "
                               + "changed=\(changed) at_limit=\(atLimit)")

            let attachment = XCTAttachment(string: String(describing: result))
            attachment.name = "local-volume-answer-\(direction)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: - Observation helpers

    private func sampleOutputVolume(_ session: AVAudioSession, seconds: TimeInterval) async -> [Float] {
        var values: [Float] = []
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            values.append(session.outputVolume)
            if Date() >= deadline { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return values
    }

    private func describeChanges(_ values: [Float]) -> String {
        var parts: [String] = []
        var previous: Float?
        for (index, value) in values.enumerated() {
            guard value != previous else { continue }
            parts.append(String(format: "%dms=%.4f", index * 100, value))
            previous = value
        }
        return parts.joined(separator: " ")
    }
}
