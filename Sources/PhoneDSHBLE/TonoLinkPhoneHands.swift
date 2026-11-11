// SPDX-License-Identifier: MIT
// Touch and keys on this iPhone through the board's BLE HID, driven over USB NCM (`/v1/hid/*` on
// 192.168.247.1:8767). Ported from the firmware repo's tools/phone-agent/venus_agent.py, which is
// what worked on the real phone:
//
// - Coordinates are 0–1000 of the screen, both axes. Absolute pointer reports are 0–32767.
// - Taps glide: 2–3 pointer moves ~180 ms apart, then press/release at the target. A single far
//   jump + press is not followed by iOS (Control Center especially): the press lands where the
//   pointer was.
// - The board's cmd+h / cmd+space do nothing on this iPhone; Home goes through the AssistiveTouch
//   menu, whose positions depend on where the user left the button (`TonoLinkPhoneLayout`).
// - The board types ASCII only. Chinese goes through the phone's Pinyin input method: ctrl+space
//   switches to it, each word is typed as pinyin and space picks the first candidate, ctrl+space
//   switches back. (The pasteboard is no way out: a background app cannot write it.) This assumes
//   the hardware keyboard rests in English, which is how it starts and how `type` leaves it.
// - `release_all` on the board hides the HID service; before acting, wait until the phone has the
//   keyboard and absolute pointer subscribed, and after a re-attach send one buttonless move (iOS
//   swallows the first click to show the pointer).
import Foundation

public struct TonoLinkHandsError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// Screen positions (0–1000) of the AssistiveTouch button and its menu items on this phone.
/// The menu opens next to the button, so all of them move when the button is dragged.
public struct TonoLinkPhoneLayout: Codable, Equatable, Sendable {
    public var assistiveButton = TonoLinkPoint(910, 750)
    public var assistiveHome = TonoLinkPoint(634, 850)
    public var assistiveControlCenter = TonoLinkPoint(826, 820)
    public var mirrorButton = TonoLinkPoint(401, 564)
    public var mirrorTarget = TonoLinkPoint(567, 579)
    public init() {}

    static let key = "phone-dsh.tonolink.phone-layout.v1"
    public static func load(_ defaults: UserDefaults = .standard) -> TonoLinkPhoneLayout {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(TonoLinkPhoneLayout.self, from: $0) } ?? .init()
    }
    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

public struct TonoLinkPoint: Codable, Equatable, Sendable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

@MainActor public final class TonoLinkPhoneHands {
    private let http: TonoLinkHTTP
    public var layout: TonoLinkPhoneLayout
    public let controller: String

    public init(http: TonoLinkHTTP? = nil, layout: TonoLinkPhoneLayout = .load(), controller: String = "phone-dsh") {
        self.http = http ?? TonoLinkURLSessionHTTP(); self.layout = layout; self.controller = controller
    }

    // MARK: board HTTP

    @discardableResult
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 15) async throws -> [String: Any] {
        var request = URLRequest(url: TonoLinkUSB.baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(controller, forHTTPHeaderField: "X-Controller")
        var data: Data?
        if let body {
            data = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        let (status, reply) = try await http.send(request, body: data, progress: nil)
        guard (200...299).contains(status) else {
            let text = String(decoding: reply.prefix(200), as: UTF8.self)
            throw TonoLinkHandsError("板子 \(path) 返回 HTTP \(status)：\(text)")
        }
        return (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
    }

    public func batch(_ steps: [[String: Any]]) async throws {
        let planned = steps.reduce(0.0) { $0 + Double(($1["delay_ms"] as? Int) ?? 0) / 1000 }
        // 503 busy_exec: the board's HID executor was still finishing the previous batch and ran
        // nothing of this one, so resending is safe (tonolink-board.md §2). Any other failure is not retried.
        for attempt in 0..<10 {
            do {
                try await call("POST", "/v1/hid/batch", ["steps": steps, "wait": true], timeout: 15 + planned)
                return
            } catch let error as TonoLinkHandsError where Self.isBusy(error) && attempt < 9 {
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    nonisolated static func isBusy(_ error: TonoLinkHandsError) -> Bool {
        error.description.contains("HTTP 503") && error.description.contains("busy_exec")
    }

    /// Waits until the phone has the board's keyboard and absolute pointer attached.
    public func ensureHID(timeout: Duration = .seconds(15)) async throws {
        let clock = ContinuousClock(), deadline = clock.now + timeout
        var enabledAt: ContinuousClock.Instant?
        var cycledAt: ContinuousClock.Instant?
        while clock.now < deadline {
            if let status = try? await call("GET", "/v1/phone/status", timeout: 5), let hid = status["hid"] as? [String: Any],
               hid["keyboard"] as? Bool == true, hid["absolute"] as? Bool == true, hid["input_mode"] as? Bool == true {
                if enabledAt != nil {
                    try await Task.sleep(for: .milliseconds(800))
                    try await batch([Self.absolute(500, 500, 0)])
                    try await Task.sleep(for: .milliseconds(600))
                }
                return
            }
            if await cycleIfStuck(clock: clock, enabledAt: &enabledAt, cycledAt: &cycledAt) { continue }
            if enabledAt.map({ clock.now - $0 > .seconds(6) }) ?? true {
                _ = try? await call("POST", "/v1/hid/enable", ["on": true], timeout: 8)
                enabledAt = clock.now
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw TonoLinkHandsError("手机还没有接上板子的键盘和鼠标（蓝牙 HID）")
    }

    /// A `{"on":true}` sent immediately after a hide may be coalesced with that hide by the host:
    /// the service is visible again, but iOS never re-reads the Report Map, so no report
    /// subscription comes back and the board reports `input_mode:true` with every subscription
    /// false. The board treats a repeated enable as a no-op, so only a new visibility change
    /// recovers it. These are desired-state requests (tonolink-board.md §2), not HID steps:
    /// repeating them replays no key or pointer action. One cycle every few seconds at most.
    private func cycleIfStuck(clock: ContinuousClock, enabledAt: inout ContinuousClock.Instant?,
                              cycledAt: inout ContinuousClock.Instant?) async -> Bool {
        guard let enabled = enabledAt, clock.now - enabled > .seconds(3),
              cycledAt.map({ clock.now - $0 > .seconds(3) }) ?? true else { return false }
        cycledAt = clock.now
        _ = try? await call("POST", "/v1/hid/enable", ["on": false], timeout: 8)
        try? await Task.sleep(for: .milliseconds(500))
        _ = try? await call("POST", "/v1/hid/enable", ["on": true], timeout: 8)
        enabledAt = clock.now
        return true
    }

    /// Waits for the Consumer Control report needed by direct voice volume commands. Older board
    /// firmware omits this status field and rejects the corresponding batch step before output.
    public func ensureVolumeHID(timeout: Duration = .seconds(15)) async throws {
        let clock = ContinuousClock(), deadline = clock.now + timeout
        var enabledAt: ContinuousClock.Instant?
        var cycledAt: ContinuousClock.Instant?
        while clock.now < deadline {
            if let status = try? await call("GET", "/v1/phone/status", timeout: 5),
               let hid = status["hid"] as? [String: Any] {
                guard hid["consumer_control"] != nil else {
                    throw TonoLinkHandsError("小智 Link 固件还不支持语音调音量，请更新 Link 固件后重新连接")
                }
                if hid["consumer_control"] as? Bool == true, hid["input_mode"] as? Bool == true { return }
            }
            if await cycleIfStuck(clock: clock, enabledAt: &enabledAt, cycledAt: &cycledAt) { continue }
            if enabledAt.map({ clock.now - $0 > .seconds(6) }) ?? true {
                _ = try? await call("POST", "/v1/hid/enable", ["on": true], timeout: 8)
                enabledAt = clock.now
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw TonoLinkHandsError("小智 Link 的音量按键没有连上手机，请在蓝牙配件页重新连接小智 Link")
    }

    /// Hides the board's external keyboard and pointer after phone control so the iPhone can
    /// present its software keyboard again. A later task reattaches HID through ensureHID().
    public func disableHID() async throws {
        _ = try await call("POST", "/v1/hid/enable", ["on": false], timeout: 8)
    }

    /// Emits one standard Consumer Control volume step. The result means firmware accepted the
    /// reports; it does not by itself prove that iOS changed its output level.
    public func adjustOutputVolume(_ direction: TonoLinkVolumeDirection) async throws {
        try await ensureVolumeHID()
        try await batch([Self.consumerVolumeStep(direction)])
    }

    nonisolated static func consumerVolumeStep(_ direction: TonoLinkVolumeDirection) -> [String: Any] {
        ["op": "consumer", "key": direction == .up ? "volume_up" : "volume_down"]
    }

    // MARK: gestures

    nonisolated static func absolute(_ x: Double, _ y: Double, _ buttons: Int) -> [String: Any] {
        ["op": "absolute", "x": Int((min(max(x, 0), 1000) * 32767 / 1000).rounded()),
         "y": Int((min(max(y, 0), 1000) * 32767 / 1000).rounded()), "buttons": buttons]
    }

    /// Glide toward the target from the centre, then press and release there.
    nonisolated static func glideSteps(_ x: Double, _ y: Double, holdMs: Int) -> [[String: Any]] {
        var steps: [[String: Any]] = []
        for f in [0.0, 0.5, 0.85, 1.0, 1.0] {
            steps.append(absolute(500 + (x - 500) * f, 500 + (y - 500) * f, 0)); steps.append(["delay_ms": 180])
        }
        steps += [absolute(x, y, 1), ["delay_ms": holdMs], absolute(x, y, 0)]
        return steps
    }

    public func tap(_ x: Double, _ y: Double) async throws { try await batch(Self.glideSteps(x, y, holdMs: 120)) }
    public func tap(_ point: TonoLinkPoint) async throws { try await tap(point.x, point.y) }

    public func doubleTap(_ x: Double, _ y: Double) async throws {
        var steps = Self.glideSteps(x, y, holdMs: 60)
        steps += [["delay_ms": 80], Self.absolute(x, y, 1), ["delay_ms": 60], Self.absolute(x, y, 0)]
        try await batch(steps)
    }

    public func longPress(_ x: Double, _ y: Double, ms: Int = 800) async throws { try await batch(Self.glideSteps(x, y, holdMs: ms)) }

    /// iOS 27.2 ignores absolute moves while the button is held (xiaozhi-link AssistiveTouchPointer),
    /// so the board's own `swipe` op (all absolute) does not scroll. Press absolutely at the start,
    /// advance the touch with relative moves, release absolutely at the end.
    public func swipe(from a: TonoLinkPoint, to b: TonoLinkPoint, ms: Int = 400) async throws {
        try await batch(Self.swipeSteps(from: a, to: b, ms: ms))
    }

    /// Relative units per 0–1000 of the screen (about one unit per point on a 430×932 pt iPhone).
    nonisolated static let relativeScale = (x: 0.43, y: 0.932)

    nonisolated static func swipeSteps(from a: TonoLinkPoint, to b: TonoLinkPoint, ms: Int) -> [[String: Any]] {
        var steps: [[String: Any]] = []
        for f in [0.0, 0.6, 1.0, 1.0] {
            steps.append(absolute(500 + (a.x - 500) * f, 500 + (a.y - 500) * f, 0)); steps.append(["delay_ms": 150])
        }
        steps += [absolute(a.x, a.y, 1), ["delay_ms": 120]]
        let dx = (b.x - a.x) * relativeScale.x, dy = (b.y - a.y) * relativeScale.y
        let n = max(2, min(40, Int((max(abs(dx), abs(dy)) / 20).rounded(.up))))
        let gap = max(8, (ms - 120) / n)
        var sentX = 0, sentY = 0
        for i in 1...n {
            let tx = Int((dx * Double(i) / Double(n)).rounded()), ty = Int((dy * Double(i) / Double(n)).rounded())
            steps += [["op": "move", "dx": tx - sentX, "dy": ty - sentY], ["delay_ms": gap]]
            sentX = tx; sentY = ty
        }
        steps += [["delay_ms": 100], absolute(b.x, b.y, 0)]
        return steps
    }

    public func key(_ combo: String) async throws { try await batch([["op": "key", "combo": combo]]) }

    public func type(_ text: String) async throws {
        for segment in Self.typingSegments(text) {
            switch segment {
            case .ascii(let run):
                try await batch([["op": "type", "text": run]])
            case .pinyin(let words):
                var steps: [[String: Any]] = [["op": "key", "combo": "ctrl+space"], ["delay_ms": 500]]
                for word in words {
                    steps += [["op": "type", "text": word], ["delay_ms": 350], ["op": "key", "combo": "space"], ["delay_ms": 200]]
                }
                steps += [["op": "key", "combo": "ctrl+space"], ["delay_ms": 300]]
                try await batch(steps)
            }
        }
    }

    public enum TypingSegment: Equatable, Sendable {
        case ascii(String)
        /// Pinyin of each Chinese word, typed into the Pinyin input method one candidate at a time.
        case pinyin([String])
    }

    /// Splits text into ASCII runs and Chinese runs; Chinese runs become per-word pinyin (word
    /// boundaries from the system tokenizer, so the first candidate is usually the intended word).
    nonisolated public static func typingSegments(_ text: String) -> [TypingSegment] {
        var segments: [TypingSegment] = []
        var current = "", currentASCII = true
        func flush() {
            guard !current.isEmpty else { return }
            if currentASCII { segments.append(.ascii(current)) } else {
                let words = chineseWords(current).compactMap { word -> String? in
                    let latin = word.applyingTransform(.mandarinToLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? ""
                    let ascii = String(latin.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
                    return ascii.isEmpty ? nil : ascii
                }
                if !words.isEmpty { segments.append(.pinyin(words)) }
            }
            current = ""
        }
        for ch in text where !ch.isNewline {
            let ascii = ch.isASCII
            if ascii != currentASCII { flush(); currentASCII = ascii }
            current.append(ch)
        }
        flush()
        return segments
    }

    nonisolated static func chineseWords(_ text: String) -> [String] {
        let cf = text as CFString
        let tokenizer = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: CFStringGetLength(cf)),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "zh_CN") as CFLocale)
        var words: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            words.append((text as NSString).substring(with: NSRange(location: range.location, length: range.length)))
        }
        return words.isEmpty ? [text] : words
    }

    public func home() async throws {
        try await tap(layout.assistiveButton)
        try await Task.sleep(for: .milliseconds(900))
        try await tap(layout.assistiveHome)
    }

    /// Home, home again (back to the first page), pull down for Search, type the app name.
    public func openSearch(typing query: String) async throws {
        try await home(); try await Task.sleep(for: .seconds(1))
        try await home(); try await Task.sleep(for: .seconds(1))
        try await swipe(from: TonoLinkPoint(500, 380), to: TonoLinkPoint(500, 700), ms: 350)
        try await Task.sleep(for: .milliseconds(1200))
        try await type(query)
    }

    /// AssistiveTouch → Control Center → Screen Mirroring → the board's receiver.
    public func startMirroring() async throws {
        try await tap(layout.assistiveButton); try await Task.sleep(for: .milliseconds(900))
        try await tap(layout.assistiveControlCenter); try await Task.sleep(for: .milliseconds(1500))
        try await tap(layout.mirrorButton); try await Task.sleep(for: .seconds(2))
        try await tap(layout.mirrorTarget); try await Task.sleep(for: .seconds(5))
    }

    /// Makes the board's USB network and AirPlay receiver come up (they are RAM-only on the board).
    /// True when the board reports an active AirPlay mirror session (`/v1/phone/status`, read-only).
    public func mirrorActive() async -> Bool {
        guard let status = try? await call("GET", "/v1/phone/status", timeout: 5),
              let airplay = status["airplay"] as? [String: Any] else { return false }
        return airplay["mirror_active"] as? Bool == true
    }

    public func enableUSB() async throws { try await call("POST", "/v1/usb", ["action": "enable"], timeout: 10) }
}
