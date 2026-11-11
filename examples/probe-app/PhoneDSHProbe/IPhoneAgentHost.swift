// SPDX-License-Identifier: MIT
// Runs UI-Venus phone tasks on this iPhone with no computer: the board's AirPlay stream
// (`TonoLinkScreen`, decoded here) is the screen, the board's BLE HID (`TonoLinkPhoneHands`, driven
// over USB) is the finger, and the OpenAI-compatible service in UI-Venus settings is the model.
// Device voice reaches it as a tool call inside the device's fixed DSH session.

import Foundation
import OSLog
import PhoneDSHBLE
import PhoneDSHLoopback
import PhoneDSHVenus

/// The app's one native MCP endpoint: `iphone_agent_run` in front of the BLE tools (which fall
/// through to ADB). Both the Worker's direct `/mcp/native` and the Bot listener's forwarder use this
/// same instance, so one receipt store and one in-flight task guard serve every caller.
@MainActor enum PhoneNativeMCP {
    #if DEBUG
    /// DEBUG builds record what reaches the native tools (`GET /debug/native-mcp`).
    static let server: any NativeMCPServing = NativeMCPDebugRecorder(IPhoneAgentMCPServer(
        fallback: DeviceMCPServer.shared, executor: IPhoneAgentHost.shared))
    #else
    static let server: any NativeMCPServing = IPhoneAgentMCPServer(
        fallback: DeviceMCPServer.shared, executor: IPhoneAgentHost.shared)
    #endif
}

#if DEBUG
/// DEBUG-only: keeps the last 20 native MCP requests (method, tool, whether the journal key
/// header arrived, arguments) so a developer can see what the Worker actually sent.
final class NativeMCPDebugRecorder: NativeMCPServing, @unchecked Sendable {
    static weak var current: NativeMCPDebugRecorder?
    private let inner: any NativeMCPServing
    private let lock = NSLock()
    private var entries: [[String: Any]] = []
    init(_ inner: any NativeMCPServing) { self.inner = inner; Self.current = self }

    func handle(_ request: LoopbackRequest) async -> NativeMCPResponse {
        let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let params = message?["params"] as? [String: Any]
        let args = params?["arguments"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()), "method": message?["method"] as? String ?? "?",
            "tool": params?["name"] as? String ?? "",
            "has_key": request.headers.contains { $0.key.lowercased() == "x-pdsh-idempotency-key" && !$0.value.isEmpty },
            "headers": request.headers.keys.map { $0.lowercased() }.sorted(),
            // Not secret; shows whether the Worker's client accepts the long-call SSE answer.
            "accept": request.headers.first { $0.key.lowercased() == "accept" }?.value ?? "",
            "arguments": args.map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? "",
        ]
        let response = await inner.handle(request)
        entry["status"] = response.status
        entry["result"] = String(decoding: response.body.prefix(400), as: UTF8.self)
        lock.withLock { entries.append(entry); if entries.count > 20 { entries.removeFirst() } }
        return response
    }
    func cancelPendingOperations() async { await inner.cancelPendingOperations() }
    func snapshot() -> [[String: Any]] { lock.withLock { entries } }
}
#endif

@MainActor final class IPhoneAgentHost: IPhoneAgentDevice, IPhoneAgentTaskExecuting {
    static let shared = IPhoneAgentHost()
    let screen = TonoLinkScreen.shared
    let hands = TonoLinkPhoneHands()
    private(set) var running: String?
    private(set) var lastResult: [String: Any] = [:]
    private let logger = Logger(subsystem: "dev.phone-dsh.voice", category: "iphone-agent")

    /// English names find apps in Spotlight without the pasteboard.
    static let appQuery = ["设置": "Settings", "电话": "Phone", "信息": "Messages", "相机": "Camera", "照片": "Photos",
                           "时钟": "Clock", "天气": "Weather", "地图": "Maps", "备忘录": "Notes", "日历": "Calendar",
                           "计算器": "Calculator", "提醒事项": "Reminders", "音乐": "Music", "邮件": "Mail",
                           "微信": "WeChat", "支付宝": "Alipay", "哔哩哔哩": "bilibili", "B站": "bilibili",
                           "京东": "JD", "高德地图": "Amap", "百度地图": "Baidu Maps", "网易云音乐": "NetEase Cloud Music"]

    /// Spotlight query for an app: its English name when known, else pinyin for Chinese names
    /// (Spotlight matches "xiaohongshu" to 小红书) — the board's keyboard types ASCII only.
    static func searchQuery(for app: String) -> String {
        if let english = appQuery[app] { return english }
        guard !app.allSatisfy(\.isASCII) else { return app }
        let latin = app.applyingTransform(.mandarinToLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? app
        let ascii = String(latin.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        return ascii.isEmpty ? app : ascii
    }

    /// Keeps the viewer connected from launch: iOS sends a keyframe only when mirroring starts.
    func start() { screen.start() }

    func run(_ task: String) async throws -> IPhoneAgentResult {
        guard running == nil else { throw IPhoneAgentError("上一个手机任务还在执行") }
        running = task
        defer { running = nil }
        let folder = Self.runFolder()
        let agent = IPhoneAgent(device: self)
        agent.onStep = { [logger] step in
            logger.info("step \(step.index, privacy: .public) \(step.action, privacy: .public) → \(step.executed, privacy: .public)")
            try? step.screenshot.write(to: folder.appendingPathComponent(String(format: "step%02d.jpg", step.index)))
            Self.append("[\(step.index)] \(String(format: "%.1f", step.modelSeconds))s \(step.action) → \(step.executed)", to: folder)
        }
        Self.append("task: \(task)", to: folder)
        do {
            let result = try await agent.run(task)
            do { try await hands.disableHID() }
            catch { Self.append("hid detach failed: \(error.localizedDescription)", to: folder) }
            Self.append("result: \(result.answer) finished=\(result.finished) steps=\(result.steps.count) \(Int(result.seconds))s", to: folder)
            lastResult = ["task": task, "answer": result.answer, "finished": result.finished, "steps": result.steps.count,
                          "seconds": Int(result.seconds), "run": folder.lastPathComponent]
            return result
        } catch {
            do { try await hands.disableHID() }
            catch { Self.append("hid detach failed: \(error.localizedDescription)", to: folder) }
            Self.append("error: \(error)", to: folder)
            lastResult = ["task": task, "error": "\(error)", "run": folder.lastPathComponent]
            throw error
        }
    }

    // MARK: IPhoneAgentDevice

    func prepare() async throws {
        screen.start()
        try await hands.ensureHID()
        if screen.currentStats.decodedFrames > 0, (try? await screen.snapshot()) != nil { return }
        // A viewer that just connected gets the board's cached GOP within a moment; wait for it
        // instead of assuming mirroring is off.
        let warmup = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < warmup {
            if (try? await screen.snapshot()) != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        // Mirroring is on but no picture yet: never touch Control Center, since the mirroring
        // control there is a toggle and tapping it would end the session.
        if await hands.mirrorActive() {
            throw IPhoneAgentError("板子在接收镜像但还没有画面（\(screen.currentStats.status)），请稍后重试")
        }
        // No mirror session: start mirroring to the board ourselves, then wait for the first frames.
        try await hands.startMirroring()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if (try? await screen.snapshot()) != nil { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw IPhoneAgentError("看不到手机画面：请在控制中心 → 屏幕镜像里选择板子（\(screen.currentStats.status)）")
    }

    func screenshot(after frame: Int?) async throws -> IPhoneFrame {
        let shot = try await screen.snapshot(newerThan: frame)
        return IPhoneFrame(jpeg: shot.jpeg, width: shot.width, height: shot.height, frame: shot.frame)
    }

    func perform(_ action: IPhoneAction) async throws -> String {
        try await hands.ensureHID()
        let p = action.points.map { TonoLinkPoint($0.x, $0.y) }
        let needs = ["click": 1, "tap": 1, "doubleclick": 1, "longpress": 1, "drag": 2, "swipe": 2][action.name] ?? 0
        guard p.count >= needs else { throw IPhoneAgentError("\(action.raw.prefix(80)) has no coordinates") }
        switch action.name {
        case "click", "tap":
            try await hands.tap(p[0]); return "tap (\(Int(p[0].x)),\(Int(p[0].y)))"
        case "doubleclick":
            try await hands.doubleTap(p[0].x, p[0].y); return "double tap"
        case "longpress":
            try await hands.longPress(p[0].x, p[0].y); return "long press"
        case "drag", "swipe":
            try await hands.swipe(from: p[0], to: p[1], ms: action.name == "drag" ? 1000 : 400)
            return "swipe (\(Int(p[0].x)),\(Int(p[0].y)))→(\(Int(p[1].x)),\(Int(p[1].y)))"
        case "scroll":
            // direction = which side's content to reveal: down → finger moves up.
            let x = min(max(p.first?.x ?? 500, 100), 900), y = min(max(p.first?.y ?? 500, 250), 750)
            let (a, b): (TonoLinkPoint, TonoLinkPoint) = switch action.direction ?? "down" {
            case "up": (.init(x, 300), .init(x, 750))
            case "left": (.init(150, y), .init(850, y))
            case "right": (.init(850, y), .init(150, y))
            default: (.init(x, 750), .init(x, 300))
            }
            try await hands.swipe(from: a, to: b, ms: 450); return "scroll \(action.direction ?? "down")"
        case "type":
            try await hands.type(action.text); return "type \(action.text.count) chars"
        case "presshome":
            return try await home()
        case "pressenter":
            try await hands.key("enter"); return "enter"
        case "launchapp", "launch":
            // Never guess: an empty name used to open 设置 and send the model hunting for the wrong app.
            guard !action.text.isEmpty else { throw IPhoneAgentError("LaunchApp needs the app's name, e.g. LaunchApp(app='小红书')") }
            let app = action.text
            let query = Self.searchQuery(for: app)
            // Like xiaozhi-link: Home, open Search (every home page has the 搜索 button above the dock),
            // type the name, Return opens Spotlight's top hit. The model checks the result on the next screenshot.
            _ = try await home()
            try await Task.sleep(for: .milliseconds(800))
            do { _ = try await tapLocated(Self.searchButton, waitForChange: true) } catch {
                try await hands.swipe(from: TonoLinkPoint(500, 380), to: TonoLinkPoint(500, 700), ms: 350)
            }
            try await Task.sleep(for: .milliseconds(1000))
            try await hands.type(query)
            try await Task.sleep(for: .milliseconds(900))
            let typed = try? await screen.snapshot()
            try await hands.key("enter")
            // With the Pinyin keyboard active the letters sit in its candidate bar and Return only
            // commits them; Spotlight is then still on screen. An app takes a moment to appear on the
            // mirror, so wait for it (up to 2.5 s) before deciding: a second Return in an opened app is a keypress there.
            if let typed, !(try await waitForChange(since: typed, atLeast: Self.stillSpotlight, within: .milliseconds(2500))) {
                try await hands.key("enter")
                return "searched \(query) in Spotlight and pressed Return twice (the first only committed the keyboard's input)"
            }
            return "searched \(query) in Spotlight and pressed Return (top hit)"
        case "wait":
            try await Task.sleep(for: .milliseconds(1500)); return "wait"
        case "pressback", "pressrecent", "getscreenshot":
            throw IPhoneAgentError("\(action.raw.prefix(40)) is not available on this iPhone; to go back tap the visible \"<\" back button")
        default:
            throw IPhoneAgentError("unsupported action: \(action.raw.prefix(120))")
        }
    }

    // MARK: system gestures located on the current screen

    /// Below this mean difference the screen after Return is still Spotlight, not a launched app.
    static let stillSpotlight = 15.0

    static let assistiveButton = "the AssistiveTouch floating button: a round, semi-transparent grey button with a white ring, usually at the left or right edge of the screen"
    static let searchButton = "the 搜索 (Search) button: a small pill labelled 搜索 with a magnifier, just above the dock at the bottom of the home screen"
    static let assistiveHome = "the 主屏幕 (Home) item in the AssistiveTouch menu (a dark rounded panel with several icons)"

    /// Taps the element UI-Venus finds on a fresh screenshot.
    func tapLocated(_ target: String, waitForChange: Bool = false) async throws -> TonoLinkPoint {
        guard let point = try await locate(target, waitForChange: waitForChange) else { throw IPhoneAgentError("屏幕上找不到：\(target)") }
        try await hands.tap(point)
        return point
    }

    /// Home through AssistiveTouch → 主屏幕. The button sits wherever the user left it, and on some
    /// screens a tap there reaches the app instead (钱包's own floating buttons sit right under it).
    /// So the menu must be seen to open (the screen changes a lot) before 主屏幕 is tapped: a blind
    /// second tap used to land on whatever was underneath, on the home screen the 钱包 icon.
    func home() async throws -> String {
        var button = hands.layout.assistiveButton
        var item = try await openAssistiveMenu(at: button)
        if item == nil {
            // The first click may only have woken the pointer: once more at the same place.
            item = try await openAssistiveMenu(at: button)
        }
        if item == nil, let found = try await locate(Self.assistiveButton, waitForChange: false),
           abs(found.x - button.x) > 30 || abs(found.y - button.y) > 30 {
            button = found
            item = try await openAssistiveMenu(at: button)
        }
        guard let item else {
            throw IPhoneAgentError("Home did not work: the AssistiveTouch menu did not open on this screen "
                + "(a button of the app may sit under it, or a system prompt is in front). Close what is open with "
                + "its own visible button (取消 / 完成 / 关闭 / <) first; for a permission prompt use CallUser.")
        }
        try await hands.tap(item)
        hands.layout.assistiveButton = button
        hands.layout.assistiveHome = item
        hands.layout.save()
        return "home via AssistiveTouch (\(Int(button.x)),\(Int(button.y))) → (\(Int(item.x)),\(Int(item.y)))"
    }

    /// Taps the AssistiveTouch button; returns the menu's 主屏幕 item only if the menu visibly opened.
    private func openAssistiveMenu(at button: TonoLinkPoint) async throws -> TonoLinkPoint? {
        let before = try await screen.snapshot()
        try await hands.tap(button)
        try await Task.sleep(for: .milliseconds(700))
        let after = try await screen.snapshot(newerThan: before.frame, fresh: 2, timeout: .seconds(2))
        guard let difference = IPhoneScreenDiff.mean(before.jpeg, after.jpeg), difference >= Self.menuOpened else {
            return nil
        }
        let frame = IPhoneFrame(jpeg: after.jpeg, width: after.width, height: after.height, frame: after.frame)
        guard let point = try await IPhoneGrounding.locate(Self.assistiveHome, in: frame) else {
            try? await hands.key("esc")   // a menu opened but it is not AssistiveTouch's: close it
            return nil
        }
        return TonoLinkPoint(point.x, point.y)
    }

    /// True once the screen differs from `shot` by at least `atLeast` (mean, 0–255) within `within`.
    private func waitForChange(since shot: TonoLinkScreenShot, atLeast: Double, within: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(300))
            guard let now = try? await screen.snapshot(),
                  let difference = IPhoneScreenDiff.mean(shot.jpeg, now.jpeg) else { continue }
            if difference >= atLeast { return true }
        }
        return false
    }

    /// The AssistiveTouch menu darkens and covers about half the screen: far above this mean difference.
    static let menuOpened = 6.0

    func locate(_ target: String, waitForChange: Bool) async throws -> TonoLinkPoint? {
        let shot = try await screen.snapshot(newerThan: waitForChange ? screen.frameCount : nil, fresh: 3, timeout: .seconds(2))
        let frame = IPhoneFrame(jpeg: shot.jpeg, width: shot.width, height: shot.height, frame: shot.frame)
        return try await IPhoneGrounding.locate(target, in: frame).map { TonoLinkPoint($0.x, $0.y) }
    }

    // MARK: run logs (Documents/iphone-agent/<time>/)

    static func runFolder() -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iphone-agent").appendingPathComponent(formatter.string(from: Date()))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func append(_ line: String, to folder: URL) {
        let file = folder.appendingPathComponent("log.txt")
        let data = Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: file) }
    }

    #if DEBUG
    // MARK: relay debug routes (only while the developer relay is switched on)

    func route(_ request: TonoLinkRelayRequest) async -> TonoLinkRelayResponse? {
        switch (request.method, request.path) {
        case ("POST", "/debug/chat"):
            // DEBUG: submit one message to the current chat, exactly as the composer does.
            let text = String(decoding: request.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .error(400, "body: message text") }
            let accepted = await ChatModel.shared.send(text)
            return .json(200, ["accepted": accepted])
        case ("GET", "/debug/transcript"):
            let n = Int(request.queryValue("n") ?? "") ?? 12
            let items = ChatModel.shared.items.suffix(max(1, min(n, 200))).map { item in
                ["kind": "\(item.kind)", "title": item.title, "text": String(item.text.prefix(2000))]
            }
            return .json(200, ["turn_running": ChatModel.shared.turnRunning, "items": Array(items)])
        case ("GET", "/debug/voice"):
            return .json(200, TonoLinkVoiceHost.shared.debugSnapshot)
        case ("POST", "/debug/voice/wake"):
            // As if the board heard 你好小智: 我在, then the board records one turn.
            TonoLinkVoiceHost.shared.beginTurn(wake: 0, source: "debug")
            return .json(200, ["ok": true])
        case ("POST", "/debug/voice/say"):
            let text = String(decoding: request.body, as: UTF8.self)
            guard let credential = await TonoLinkVoiceHost.shared.credential() else { return .error(409, "no cloud credential") }
            do { try await TonoLinkVoiceHost.shared.speakAloud(text, credential: credential) } catch { return .error(502, error.localizedDescription) }
            return .json(200, ["ok": true])
        case ("POST", "/debug/voice/opus"):
            // Body: `[len u16 LE][Opus 20 ms]…`; `?chat=1` also sends the text to the chat and speaks the reply.
            return .json(200, await TonoLinkVoiceHost.shared.debugRecognize(request.body, chat: request.queryValue("chat") == "1"))
        case ("GET", "/debug/ble"):
            // What the Bluetooth devices page shows, for named or connected devices.
            let store = BLEDeviceStore.shared
            let rows = store.devices.filter { $0.name != "未命名 BLE 设备" || $0.state != "未连接" }.map { d -> [String: Any] in
                ["id": d.id.uuidString, "name": d.name, "state": d.state, "link": d.linkState, "link_id": d.linkIdentity,
                 "tools": d.linkTools, "granted": d.grantedTools.sorted(), "read": d.allowRead, "alert": d.allowAlert]
            }
            return .json(200, ["status": store.status, "trust": store.trustConnectedDevices, "devices": rows])
        case ("POST", "/debug/ble/scan"):
            BLEDeviceStore.shared.scan()   // the page's scan button
            return .json(200, ["ok": true])
        case ("POST", "/debug/ble/connect"):
            // The board row's 连接 button: the same store call the page makes.
            let want = request.queryValue("name") ?? "PhoneAgent"
            guard let device = BLEDeviceStore.shared.devices.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) else {
                return .error(404, "no listed device named \(want); POST /debug/ble/scan first")
            }
            BLEDeviceStore.shared.connect(device.id)
            return .json(200, ["id": device.id.uuidString, "name": device.name])
        case ("GET", "/debug/native-mcp"):
            return .json(200, ["requests": NativeMCPDebugRecorder.current?.snapshot() ?? []])
        case ("GET", "/agent/status"):
            var status: [String: Any] = ["running": running ?? "", "last": lastResult, "layout": [
                "assistive_button": [hands.layout.assistiveButton.x, hands.layout.assistiveButton.y]]]
            if let data = try? JSONEncoder().encode(screen.currentStats), let stats = try? JSONSerialization.jsonObject(with: data) {
                status["screen"] = stats
            }
            return .json(200, status)
        case ("GET", "/agent/screen.jpg"):
            do {
                let shot = try await screen.snapshot()
                return TonoLinkRelayResponse(status: 200, contentType: "image/jpeg", body: shot.jpeg)
            } catch { return .error(503, "\(error)") }
        case ("POST", "/agent/run"):
            let task = String(decoding: request.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return .error(400, "body: task text") }
            do {
                let result = try await run(task)
                return .json(200, ["answer": result.answer, "finished": result.finished, "steps": result.steps.map { "\($0.action) → \($0.executed)" },
                                   "seconds": Int(result.seconds)])
            } catch { return .error(500, "\(error)") }
        case ("POST", "/agent/act"):
            var action = IPhoneAction.parse(String(decoding: request.body, as: UTF8.self))
            action.points = action.points.map { IPhoneAction.normalized($0, width: 1000, height: 1000) }
            do { return .json(200, ["did": try await perform(action)]) } catch { return .error(500, "\(error)") }
        case ("POST", "/agent/home"):
            do { try await hands.ensureHID(); return .json(200, ["did": try await home()]) }
            catch { return .error(500, "\(error)") }
        case ("POST", "/agent/locate"):
            let target = String(decoding: request.body, as: UTF8.self)
            do {
                let frame = try await screenshot(after: nil)
                let p = try await IPhoneGrounding.locate(target, in: frame)
                return .json(200, ["point": p.map { [$0.x, $0.y] } ?? []])
            } catch { return .error(500, "\(error)") }
        case ("POST", "/agent/mirror"):
            do { try await hands.ensureHID(); try await hands.startMirroring(); return .json(200, ["ok": true]) }
            catch { return .error(500, "\(error)") }
        default:
            return nil
        }
    }
    #endif
}
