// SPDX-License-Identifier: MIT
// UI-Venus operating this iPhone, entirely on the phone: screenshot → UI-Venus picks one action →
// the board's HID performs it → fresh screenshot … until Finished/Answer. Ported from the firmware
// repo's tools/phone-agent/venus_agent.py (prompt, action handling, settle times), which ran the
// same loop on a Mac. The screen and the hands are behind `IPhoneAgentDevice` (the app wires the
// board's AirPlay stream and HID; tests use a fake).
import Foundation

public struct IPhoneFrame: Sendable {
    public let jpeg: Data
    public let width: Int
    public let height: Int
    /// Opaque frame counter: pass it back to `screenshot(after:)` to wait for a newer picture.
    public let frame: Int
    public init(jpeg: Data, width: Int, height: Int, frame: Int) { self.jpeg = jpeg; self.width = width; self.height = height; self.frame = frame }
}

/// One UI-Venus action. Points are 0–1000 of the screen.
public struct IPhoneAction: Equatable, Sendable {
    public var name: String
    public var points: [IPhonePoint]
    public var text: String
    public var direction: String?
    public var raw: String

    public struct IPhonePoint: Equatable, Sendable {
        public var x: Double, y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    /// Parses `<action>Click(point=(x, y))</action>` (the last `<action>` wins; without tags, the whole text).
    public static func parse(_ reply: String) -> IPhoneAction {
        // With `stop: ["</action>"]` the server leaves the closing tag out: take what follows the last <action>.
        let tagged = reply.ranges(of: #/(?s)<action>(.*?)</action>/#).last.map { String(reply[$0]) }
            ?? reply.range(of: "<action>", options: .backwards).map { String(reply[$0.lowerBound...]) }
        var raw = (tagged ?? reply)
        raw = raw.replacingOccurrences(of: "<action>", with: "").replacingOccurrences(of: "</action>", with: "")
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if tagged == nil, let line = raw.firstMatch(of: #/(?s)Action:\s*(.+)$/#) { raw = String(line.1).trimmingCharacters(in: .whitespacesAndNewlines) }
        // Some replies fall back to JSON: {"action_type": "scroll", "start_coordinate": [x, y], ...}
        let jsonName = raw.firstMatch(of: #/"action_type"\s*:\s*"([A-Za-z_]+)"/#).map { String($0.1).lowercased() }
        var name = jsonName ?? raw.firstMatch(of: #/^\s*([A-Za-z_]+)/#).map { String($0.1).lowercased() } ?? ""
        if jsonName == "scroll", raw.contains("end_coordinate") { name = "swipe" }
        var points: [IPhonePoint] = []
        for match in raw.matches(of: #/[\(\[]\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*[\)\]]/#) {
            if let x = Double(match.1), let y = Double(match.2) { points.append(.init(x, y)) }
        }
        let direction = raw.firstMatch(of: #/(?i)direction\s*=\s*['"]?(up|down|left|right)/#).map { String($0.1).lowercased() }
        let text = raw.firstMatch(of: #/(?s)(?:content|app|text)\s*=\s*(['"])(.*?)\1/#).map { String($0.2) }
            // JSON fallback: {"action_type": "LaunchApp", "app_name": "小红书"} / "text" / "content"
            ?? raw.firstMatch(of: #/(?s)"(?:app_name|app|text|content)"\s*:\s*"((?:[^"\\]|\\.)*)"/#).map { String($0.1) }
            ?? raw.firstMatch(of: #/(?s)\(\s*(['"])(.*?)\1/#).map { String($0.2) } ?? ""
        return IPhoneAction(name: name, points: points, text: text, direction: direction, raw: raw)
    }

    /// The model may answer in 0–1000 or in screenshot pixels; anything above 1000 is pixels.
    public static func normalized(_ p: IPhonePoint, width: Int, height: Int) -> IPhonePoint {
        var x = p.x, y = p.y
        if x > 1000 || y > 1000 { x = x * 1000 / Double(max(width, 1)); y = y * 1000 / Double(max(height, 1)) }
        return .init(min(max(x, 0), 1000), min(max(y, 0), 1000))
    }
}

@MainActor public protocol IPhoneAgentDevice: AnyObject {
    /// Makes sure the screen stream and HID are usable (may throw with a user-facing reason).
    func prepare() async throws
    func screenshot(after frame: Int?) async throws -> IPhoneFrame
    /// Performs one action with points already in 0–1000; returns what was done.
    func perform(_ action: IPhoneAction) async throws -> String
}

public struct IPhoneAgentStep: Sendable {
    public let index: Int
    public let action: String
    public let executed: String
    public let modelSeconds: Double
    public let screenshot: Data
}

public struct IPhoneAgentResult: Sendable {
    public let answer: String
    public let finished: Bool
    public let steps: [IPhoneAgentStep]
    public let seconds: Double
}

public struct IPhoneAgentError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

@MainActor public final class IPhoneAgent {
    public nonisolated static let defaultModel = "ui-venus-2-9b"
    public var model: String
    public var maxSteps: Int
    public var settle: Duration
    public var onStep: ((IPhoneAgentStep) -> Void)?
    private let client: VenusClient
    private let device: IPhoneAgentDevice

    public init(device: IPhoneAgentDevice, client: VenusClient = VenusClient(), model: String = IPhoneAgent.defaultModel,
                maxSteps: Int = 15, settle: Duration = .milliseconds(1200)) {
        self.device = device; self.client = client; self.model = model; self.maxSteps = maxSteps; self.settle = settle
    }

    /// Sends one request per step: the system prompt, earlier turns as text, the current screenshot.
    nonisolated static func messages(task: String, turns: [(feedback: String, reply: String)], feedback: String, jpeg: Data) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt.replacingOccurrences(of: "{user_task}", with: task)]]
        for turn in turns {
            messages.append(["role": "user", "content": turn.feedback.isEmpty ? "(previous screenshot omitted)" : turn.feedback])
            messages.append(["role": "assistant", "content": turn.reply])
        }
        messages.append(["role": "user", "content": [
            ["type": "text", "text": "Current Screenshot:\n" + feedback],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
        ]])
        return messages
    }

    public func run(_ task: String) async throws -> IPhoneAgentResult {
        let started = ContinuousClock.now
        try await device.prepare()
        var turns: [(feedback: String, reply: String)] = []
        var feedback = ""
        var steps: [IPhoneAgentStep] = []
        var lastFrame: Int?
        var previous: (jpeg: Data, action: IPhoneAction)?
        var loopGuard = IPhoneLoopGuard()
        for index in 1...maxSteps {
            try Task.checkCancellation()
            let shot = try await Self.deadline(.seconds(20), "截图") { try await self.device.screenshot(after: lastFrame) }
            // Tell the model when its last action left the screen as it was (a missed tap, a Home
            // that did not take effect): otherwise it believes the action worked and repeats it.
            if let previous, Self.visibleActions.contains(previous.action.name),
               let difference = IPhoneScreenDiff.mean(previous.jpeg, shot.jpeg), difference < IPhoneScreenDiff.unchanged {
                let note = "The screen looks unchanged after your previous action (\(previous.action.raw)): it may not have taken effect."
                feedback = feedback.isEmpty ? note : note + " " + feedback
            }
            let t0 = ContinuousClock.now
            let messages = Self.messages(task: task, turns: turns, feedback: feedback, jpeg: shot.jpeg)
            let reply = try await Self.deadline(stepTimeout, "UI-Venus 请求") {
                try await self.client.chat(model: self.model, messages: messages, maxTokens: 512, timeout: 90)
            }
            let modelSeconds = Self.seconds(ContinuousClock.now - t0)
            var action = IPhoneAction.parse(reply)
            action.points = action.points.map { IPhoneAction.normalized($0, width: shot.width, height: shot.height) }
            let thought = reply.firstMatch(of: #/(?s)<think>(.*?)</think>/#).map { String($0.1).trimmingCharacters(in: .whitespacesAndNewlines) }
            func done(_ answer: String, finished: Bool) -> IPhoneAgentResult {
                let step = IPhoneAgentStep(index: index, action: action.raw, executed: "done", modelSeconds: modelSeconds, screenshot: shot.jpeg)
                onStep?(step)
                return IPhoneAgentResult(answer: answer, finished: finished, steps: steps + [step], seconds: Self.seconds(ContinuousClock.now - started))
            }
            switch action.name {
            case "finished", "answer":
                return done(action.text.isEmpty ? String((thought ?? action.raw).prefix(200)) : action.text, finished: true)
            case "calluser":
                return done("需要你来处理：" + (action.text.isEmpty ? String((thought ?? action.raw).prefix(200)) : action.text), finished: false)
            default: break
            }
            switch loopGuard.record(action) {
            case .stop(let answer):
                return done(answer, finished: false)
            case .nudge(let note):
                // Do not repeat the action again: ask once more about this same screen.
                let step = IPhoneAgentStep(index: index, action: action.raw, executed: "skipped: repeated without progress",
                                           modelSeconds: modelSeconds, screenshot: shot.jpeg)
                steps.append(step)
                onStep?(step)
                turns.append((feedback, reply))
                feedback = note
                continue
            case .proceed:
                break
            }
            let executed: String
            var nextFeedback = ""
            do {
                executed = try await Self.deadline(stepTimeout, "动作") { try await self.device.perform(action) }
                if ["launchapp", "launch"].contains(action.name) {
                    nextFeedback = "Searched for \(action.text.isEmpty ? "the app" : action.text) and opened the top result: check that it is the right app."
                }
            } catch {
                executed = "FAILED \(error)"
                nextFeedback = "The previous action was not executed: \(error)"
            }
            let step = IPhoneAgentStep(index: index, action: action.raw, executed: executed, modelSeconds: modelSeconds, screenshot: shot.jpeg)
            steps.append(step)
            onStep?(step)
            turns.append((feedback, reply))
            feedback = nextFeedback
            lastFrame = shot.frame
            previous = (shot.jpeg, action)
            try await Task.sleep(for: settle)
        }
        return IPhoneAgentResult(answer: "没有在 \(maxSteps) 步内完成", finished: false, steps: steps, seconds: Self.seconds(ContinuousClock.now - started))
    }

    /// Actions that should visibly change the screen (Wait and the answers do not).
    static let visibleActions: Set<String> = ["click", "tap", "doubleclick", "longpress", "drag", "swipe", "scroll",
                                              "presshome", "launchapp", "launch", "pressenter", "type"]

    /// Upper bound for one model request or one action (a stalled request must not freeze the agent).
    public var stepTimeout: Duration = .seconds(100)

    /// Runs `body`, throwing if it has not finished within `limit` (the body is cancelled).
    static func deadline<T: Sendable>(_ limit: Duration, _ what: String, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw IPhoneAgentError("\(what)超时（\(Int(limit.components.seconds)) 秒）")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    nonisolated static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    // UI-Venus-2's official mobile prompt and action format (inclusionAI/UI-Venus mobile_example.py),
    // with iPhone notes in Instructions. xiaozhi-link found a custom format loses the model's edge.
    public nonisolated static let systemPrompt = """
    **You are a GUI Agent.** Your role is to analyze the user's task, provide clear and accurate answers to their questions, and execute the task with precise actions.

    ### Available Actions
    You may execute one of the following functions:

    - Click(point=(x1, y1))
    > Perform a tap action at the specified screen coordinate. Valid coordinates range from the top-left corner (0, 0) to the bottom-right corner (999, 999).

    - Drag(start=(x1, y1), end=(x2, y2))
    > Perform a drag action by long-pressing at the start coordinate for a few seconds and then dragging to the end coordinate. This is typically used for adjusting app layouts, moving sliders, solving slider captchas, etc. Valid coordinates range from the top-left corner (0, 0) to the bottom-right corner (999, 999).

    - Swipe(start=(x1, y1), end=(x2, y2))
    > Perform a swipe action by dragging from the start coordinate to the end coordinate. This is typically used for scrolling to find content, switching tabs, pulling down the notification shade, etc. Valid coordinates range from the top-left corner (0, 0) to the bottom-right corner (999, 999).

    - DoubleClick(point=(x1, y1))
    > Perform a double tap action at the specified screen coordinate. Valid coordinates range from the top-left corner (0, 0) to the bottom-right corner (999, 999).

    - LongPress(point=(x1, y1))
    > Perform a long-press action at the specified screen coordinate for a certain duration. This can be used to trigger additional options, such as copy, forward, delete, etc. Valid coordinates range from the top-left corner (0, 0) to the bottom-right corner (999, 999).

    - Type(content='')
    > Enter the specified text into the currently active input field.

    - LaunchApp(app='')
    > Launch the target app. Use this action when the target app is not currently visible on the screen.

    - Wait()
    > Wait for the current page, animation, or content to finish loading.

    - CallUser(content='')
    > Request user takeover or additional information when needed, for example, when there are multiple on-screen options that satisfy the requirement.

    - PressHome()
    > Return to the system home screen.

    - PressEnter()
    > Perform an Enter key action.

    - Answer(content='')
    > Answer the user's questions as requested.

    - Finished(content='')
    > Mark the task as completed and inform the user of the task execution status.

    ### Instructions
    - Make sure you understand the task goal to avoid wrong actions.
    - Make sure you carefully examine the current screenshot. Sometimes the summarized history might not be reliable, over-claiming some effects.
    - If additional information is needed during task execution, use `CallUser` to interact with the user.
    - Consider exploring the screen by using the `Swipe` action with different directions to reveal additional content.
    - The device is an iPhone (iOS). There is no system Back key: to go back, tap the visible back button (usually "<" at the top-left).
    - The round grey AssistiveTouch button floating on the right edge is part of the automation tool: never tap it.
    - To open an app, use `LaunchApp` with its name: it searches the phone and opens the best match. Do not look for app icons on the home screen. If a different app opened, use `LaunchApp` again with the app's English name.
    - When the task asks you to read, check or report something, use `Answer` as soon as the screen shows it. Do not leave that screen first (for example back to a list or the home screen), even if the task also says to go back afterwards: answering is the end of the task.
    - If a system permission or privacy prompt is in front (for example 允许 / 不允许, 共享联系人, 位置, 通知), do not choose for the user: use `CallUser` and say what the prompt asks.
    - Chat apps (微信, Messages, 短信 …): tap the input bar once before typing; if it shows 「按住 转文字」or 「按住 说话」it is in voice mode and typed text goes nowhere. After the text is visibly in the field, send it with `PressEnter()`. The board's hardware keyboard makes WeChat keep ⊕ on the right instead of turning it into 「发送」, so do not hunt for a send button; tap a visible 「发送」only if one is actually on screen.
    - Typing Chinese switches the iOS keyboard and can leave the input-source list (「简体拼音 / English (US) / 表情符号」) over the screen. Tap the message area once to dismiss it before sending.
    - After sending, look at the new screenshot: the message must appear as a bubble in the conversation and the input field must be empty. Text still sitting in the field means it was not sent.
    - Answer in Chinese.

    ### Output Format
    <think> your thinking process </think>
    <action> the next action </action>

    ### User Task
    {user_task}
    """
}


/// Finds one on-screen element with UI-Venus (grounding), for the agent's own system gestures:
/// the AssistiveTouch button and its menu sit wherever the user left them, so fixed coordinates
/// break from phone to phone.
public enum IPhoneGrounding {
    public static func prompt(_ target: String) -> String {
        """
        You are a GUI grounding model. Find this element in the iPhone screenshot: \(target)
        Output only <action>Click(point=(x, y))</action> at its centre, with x and y from 0 to 999 of the screenshot.
        If it is not visible, output only <action>CallUser(content='not found')</action>.
        """
    }

    /// Returns the element's centre in 0–1000, or nil when the model does not see it.
    public static func locate(_ target: String, in frame: IPhoneFrame, client: VenusClient = VenusClient(),
                              model: String = IPhoneAgent.defaultModel) async throws -> IPhoneAction.IPhonePoint? {
        let messages: [[String: Any]] = [["role": "user", "content": [
            ["type": "text", "text": prompt(target)],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + frame.jpeg.base64EncodedString()]],
        ]]]
        let action = IPhoneAction.parse(try await client.chat(model: model, messages: messages, maxTokens: 128, timeout: 60))
        guard ["click", "tap"].contains(action.name), let point = action.points.first else { return nil }
        return IPhoneAction.normalized(point, width: frame.width, height: frame.height)
    }
}
