// SPDX-License-Identifier: MIT
// Physical-device proof for the HID / software-keyboard fix, without UI automation.
//
// The board's external Bluetooth keyboard suppresses the iPhone's software keyboard. After a
// phone task the app now hides the HID service (`disableHID()`), so a text field must get the
// system keyboard again; the next task reattaches it through `ensureHID()`. This test runs inside
// the app process (hosted unit test), drives the real board API and asks UIKit directly whether
// the software keyboard is presented in each state.
//
// It is not a tap test: `TonoLinkKeyboardRecoveryUITests` is the stricter XCUITest. Run this one
// when the UI-test runner cannot bootstrap on the device.
import GameController
import UIKit
import XCTest
@testable import PhoneDSHBLE
@testable import PhoneDSHProbe

@MainActor
final class TonoLinkKeyboardDeviceTests: XCTestCase {
    private var window: UIWindow?
    private var field: UITextView?

    override func tearDownWithError() throws {
        field?.resignFirstResponder()
        window?.isHidden = true
        window = nil
        field = nil
    }

    private func requireKeyboardFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        let enabled = environment["TEST_RUNNER_PDSH_TONOLINK_KEYBOARD_TEST"] ?? environment["PDSH_TONOLINK_KEYBOARD_TEST"]
        guard enabled == "1" else {
            throw XCTSkip("TonoLink keyboard fixture not supplied: pass TEST_RUNNER_PDSH_TONOLINK_KEYBOARD_TEST=1")
        }
    }

    /// Focuses an editable text view in its own window and reports whether UIKit presented the
    /// software keyboard within `timeout`. Written to Documents as well as the test log, so the
    /// observation can be pulled off the phone independently of the xcresult.
    private var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first
    }

    /// Focuses an editable text view in the app's own key window and reports whether UIKit
    /// presented the software keyboard within `timeout`. Also records whether iOS still sees a
    /// coalesced hardware keyboard (`GCKeyboard`), which is what suppresses the software one.
    private func softwareKeyboardAppears(timeout: TimeInterval) async -> Bool {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        var shown = false
        let token = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification,
                                                           object: nil, queue: .main) { _ in shown = true }
        defer { NotificationCenter.default.removeObserver(token) }

        field?.resignFirstResponder()
        field?.removeFromSuperview()
        guard let window = keyWindow else {
            note("probe_error=no key window")
            return false
        }
        let field = UITextView(frame: CGRect(x: 20, y: 120, width: window.bounds.width - 40, height: 120))
        field.text = "keyboard probe"
        field.font = .systemFont(ofSize: 18)
        field.isEditable = true
        window.addSubview(field)
        self.field = field
        let focused = field.becomeFirstResponder()
        note("probe focused=\(focused) isFirstResponder=\(field.isFirstResponder) "
             + "hardware_keyboard=\(GCKeyboard.coalesced != nil ? "present" : "absent")")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !shown {
            try? await Task.sleep(for: .milliseconds(100))
        }
        note("probe keyboard_shown=\(shown) isFirstResponder=\(field.isFirstResponder) "
             + "hardware_keyboard=\(GCKeyboard.coalesced != nil ? "present" : "absent")")
        return shown
    }

    private func note(_ line: String) {
        print("PDSH-KEYBOARD \(line)")
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = folder.appendingPathComponent("tonolink-keyboard-test.log")
        let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// The regression: with the board keyboard attached the software keyboard stays away; after
    /// the task's HID detach the same field must get it; a later `ensureHID()` reattaches the
    /// external keyboard and suppresses it again (the state a task needs).
    func testSoftwareKeyboardFollowsTheBoardHIDVisibility() async throws {
        try requireKeyboardFixture()
        let hands = TonoLinkPhoneHands()

        try await hands.ensureHID()
        let status = try await hands.call("GET", "/v1/phone/status", timeout: 5)
        let hid = status["hid"] as? [String: Any] ?? [:]
        note("hid_attached keyboard=\(hid["keyboard"] ?? "?") absolute=\(hid["absolute"] ?? "?") input_mode=\(hid["input_mode"] ?? "?")")
        let withHID = await softwareKeyboardAppears(timeout: 3)
        note("keyboard_with_HID_attached=\(withHID)")
        XCTAssertFalse(withHID,
                       "the software keyboard was already visible with the board's HID keyboard attached; "
                       + "this device does not reproduce the suppression the fix targets")

        try await hands.disableHID()
        try await Task.sleep(for: .seconds(3))
        let detachedStatus = try await hands.call("GET", "/v1/phone/status", timeout: 5)
        let detachedHID = detachedStatus["hid"] as? [String: Any] ?? [:]
        note("hid_detached keyboard=\(detachedHID["keyboard"] ?? "?") input_mode=\(detachedHID["input_mode"] ?? "?")")
        let withoutHID = await softwareKeyboardAppears(timeout: 6)
        note("keyboard_after_detach=\(withoutHID)")
        XCTAssertTrue(withoutHID, "no software keyboard after the task's HID detach; the detach did not free it")

        // The next task needs the external keyboard again; that state suppresses the software one.
        window?.isHidden = true
        field?.resignFirstResponder()
        try await hands.ensureHID()
        let reattached = await softwareKeyboardAppears(timeout: 3)
        note("keyboard_after_reattach=\(reattached)")
        XCTAssertFalse(reattached, "the board's HID keyboard was reattached but the software keyboard still appeared")

        try? await hands.disableHID()
    }
}
