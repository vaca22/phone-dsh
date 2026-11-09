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
    static let server: any NativeMCPServing = IPhoneAgentMCPServer(
        fallback: DeviceMCPServer.shared, executor: IPhoneAgentHost.shared)
}

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
            Self.append("result: \(result.answer) finished=\(result.finished) steps=\(result.steps.count) \(Int(result.seconds))s", to: folder)
            lastResult = ["task": task, "answer": result.answer, "finished": result.finished, "steps": result.steps.count,
                          "seconds": Int(result.seconds), "run": folder.lastPathComponent]
            return result
        } catch {
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
            let app = action.text.isEmpty ? "设置" : action.text
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
            try await hands.key("enter")
            return "launched \(app): Spotlight \(query) → top hit"
        case "wait":
            try await Task.sleep(for: .milliseconds(1500)); return "wait"
        case "pressback", "pressrecent", "getscreenshot":
            throw IPhoneAgentError("\(action.raw.prefix(40)) is not available on this iPhone; to go back tap the visible \"<\" back button")
        default:
            throw IPhoneAgentError("unsupported action: \(action.raw.prefix(120))")
        }
    }

    // MARK: system gestures located on the current screen

    static let assistiveButton = "the AssistiveTouch floating button: a round, semi-transparent grey button with a white ring, usually at the left or right edge of the screen"
    static let searchButton = "the 搜索 (Search) button: a small pill labelled 搜索 with a magnifier, just above the dock at the bottom of the home screen"
    static let assistiveHome = "the 主屏幕 (Home) item in the AssistiveTouch menu (a dark rounded panel with several icons)"

    /// Taps the element UI-Venus finds on a fresh screenshot.
    func tapLocated(_ target: String, waitForChange: Bool = false) async throws -> TonoLinkPoint {
        guard let point = try await locate(target, waitForChange: waitForChange) else { throw IPhoneAgentError("屏幕上找不到：\(target)") }
        try await hands.tap(point)
        return point
    }

    /// Home through AssistiveTouch → 主屏幕. The button sits wherever the user left it and fades when
    /// idle (UI-Venus then misses it), so tap the remembered position first and only look for the button
    /// again when the menu does not open. Each successful position is remembered for next time.
    func home() async throws -> String {
        var button = hands.layout.assistiveButton
        try await hands.tap(button)
        try await Task.sleep(for: .milliseconds(800))
        var item = try await locate(Self.assistiveHome, waitForChange: true)
        if item == nil {
            // Wrong spot: close whatever opened, find the button on screen, try once more.
            try await hands.key("esc")
            try await Task.sleep(for: .milliseconds(500))
            guard let found = try await locate(Self.assistiveButton, waitForChange: false) else {
                throw IPhoneAgentError("屏幕上找不到辅助触控按钮（请确认辅助功能里已打开辅助触控）")
            }
            button = found
            try await hands.tap(button)
            try await Task.sleep(for: .milliseconds(800))
            item = try await locate(Self.assistiveHome, waitForChange: true)
        }
        guard let item else { throw IPhoneAgentError("辅助触控菜单里找不到“主屏幕”") }
        try await hands.tap(item)
        hands.layout.assistiveButton = button
        hands.layout.assistiveHome = item
        hands.layout.save()
        return "home via AssistiveTouch (\(Int(button.x)),\(Int(button.y))) → (\(Int(item.x)),\(Int(item.y)))"
    }

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
