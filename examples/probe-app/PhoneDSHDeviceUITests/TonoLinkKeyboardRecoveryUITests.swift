// SPDX-License-Identifier: MIT

import XCTest

/// Real-device regression for the TonoLink HID / software-keyboard bug.
///
/// After a phone UI task the board's external Bluetooth keyboard used to stay
/// attached to iOS, so tapping the chat composer no longer brought up the
/// software keyboard. The fix makes every `iphone_agent_run` task end with a
/// best-effort `TonoLinkPhoneHands.disableHID()`; the next task re-enables HID
/// through `ensureHID()`.
///
/// This test needs the real iPhone, the connected TonoLink board, the real
/// configured model and the real `iphone_agent_run` MCP path. It is gated so a
/// simulator run skips instead of pretending to prove anything:
///
///     TEST_RUNNER_PDSH_TONOLINK_KEYBOARD_TEST=1 xcodebuild test ...
///
/// The turn is started by the established unattended hook
/// (`PDSH_CHAT_AUTOSTART` / `PDSH_CHAT_AUTOPROMPT`), then this test waits for
/// the real turn to finish, taps the composer with a synthesized touch and
/// requires the software keyboard to appear. A missing keyboard always fails:
/// there is no conditional pass.
@MainActor
final class TonoLinkKeyboardRecoveryUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The task deliberately stays inside the chat app. A task that opens
    /// another app (for example 计算器) backgrounds the app under test, and then
    /// neither the running indicator nor the post-task composer can be checked
    /// without racing a backgrounded accessibility tree. `iphone_agent_run`
    /// still performs the real path: `prepare()` → `ensureHID()` attaches the
    /// board's keyboard/pointer, `perform()` uses the HID, and the host detaches
    /// it with `disableHID()` when the task returns.
    private static let uiTask = "在当前聊天界面上，用手指在屏幕中间向上滑动一次，然后只回复：已滑动。"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        // xcodebuild strips the TEST_RUNNER_ prefix before the runner starts.
        guard env["PDSH_TONOLINK_KEYBOARD_TEST"] == "1"
                || env["TEST_RUNNER_PDSH_TONOLINK_KEYBOARD_TEST"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_PDSH_TONOLINK_KEYBOARD_TEST=1 and run on the iPhone with the TonoLink board and a real configured model")
        }
        app = XCUIApplication()
        app.launchEnvironment["PDSH_CHAT_AUTOSTART"] = "1"
        app.launchEnvironment["PDSH_CHAT_AUTOPROMPT"] = Self.uiTask
        XCUIDevice.shared.orientation = .portrait
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testSoftwareKeyboardReturnsAfterRealUITask() throws {
        // 1. The real model must actually start an `iphone_agent_run` turn.
        let stop = app.buttons.matching(NSPredicate(format: "label == %@", "停止执行")).firstMatch
        guard stop.waitForExistence(timeout: 120) else {
            dumpDiagnostics(named: "turn-never-started")
            XCTFail("the unattended phone UI task never started: 停止执行 did not appear within 120 s. "
                    + "The host may not have booted, the configured model may be unavailable, or "
                    + "PDSH_CHAT_AUTOPROMPT was not delivered (see the attached tree and screenshot).")
            return
        }

        // 2. Wait for the real turn to finish. 停止执行 is the composer's running
        //    indicator; it is replaced by 发送消息 as soon as `turnRunning` is false.
        let finished = waitUntil(timeout: 180) { !stop.exists }
        XCTAssertTrue(finished, "the unattended phone UI task did not finish within 180 s: 停止执行 "
                      + "is still visible; the turn was still running when the keyboard check was due")
        guard finished else {
            dumpDiagnostics(named: "turn-never-finished")
            return
        }

        // The composer label is the idle projection of `turnRunning`; waiting for
        // it also covers the short window where the stop button disappears before
        // the composer has re-rendered.
        let composer = composerElement
        let idle = waitUntil(timeout: 60) {
            composer.exists && composer.isEnabled && composer.label.hasPrefix("发消息或创建任务")
        }
        XCTAssertTrue(idle, "the turn ended but the composer did not return to its idle state within 60 s "
                      + "(label: \(composer.exists ? composer.label : "<missing>"))")
        guard idle else {
            dumpDiagnostics(named: "composer-not-idle")
            return
        }

        attachTranscriptEvidence()
        attachScreenshot(named: "01-after-task-composer-no-keyboard")
        if composer.exists {
            let area = XCTAttachment(screenshot: composer.screenshot())
            area.name = "01b-composer-area-after-task"
            area.lifetime = .keepAlways
            add(area)
        }

        // A keyboard that was already up would make the post-tap check meaningless.
        XCTAssertFalse(app.keyboards.firstMatch.exists,
                       "the software keyboard was already visible after the task, before any tap; "
                       + "this run cannot prove that the task's HID detach restored it")

        // 3. The regression assertion: one real synthesized tap on the composer
        //    must bring the software keyboard back.
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "composer not found after the task")
        XCTAssertTrue(composer.isHittable, "the composer exists but is not hittable after the task")
        composer.tap()

        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 12) {
            attachScreenshot(named: "02-composer-tap-keyboard-visible")
            return
        }

        // No keyboard: this is the regression. Dump the tree and fail precisely.
        let state = "\(app.state)"
        let hittable = composer.exists && composer.isHittable
        dumpDiagnostics(named: "keyboard-missing-after-tap")
        XCTFail("no software keyboard appeared within 12 s after tapping the composer at the end of a real "
                + "iphone_agent_run task. app.state=\(state), composer.exists=\(composer.exists), "
                + "composer.isHittable=\(hittable). XCUITest exposes no public keyboard-focus attribute, so "
                + "focus can only be inferred: the tap was delivered to a hittable composer, but no keyboard "
                + "followed. If the board's HID was still attached, the post-task disableHID did not free the "
                + "software keyboard. See the attached accessibility tree and screenshot.")
    }

    // MARK: - Lookup

    /// `消息输入` was the composer's identifier before the native composer moved
    /// to a UIViewRepresentable; the current element exposes the placeholder as
    /// its accessibility label. Accept both so this test survives either build.
    private var composerElement: XCUIElement {
        app.textViews.matching(NSPredicate(
            format: "identifier == %@ OR label BEGINSWITH %@",
            "消息输入", "发消息或创建任务")).firstMatch
    }

    // MARK: - Evidence

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachTranscriptEvidence() {
        let text = transcriptTexts().suffix(40).joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = "transcript-after-task"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("PDSH-UI-TRANSCRIPT\n" + text)
    }

    private func dumpDiagnostics(named name: String) {
        let tree = app.debugDescription
        let attachment = XCTAttachment(string: tree)
        attachment.name = "\(name)-tree"
        attachment.lifetime = .keepAlways
        add(attachment)
        attachScreenshot(named: "\(name)-screenshot")
        print("PDSH-UI-TREE \(name)\n" + tree)
    }

    /// One read of the whole tree: the transcript keeps updating, so per-element
    /// reads race.
    private func transcriptTexts() -> [String] {
        app.debugDescription.split(separator: "\n").compactMap { line -> String? in
            guard line.contains("StaticText"), let start = line.range(of: "label: '") else { return nil }
            var label = String(line[start.upperBound...])
            if label.hasSuffix("'") { label.removeLast() }
            return label.isEmpty ? nil : label
        }
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }
}
