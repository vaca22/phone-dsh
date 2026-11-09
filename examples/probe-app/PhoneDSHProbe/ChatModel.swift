// SPDX-License-Identifier: MIT
import PhoneDSHSSH
// phone-dsh phone DSH — iOS probe app: interactive chat over the phone host.
//
// The Chat page boots the same `PhoneDSHHost` the scenario runner uses, opens
// one harness session on `/dsh/workspace` and lets a person type prompts and
// watch the agent work: streamed assistant text, every tool call with its
// arguments, every tool result, turn endings and usage. The model credential
// stays on the host side (Keychain → `CredentialProvider`); the Worker only
// ever sees a placeholder key, exactly like the scenario runner.

import Foundation
import Observation
import ProbeKit
import SwiftUI
import UIKit
import CryptoKit
import PhoneDSHAgentCore
import PhoneDSH
import enum PhoneDSHController.DeviceTier
import struct PhoneDSHController.BudgetTable
import struct PhoneDSHController.RestartPolicy
import PhoneDSHEngine
import PhoneDSHShell
import PhoneDSHADB
import PhoneDSHBot
import PhoneDSHBLE
import PhoneDSHVenus

// MARK: - Settings persistence

/// Non-model preferences still live in UserDefaults. The model service,
/// endpoint and API key live only in `PhoneModelProviderSettings` (one
/// non-secret document plus the device Keychain); both the native Chat page and
/// the complete Web page read that same authority at every host start. There is
/// no second base-URL/key fallback to keep an old service alive after deletion.
enum ChatSettings {
    private static let egressKey = "chat.egress.allow"
    /// Hosts the Worker may fetch anonymously through the host gateway (exact host names; the gateway has no wildcard).
    static let defaultEgressAllow = "wttr.in, api.open-meteo.com, geocoding-api.open-meteo.com, api.github.com, raw.githubusercontent.com, github.com, pypi.org, files.pythonhosted.org, registry.npmjs.org, cdn.jsdelivr.net, unpkg.com, en.wikipedia.org, zh.wikipedia.org, httpbin.org, example.com"
    /// A single `*` admits every host; the gateway and the credential provider both understand it.
    static let allowAllEgress = "*"
    static var egressAllow: String {
        get { UserDefaults.standard.string(forKey: egressKey) ?? ProcessInfo.processInfo.environment["PDSH_EGRESS_ALLOW"] ?? defaultEgressAllow }
        set { UserDefaults.standard.set(newValue, forKey: egressKey) }
    }

    private static let keepAliveKey = "chat.background.keepalive"
    /// Keep the agent running in the background with a silent audio session
    /// (instead of parking the host). On by default.
    static var backgroundKeepAlive: Bool {
        get { UserDefaults.standard.object(forKey: keepAliveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepAliveKey) }
    }
}

// MARK: - Transcript items

/// One server-registered command exposed by the active DSH session.
struct NativeCommandDescriptor: Identifiable, Equatable {
    let name: String
    let description: String
    let inputHint: String?
    let acceptsAttachments: Bool
    /// DSH `definitionId`. The official composer menu keys its localized face
    /// on this identity, never on the display copy.
    var definitionID: String? = nil
    /// Parsed from the catalog's `input` object: official clients only claim
    /// arguments from a command that declares an input shape; a bare pick of
    /// every other row executes the command directly.
    var hasInput: Bool = false
    var id: String { name }
}

/// The immediate canonical Remote acknowledgment for a command invocation.
struct NativeCommandExecution: Identifiable, Equatable {
    let id: String
    let name: String
    let line: String
    let kind: String
    let text: String?
}

/// One row of the composer's localized command face.
struct NativeCommandFace: Equatable {
    let title: String
    let description: String
    /// Localized input spelling written into the draft (official `claimToken`).
    let token: String
    /// SF Symbol standing in for the official icon asset.
    let icon: String
}

/// The composer menu's command vocabulary: the localized face of the
/// first-party DSH commands plus the token/alias resolution the web client
/// performs before it executes a typed line.
///
/// The Host catalog carries English descriptors (`compact`, `Compact older
/// conversation history`). Official clients replace the six built-ins with the
/// `command` locale namespace (`packages/client/ui-commands/src/client/`:
/// `presentation.ts`, `locales.ts`, `resolution.ts`) and keep the catalog text
/// for every other row. The phone has no locale seat for that namespace, so the
/// same table is carried here, keyed by `definitionId` first and by canonical
/// name for hosts that omit it.
enum NativeCommandCatalog {
    private static let facesByDefinition: [String: NativeCommandFace] = [
        "@deepseek-ai/dsh-command-goal":
            NativeCommandFace(title: "目标", description: "设置或查看长期任务目标",
                              token: "目标", icon: "target"),
        "@deepseek-ai/dsh-plan-mode":
            NativeCommandFace(title: "计划", description: "进入或退出计划模式",
                              token: "计划", icon: "list.bullet.rectangle"),
        "@deepseek-ai/dsh-command-feedback":
            NativeCommandFace(title: "反馈", description: "发送关于当前会话的反馈",
                              token: "反馈", icon: "paperplane"),
        "@deepseek-ai/dsh-command-compact":
            NativeCommandFace(title: "压缩", description: "压缩以上对话内容",
                              token: "压缩", icon: "rectangle.compress.vertical"),
        "@deepseek-ai/dsh-permission-presets":
            NativeCommandFace(title: "权限", description: "切换权限预设（沙箱模式与审批策略）",
                              token: "权限", icon: "lock.shield"),
        "@deepseek-ai/dsh-session-log-export":
            NativeCommandFace(title: "下载日志", description: "将当前会话内容导出为 ZIP",
                              token: "导出", icon: "square.and.arrow.down"),
    ]

    /// Canonical catalog name → definition id, used when the phone Host's
    /// descriptor carries no `definitionId`.
    private static let definitionByCommandName: [String: String] = [
        "goal": "@deepseek-ai/dsh-command-goal",
        "plan": "@deepseek-ai/dsh-plan-mode",
        "feedback": "@deepseek-ai/dsh-command-feedback",
        "compact": "@deepseek-ai/dsh-command-compact",
        "permission": "@deepseek-ai/dsh-permission-presets",
        "export": "@deepseek-ai/dsh-session-log-export",
    ]

    /// Typed spellings official `TOKEN_ALIASES` resolves, plus the canonical
    /// English names. Keys are lowercased; Chinese tokens are unaffected.
    private static let commandNameByToken: [String: String] = [
        "goal": "goal", "目标": "goal",
        "plan": "plan", "计划": "plan",
        "feedback": "feedback", "反馈": "feedback",
        "compact": "compact", "压缩": "compact",
        "permission": "permission", "权限": "permission",
        "export": "export", "导出": "export",
    ]

    static func definitionID(for descriptor: NativeCommandDescriptor) -> String? {
        if let id = descriptor.definitionID, !id.isEmpty { return id }
        return definitionByCommandName[descriptor.name.lowercased()]
    }

    /// The localized menu face for a first-party descriptor; nil for any other
    /// row, which keeps its catalog name and description.
    static func face(for descriptor: NativeCommandDescriptor) -> NativeCommandFace? {
        definitionID(for: descriptor).flatMap { facesByDefinition[$0] }
    }

    static func title(for descriptor: NativeCommandDescriptor) -> String {
        face(for: descriptor)?.title ?? descriptor.name
    }

    static func description(for descriptor: NativeCommandDescriptor) -> String {
        face(for: descriptor)?.description ?? descriptor.description
    }

    static func icon(for descriptor: NativeCommandDescriptor) -> String {
        face(for: descriptor)?.icon ?? "terminal"
    }

    /// Resolve a typed token (with or without the leading slash) against the
    /// live catalog, the way official `resolveCommand` does: the registered
    /// name first, then the localized spelling of a known definition. Case is
    /// folded so a phone keyboard's autocapitalized `Compact` still resolves.
    static func resolve(_ typed: String, in commands: [NativeCommandDescriptor]) -> NativeCommandDescriptor? {
        let token = typed.hasPrefix("/") ? String(typed.dropFirst()) : typed
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = commands.first(where: { $0.name == trimmed }) { return exact }
        if let folded = commands.first(where: { $0.name.lowercased() == trimmed.lowercased() }) { return folded }
        guard let canonical = commandNameByToken[trimmed.lowercased()] else { return nil }
        return commands.first { descriptor in
            descriptor.name.lowercased() == canonical
                || definitionID(for: descriptor) == definitionByCommandName[canonical]
        }
    }

    /// Official `/command 不接受附件` refusal, surfaced before a line is sent.
    static func attachmentRefusal(for name: String) -> String {
        "/\(name) 不接受附件，请先移除附件"
    }
}

/// Compaction wording and marker assembly shared by the live stream and the
/// durable projection, so one compaction always reads as one row.
///
/// Official strings come from `packages/client/ui-chat/src/client/locale.ts`
/// (`message.compaction*`) and the marker shape from
/// `chat/CompactionItem.tsx`: title 上下文已压缩, one collapsed summary line,
/// the summary itself behind a disclosure (not modelled by the phone row yet).
enum NativeCompaction {
    static let title = "上下文已压缩"
    static let running = "正在压缩…"
    static let expand = "点击查看压缩摘要"
    static let unavailable = "压缩摘要不可用"
    /// Official `message.compaction.commandTitle` for a manual `/compact`.
    static let manualTitle = "compact"

    static func completed(items: Int, tokens: Int) -> String {
        "已压缩 \(items) 条历史记录（约 \(tokens) tokens）"
    }

    /// Durable facts cited by one replacement checkpoint.
    struct Facts: Equatable {
        var itemCount: Int?
        var tokenCount: Int?
        var summary: String?
        /// Settlement text of the manual command that produced the checkpoint.
        var commandText: String?
    }

    /// The row's single summary line, in official precedence: structured
    /// counts, then the manual command settlement, then the disclosure hint
    /// and finally the unavailable note.
    static func summaryLine(for facts: Facts) -> String {
        if let items = facts.itemCount, let tokens = facts.tokenCount {
            return completed(items: items, tokens: tokens)
        }
        if let text = facts.commandText, !text.isEmpty { return text }
        if let summary = facts.summary, !summary.isEmpty { return expand }
        return unavailable
    }

    static func summaryLine(forSummary summary: String) -> String {
        summary.isEmpty ? unavailable : summary
    }
}

/// One durable DSH session journal record shown in the native trajectory ledger.
/// `payload` preserves the original event envelope for detail inspection.
struct NativeTrajectoryEntry: Identifiable, Equatable {
    enum Category: String, CaseIterable, Identifiable {
        case systemPrompt, userMessage, steeringMessage, developerMessage, assistantMessage, toolCall, toolResult
        case requestBoundary, compaction, command, sessionBoundary, otherBusiness
        var id: String { rawValue }
    }

    let id: String
    let sessionID: String
    let seq: Int
    let timestamp: Date
    let eventType: String
    let category: Category
    let preview: String
    let payload: JSONValue
}

/// A permission the harness asked for and the person has not answered yet.
struct ChatPermission: Identifiable, Equatable {
    let id: String
    let tool: String
    let summary: String
    /// 这次工具调用的参数,只用来在卡上写相对路径/命令原文;拿不到就是空。
    var arguments: [String: String] = [:]
}

/// One current-session permission mode returned by the active DSH Worker.
struct NativeAccessMode: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
}

/// UI wording for permission modes, keyed only by the stable catalog id.
/// The host's `name` is deliberately ignored: it can be an internal English
/// code (`danger-full-access`, `workspace-write`) that must never reach the UI.
/// An id without a mapping is not shown at all.
enum AccessModeWording {
    static func title(for id: String) -> String? {
        switch id {
        // 名字只翻成中文,不合并档位、不改宿主的顺序;翻不出中文的一律不露代号。
        case "read-only", "phone-read-only": return "仅可查看"
        case "workspace-write", "phone": return "工作区内修改"
        case "danger-full-access", "bypassPermissions": return "完全权限"
        case "auto": return "自动判断"
        case "plan": return "只出方案"
        case "acceptEdits": return "改前不问"
        default: return nil
        }
    }

    /// 只能拿来报状态、不能给人选的两档:当前组合没匹配上任何预设时的那一格。
    static func statusText(forCurrent id: String?) -> String? {
        guard let id else { return nil }
        if id == "custom" { return "自定义 · 当前" }
        return title(for: id) == nil ? "其它模式 · 当前" : nil
    }

    /// 没有命名映射的模式(落到「其它模式」),菜单里选它之前先说明一句。
    static func isUnnamed(_ id: String) -> Bool { title(for: id) == "其它模式" }

    /// Extra sentence for the modes that widen what the agent may do without
    /// asking. Keyed by the same ids so both ids that mean 全部放开 share one
    /// sentence.
    static func confirmationMessage(for id: String) -> String? {
        switch id {
        case "bypassPermissions", "danger-full-access":
            return "之后改文件、跑命令都不再问你。"
        case "acceptEdits":
            return "开了之后，改文件不再问，跑命令还会问。"
        default:
            // 未命名的模式:选它之前把「这是它自己决定的」说清楚。
            return title(for: id) == "其它模式"
                ? "这个模式没在这个版本里命名,行为由它自己决定。"
                : nil
        }
    }
}

/// One file under the materialized workspace.
struct WorkspaceFile: Identifiable, Hashable {
    let relativePath: String
    let size: Int
    var id: String { relativePath }
}

// MARK: - Model

/// Owns the host, the harness session and the transcript. One instance per app
/// launch; the page observes it.
@MainActor
@Observable
final class ChatModel {
    static let shared = ChatModel()

    /// 参数只取一层标量,拼成 [键:字符串];嵌套结构换成 JSON 文本,够卡上用。
    static func flattenedArguments(_ value: JSONValue) -> [String: String] {
        guard let object = value.objectValue else { return [:] }
        var result: [String: String] = [:]
        for (key, item) in object {
            if let string = item.stringValue { result[key] = string }
            else if let number = item.numberValue { result[key] = String(describing: number) }
            else if let data = try? item.encoded(), let text = String(data: data, encoding: .utf8) {
                result[key] = text
            }
        }
        return result
    }
    private static let currentSessionDefaultsKey = "chat.dsh.currentSessionID"
    private static let retryableRequestIDsDefaultsKey = "chat.dsh.retryableRequestIDs"

    /// Visible one-point anchor the Chat page embeds; WebKit needs the page in
    /// a window for the Worker to run (G2-FIX-21).
    let anchor = VisibleEngineAnchor()

    /// Display label for the model the selected provider asked the DSH
    /// session to use. The provider document itself is the source of truth;
    /// this value is refreshed from it whenever the host starts.
    var modelName = ""
    var egressAllow = ChatSettings.egressAllow
    var backgroundKeepAlive = ChatSettings.backgroundKeepAlive

    private(set) var hostState = "stopped"
    private var lastPrompt: (String, [HarnessAttachment])?
    private(set) var statusLine = "Host not started"
    /// The session's DSH goal (the input-dock GoalBar source).
    private(set) var goal: HarnessGoal?
    private(set) var busy = false
    private(set) var turnRunning = false
    /// Bumped on every turn boundary. The composer queue re-reads the durable
    /// inbox from this even when `turnRunning` flips false→true between two
    /// observations and no intermediate render is guaranteed.
    private(set) var turnBoundaryRevision = 0
    /// Bumped for every mapped `agent/inbox/spliced` event. Claims/removals do
    /// not map to an event kind, so turn boundaries cover those separately.
    private(set) var inboxSplicedRevision = 0
    private(set) var eventStreamRecovering = false
    private(set) var userFacingError: String?
    /// Non-secret, user-facing explanation of the last search launch decision.
    /// A normal first launch without a model service leaves this nil.
    private(set) var searchLaunchWarning: String?
    /// Exact MCP admission/credential policy for this host. The native MCP
    /// editor and the Web bridge update the same object in place.
    private(set) var mcpAccessPolicy = MCPEgressPolicy()
    private(set) var items: [ChatItem] = []
    private(set) var transcriptHasMore = false
    private(set) var transcriptError: String?
    private(set) var trajectoryEntries: [NativeTrajectoryEntry] = []
    private(set) var trajectoryHasMore = false
    private(set) var trajectoryError: String?
    private(set) var availableCommands: [NativeCommandDescriptor] = []
    private(set) var commandsLoading = false
    private(set) var commandsError: String?
    private(set) var pendingPermission: ChatPermission?
    /// 工具名到最近一次参数:权限请求本身不带参数,靠这层对上这次调用。
    private var recentToolArguments: [String: [String: String]] = [:]
    private(set) var pendingQuestion: HarnessQuestion?
    private(set) var availableAccessModes: [NativeAccessMode] = []
    private(set) var currentAccessMode: String?
    private(set) var accessModeError: String?
    /// True while this session's permission catalog/projection is being read,
    /// including the automatic retries; the composer shows a small spinner
    /// instead of a page banner.
    private(set) var accessModeLoading = false
    /// Bumped by every refresh so an older retry loop stops as soon as a newer
    /// refresh (or a session switch) starts.
    private var accessModeRefreshGeneration = 0
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var modelRequests = 0
    private(set) var sessionStats: NativeSessionStats?
    private(set) var tokenUsage: NativeTokenUsage?
    private(set) var contextPressure: NativeContextPressure?
    private(set) var contextBreakdown: NativeContextBreakdown?
    /// Raw `session/projections` values from the last refresh. The session
    /// page consumes `todos/plan/inbox/userQuestions/subagentCatalog/goal/title`
    /// from this one snapshot instead of making a separate call per surface.
    private(set) var projectionValues: JSONValue?
    var projectedTodos: JSONValue? { projectionValues?["todos"] }
    var projectedPlan: JSONValue? { projectionValues?["plan"] }
    var projectedInbox: JSONValue? { projectionValues?["inbox"] }
    var projectedQuestions: JSONValue? { projectionValues?["userQuestions"] }
    var projectedSubagents: JSONValue? { projectionValues?["subagentCatalog"] }
    var projectedGoal: JSONValue? { projectionValues?["goal"] }
    var projectedTitle: String? { projectionValues?["title"]?.stringValue }
    /// Session projection `agentPreset` is a recorded preset identity; the
    /// header shows it as a read-only label (the picker lives in settings).
    var projectedAgentPreset: String? {
        projectionValues?["agentPreset"]?.stringValue
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// `agentPresets/list` display names keyed by preset id; the header falls
    /// back to the recorded id until the roster arrives.
    private(set) var agentPresetNames: [String: String] = [:]
    var agentPresetLabel: String? {
        guard let id = projectedAgentPreset else { return nil }
        return agentPresetNames[id] ?? id
    }

    func refreshAgentPresetNames() async {
        guard agentPresetNames.isEmpty else { return }
        do {
            let transport = try await transportForManagement()
            let response = try await transport.call("agentPresets/list", args: .object([:]))
            var names: [String: String] = [:]
            for row in response["presets"]?.arrayValue ?? [] {
                guard let id = row["id"]?.stringValue else { continue }
                names[id] = row["name"]?.stringValue ?? id
            }
            agentPresetNames = names
        } catch {
            // The read-only label keeps the id if the roster is unavailable.
        }
    }

    /// Host-declared image attachment limits; fall back to the deployment
    /// defaults when the projection is absent.
    var imageLimits: NativeImageLimits {
        guard let limits = projectionValues?["imageLimits"] else { return .fallback }
        return NativeImageLimits(
            maxImagesPerMessage: limits["maxImagesPerMessage"]?.intValue ?? 20,
            maxImageBytes: limits["maxImageBytes"]?.intValue ?? 20 * 1024 * 1024,
            maxMessageImageBytes: limits["maxMessageImageBytes"]?.intValue ?? 200 * 1024 * 1024)
    }

    /// Closed-Turn control state. `nil` for the open Turn (official renders no
    /// control row while running).
    func turnProcessState(for turn: Int) -> NativeTurnProcessState? {
        guard let reason = turnEndReasons[turn] else { return nil }
        let elapsed = turnStartTimes[turn].flatMap { start in
            turnEndTimes[turn].map { max(0, $0.timeIntervalSince(start)) }
        }
        return NativeTurnProcessState.resolve(endReasonKind: reason, elapsed: elapsed)
    }

    /// Official `todos` projection → the dock's view model. Unknown statuses are
    /// dropped rather than guessed; an empty projection renders no dock.
    var todoDockItems: [NativeTodoItem] {
        (projectedTodos?.arrayValue ?? []).compactMap { row in
            guard let content = row["content"]?.stringValue,
                  let status = NativeTodoItem.Status(wireValue: row["status"]?.stringValue ?? "")
            else { return nil }
            return NativeTodoItem(content: content, status: status)
        }
    }

    /// Official `plan` projection → the composer chip. Absent/null means the
    /// capability or the session state is absent.
    var planModeState: NativePlanModeState? {
        guard let plan = projectedPlan, plan.objectValue != nil else { return nil }
        return NativePlanModeState(active: plan["active"]?.boolValue ?? false,
                                   pending: plan["pending"]?.boolValue ?? false)
    }

    /// `/plan off` through the live command registry, then refresh the folded
    /// projection so the chip disappears only when the host confirms it.
    func exitPlanMode() async {
        _ = await executeCommand(name: "plan", input: "off")
        await refreshNativeMetrics()
    }
    private var nativeMetricsRefreshTask: Task<Void, Never>?
    private var activeTurn: Int?
    private var activeStep: Int?
    /// `turn/start` time for the open Turn, driving the transcript running
    /// clock (distinct from the host `startedAt`).
    private(set) var activeTurnStartedAt: Date?
    /// Durable per-Turn facts for the closed-Turn control row. History replay
    /// needs its own projector facts; live turns fill these from the events.
    private(set) var turnStartTimes: [Int: Date] = [:]
    private(set) var turnEndReasons: [Int: String] = [:]
    private(set) var turnEndTimes: [Int: Date] = [:]
    /// 这次引擎起来的时间点,「运行状态」第一行要报「已运行多久」;停掉就清空。
    private(set) var startedAt: Date?
    private(set) var files: [WorkspaceFile] = []
    private(set) var previewPath: String?
    private(set) var previewText: String?

    var isStarted: Bool { host != nil }
    /// True between the background park and the foreground resume (D14).
    private(set) var parked = false
    /// True while the app is in the background and the silent audio session
    /// keeps the host (and, if WebKit cooperates, the Worker) running.
    private(set) var keepingAlive = false

    private var host: PhoneDSHHost?
    private var botLaunch: BotRuntimeComposition.Launch?
    /// UI-visible Bot runtime state; set by the composition whenever the Host
    /// rebinds, a recovery fails, or the runtime stops.
    private(set) var botRuntimeState: BotRuntimeState = .idle
    var botRuntimeIssue: String? {
        if case .failed(let message) = botRuntimeState { return message }
        return nil
    }
    /// The production Bot page builds its drivers from this composition; it
    /// is created before the first Host so the page never falls back to a
    /// fixture.
    var botRuntime: BotRuntimeComposition? { botLaunch?.composition }
    private var phoneCapabilityBridge: PhoneCapabilityBridge?
    private let keepAlive = SilentAudioKeepAlive.shared
    private var backgroundHeartbeat: Task<Void, Never>?
    /// Harness events handled so far; the background heartbeat logs the delta
    /// so the status log shows whether the Worker made progress while hidden.
    private var eventsHandled = 0
    /// Keeps the process alive while the host drains and parks after the
    /// app left the foreground (the drain window is up to `drainDeadline`).
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var harness: (any AgentHarness)?
    private var sessionID: String?
    var currentSessionID: String? { sessionID }
    private var transcriptReady = false
    var isTranscriptReady: Bool { transcriptReady }
    /// The last transcript is on screen from disk while the engine boots.
    private(set) var isShowingCachedTranscript = false
    private var transcriptThroughSeq: Int?
    private var transcriptBeforeSeq: Int?
    private var hostLifecycleTransition = false
    // Planned-restart policy (see RestartPolicy): one sample per minute,
    // executed only at a tool-call boundary.
    private var restartPolicyTask: Task<Void, Never>?
    private var restartPolicyHighSamples = 0
    private var restartPolicySawTermination = false
    private var restartPolicyBudget: BudgetTable?
    private var failedHost: PhoneDSHHost?
    private(set) var engineNeedsReset = false
    /// One automatic reset per process launch (see ``start(autoRecover:)``).
    /// A fault that survives it keeps the manual button and stays fail-loud.
    private var autoRecoveryAttempted = false
    private var foregroundResumeRequested = false
    private var backgroundParkRequested = false
    var canSend: Bool { harness != nil && sessionID != nil && transcriptReady && !eventStreamRecovering && !busy && !parked && !hostLifecycleTransition }
    var canStartBySending: Bool {
        ChatEngineLifecycle.canStartBySending(hostIsStopped: host == nil,
                                              busy: busy,
                                              parked: parked,
                                              hostLifecycleTransition: hostLifecycleTransition)
    }
    private(set) var modelProviderIssue: String? = "请先配置模型服务和 API Key"

    func refreshModelProviderReadiness() {
        let settings = PhoneModelProviderSettings.shared
        do {
            guard let profile = try settings.load().selected else {
                modelProviderIssue = "请先配置模型服务和 API Key"
                return
            }
            switch try settings.apiKeyStatus(for: profile.id) {
            case .present: modelProviderIssue = nil
            case .missing: modelProviderIssue = "请先配置模型服务的 API Key"
            case .unreadable: modelProviderIssue = "无法读取 API Key，请解锁设备后重试"
            }
        } catch {
            modelProviderIssue = "无法读取模型服务配置，请检查设置"
        }
    }

    var displayStatus: String {
        if eventStreamRecovering { return "重新同步中" }
        if parked { return "已暂停" }
        if host == nil { return "已停止" }
        if userFacingError != nil || hostState.lowercased().contains("fail") { return "失败" }
        if busy || hostLifecycleTransition { return "处理中" }
        if pendingQuestion != nil || pendingPermission != nil { return "等待回复" }
        if turnRunning { return "运行中" }
        if transcriptReady { return "就绪" }
        return "未连接"
    }
    var canSteer: Bool { harness != nil && sessionID != nil && transcriptReady && !eventStreamRecovering && turnRunning && !busy && !parked && !hostLifecycleTransition }
    private var pumpTask: Task<Void, Never>?
    private var hostEventTask: Task<Void, Never>?
    private var lastSeq: UInt64?
    private var trajectoryThroughSeq: Int?
    private var trajectoryBeforeSeq: Int?
    private var trajectoryRefreshTask: Task<Void, Never>?
    private(set) var lastCommandExecution: NativeCommandExecution?

    func clearError() { userFacingError = nil }

    /// The composer surfaces this text in its own notice row; the page-level
    /// banner must not repeat it.
    func dismissCommandsError() { commandsError = nil }

    /// Read the active Worker catalog and this Session's durable permission fold.
    /// Missing Remote support stays explicit instead of being replaced by a local default.
    func refreshAccessModes() async {
        accessModeRefreshGeneration &+= 1
        let generation = accessModeRefreshGeneration
        guard let sessionID else {
            availableAccessModes = []
            currentAccessMode = nil
            accessModeLoading = false
            accessModeError = "本地引擎还没启动,启动之后才能看权限。"
            return
        }
        accessModeLoading = true
        accessModeError = nil
        // A fresh session's permission fold can lag its open by a moment; read
        // again on a short backoff instead of asking the user to tap retry.
        let retryDelaysMs: [UInt64] = [0, 500, 1_000, 2_000, 4_000, 8_000]
        for delay in retryDelaysMs {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            guard generation == accessModeRefreshGeneration, self.sessionID == sessionID else { return }
            if await loadAccessModesOnce(sessionID: sessionID) {
                guard generation == accessModeRefreshGeneration, self.sessionID == sessionID else { return }
                accessModeLoading = false
                accessModeError = nil
                return
            }
        }
        guard generation == accessModeRefreshGeneration, self.sessionID == sessionID else { return }
        accessModeLoading = false
        availableAccessModes = []
        currentAccessMode = nil
        accessModeError = "暂时读不到权限，打开菜单会自动再试。"
    }

    /// One read of the Worker catalog and the Session's permission fold.
    /// Returns false when either call fails or the fold has no current value.
    private func loadAccessModesOnce(sessionID: String) async -> Bool {
        do {
            let transport = try await transportForManagement()
            async let catalogCall = transport.call("permissionPresets/catalog", args: .object([:]))
            async let projectionCall = transport.call("session/projections", args: .object([
                "request": .object(["sessionId": .string(sessionID)]),
            ]))
            let (catalog, projections) = try await (catalogCall, projectionCall)
            guard self.sessionID == sessionID else { return false }
            projectionValues = projections["values"]
            availableAccessModes = (catalog["options"]?.arrayValue ?? []).compactMap { option in
                guard let id = option["value"]?.stringValue,
                      let name = option["name"]?.stringValue else { return nil }
                return NativeAccessMode(id: id, name: name,
                                        description: option["description"]?.stringValue)
            }
            guard let current = projections["values"]?["permissions"]?["currentValue"]?.stringValue else {
                return false
            }
            currentAccessMode = current
            return true
        } catch {
            return false
        }
    }

    /// Switch this Session using DSH's canonical `/permission` command, then
    /// verify the committed value through the Session projection.
    func selectAccessMode(_ id: String) async -> Bool {
        guard let sessionID else {
            accessModeError = "本地引擎还没启动,启动之后才能改权限。"
            return false
        }
        guard id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              availableAccessModes.contains(where: { $0.id == id }) else {
            accessModeError = "这一档现在选不了。"
            return false
        }
        do {
            let transport = try await transportForManagement()
            let response = try await transport.call("commands/execute", args: .object([
                "agentId": .string(sessionID),
                "line": .string("/permission \(id)"),
                "submittedAttachments": .array([]),
            ]))
            guard self.sessionID == sessionID else { return false }
            guard response["result"]?["kind"]?.stringValue == "success" else {
                accessModeError = "没改成这一档,再试一次。"
                return false
            }
            await refreshAccessModes()
            return self.sessionID == sessionID && currentAccessMode == id
        } catch {
            guard self.sessionID == sessionID else { return false }
            accessModeError = "没读到权限,再试一次。"
            return false
        }
    }

    /// Fetch the command descriptors registered for this exact DSH session.
    /// Names and hints come from the Worker command registry, never a local list.
    func loadCommands() async {
        guard let sessionID else {
            availableCommands = []
            commandsError = "本地引擎还没启动,启动之后才能看命令。"
            return
        }
        commandsLoading = true
        defer { commandsLoading = false }
        do {
            let transport = try await transportForManagement()
            let response = try await transport.call("commands/list", args: .object([
                "agentId": .string(sessionID),
            ]))
            guard self.sessionID == sessionID else { return }
            let rows = response.arrayValue
                ?? response["commands"]?.arrayValue
                ?? response["value"]?.arrayValue
                ?? []
            let parsedNames: [String] = rows.compactMap { $0["name"]?.stringValue }
            if !parsedNames.isEmpty {
                appendStatus("commands: \(parsedNames.count), goal=\(parsedNames.contains("goal") ? "yes" : "no")")
            }
            availableCommands = rows.compactMap { row in
                guard let name = row["name"]?.stringValue,
                      !name.isEmpty,
                      let description = row["description"]?.stringValue else { return nil }
                // `input` present means the command claims arguments; official
                // clients read `desc.input !== undefined` to decide claim vs a
                // bare detached execution on a menu pick.
                let input = row["input"].flatMap { $0 == .null ? nil : $0 }
                return NativeCommandDescriptor(name: name, description: description,
                                               inputHint: input?["hint"]?.stringValue,
                                               acceptsAttachments: input?["attachments"]?.boolValue ?? false,
                                               definitionID: row["definitionId"]?.stringValue,
                                               hasInput: input != nil)
            }
            commandsError = nil
        } catch {
            guard self.sessionID == sessionID else { return }
            availableCommands = []
            commandsError = "没执行成功,再试一次。"
        }
    }

    /// Execute one command admitted by the live DSH registry. Returned text is
    /// kept as a UI result; durable command/run and command/done records are
    /// separately refreshed into the trajectory ledger.
    @discardableResult
    func executeCommand(name: String, input: String = "",
                        attachments: [HarnessAttachment] = []) async -> NativeCommandExecution? {
        guard let sessionID, !parked, !hostLifecycleTransition,
              let descriptor = NativeCommandCatalog.resolve(name, in: availableCommands) else {
            commandsError = "这条命令现在用不了。"
            return nil
        }
        guard attachments.isEmpty || descriptor.acceptsAttachments else {
            commandsError = NativeCommandCatalog.attachmentRefusal(for: descriptor.name)
            return nil
        }
        let line = "/\(descriptor.name)" + (input.isEmpty ? "" : " \(input)")
        do {
            let transport = try await transportForManagement()
            let submittedAttachments: [JSONValue] = attachments.map { attachment in
                .object(["type": .string("image"), "mediaType": .string(attachment.mimeType),
                         "data": .string(attachment.data.base64EncodedString()), "name": .string(attachment.name)])
            }
            let response = try await transport.call("commands/execute", args: .object([
                "agentId": .string(sessionID),
                "line": .string(line),
                "submittedAttachments": .array(submittedAttachments),
            ]))
            guard self.sessionID == sessionID else { return nil }
            let result = response["result"] ?? .null
            guard let kind = result["kind"]?.stringValue else {
                commandsError = "The DSH command Remote returned no execution result."
                return nil
            }
            let execution = NativeCommandExecution(
                id: response["commandId"]?.stringValue ?? UUID().uuidString,
                name: descriptor.name, line: line, kind: kind,
                text: result["text"]?.stringValue)
            lastCommandExecution = execution
            commandsError = kind == "error" ? (execution.text ?? "Command failed.") : nil
            await refreshTrajectory()
            return execution
        } catch {
            guard self.sessionID == sessionID else { return nil }
            commandsError = "没执行成功,再试一次。"
            return nil
        }
    }

    /// Durable session journal entries in ascending DSH sequence order.
    /// The record envelope and payload are preserved for native detail views.
    func refreshTrajectory() async {
        guard let sessionID else {
            trajectoryEntries = []
            trajectoryHasMore = false
            trajectoryError = "Start a DSH session to read its trajectory."
            return
        }
        do {
            let transport = try await transportForManagement()
            let cursor = try await currentJournalCursor(sessionID: sessionID, transport: transport)
            guard self.sessionID == sessionID else { return }
            guard cursor >= 0 else {
                trajectoryEntries = []
                trajectoryThroughSeq = nil
                trajectoryBeforeSeq = nil
                trajectoryHasMore = false
                trajectoryError = nil
                return
            }
            let request: [String: JSONValue] = [
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(cursor)),
                "maxMessages": .number(60),
            ]
            let page = try await transport.call("session/page", args: .object(["request": .object(request)]))
            guard self.sessionID == sessionID else { return }
            let events = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            let fresh = Self.trajectoryEntries(from: events, sessionID: sessionID)
            let hadOlderLoaded = trajectoryBeforeSeq != nil && trajectoryEntries.count > fresh.count
            var byID = Dictionary(uniqueKeysWithValues: trajectoryEntries.map { ($0.id, $0) })
            for entry in fresh { byID[entry.id] = entry }
            trajectoryEntries = byID.values.sorted { $0.seq < $1.seq }
            trajectoryThroughSeq = cursor
            trajectoryHasMore = hadOlderLoaded || (page["hasMore"]?.boolValue ?? false)
            trajectoryBeforeSeq = events.compactMap { $0["seq"]?.intValue }.min()
            trajectoryError = nil
        } catch {
            guard self.sessionID == sessionID else { return }
            trajectoryError = error.localizedDescription
        }
    }

    /// Prepend one older page from the authoritative Session journal.
    func loadEarlierTrajectory() async {
        guard trajectoryHasMore, let sessionID, let throughSeq = trajectoryThroughSeq,
              let beforeSeq = trajectoryBeforeSeq else { return }
        do {
            let transport = try await transportForManagement()
            let page = try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(throughSeq)),
                "beforeSeq": .number(Double(beforeSeq)),
                "maxMessages": .number(60),
            ])]))
            guard self.sessionID == sessionID else { return }
            let events = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            guard let nextBeforeSeq = events.compactMap({ $0["seq"]?.intValue }).min(),
                  nextBeforeSeq < beforeSeq else {
                trajectoryHasMore = false
                trajectoryError = "The DSH history page did not advance before seq \(beforeSeq)."
                return
            }
            let older = Self.trajectoryEntries(from: events, sessionID: sessionID)
            let existingIDs = Set(trajectoryEntries.map(\.id))
            trajectoryEntries = (older.filter { !existingIDs.contains($0.id) } + trajectoryEntries)
                .sorted { $0.seq < $1.seq }
            trajectoryBeforeSeq = nextBeforeSeq
            trajectoryHasMore = page["hasMore"]?.boolValue ?? false
            trajectoryError = nil
        } catch {
            guard self.sessionID == sessionID else { return }
            trajectoryError = error.localizedDescription
        }
    }

    /// Reload the committed MCP grants into the live policy after the native
    /// editor changes a route or credential.
    func refreshMCPAccessPolicy() {
        PhoneMCPAccessSettings.shared.apply(to: mcpAccessPolicy)
    }

    /// Returns the host's DSH RPC transport for session-management surfaces.
    func transportForManagement() async throws -> any DSHRemoteTransport {
        guard let host else { throw ProbeHostError.notStarted }
        return try await host.makeTransport()
    }

    let workspaceRoot: URL = ChatHostConfiguration.workspaceRoot()

    private var materializedWorkspace: URL {
        workspaceRoot.appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
    }

    /// The materialized workspace directory: what the browser lists and the
    /// PAGE surface serves from `pdsh-page://<session>/...`.
    var workspaceDirectoryURL: URL { materializedWorkspace }

    /// A file's owning workspace: the page origin must be that workspace's
    /// directory, and the path must be relative to it.
    struct PageWorkspaceOwner {
        let sessionID: String
        let relativePath: String
    }

    /// Finds the workspace that owns `relativePath` (relative to
    /// `/dsh/workspace`) and a session of it. The longest workspace directory
    /// wins; a workspace registered at `/dsh/workspace` owns every path.
    func pageWorkspaceOwner(for relativePath: String) -> PageWorkspaceOwner? {
        let workspaces = DSHManagementModel.shared.workspaces.map {
            (path: $0.path, sessionIDs: $0.sessionIDs)
        }
        guard let owner = PDSHPageWorkspaceMap.owner(relativePath: relativePath,
                                                    workspaces: workspaces) else {
            return nil
        }
        return PageWorkspaceOwner(sessionID: owner.sessionID,
                                  relativePath: owner.relativePath)
    }

    /// sessionID → the materialized directory its page origin serves. The
    /// host supports several workspaces (`workspace/create`, `workspace/follow`),
    /// and each record's `path` is its sessions' cwd: `/dsh/workspace/proj2`
    /// serves `materialized/workspace/proj2`, so two workspaces with the same
    /// file name do not read each other's bytes. A session the host does not
    /// list stays unmapped (the handler then refuses the URL).
    func pageWorkspaceMap() -> [String: URL] {
        let root = workspaceDirectoryURL
        var map = PDSHPageWorkspaceMap.directories(
            root: root,
            workspaces: DSHManagementModel.shared.workspaces.map {
                (path: $0.path, sessionIDs: $0.sessionIDs)
            })
        if let sessionID = currentSessionID, map[sessionID] == nil {
            map[sessionID] = root
        }
        return map
    }

    private var materializedHome: URL {
        workspaceRoot.appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    // MARK: Lifecycle

    private struct HostLaunch {
        let host: PhoneDSHHost
        let budgets: BudgetTable
        let selectedProfile: ProviderProfile?
        let egressHosts: Set<String>
    }

    private func prepareBotRuntime() async -> Bool {
        if let launch = botLaunch {
            botRuntimeState = launch.composition.state
            return true
        }
        botRuntimeState = .preparing
        do {
            let store = try SQLiteDomainStore.applicationSupport()
            let launch = try await BotRuntimeComposition.prepare(store: store)
            launch.composition.onStateChange = { [weak self] state in
                self?.botRuntimeState = state
            }
            botLaunch = launch
            botRuntimeState = launch.composition.state
            return true
        } catch {
            botRuntimeState = .failed("Bot 启动失败：\(error.localizedDescription)")
            reportError("Bot 启动失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Retry the Bot half after a visible disconnect. A running Host is
    /// rebound; without a Host the normal engine start is attempted again.
    func retryBotRuntime() async {
        if let composition = botLaunch?.composition, let host {
            await composition.retry()
            botRuntimeState = composition.state
        } else {
            await start()
        }
    }

    private func attachBotRuntime(to host: PhoneDSHHost) async {
        guard let composition = botLaunch?.composition else { return }
        do {
            try await composition.start(host: host)
            botRuntimeState = composition.state
        } catch {
            botRuntimeState = composition.state
            reportError("Bot 大脑连接失败：\(error.localizedDescription)")
        }
    }

    /// Boots the host and adopts the persisted session. Launching and sending
    /// may acknowledge one persisted `Failed` controller per process.
    func start(autoRecover: Bool = false) async {
        guard host == nil, !busy else { return }
        if engineNeedsReset, failedHost != nil {
            await restartEngine()
            return
        }
        busy = true
        defer { busy = false }
        guard await prepareBotRuntime() else { return }
        guard let launch = makeHostLaunch() else { return }
        // Show the last conversation from disk immediately; the engine boots
        // in the background and replaces it when the host history arrives.
        restoreCachedTranscriptIfAvailable()
        statusLine = "Booting the Worker…"
        appendStatus("Booting the host (Worker bundle + image)…")
        observeHost(launch.host)
        do {
            try await ADBMCPServer.shared.setWorkspaceDirectory(materializedWorkspace)
            await botLaunch?.composition.attachNativeMCP(PhoneNativeMCP.server)
            try await launch.host.start()
        } catch {
            Self.appendDiagnostic("host start failed: \(error)")
            reportError("引擎停了：\(Self.condensed(String(describing: error)))")
            hostEventTask?.cancel(); hostEventTask = nil
            let state = await launch.host.state
            guard ChatEngineLifecycle.needsReset(afterStartIn: state) else {
                failedHost = nil
                engineNeedsReset = false
                return
            }
            failedHost = launch.host
            engineNeedsReset = true
            if autoRecover, !autoRecoveryAttempted {
                autoRecoveryAttempted = true
                Task { @MainActor [weak self] in
                    await self?.restartEngineWhenIdle()
                }
            }
            return
        }
        await adoptRunningHost(launch.host,
                               budgets: launch.budgets,
                               selectedProfile: launch.selectedProfile,
                               egressHosts: launch.egressHosts)
    }

    private func makeHostLaunch() -> HostLaunch? {
        guard let bundle = WorkerBundleLocator.bundle() else {
            reportError("引擎停了")
            return nil
        }
        guard anchor.isInWindow else {
            reportError("The page anchor is not in a window yet; try again")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        } catch {
            reportError("Cannot create the workspace: \(error)")
            return nil
        }

        let egressHosts = Self.egressHosts(from: egressAllow)
        // The provider document is the only model configuration authority.
        // It is read for every new host — including the rebuild a reset does —
        // so deleting or switching a service can never leave the previous
        // endpoint/key active in this process. A missing selection still boots
        // the complete Web surface: model calls fail later with the host
        // credential provider's unauthorized error, and Settings → 模型服务
        // stays reachable.
        var selectedProfile: ProviderProfile?
        var allowedModelHosts = Set<String>()
        var credentialProvider: any CredentialProvider = PhoneModelProviderSettings.shared
            .makeEgressOnlyCredentialProvider(egressAllowHosts: egressHosts)
        var environment: [String: String] = [
            // The host gateway injects the real key; the Worker never holds it.
            "DEEPSEEK_API_KEY": "phone-host-injects-key",
            "DSH_TELEMETRY_DISABLED": "1",
            // Caller bash timeouts still apply through its fused abort signal.
            // The independent Worker backstop must allow 1 GiB transfers.
            "PDSH_SHELL_TIMEOUT_MS": "3600000",
        ]
        do {
            let settings = PhoneModelProviderSettings.shared
            let snapshot = try settings.load()
            if let profile = snapshot.selected {
                var plan = ModelProviderLaunchPlan()
                try settings.apply(to: &plan, egressAllowHosts: egressHosts)
                selectedProfile = profile
                allowedModelHosts = plan.allowedModelHosts
                credentialProvider = plan.credentialProvider
                environment.merge(plan.environment) { _, new in new }
                modelName = profile.model
            } else {
                modelName = ""
            }
        } catch {
            modelName = ""
            appendStatus("Model service settings are invalid; booting without a model route: \(error.localizedDescription)")
        }
        var launchPlan = ModelProviderLaunchPlan(allowedModelHosts: allowedModelHosts,
                                                 credentialProvider: credentialProvider,
                                                 environment: environment)
        let searchPlan = WebSearchHostConfiguration.apply(to: &launchPlan,
                                                          modelProfile: selectedProfile)
        allowedModelHosts = launchPlan.allowedModelHosts
        credentialProvider = launchPlan.credentialProvider
        environment = launchPlan.environment
        searchLaunchWarning = searchPlan.warning
        if let warning = searchLaunchWarning {
            appendStatus("Web search: \(warning)")
        }
        PhoneMCPAccessSettings.shared.reconcile(materializedHome: materializedHome)
        let mcpPolicy = MCPHostConfiguration.apply(to: &launchPlan,
                                                   settings: .shared)
        if let endpoint = botLaunch?.composition.server.url {
            do {
                try mcpPolicy.grantBotRuntimeEndpoint(
                    endpoint, token: botLaunch?.composition.server.token)
            } catch {
                reportError("Bot MCP 出口配置失败：\(error.localizedDescription)")
                return nil
            }
        }
        mcpAccessPolicy = mcpPolicy
        allowedModelHosts = launchPlan.allowedModelHosts
        credentialProvider = launchPlan.credentialProvider
        environment = launchPlan.environment
        // Model POSTs keep the gateway's 429/5xx backoff; egress POSTs do not
        // (PR #1 review finding). Only the selected profile's standard model
        // endpoints are replay-safe, so expand its base URL here.
        let replaySafeModelEndpoints = selectedProfile?.endpointURL
            .map { PhoneDSHConfiguration.standardModelEndpoints(baseURL: $0) } ?? []
        // ChatHostConfiguration.makeProduction is the shared production
        // assembly (nativeMCP, Worker environment, timeouts, gateway inputs);
        // the E2E boots the same function instead of copying these values.
        var configuration = ChatHostConfiguration.makeProduction(
            workspaceRoot: workspaceRoot,
            bundle: bundle,
            // Budgets follow the device: the 12 GiB row is selected only at or
            // above 12 GiB (budgets.md §4).
            deviceTier: DeviceTier.forPhysicalMemory(ProcessInfo.processInfo.physicalMemory),
            allowedModelHosts: allowedModelHosts,
            egressAllowHosts: egressHosts,
            replaySafeModelEndpoints: replaySafeModelEndpoints,
            credentialProvider: credentialProvider,
            egressAuthorizer: mcpPolicy,
            workerEnvironment: environment.merging(botLaunch?.workerEnvironment ?? [:]) { _, new in new },
            // iphone_agent_run (UI-Venus over the TonoLink board) in front of the BLE tools, so one
            // native endpoint serves the phone task and Link tools such as light.set (native-mcp.md).
            nativeMCP: PhoneNativeMCP.server)
        configuration.officialDeepSeekWebCredentialProvider = searchPlan.officialDeepSeekWebCredentialProvider
        // One line states what the host actually enforces. The Worker's
        // published manifest can lag behind a rebuilt bundle; this is the
        // number the write path uses.
        appendStatus("Engine budgets: tier=\(configuration.deviceTier) "
            + "workspace=\(configuration.budgets.workspaceBytes / 1_048_576) MiB "
            + "vfs=\(configuration.budgets.vfsLogicalBytes / 1_048_576) MiB "
            + "single=\(configuration.budgets.singleFileBytes / 1_048_576) MiB "
            + "hot=\(configuration.budgets.wasiHotInstanceBytes / 1_048_576) MiB")
        // Publish the real read-only accelerators only when the linked Rust
        // library advertises them. Without the XCFramework `acceleratorNames`
        // is empty, so the host keeps advertising none instead of faking a
        // capability. `phone`/`ctx` are registered by the library but need an
        // injected PhoneToolBridge (there is no MCP bridge in this host yet),
        // so `channelAcceleratorNames` keeps them out of the host HELLO and the
        // EXEC_REQ whitelist instead of advertising commands that would exit 69.
        let capabilityBridge = PhoneCapabilityBridge()
        phoneCapabilityBridge = capabilityBridge
        let toolBridge = CompositePhoneToolBridge(
            office: OfficeToolBridge(presenter: OfficePresenter()),
            phone: capabilityBridge)
        let shell = PDSHShellProvider(materializedWorkspace: materializedWorkspace,
                                      materializedHome: materializedHome,
                                      toolBridge: toolBridge)
        if !shell.acceleratorNames.isEmpty {
            configuration.accelerators = shell
            let names = shell.channelAcceleratorNames
            if !names.isEmpty {
                configuration.acceleratorNames = names
            }
        }
        let sshProvider = SSHExecProvider(
            workspace: materializedWorkspace, home: materializedHome, fallback: shell,
            byteLimit: configuration.budgets.singleFileBytes,
            connections: { await SSHSettingsStore.shared.list() },
            resolve: { destination in try await SSHSettingsStore.shared.resolve(destination) })
        configuration.execProvider = ADBExecProvider(workspace: materializedWorkspace, fallback: sshProvider,
                                                      byteLimit: configuration.budgets.singleFileBytes)
        configuration.acceleratorNames = shell.channelAcceleratorNames + ["ssh", "scp", "adb"]
        let anchor = self.anchor
        let host = PhoneDSHHost(configuration: configuration, engineFactory: { configuration in
            await anchor.makeEngine(configuration)
        })
        return HostLaunch(host: host,
                          budgets: configuration.budgets,
                          selectedProfile: selectedProfile,
                          egressHosts: egressHosts)
    }

    private func restartEngineWhenIdle() async {
        var waited = 0
        while busy && waited < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        await restartEngine()
    }

    private func ensureEngineRunning() async {
        guard host == nil, !busy else { return }
        await start(autoRecover: true)
    }

    /// The explicit user acknowledgement D14 requires before a persisted
    /// `Failed` controller may boot again.
    ///
    /// It stops the failed host and builds a new one with the current settings
    /// rather than reusing the failed instance: the host captures its provider
    /// credential, search plan, MCP policy and budget at construction, so a
    /// person who fixed an API key and retried would otherwise keep booting
    /// with the stale document. The persisted `Failed` state is still acked
    /// with `reset()` — the new host's first `start()` refuses it, so the
    /// engine is rebuilt and then reset — and the session is adopted through
    /// the same path a normal start uses.
    ///
    /// A failure that survives this stays fail-loud: the host is kept in
    /// ``failedHost`` and ``engineNeedsReset`` stays true.
    func restartEngine() async {
        guard host == nil, !busy else { return }
        guard let failed = failedHost else {
            await start()
            return
        }
        busy = true
        defer { busy = false }
        statusLine = "Restarting the engine…"
        appendStatus("User reset: clearing the persisted failed controller")
        do {
            try await failed.stop()
        } catch {
            reportError("引擎无法重新启动：\(Self.condensed(String(describing: error)))")
            return
        }
        // Build the replacement first: `makeHostLaunch` can refuse (bundle
        // missing, anchor not in a window) and clearing the reset state before
        // that would drop the only path back to a working engine.
        guard await prepareBotRuntime() else { return }
        guard let launch = makeHostLaunch() else { return }
        failedHost = nil
        engineNeedsReset = false
        restoreCachedTranscriptIfAvailable()
        observeHost(launch.host)
        do {
            do {
                try await ADBMCPServer.shared.setWorkspaceDirectory(materializedWorkspace)
                await botLaunch?.composition.attachNativeMCP(PhoneNativeMCP.server)
                try await launch.host.start()
            } catch {
                let state = await launch.host.state
                guard ChatEngineLifecycle.needsReset(afterStartIn: state) else { throw error }
                try await launch.host.reset()
            }
        } catch {
            Self.appendDiagnostic("host reset failed: \(error)")
            reportError("引擎无法重新启动：\(Self.condensed(String(describing: error)))")
            hostEventTask?.cancel(); hostEventTask = nil
            let state = await launch.host.state
            failedHost = ChatEngineLifecycle.needsReset(afterStartIn: state) ? launch.host : nil
            engineNeedsReset = failedHost != nil
            return
        }
        await adoptRunningHost(launch.host,
                               budgets: launch.budgets,
                               selectedProfile: launch.selectedProfile,
                               egressHosts: launch.egressHosts)
    }

    /// Parses the comma-separated egress allow list the settings page stores.
    static func egressHosts(from list: String) -> Set<String> {
        Set(list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    /// Adopts a host that has finished booting: opens the persisted (or a
    /// fresh) session, loads its history and starts the pumps.
    ///
    /// Shared by ``start()`` and ``restartEngine()`` so the user-reset path
    /// lands in exactly the state a normal boot produces.
    private func adoptRunningHost(_ newHost: PhoneDSHHost,
                                  budgets: BudgetTable,
                                  selectedProfile: ProviderProfile?,
                                  egressHosts: Set<String>) async {
        host = newHost
        await attachBotRuntime(to: newHost)
        failedHost = nil
        engineNeedsReset = false
        startedAt = Date()
        restartPolicyBudget = budgets
        startRestartPolicyMonitor()
        do {
            let harness = try await newHost.harness()
            self.harness = harness
            let persistedSessionID = UserDefaults.standard.string(forKey: Self.currentSessionDefaultsKey)
            let requestedSessionID = persistedSessionID.flatMap {
                DeviceSessionCoordinator.shared.isDeviceSession($0) ? nil : $0
            }
            if persistedSessionID != nil && requestedSessionID == nil {
                UserDefaults.standard.removeObject(forKey: Self.currentSessionDefaultsKey)
            }
            let session = try await harness.openSession(HarnessSessionRequest(
                sessionID: requestedSessionID, workspace: "/dsh/workspace"))
            resetSessionLedgers()
            self.sessionID = session.id
            UserDefaults.standard.set(session.id, forKey: Self.currentSessionDefaultsKey)
            lastSeq = nil
            let transport = try await newHost.makeTransport()
            if let selectedProfile {
                do {
                    try await selectProviderModel(selectedProfile, sessionID: session.id, transport: transport)
                } catch {
                    appendStatus("The provider model could not be selected for this session: \(error.localizedDescription)")
                }
            }
            let history: SessionHistory
            do {
                history = try await loadSessionHistory(sessionID: session.id,
                                                        transport: transport)
                items = history.items
            turnStartTimes = history.turnFacts.starts
            turnEndReasons = history.turnFacts.endReasons
            turnEndTimes = history.turnFacts.ends
                transcriptHasMore = history.hasMore
                transcriptBeforeSeq = history.beforeSeq
                transcriptThroughSeq = history.throughSeq
                isShowingCachedTranscript = false
                persistTranscriptSnapshot()
            } catch {
                reportError("Session opened, but its DSH history could not be loaded: \(error)")
                transcriptReady = false
                refreshFiles()
                return
            }
            transcriptReady = true
            clearError()
            Task { await self.refreshGoal() }
            turnRunning = history.turnRunning
            startPump(harness: harness, sessionID: session.id, after: history.after)
            Task { await self.refreshAccessModes() }
            Task { await self.refreshNativeMetrics() }
            Task { await self.refreshTrajectory() }
            Task { await self.loadCommands() }
            statusLine = "Session \(session.id.prefix(8)) open — type a task"
            appendStatus("Session \(requestedSessionID == nil ? "created" : "resumed"): \(session.id); egress allow-list: \(egressHosts.isEmpty ? "(none)" : egressHosts.sorted().joined(separator: ", "))")
        } catch {
            reportError("Session failed: \(error)")
        }
        refreshFiles()
    }

    /// Apply the selected provider's model and reasoning effort to the DSH
    /// session. The endpoint/base URL is host configuration, but DSH still
    /// needs the session-local model route: without this call it keeps the
    /// profile default and the user's provider model/effort would be inert.
    private func selectProviderModel(_ profile: ProviderProfile,
                                     sessionID: String,
                                     transport: any DSHRemoteTransport) async throws {
        var request: [String: JSONValue] = [
            "sessionId": .string(sessionID),
            // llm-deepseek registers this route; DEEPSEEK_BASE_URL selects
            // the endpoint and the host CredentialProvider supplies its key.
            "provider": .string("deepseek-official"),
            "model": .string(profile.model),
        ]
        if let effort = profile.reasoningEffort, !effort.isEmpty {
            request["reasoningEffort"] = .string(effort)
        }
        _ = try await transport.call("session/selectModel",
                                     args: .object(["request": .object(request)]))
    }

    /// Opens a new session through DSH and makes it the active chat.
    func newSession() async {
        await openManagedSession(id: nil)
    }

    @discardableResult
    func newSession(preset: String) async -> Bool {
        await openManagedSession(id: nil, preset: preset)
    }

    /// Resumes an existing DSH session by its server-issued identifier.
    func selectSession(_ id: String) async {
        let requested = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { reportError("Session ID cannot be empty"); return }
        await openManagedSession(id: requested)
    }

    @discardableResult
    private func openManagedSession(id: String?, preset: String? = nil) async -> Bool {
        if let id, DeviceSessionCoordinator.shared.isDeviceSession(id) {
            reportError("设备会话只能以只读监视方式打开")
            return false
        }
        guard let host else { reportError("Start the host before opening a session"); return false }
        guard !busy else { return false }
        guard !hostLifecycleTransition else {
            reportError("Wait for the host to finish pausing or resuming before switching sessions")
            return false
        }
        guard !turnRunning && !keepingAlive && pendingQuestion == nil && pendingPermission == nil else {
            reportError("Finish the current turn and answer pending requests before switching sessions")
            return false
        }
        busy = true
        defer { busy = false }
        do {
            let harness: any AgentHarness
            if let activeHarness = self.harness {
                harness = activeHarness
            } else {
                harness = try await host.harness()
                self.harness = harness
            }
            let session = try await harness.openSession(HarnessSessionRequest(
                sessionID: id, preset: preset, workspace: "/dsh/workspace"))
            let transport = try await transportForManagement()
            if let profile = try? PhoneModelProviderSettings.shared.load().selected {
                try? await selectProviderModel(profile, sessionID: session.id, transport: transport)
            }
            let history = try await loadSessionHistory(sessionID: session.id, transport: transport)
            pumpTask?.cancel()
            resetSessionLedgers()
            self.sessionID = session.id
            UserDefaults.standard.set(session.id, forKey: Self.currentSessionDefaultsKey)
            lastSeq = history.after
            items = history.items
            turnStartTimes = history.turnFacts.starts
            turnEndReasons = history.turnFacts.endReasons
            turnEndTimes = history.turnFacts.ends
            isShowingCachedTranscript = false
            persistTranscriptSnapshot()
            transcriptHasMore = history.hasMore
            transcriptBeforeSeq = history.beforeSeq
            transcriptThroughSeq = history.throughSeq
            transcriptReady = true
            pendingPermission = nil
            pendingQuestion = nil
            turnRunning = history.turnRunning
            startPump(harness: harness, sessionID: session.id, after: history.after)
            Task { await self.refreshAccessModes() }
            Task { await self.refreshNativeMetrics() }
            Task { await self.refreshTrajectory() }
            Task { await self.loadCommands() }
            statusLine = "Session \(session.id.prefix(8)) open — type a task"
            clearError()
            appendStatus("Session \(id == nil ? "created" : "resumed"): \(session.id)")
            return true
        } catch {
            reportError("Could not \(id == nil ? "create" : "resume") session: \(error)")
            return false
        }
    }

    /// Applies a saved model-service change to the running host.
    ///
    /// The host captures its credential provider when it boots, so a key added
    /// while it runs is invisible to the gateway: every model request then
    /// fails with the provider's 401 and the app can only say "密钥不被接受".
    /// Restarting re-reads the provider document and rebinds the key.
    func reloadModelProvider() async {
        guard isStarted, !hostLifecycleTransition else {
            appendStatus("模型服务已保存；引擎下次启动时生效")
            return
        }
        guard !turnRunning else {
            appendStatus("模型服务已保存；当前回合结束后重启引擎生效")
            return
        }
        let previousSession = sessionID
        await stop()
        await start()
        if let previousSession, sessionID != previousSession {
            await selectSession(previousSession)
        }
        appendStatus("模型服务已保存，引擎已重启")
    }

    /// 归档的正好是当前打开的那个会话:把它从页面上摘掉,回到空屏,
    /// 不让用户停在一个已经不在列表里的对话上。不关宿主、不动别的会话。
    func detachArchivedSession() async {
        pumpTask?.cancel(); pumpTask = nil
        eventStreamRecovering = false
        if let harness, let sessionID { await harness.closeSession(sessionID) }
        harness = nil
        sessionID = nil
        transcriptReady = false
        items = []
        pendingPermission = nil
        pendingQuestion = nil
        turnRunning = false
        startedAt = nil
    }

    func stop() async {
        guard let host else {
            await botLaunch?.composition.stop()
            if let composition = botLaunch?.composition {
                botRuntimeState = composition.state
            }
            return
        }
        guard !busy && !hostLifecycleTransition else {
            reportError("Wait for the current host operation to finish before stopping")
            return
        }
        busy = true
        defer { busy = false }
        pumpTask?.cancel(); pumpTask = nil
        eventStreamRecovering = false
        if let harness, let sessionID { await harness.closeSession(sessionID) }
        harness = nil; sessionID = nil
        transcriptReady = false
        pendingPermission = nil; pendingQuestion = nil
        availableAccessModes = []; currentAccessMode = nil; accessModeError = nil; accessModeLoading = false
        await botLaunch?.composition.stop()
        if let composition = botLaunch?.composition {
            botRuntimeState = composition.state
        }
        do { try await host.stop() } catch { reportError("Stop reported: \(error)") }
        hostEventTask?.cancel(); hostEventTask = nil
        self.host = nil
        startedAt = nil
        turnRunning = false
        parked = false
        foregroundResumeRequested = false
        backgroundParkRequested = false
        hostLifecycleTransition = false
        syncIdleTimer()
        statusLine = "Host stopped"
        appendStatus("Host stopped")
    }

    private func resetSessionLedgers() {
        trajectoryRefreshTask?.cancel()
        trajectoryRefreshTask = nil
        nativeMetricsRefreshTask?.cancel()
        nativeMetricsRefreshTask = nil
        sessionStats = nil
        tokenUsage = nil
        contextPressure = nil
        contextBreakdown = nil
        projectionValues = nil
        eventStreamRecovering = false
        activeTurn = nil
        activeStep = nil
        activeTurnStartedAt = nil
        turnStartTimes = [:]
        turnEndReasons = [:]
        turnEndTimes = [:]
        trajectoryEntries = []
        trajectoryHasMore = false
        trajectoryError = nil
        trajectoryThroughSeq = nil
        trajectoryBeforeSeq = nil
        transcriptHasMore = false
        transcriptError = nil
        transcriptThroughSeq = nil
        transcriptBeforeSeq = nil
        availableCommands = []
        commandsError = nil
        lastCommandExecution = nil
        availableAccessModes = []
        currentAccessMode = nil
        accessModeError = nil
        accessModeLoading = true
    }

    // MARK: Scene phase (D14 park / resume)

    /// Parks the host when the app leaves the foreground and resumes it when
    /// the app is active again. Without this the WKWebView Worker is simply
    /// frozen by iOS mid-turn and every connection it holds dies, so the next
    /// event after returning is an error. A park drains the work in flight
    /// (up to `drainDeadline`, 20 s here) and cancels what is still open; a
    /// resume replays the WAL and the same session continues.
    ///
    /// `PhoneDSHProbeApp` is the caller, through `ProbeScenePhaseForwarding`.
    /// A running turn with background keep-alive holds a silent playback
    /// session and leaves the host running. An idle host still parks.
    func scenePhaseChanged(_ phase: ScenePhase) async {
        guard let host else { return }
        switch phase {
        case .background:
            if hostLifecycleTransition {
                foregroundResumeRequested = false
                backgroundParkRequested = true
                return
            }
            guard !parked, !keepingAlive else { return }
            beginBackgroundTask()
            // A running turn is kept alive (the user's task continues); an idle
            // host is parked as before, which costs no battery.
            if backgroundKeepAlive && turnRunning {
                keepAlive.onEvent = { [weak self] message in self?.appendStatus(message) }
                do {
                    try keepAlive.start()
                    keepingAlive = true
                    appendStatus("App in background: keeping the agent alive with a silent audio session; the turn continues")
                    startBackgroundHeartbeat()
                    return
                } catch {
                    appendStatus("Keep-alive audio failed (\(error)); parking the host instead")
                }
            }
            await parkHost(host)
        case .active:
            if keepingAlive {
                stopBackgroundHeartbeat()
                keepAlive.stop()
                keepingAlive = false
                appendStatus("Back in the foreground; keep-alive audio stopped")
                endBackgroundTask()
                refreshFiles()
            }
            if hostLifecycleTransition {
                backgroundParkRequested = false
                foregroundResumeRequested = true
                appendStatus("Foreground return queued until the host pause completes")
                return
            }
            guard parked else { return }
            await resumeHost(host)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func parkHost(_ host: PhoneDSHHost) async {
        guard !hostLifecycleTransition else { return }
        hostLifecycleTransition = true
        // Every early return, thrown error or lost continuation must release
        // the flag: while it is set the composer reads "处理中" and every
        // send/session switch/park/resume is refused. The watchdog is the
        // last resort behind the host's own 20 s drain bound.
        let watchdog = transitionWatchdog(seconds: 60, label: "Host park")
        defer {
            watchdog.cancel()
            hostLifecycleTransition = false
        }
        appendStatus("App in background: parking the host (in-flight work gets the drain window, then the turn is cancelled)…")
        do {
            try await host.park()
            parked = true
            appendStatus("Host parked; resume by returning to the app")
        } catch {
            parked = false
            reportError("Park failed: \(error)")
        }
        endBackgroundTask()
        let shouldResume = foregroundResumeRequested
        foregroundResumeRequested = false
        let shouldParkAgain = backgroundParkRequested
        backgroundParkRequested = false
        // Release before the queued follow-up so it passes its own guard.
        hostLifecycleTransition = false
        if shouldResume && parked {
            await resumeHost(host)
        } else if shouldParkAgain && !parked {
            await parkHost(host)
        }
    }

    /// Resumes a parked host from the UI (the drawer opens sessions from any
    /// state). Returns once the resume attempt finished.
    func resumeParkedHost() async {
        guard let host, parked, !hostLifecycleTransition else { return }
        await resumeHost(host)
    }

    private func resumeHost(_ host: PhoneDSHHost) async {
        guard parked, !hostLifecycleTransition else { return }
        hostLifecycleTransition = true
        // See parkHost: the flag must never stay set. A resume waits for the
        // host's own 240 s hello timeout, so the watchdog clears only past it.
        let watchdog = transitionWatchdog(seconds: 300, label: "Host resume")
        defer {
            watchdog.cancel()
            hostLifecycleTransition = false
        }
        do {
            try await host.resume()
            parked = false
            appendStatus("Host resumed; the session continues from the WAL")
            refreshFiles()
            await reconcileTurnStateAfterResume()
        } catch {
            reportError("Resume failed: \(error)")
        }
        let shouldPark = backgroundParkRequested
        foregroundResumeRequested = false
        backgroundParkRequested = false
        // Release before the queued follow-up so it passes its own guard.
        hostLifecycleTransition = false
        if shouldPark && !parked { await parkHost(host) }
    }

    /// Releases a latched host transition after a bound the host's own
    /// drain/hello timeouts cannot exceed, so a wedged host fails loud on the
    /// status line instead of pinning the composer at "处理中" forever.
    private func transitionWatchdog(seconds: UInt64, label: String) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.hostLifecycleTransition else { return }
            self.hostLifecycleTransition = false
            self.appendStatus("\(label) did not finish in time; the host transition was released")
        }
    }

    /// Reconciles `turnRunning` with the host after a park/resume cycle.
    ///
    /// A parked host drains and cancels its open turn; the terminal event can
    /// be lost across the resume, which used to leave this app believing a
    /// turn was still running. Every later send was then queued behind a turn
    /// that no longer existed and every session switch was refused.
    private func reconcileTurnStateAfterResume() async {
        guard let sessionID else { return }
        do {
            let transport = try await transportForManagement()
            let value = try await transport.call("session/list", args: .object([:]))
            let running = (value["items"]?.arrayValue ?? []).first { item in
                item["sessionId"]?.stringValue == sessionID
            }?["running"]?.boolValue
            guard running == false, turnRunning else { return }
            finishStreamingAssistant()
            turnRunning = false
            syncIdleTimer()
            clearQueueLines()
            statusLine = "已恢复：上一次回合在后台被取消"
            appendStatus("Turn was cancelled while the app was in the background; state cleared")
        } catch {
            // A failed probe leaves the previous behaviour in place; the next
            // turn event or an explicit stop still corrects the state.
        }
    }

    /// The turn finished while the app was hidden: release the audio session
    /// and park the idle host so the keep-alive never outlives the work.
    private func finishBackgroundKeepAlive() async {
        guard keepingAlive, let host else { return }
        stopBackgroundHeartbeat()
        keepAlive.stop()
        keepingAlive = false
        appendStatus("Turn finished in the background; keep-alive audio stopped, parking the idle host")
        await parkHost(host)
    }

    /// Every 10 s while hidden: how many harness events arrived since the last
    /// beat. Written to the status log only (not the transcript), so the log
    /// answers "did the Worker keep working?" after the fact.
    private func startBackgroundHeartbeat() {
        backgroundHeartbeat?.cancel()
        let started = Date()
        backgroundHeartbeat = Task { [weak self] in
            var lastCount = self?.eventsHandled ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                let now = self.eventsHandled
                let elapsed = Int(Date().timeIntervalSince(started))
                // With an active audio session iOS reports the remaining time as
                // DBL_MAX (finite!); converting that to Int traps, so clamp.
                let remainingSeconds = UIApplication.shared.backgroundTimeRemaining
                let remaining = remainingSeconds > 1_000_000 ? "unlimited" : String(Int(max(0, min(remainingSeconds, 1_000_000))))
                Self.persistStatus("bg-heartbeat t=\(elapsed)s events+=\(now - lastCount) total=\(now) turnRunning=\(self.turnRunning) host=\(self.hostState) audio=\(self.keepAlive.isActive) remaining=\(remaining)")
                lastCount = now
            }
        }
    }

    private func stopBackgroundHeartbeat() {
        backgroundHeartbeat?.cancel()
        backgroundHeartbeat = nil
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "phone-dsh.chat.park") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Keeps the screen on while a turn runs so auto-lock does not park the
    /// host in the middle of a long task.
    private func syncIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = turnRunning && host != nil
    }

    private func observeHost(_ host: PhoneDSHHost) {
        hostEventTask?.cancel()
        let stream = host.eventStream()
        hostEventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .stateChanged(_, let to):
                    self.hostState = "\(to)"
                    if to == .failed { self.hostDidFail(host) }
                case .error(let message):
                    // Keep the raw host text: the friendly summary alone made
                    // a WAL recovery failure look like a model-service error.
                    Self.appendDiagnostic("host error: \(message)")
                    self.reportError("引擎报错：\(Self.condensed(message))")
                case .webContentTerminated(let count):
                    self.restartPolicySawTermination = true
                    self.appendStatus("WebContent terminated (\(count)); the host restarts the Worker")
                case .restarted:
                    self.restartPolicyHighSamples = 0
                    self.restartPolicySawTermination = false
                    self.startedAt = Date()
                    self.appendStatus("Worker restarted; the session resumes from the WAL")
                default:
                    break
                }
            }
        }
    }

    private func hostDidFail(_ failed: PhoneDSHHost) {
        guard host === failed else { return }
        pumpTask?.cancel(); pumpTask = nil
        eventStreamRecovering = false
        hostEventTask?.cancel(); hostEventTask = nil
        host = nil
        failedHost = failed
        engineNeedsReset = true
        harness = nil
        sessionID = nil
        transcriptReady = false
        pendingPermission = nil
        pendingQuestion = nil
        availableAccessModes = []
        currentAccessMode = nil
        accessModeError = nil
        accessModeLoading = false
        startedAt = nil
        turnRunning = false
        parked = false
        foregroundResumeRequested = false
        backgroundParkRequested = false
        hostLifecycleTransition = false
        if keepingAlive {
            stopBackgroundHeartbeat()
            keepAlive.stop()
            keepingAlive = false
            endBackgroundTask()
        }
        syncIdleTimer()
    }

    // MARK: Unattended test hook

    /// Launch-time automation for device tests driven from the Mac.
    ///
    /// - `PDSH_CHAT_AUTOSTART=1` starts the host as soon as its anchor is in a
    ///   window and, when `PDSH_CHAT_AUTOPROMPT` is set, sends that prompt.
    /// - `PDSH_CHAT_AUTOSTOP=1` stops the host first and then sends the
    ///   prompt: that is the "typing boots the engine" path a person hits after
    ///   stopping it by hand, and `devicectl` cannot tap the composer.
    /// - `PDSH_CHAT_AUTORESTART=1` reports the launch-path acknowledgement of a
    ///   persisted `Failed` controller (`start(autoRecover:)`).
    ///
    /// `devicectl device process launch --environment-variables` supplies
    /// these; the model key still comes from the provider settings.
    private var autostartDone = false

    func autostartIfRequested() {
        guard !autostartDone else { return }
        let environment = ProcessInfo.processInfo.environment
        let autostart = environment["PDSH_CHAT_AUTOSTART"] == "1"
        let autostop = environment["PDSH_CHAT_AUTOSTOP"] == "1"
        guard autostart || autostop else { return }
        autostartDone = true
        let prompt = environment["PDSH_CHAT_AUTOPROMPT"]
        let autoRestart = environment["PDSH_CHAT_AUTORESTART"] == "1"
        Task { [weak self] in
            // The anchor view attaches to its window a moment after onAppear.
            for _ in 0..<20 {
                if self?.anchor.isInWindow == true { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self else { return }
            appendStatus("Autostart requested by the launch environment")
            // The page starts the host on appear too; wait for that start to
            // release the gate so this hook judges a settled state.
            for _ in 0..<40 {
                if !busy { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if autostart, !isStarted {
                await start(autoRecover: true)
            }
            if autoRestart {
                appendStatus("Auto restart: engineNeedsReset=\(engineNeedsReset) started=\(isStarted)")
            }
            if autostop, isStarted {
                await stop()
                appendStatus("Autostop requested by the launch environment; the send below must boot the engine")
            }
            if let prompt, !prompt.isEmpty {
                var sent = false
                // onAppear may still be booting the host/session. Wait for the
                // chat transport before dispatching an unattended test prompt.
                for _ in 0..<300 {
                    if canSend { sent = await send(prompt); break }
                    guard busy || isStarted else { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if !sent { appendStatus("Autoprompt not sent: the chat session did not become ready") }
                appendStatus("Autostart prompt delivered=\(sent) started=\(isStarted)")
            }
        }
    }

    // MARK: Turns

    func send(_ text: String) async -> Bool {
        await send(text, attachments: [])
    }

    /// 重发时把 `reusing` 传进来:仍用原来那条气泡,不再长出新的一行。
    func send(_ text: String, attachments: [HarnessAttachment], reusing itemID: String? = nil) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty else { return false }
        // Sending is the clearest signal that the engine is wanted. Boot it
        // here (the transcript stays visible from the cache meanwhile) instead
        // of silently dropping the message because nothing is running.
        if !isStarted, !busy {
            await ensureEngineRunning()
        }
        guard canSend, let harness, let sessionID else { return false }
        busy = true
        defer { busy = false }
        let (fingerprint, requestID) = Self.retryableRequest(operation: "prompt", text: prompt,
                                                            attachments: attachments)
        let dispatchStart = ProcessInfo.processInfo.systemUptime
        Self.persistStatus("latency client-observed phase=prompt-rpc-start request=\(requestID)")
        do {
            try await harness.send(.prompt(text: prompt, attachments: attachments, requestID: requestID), to: sessionID)
            Self.persistStatus("latency client-observed phase=prompt-rpc-accepted request=\(requestID) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - dispatchStart) * 1000))")
            Self.completeRetryableRequest(fingerprint: fingerprint, requestID: requestID)
            // The drawer needs a readable row before DSH publishes its own
            // title projection.
            SessionTitleHints.remember(prompt, for: sessionID)
            let attachmentLabel = attachments.map { "[\($0.name)]" }.joined(separator: " ")
            let visiblePrompt = [prompt, attachmentLabel].filter { !$0.isEmpty }.joined(separator: "\n")
            var input = ChatItem(id: itemID ?? "\(sessionID):prompt:\(requestID)",
                                 kind: .user, title: "You", text: visiblePrompt)
            input.promptRequestID = requestID
            NativeTranscriptProjector.acceptInput(input, in: &items)
            turnRunning = true
            syncIdleTimer()
            clearError()
            lastPrompt = (prompt, attachments)
            lastPromptRequestID = requestID
            return true
        } catch {
            Self.persistStatus("latency client-observed phase=prompt-rpc-failed request=\(requestID) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - dispatchStart) * 1000))")
            syncIdleTimer()
            reportError("Prompt failed: \(error)")
            return false
        }
    }

    func steer(_ text: String) async -> Bool {
        let guidance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guidance.isEmpty, canSteer, let harness, let sessionID else { return false }
        busy = true
        defer { busy = false }
        let (fingerprint, requestID) = Self.retryableRequest(operation: "steer", text: guidance,
                                                            attachments: [])
        do {
            try await harness.send(.steer(text: guidance, requestID: requestID), to: sessionID)
            Self.completeRetryableRequest(fingerprint: fingerprint, requestID: requestID)
            var input = ChatItem(id: "\(sessionID):steer:\(requestID)", kind: .user,
                                 title: "You (steering)", text: guidance)
            input.promptRequestID = requestID
            NativeTranscriptProjector.acceptInput(input, in: &items)
            clearError()
            return true
        } catch {
            reportError("Steer failed: \(error)")
            return false
        }
    }

    /// Drops the permission/question cards without answering them.
    ///
    /// The runtime re-delivers pending approvals to every new connection, so a
    /// local dismiss loses nothing. It is what lets Stop and a session switch
    /// proceed while a card is on screen instead of being refused forever.
    func dismissPendingRequests() {
        pendingPermission = nil
        pendingQuestion = nil
    }

    /// Close the question seat without touching an unrelated approval card.
    /// The host waterfall is not cancelled (the remote has no client-side
    /// cancellation command); a re-delivery still reopens the card.
    func dismissQuestion() {
        pendingQuestion = nil
    }

    func cancelTurn() async {
        // The card belongs to the turn being stopped; leaving it on screen
        // locked the composer and every session switch afterwards.
        dismissPendingRequests()
        guard let harness, let sessionID else { return }
        // The cancel RPC has no transport timeout: a busy Worker (a heavy
        // bash step, a WebContent restart) can swallow its response and this
        // await would never return, leaving `turnRunning` and the stop
        // spinner locked forever. Bound it; the local fallback below always
        // ends the turn for the person who pressed stop.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await harness.send(.cancel, to: sessionID)
                } catch {
                    // A wedged Worker can also fail the cancel call itself.
                    await MainActor.run { self.appendStatus("取消请求发送失败：\(error.localizedDescription)") }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
            }
            await group.next()
            group.cancelAll()
        }
        clearError()
        // The pinned runtime journals turn/end on cancel in the normal case.
        // When the turn is already stalled (no session events at all) that
        // terminal never arrives, and the composer would stay locked; give it
        // a short window, then end the turn on this side and say so.
        let deadline = Date().addingTimeInterval(3)
        while turnRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard turnRunning else { return }
        finishStreamingAssistant()
        turnRunning = false
        syncIdleTimer()
        clearQueueLines()
        clearError()
        statusLine = "已停止（运行时未确认）"
        appendStatus("已停止（运行时未确认）。若之后没有响应，请在 ⋯ 菜单里停止主机再重新启动。")
    }

    func respond(to permission: ChatPermission, decision: PermissionDecision) async {
        guard let harness, let sessionID else { return }
        do {
            try await harness.send(.permissionResponse(requestID: permission.id, decision: decision), to: sessionID)
            if pendingPermission?.id == permission.id { pendingPermission = nil }
            clearError()
            appendStatus("Permission for \(permission.tool): \(decision.rawValue)")
        } catch {
            reportError("Permission response failed: \(error)")
        }
    }

    func respondToQuestion(answer: String) async {
        guard let question = pendingQuestion, let harness, let sessionID else { return }
        do {
            try await harness.send(.questionResponse(requestID: question.requestID, answer: answer), to: sessionID)
            if pendingQuestion?.requestID == question.requestID { pendingQuestion = nil }
            clearError()
            appendStatus("Answered the agent's question")
        } catch {
            reportError("Question response failed: \(error)")
        }
    }

    private struct SessionHistory {
        var items: [ChatItem]
        var after: UInt64?
        var turnRunning: Bool
        var hasMore: Bool
        var beforeSeq: Int?
        var throughSeq: Int?
        var turnFacts: TurnFacts
        var inputReceipts: [String: Int]
    }

    /// Durable turn/start + turn/end facts, kept beside (not inside) ChatItem so
    /// history replay can draw the same closed-Turn control row as live events.
    private struct TurnFacts {
        var starts: [Int: Date] = [:]
        var endReasons: [Int: String] = [:]
        var ends: [Int: Date] = [:]
    }

    /// Reads DSH's durable event log directly so user prompts, which are not
    /// projected by AgentHarness.events, appear in their original position.
    private func loadSessionHistory(sessionID: String,
                                   transport: any DSHRemoteTransport,
                                   requireRunningState: Bool = false,
                                   pendingInputs: [ChatItem] = []) async throws -> SessionHistory {
        let mux = try await transport.openMux()
        let streamID = "phone-chat-history-\(UUID().uuidString)"
        let cursor: Int
        let snapshot: JSONValue
        do {
            try await mux.send(.object([
                "type": .string("open"),
                "streamId": .string(streamID),
                "endpoint": .string("session/follow"),
                "payload": .object(["args": .object(["request": .object([
                    "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                    "maxMessages": .number(1),
                    "assistantStream": .bool(false),
                ])])]),
            ]))
            snapshot = try await receiveHistorySnapshot(from: mux, streamID: streamID)
            guard let snapshotCursor = snapshot["cursor"]?.intValue else {
                throw ProviderError.invalidResponse("session/follow snapshot has no cursor")
            }
            cursor = snapshotCursor
            await mux.close()
        } catch {
            await mux.close()
            throw error
        }

        var records: [JSONValue] = []
        var hasMore = false
        var beforeSeq: Int?
        var historyPage: JSONValue = .object([:])
        if cursor >= 0 {
            let page = try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(cursor)),
                "maxMessages": .number(60),
            ])]))
            records = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            hasMore = page["hasMore"]?.boolValue ?? false
            beforeSeq = records.compactMap { $0["seq"]?.intValue }.min()
            historyPage = page
        }
        let inputReceipts = try await NativeTranscriptProjector.inputReceipts(
            for: pendingInputs, historyPage: historyPage, inbox: snapshot["projections"]?["values"]?["inbox"]
        ) { before in
            try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(cursor)), "beforeSeq": .number(Double(before)),
                "maxMessages": .number(60),
            ])]))
        }
        let after = cursor >= 0
            ? UInt64(cursor + 1) * DSHEventMapper.partsPerEvent - 1
            : nil
        let running: Bool?
        if requireRunningState {
            let sessions = try await transport.call("session/list", args: .object([:]))
            guard let confirmed = sessions["items"]?.arrayValue?.first(where: {
                $0["sessionId"]?.stringValue == sessionID
            })?["running"]?.boolValue else {
                throw PhoneDSHError.invalidResponse("session running state is unavailable")
            }
            running = confirmed
        } else if let sessions = try? await transport.call("session/list", args: .object([:])),
                  let row = sessions["items"]?.arrayValue?.first(where: { $0["sessionId"]?.stringValue == sessionID }) {
            running = row["running"]?.boolValue
        } else { running = nil }
        return SessionHistory(items: Self.transcriptItems(from: records, sessionID: sessionID), after: after,
                              turnRunning: running ?? Self.isTurnRunning(in: records),
                              hasMore: hasMore, beforeSeq: beforeSeq,
                              throughSeq: cursor >= 0 ? cursor : nil,
                              turnFacts: Self.turnFacts(in: records), inputReceipts: inputReceipts)
    }

    /// Loads one older message-aligned page and prepends unseen durable events.
    /// The existing tail remains untouched so the view can preserve its anchor.
    func loadEarlierTranscript() async {
        guard transcriptHasMore, let sessionID, let throughSeq = transcriptThroughSeq,
              let beforeSeq = transcriptBeforeSeq else { return }
        do {
            let transport = try await transportForManagement()
            let page = try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(throughSeq)),
                "beforeSeq": .number(Double(beforeSeq)),
                "maxMessages": .number(60),
            ])]))
            guard self.sessionID == sessionID else { return }
            let events = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            guard let nextBeforeSeq = events.compactMap({ $0["seq"]?.intValue }).min(),
                  nextBeforeSeq < beforeSeq else {
                transcriptHasMore = false
                transcriptError = "The DSH history page did not advance before seq \(beforeSeq)."
                return
            }
            let existingIDs = Set(items.map(\.id))
            let older = Self.transcriptItems(from: events, sessionID: sessionID)
                .filter { !existingIDs.contains($0.id) }
            let facts = Self.turnFacts(in: events)
            turnStartTimes.merge(facts.starts) { _, new in new }
            turnEndReasons.merge(facts.endReasons) { _, new in new }
            turnEndTimes.merge(facts.ends) { _, new in new }
            items = older + items
            transcriptBeforeSeq = nextBeforeSeq
            transcriptHasMore = page["hasMore"]?.boolValue ?? false
            transcriptError = nil
        } catch {
            guard self.sessionID == sessionID else { return }
            transcriptError = error.localizedDescription
        }
    }

    private func receiveHistoryCursor(from mux: any DSHMuxConnection, streamID: String) async throws -> Int {
        let snapshot = try await receiveHistorySnapshot(from: mux, streamID: streamID)
        guard let cursor = snapshot["cursor"]?.intValue else {
            throw ProviderError.invalidResponse("session/follow snapshot has no cursor")
        }
        return cursor
    }

    private func receiveHistorySnapshot(from mux: any DSHMuxConnection, streamID: String) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    guard let frame = try await mux.receive() else {
                        throw ProviderError.unavailable(retryAfter: nil)
                    }
                    guard frame["streamId"]?.stringValue == streamID else { continue }
                    switch frame["type"]?.stringValue {
                    case "error":
                        throw ProviderError.invalidResponse("session/follow failed: \(frame["error"]?["message"]?.stringValue ?? "unknown error")")
                    case "end":
                        throw ProviderError.invalidResponse("session/follow ended before its history cursor")
                    case "item":
                        let value = frame["value"] ?? .null
                        if value["type"]?.stringValue == "snapshot" {
                            guard value["cursor"]?.intValue != nil else {
                                throw ProviderError.invalidResponse("session/follow snapshot has no cursor")
                            }
                            return value
                        }
                    default:
                        continue
                    }
                }
                throw ProviderError.cancelled
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                await mux.close()
                throw ProviderError.unavailable(retryAfter: nil)
            }
            guard let cursor = try await group.next() else {
                throw ProviderError.invalidResponse("session/follow did not publish a history cursor")
            }
            group.cancelAll()
            return cursor
        }
    }

    private func currentJournalCursor(sessionID: String,
                                      transport: any DSHRemoteTransport) async throws -> Int {
        let mux = try await transport.openMux()
        let streamID = "phone-trajectory-cursor-\(UUID().uuidString)"
        do {
            try await mux.send(.object([
                "type": .string("open"), "streamId": .string(streamID),
                "endpoint": .string("session/follow"),
                "payload": .object(["args": .object(["request": .object([
                    "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                    "maxMessages": .number(1), "assistantStream": .bool(false),
                ])])]),
            ]))
            let cursor = try await receiveHistoryCursor(from: mux, streamID: streamID)
            await mux.close()
            return cursor
        } catch {
            await mux.close()
            throw error
        }
    }

    private func scheduleTrajectoryRefresh(sessionID: String) {
        trajectoryRefreshTask?.cancel()
        trajectoryRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.sessionID == sessionID else { return }
            await self.refreshTrajectory()
        }
    }

    private static func trajectoryEntries(from events: [JSONValue],
                                          sessionID: String) -> [NativeTrajectoryEntry] {
        events.compactMap { event in
            guard let seq = event["seq"]?.intValue,
                  let eventType = event["type"]?.stringValue,
                  !eventType.hasSuffix(".status"), eventType != "host/status" else { return nil }
            let data = event["data"] ?? .null
            let category: NativeTrajectoryEntry.Category
            switch eventType {
            case "system/message": category = .systemPrompt
            case "user/message": category = .userMessage
            case "agent/steering/message": category = .steeringMessage
            case "developer/message": category = .developerMessage
            case "assistant/message": category = .assistantMessage
            case "tool/call": category = .toolCall
            case "tool/result": category = .toolResult
            case "turn/start", "turn/end", "step/start", "step/end", "assistant/attempt",
                 "llm/retry", "request/header", "agent/inbox/spliced": category = .requestBoundary
            case _ where eventType.hasPrefix("compaction/"): category = .compaction
            case "command/run", "command/done": category = .command
            case "session/start", "session/end", "session/close": category = .sessionBoundary
            default: category = .otherBusiness
            }
            let preview: String
            switch category {
            case .systemPrompt, .userMessage, .steeringMessage: preview = contentText(data["content"])
            case .developerMessage: preview = contentText(data["message"]?["content"])
            case .assistantMessage: preview = contentText(data["message"]?["content"])
            case .toolCall:
                preview = "\(data["name"]?.stringValue ?? "tool") · \(render(data["arguments"] ?? .null))"
            case .toolResult:
                let message = data["message"] ?? .null
                preview = contentText(message["content"]).isEmpty
                    ? (data["error"]?["reason"]?.stringValue ?? render(data))
                    : contentText(message["content"])
            case .command:
                preview = [data["name"]?.stringValue, data["args"]?.stringValue,
                           data["text"]?.stringValue].compactMap { $0 }.joined(separator: " · ")
            default: preview = render(data)
            }
            let date = event["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            return NativeTrajectoryEntry(id: "\(sessionID):\(seq)", sessionID: sessionID,
                                         seq: seq, timestamp: date, eventType: eventType,
                                         category: category, preview: String(preview.prefix(1_200)), payload: event)
        }.sorted { $0.seq < $1.seq }
    }

    private static func transcriptItems(from records: [JSONValue], sessionID: String) -> [ChatItem] {
        let markers = compactionMarkers(in: records, sessionID: sessionID)
        guard !markers.isEmpty else {
            return NativeTranscriptProjector.items(from: records, sessionID: sessionID)
        }
        let projector = NativeTranscriptProjector.items(from: records, sessionID: sessionID)
        // Replace the projector's context row for a checkpoint with its
        // 上下文已压缩 marker, in place, so the marker keeps the checkpoint's
        // position in the transcript.
        var output: [ChatItem] = []
        output.reserveCapacity(projector.count + 1)
        var emitted = Set<Int>()
        for item in projector {
            if let seq = transcriptSeq(of: item.id, sessionID: sessionID),
               let marker = markers[seq], !emitted.contains(seq) {
                emitted.insert(seq)
                output.append(marker)
                continue
            }
            output.append(item)
        }
        // The projector drops a replacement whose content has no text; its
        // marker still belongs at that seq, so merge the leftovers by order.
        let missing = markers.keys.filter { !emitted.contains($0) }.sorted()
        guard !missing.isEmpty else { return output }
        var pending = missing.compactMap { markers[$0] }
        var merged: [ChatItem] = []
        for item in output {
            let seq = transcriptSeq(of: item.id, sessionID: sessionID) ?? Int.max
            while let marker = pending.first {
                guard let markerSeq = transcriptSeq(of: marker.id, sessionID: sessionID),
                      markerSeq <= seq else { break }
                merged.append(marker)
                pending.removeFirst()
            }
            merged.append(item)
        }
        merged.append(contentsOf: pending)
        return merged
    }

    /// Seq carried by a projected item id (`<sessionID>:<seq>` or
    /// `<sessionID>:<seq>:block-N`).
    private static func transcriptSeq(of id: String, sessionID: String) -> Int? {
        let prefix = "\(sessionID):"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// One durable compaction (start → summary → end → replacement
    /// `user/message`) folded into the single official marker row.
    ///
    /// Official derives the row from the replacement checkpoint and cites the
    /// summary record for its counts (`ui-chat/src/client/conversation-nodes/command.ts`).
    /// The generic projector instead emits 上下文已整理 per lifecycle event and
    /// shows the replacement as injected context, which is neither one row nor
    /// the truth; this fold replaces it. Keyed by the checkpoint's seq.
    private static func compactionMarkers(in records: [JSONValue], sessionID: String) -> [Int: ChatItem] {
        struct SummaryFacts {
            var summary: String?
            var itemCount: Int?
            var tokenCount: Int?
        }
        var factsByCompaction: [String: SummaryFacts] = [:]
        var commandText: [String: String] = [:]
        var checkpoints: [(seq: Int, data: JSONValue, time: Date?)] = []

        for record in records {
            guard let seq = record["seq"]?.intValue, let type = record["type"]?.stringValue else { continue }
            let data = record["data"] ?? .null
            switch type {
            case "compaction/summary":
                guard let id = data["compactionId"]?.stringValue else { continue }
                let summary = (data["summary"]?.arrayValue ?? []).compactMap { block -> String? in
                    guard block["type"]?.stringValue == "text" else { return nil }
                    return block["text"]?.stringValue
                }.joined()
                let seqs = data["shadowedSeqs"]?.arrayValue?.compactMap(\.intValue)
                factsByCompaction[id] = SummaryFacts(
                    summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : summary,
                    itemCount: seqs?.isEmpty == false ? seqs?.count : nil,
                    tokenCount: data["shadowedTokenCount"]?.intValue)
            case "command/done":
                guard let id = data["commandId"]?.stringValue,
                      let text = data["text"]?.stringValue else { continue }
                commandText[id] = text
            case "user/message":
                guard data["source"]?["kind"]?.stringValue == "compact-checkpoint" else { continue }
                checkpoints.append((seq: seq, data: data,
                                    time: record["time"]?.numberValue.map {
                                        Date(timeIntervalSince1970: $0 / 1_000)
                                    }))
            default:
                break
            }
        }
        guard !checkpoints.isEmpty else { return [:] }

        var markers: [Int: ChatItem] = [:]
        for checkpoint in checkpoints {
            let source = checkpoint.data["source"] ?? .null
            let compactionID = source["compactionId"]?.stringValue ?? ""
            let facts = factsByCompaction[compactionID] ?? SummaryFacts()
            let line = NativeCompaction.summaryLine(for: .init(
                itemCount: facts.itemCount,
                tokenCount: facts.tokenCount,
                summary: facts.summary,
                commandText: source["sourceCommandId"]?.stringValue.flatMap { commandText[$0] }))
            var marker = ChatItem(id: "\(sessionID):\(checkpoint.seq)", kind: .systemEvent,
                                  title: NativeCompaction.title, text: line)
            marker.timestamp = checkpoint.time
            marker.turn = checkpoint.data["turn"]?.intValue
            marker.step = checkpoint.data["step"]?.intValue
            marker.sourceKind = "compaction"
            marker.sourceSummary = facts.summary
            markers[checkpoint.seq] = marker
        }
        return markers
    }

    private static func turnFacts(in records: [JSONValue]) -> TurnFacts {
        var facts = TurnFacts()
        for event in records {
            guard let type = event["type"]?.stringValue else { continue }
            let data = event["data"] ?? .null
            guard let turn = data["turn"]?.intValue else { continue }
            let time = event["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
            switch type {
            case "turn/start":
                if let time { facts.starts[turn] = time }
            case "turn/end":
                if let time { facts.ends[turn] = time }
                facts.endReasons[turn] = data["reason"]?["kind"]?.stringValue ?? "completed"
            default:
                break
            }
        }
        return facts
    }

    private static func isTurnRunning(in records: [JSONValue]) -> Bool {
        var running = false
        for event in records {
            switch event["type"]?.stringValue {
            case "turn/start": running = true
            case "turn/end": running = false
            default: break
            }
        }
        return running
    }

    private static func contentText(_ content: JSONValue?) -> String {
        (content?.arrayValue ?? []).compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text": return block["text"]?.stringValue
            case "image": return "[图片]"
            default: return nil
            }
        }.joined()
    }

    private func startPump(harness: any AgentHarness, sessionID: String, after initialSeq: UInt64? = nil) {
        pumpTask?.cancel()
        eventStreamRecovering = false
        pumpTask = Task { [weak self] in
            await ChatEventPump.run(
                after: initialSeq,
                isCurrent: { self?.sessionID == sessionID },
                events: { harness.events(sessionID: sessionID, after: $0) },
                synchronize: { [weak self] in
                    guard let self else { throw CancellationError() }
                    Self.persistStatus("latency client-observed phase=stream-resync-start")
                    return try await self.synchronizeInterruptedSession(sessionID: sessionID)
                },
                handle: { [weak self] event in
                    self?.handle(event)
                    if event.seq != nil { self?.scheduleTrajectoryRefresh(sessionID: sessionID) }
                },
                interrupted: { [weak self] error in
                    guard let self else { return }
                    self.eventStreamRecovering = true
                    self.statusLine = "事件流中断，正在重新同步会话"
                    self.appendStatus("Event stream interrupted: \(error)")
                },
                recovered: { [weak self] in
                    guard let self else { return }
                    self.eventStreamRecovering = false
                    Self.persistStatus("latency client-observed phase=stream-resync-completed")
                    self.statusLine = self.turnRunning ? "会话已同步，任务仍在运行" : "会话已同步，任务已结束"
                })
        }
    }

    private func synchronizeInterruptedSession(sessionID: String) async throws -> UInt64? {
        let transport = try await transportForManagement()
        let history = try await loadSessionHistory(sessionID: sessionID, transport: transport,
                                                   requireRunningState: true, pendingInputs: items)
        try Task.checkCancellation()
        guard self.sessionID == sessionID else { throw CancellationError() }
        items = NativeTranscriptProjector.restoring(history.items, preservingInputsFrom: items,
                                                    inputReceipts: history.inputReceipts)
        turnStartTimes = history.turnFacts.starts
        turnEndReasons = history.turnFacts.endReasons
        turnEndTimes = history.turnFacts.ends
        transcriptHasMore = history.hasMore
        transcriptBeforeSeq = history.beforeSeq
        transcriptThroughSeq = history.throughSeq
        isShowingCachedTranscript = false
        lastSeq = history.after
        turnRunning = history.turnRunning
        activeTurn = history.turnRunning ? history.turnFacts.starts.keys.max() : nil
        activeStep = nil
        activeTurnStartedAt = activeTurn.flatMap { history.turnFacts.starts[$0] }
        if !history.turnRunning {
            finishStreamingAssistant()
            finishStreamingReasoning()
            clearQueueLines()
            pendingQuestion = nil
            pendingPermission = nil
            for index in items.indices where items[index].toolState == .running {
                items[index].toolState = .stopped
            }
        }
        syncIdleTimer()
        persistTranscriptSnapshot()
        scheduleNativeMetricsRefresh()
        if !turnRunning, keepingAlive { Task { await self.finishBackgroundKeepAlive() } }
        return history.after
    }

    private var latencyFirstEvents = Set<String>()

    /// Receipt times at the native client, not upstream model timings. Source
    /// event time and sequence let a diagnostic distinguish replay from delay.
    private func recordLatency(_ phase: String, event: HarnessEvent, once: Bool = false) {
        if once && !latencyFirstEvents.insert(phase).inserted { return }
        Self.persistStatus("latency client-observed phase=\(phase) turn=\(activeTurn.map(String.init) ?? "none") seq=\(event.seq.map(String.init) ?? "none") source_time=\(ISO8601DateFormatter().string(from: event.time)) uptime_ms=\(Int(ProcessInfo.processInfo.systemUptime * 1000))")
    }

    private func handle(_ event: HarnessEvent) {
        eventsHandled += 1
        // A queued message only needs its dispatch label until the turn shows
        // any activity. Assistant text is not the only first output: a turn
        // that starts with a tool call used to keep 发送中… forever.
        if case .turnStarted = event.kind {
            // Promoted to 发送中… by the turnStarted branch below.
        } else {
            clearSendingLabels()
        }
        switch event.kind {
        case .reasoningDelta(let text):
            recordLatency("first-reasoning", event: event, once: true)
            clearSendingLabels()
            if let index = items.indices.last, items[index].kind == .reasoning,
               items[index].streaming {
                items[index].text += text
            } else {
                finishStreamingReasoning()
                var item = ChatItem(id: eventItemID(event), kind: .reasoning,
                                    title: "思考", text: text, streaming: true)
                item.timestamp = event.time
                item.turn = activeTurn
                item.step = activeStep
                items.append(item)
            }
        case .assistantDelta(let text):
            recordLatency("first-assistant", event: event, once: true)
            clearSendingLabels()
            finishStreamingReasoning()
            if let index = items.indices.last, items[index].kind == .assistant, items[index].streaming {
                items[index].text += text
            } else {
                var item = ChatItem(id: eventItemID(event), kind: .assistant,
                                    title: "Assistant", text: text, streaming: true)
                item.timestamp = event.time
                item.turn = activeTurn
                item.step = activeStep
                items.append(item)
            }
        case .assistantMessage(let text):
            recordLatency("assistant-message", event: event)
            clearSendingLabels()
            finishStreamingReasoning()
            if let index = items.indices.last, items[index].kind == .assistant, items[index].streaming {
                if !text.isEmpty { items[index].text = text }
                items[index].streaming = false
            } else if !text.isEmpty {
                var item = ChatItem(id: eventItemID(event), kind: .assistant, title: "Assistant", text: text)
                item.timestamp = event.time
                item.turn = activeTurn
                item.step = activeStep
                items.append(item)
            }
            scheduleNativeMetricsRefresh()
        case .userMessage(let text, let source):
            if let sessionID {
                NativeTranscriptProjector.acknowledgeInput(event, sessionID: sessionID, in: &items)
            }
            // Human prompts are already appended optimistically by the
            // composer. Every non-human producer (subagent-settled, goal,
            // schedule, tool-jobs, webhook, plugin) must still surface; it is
            // rendered as a turn-trigger/context row, never as a user bubble.
            // A compaction's replacement message is not input at all: the
            // 上下文已压缩 marker above already represents it (official hides
            // the checkpoint row).
            guard source != "user", source != "compact-checkpoint", !text.isEmpty else { break }
            appendIncoming(text: text, source: source, event: event)
        case .inboxSpliced(let messages):
            inboxSplicedRevision += 1
            // One splice can carry several admitted messages. Keep their order
            // and give each a stable id suffix; human steering is already in
            // the local transcript, so only non-human producers are added here.
            for (index, message) in messages.enumerated()
            where message.source != "user" && message.source != "compact-checkpoint"
                && !message.text.isEmpty {
                appendIncoming(text: message.text, source: message.source,
                               event: event, idSuffix: "inbox-\(index)")
            }
        case .toolCall(let callID, let name, let arguments):
            recordLatency("tool-start:\(callID)", event: event)
            finishStreamingAssistant()
            finishStreamingReasoning()
            recentToolArguments[name] = Self.flattenedArguments(arguments)
            var item = ChatItem(id: eventItemID(event), kind: .toolCall,
                                title: "Tool call: \(name)", text: Self.render(arguments))
            item.timestamp = event.time
            item.turn = activeTurn
            item.step = activeStep
            item.callID = callID
            item.toolName = name
            item.arguments = arguments
            item.argumentsRaw = nativeJSON(arguments)
            item.toolState = .running
            items.append(item)
        case .toolResult(let callID, let isError, let summary):
            recordLatency("tool-result:\(callID)", event: event)
            let detail = event.toolResultDetail?.text ?? summary
            let state: NativeToolState = isError
                ? (event.toolResultErrorCode == "interrupted" ? .stopped : .error)
                : .ok
            if let index = items.indices.last(where: { items[$0].callID == callID && items[$0].kind == .toolCall }) {
                items[index].toolOutput = detail
                items[index].toolMetadata = event.toolResultMeta
                items[index].toolErrorCode = event.toolResultErrorCode
                items[index].toolState = state
            } else {
                var item = ChatItem(id: eventItemID(event), kind: .toolResult(isError: isError),
                                    title: isError ? "Tool error" : "Tool result", text: detail)
                item.timestamp = event.time
                item.turn = activeTurn
                item.step = activeStep
                item.callID = callID
                item.toolOutput = detail
                item.toolMetadata = event.toolResultMeta
                item.toolErrorCode = event.toolResultErrorCode
                item.toolState = state
                items.append(item)
            }
            scheduleNativeMetricsRefresh()
            refreshFiles()
        case .permissionRequested(let request):
            pendingPermission = ChatPermission(id: request.requestID, tool: request.tool,
                                               summary: request.summary,
                                               arguments: recentToolArguments[request.tool] ?? [:])
        case .questionRequested(let question):
            pendingQuestion = question
            appendStatus("The agent asks: \(question.prompt)")
        case .turnStarted(let turnID):
            let turnNumber = Int(turnID) ?? activeTurn ?? 0
            activeTurn = turnNumber
            latencyFirstEvents.removeAll()
            recordLatency("turn-start", event: event)
            activeStep = nil
            activeTurnStartedAt = event.time
            turnStartTimes[turnNumber] = event.time
            promoteQueuedToSending()
            turnBoundaryRevision += 1
            turnRunning = true
            syncIdleTimer()
            statusLine = "Turn running…"
        case .turnEnded(let turnID, let reason):
            recordLatency("turn-end", event: event)
            finishStreamingAssistant()
            finishStreamingReasoning()
            clearSendingLabels()
            turnRunning = false
            turnBoundaryRevision += 1
            activeTurnStartedAt = nil
            let finishedTurn = Int(turnID) ?? activeTurn ?? 0
            turnEndReasons[finishedTurn] = event.rawTurnEndKind ?? Self.rawTurnEndKind(reason)
            turnEndTimes[finishedTurn] = event.time
            syncIdleTimer()
            statusLine = "Turn ended: \(Self.describe(reason))"
            if case .failed = reason {
                for index in items.indices where items[index].turn == Int(turnID) && items[index].toolState == .running {
                    items[index].toolState = .stopped
                }
            }
            if case .cancelled = reason {
                for index in items.indices where items[index].turn == Int(turnID) && items[index].toolState == .running {
                    items[index].toolState = .stopped
                }
            }
            scheduleNativeMetricsRefresh()
            persistTranscriptSnapshot()
            if case .failed(let message) = reason {
                reportError(Self.userFacingFailure(message))
                failedPrompt = lastPrompt
                failedItemID = items.last(where: { if case .user = $0.kind { return true }; return false })?.id
                // 失败和「发送中…」互斥:同一条下面只留失败那行。
                if let id = failedItemID { clearQueueLine(itemID: id) }
            } else {
                // A finished turn has no queued or dispatching message left;
                // "已并入当前任务" used to stay under the message forever.
                clearQueueLines()
                appendStatus("Turn ended: \(Self.describe(reason))")
            }
            refreshFiles()
            Task { await self.refreshGoal() }
            if keepingAlive { Task { await self.finishBackgroundKeepAlive() } }
        case .progress(let phase, let step, let total):
            if phase == "step" { activeStep = step }
            statusLine = "\(phase) step \(step)\(total.map { " of \($0)" } ?? "")"
            if phase == "step" { modelRequests += 1 }
        case .compaction(let summary):
            // Official renders one marker per compaction. The live stream only
            // carries the summary text (counts arrive with the journal record,
            // see `transcriptItems`), so the collapsed line is the summary the
            // event already delivered; the checkpoint `user/message` that
            // follows is suppressed in the `.userMessage` branch.
            var item = ChatItem(id: eventItemID(event), kind: .systemEvent,
                                title: NativeCompaction.title,
                                text: NativeCompaction.summaryLine(forSummary: summary))
            item.timestamp = event.time
            item.turn = activeTurn
            item.step = activeStep
            item.sourceSummary = summary
            item.sourceKind = "compaction"
            items.append(item)
        case .sessionStatus(let status):
            if status.lowercased().hasPrefix("error:") {
                reportError("Session: \(status)")
            } else {
                statusLine = "Session: \(status)"
            }
        case .usage(let input, let output):
            inputTokens += input
            outputTokens += output
            if let index = items.indices.last(where: { items[$0].kind == .assistant && items[$0].turn == activeTurn }) {
                var usage = NativeTurnUsage()
                usage.uncachedInputTokens = input
                usage.outputTokens = output
                usage.totalTokens = input + output
                items[index].turnUsage = usage
            }
        case .exited(let reason):
            appendStatus("Agent exited: \(reason)")
            turnRunning = false
            syncIdleTimer()
        }
    }

    private func finishStreamingAssistant() {
        if let index = items.indices.last, items[index].kind == .assistant, items[index].streaming {
            items[index].streaming = false
        }
    }

    private func finishStreamingReasoning() {
        for index in items.indices where items[index].kind == .reasoning && items[index].streaming {
            items[index].streaming = false
        }
    }

    private func eventItemID(_ event: HarnessEvent) -> String {
        guard let sessionID, let seq = event.seq else { return UUID().uuidString }
        let position = DSHEventMapper.position(of: seq)
        return "\(sessionID):\(position.dshSeq):part-\(position.part)"
    }

    private func appendIncoming(text: String, source: String, event: HarnessEvent,
                                idSuffix: String? = nil) {
        let base = eventItemID(event)
        var item = ChatItem(id: idSuffix.map { "\(base):\($0)" } ?? base,
                            kind: .context, title: Self.incomingTitle(for: source), text: text)
        item.timestamp = event.time
        item.turn = activeTurn
        item.step = activeStep
        item.sourceKind = source
        items.append(item)
    }

    static func incomingTitle(for source: String) -> String {
        switch source {
        case "subagent-settled": return "子任务状态更新"
        case "goal": return "继续执行目标"
        case "schedule": return "自动化任务"
        case "tool-jobs": return "后台任务状态更新"
        case "agent-message": return "收到任务消息"
        case "team-message": return "收到团队消息"
        case "webhook": return "收到外部事件"
        case "cordis-host-runner": return "插件状态更新"
        case "user-question-reply": return "回答先前等待中的问题"
        default: return "收到执行请求"
        }
    }

    private func appendStatus(_ text: String) {
        items.append(ChatItem(kind: .status, title: "Host", text: text))
        Self.persistStatus(text)
    }

    private var lastLoggedGoal: String?

    /// Reads the goal projection; failures keep the last known goal.
    func refreshGoal() async {
        guard let harness, let sessionID else { return }
        do {
            let next = try await harness.goal(sessionID: sessionID)
            goal = next
            let summary = next.map { "\($0.phase.rawValue) \($0.objective.prefix(40))" } ?? "none"
            if summary != lastLoggedGoal {
                lastLoggedGoal = summary
                appendStatus("goal: \(summary)")
            }
        } catch {
            appendStatus("goal read failed: \(error)")
        }
    }

    private func scheduleNativeMetricsRefresh() {
        nativeMetricsRefreshTask?.cancel()
        nativeMetricsRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            await self.refreshNativeMetrics()
        }
    }

    func refreshNativeMetrics() async {
        guard let sessionID else { return }
        do {
            let transport = try await transportForManagement()
            let response = try await transport.call("session/projections", args: .object([
                "request": .object(["sessionId": .string(sessionID)]),
            ]))
            guard self.sessionID == sessionID else { return }
            let values = response["values"]
            projectionValues = values
            sessionStats = NativeSessionStats(value: values?["sessionStats"])
            tokenUsage = NativeTokenUsage(value: values?["tokenUsage"])
            contextPressure = NativeContextPressure(value: values?["contextPressure"])
            contextBreakdown = NativeContextBreakdown(value: values?["contextBreakdown"])
        } catch {
            appendStatus("Native conversation metrics unavailable: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func rateMessage(_ messageID: String, positive: Bool) async -> Bool {
        guard let sessionID else { return false }
        do {
            let transport = try await transportForManagement()
            _ = try await transport.call("messageFeedback/put", args: .object([
                "sessionId": .string(sessionID),
                "messageId": .string(messageID),
                "rating": .string(positive ? "positive" : "negative"),
                "ifVersion": .null,
            ]))
            return true
        } catch {
            reportError("反馈没有提交成功，请重试。")
            return false
        }
    }

    // MARK: - Planned-restart policy

    /// One sample per minute; the RestartPolicy decides whether the sample is
    /// a reason to restart, and the restart only runs when no turn is in
    /// flight (the tool-call boundary).
    private func startRestartPolicyMonitor() {
        restartPolicyTask?.cancel()
        restartPolicyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                await self.evaluateRestartPolicy()
            }
        }
    }

    private func evaluateRestartPolicy() async {
        guard let host, let budget = restartPolicyBudget,
              let startedAt, isStarted, !parked, !hostLifecycleTransition else { return }
        let heap = await host.currentEngineHeapBytes()
        let atToolBoundary = !turnRunning && !busy
        let evaluation = RestartPolicy.standard.evaluate(
            engineHeapBytes: heap,
            heapBudgetBytes: budget.engineHeapBytes,
            uptime: Date().timeIntervalSince(startedAt),
            highSamples: restartPolicyHighSamples,
            webContentTerminated: restartPolicySawTermination,
            atToolBoundary: atToolBoundary)
        restartPolicyHighSamples = evaluation.nextHighSamples
        guard let trigger = evaluation.trigger else { return }
        restartPolicyHighSamples = 0
        restartPolicySawTermination = false
        appendStatus("Planned restart (\(trigger.rawValue)) at the tool-call boundary")
        do {
            try await host.plannedRestart(reason: "restart policy: \(trigger.rawValue)")
        } catch {
            appendStatus("Planned restart failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Launch transcript snapshot

    private struct CachedTranscriptItem: Codable {
        var id: String
        var kind: String
        var title: String
        var text: String
    }

    private static func snapshotURL(for sessionID: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("transcript-snapshots", isDirectory: true)
            .appendingPathComponent("\(sessionID).json")
    }

    private static func snapshotKindName(_ kind: ChatItem.Kind) -> String {
        switch kind {
        case .user: return "user"
        case .context: return "context"
        case .assistant: return "assistant"
        case .reasoning: return "reasoning"
        case .image: return "image"
        case .toolCall: return "toolCall"
        case .toolResult(let isError): return isError ? "toolError" : "toolResult"
        case .systemEvent: return "systemEvent"
        case .turnError: return "turnError"
        case .maxTokens: return "maxTokens"
        case .unknown: return "unknown"
        case .status: return "status"
        }
    }

    private static func chatKind(from name: String) -> ChatItem.Kind? {
        switch name {
        case "user": return .user
        case "context": return .context
        case "assistant": return .assistant
        case "reasoning": return .reasoning
        case "image": return .image
        case "toolCall": return .toolCall
        case "toolResult": return .toolResult(isError: false)
        case "toolError": return .toolResult(isError: true)
        case "systemEvent": return .systemEvent
        case "turnError": return .turnError
        case "maxTokens": return .maxTokens
        case "unknown": return .unknown
        case "status": return .status
        default: return nil
        }
    }

    /// Renders the last session's settled items before the host is ready.
    private func restoreCachedTranscriptIfAvailable() {
        guard items.isEmpty,
              let sessionID = UserDefaults.standard.string(forKey: Self.currentSessionDefaultsKey),
              let data = try? Data(contentsOf: Self.snapshotURL(for: sessionID)),
              let cached = try? JSONDecoder().decode([CachedTranscriptItem].self, from: data),
              !cached.isEmpty else { return }
        items = cached.compactMap { item in
            guard let kind = Self.chatKind(from: item.kind) else { return nil }
            return ChatItem(id: item.id, kind: kind, title: item.title, text: item.text)
        }
        guard !items.isEmpty else { return }
        isShowingCachedTranscript = true
        statusLine = "显示上次对话，引擎在后台启动…"
    }

    /// Saves the settled items so the next launch can paint immediately.
    private func persistTranscriptSnapshot() {
        guard !isShowingCachedTranscript, let sessionID else { return }
        let settled = items.filter { !$0.streaming }.suffix(400)
        guard !settled.isEmpty else { return }
        let cached = settled.map { item in
            CachedTranscriptItem(id: item.id,
                                 kind: Self.snapshotKindName(item.kind),
                                 title: item.title,
                                 text: item.text)
        }
        guard let data = try? JSONEncoder().encode(cached) else { return }
        let url = Self.snapshotURL(for: sessionID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// One short line of a raw host message (the full text stays in
    /// `chat-status.log`). Keeps the friendly UI readable without hiding the
    /// engineering cause.
    static func condensed(_ message: String) -> String {
        let line = message.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? message
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }

    /// 宿主回来的失败原话常常是英文并带接口域名,一律翻成一句中文;
    /// 原话只写进 chat-status.log 供诊断导出。
    static func userFacingFailure(_ raw: String) -> String {
        let lower = raw.lowercased()
        Self.appendDiagnostic("turn failed: \(raw)")
        // 六种说法,认不出来只写「没发出去」:宿主原句永远不上屏。
        if lower.contains("403") || lower.contains("forbidden") || lower.contains("host_not_allowed")
            || lower.contains("not on the configured allow-list") {
            return "模型服务拒绝访问（403，检查服务地址与允许列表）"
        }
        if lower.contains("404") || lower.contains("not found") || lower.contains("no such model") {
            return "模型或地址不对（404，检查模型名与接口地址）"
        }
        if lower.contains("429") || lower.contains("too many") || lower.contains("rate limit") {
            return "请求太频繁（429）"
        }
        if lower.contains("key") || lower.contains("auth") || lower.contains("401") || lower.contains("unauthor") {
            return "密钥不被接受（401）"
        }
        if lower.contains("quota") || lower.contains("insufficient") || lower.contains("balance") || lower.contains("402") {
            return "额度用完"
        }
        if lower.contains("timeout") || lower.contains("timed out") || lower.contains("deadline") {
            return "等太久"
        }
        if lower.contains("network") || lower.contains("offline") || lower.contains("connect") {
            return "连不上模型服务"
        }
        if lower.contains("not running") || lower.contains("not started") || lower.contains("no host") || lower.contains("missing") {
            return "引擎停了"
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("500") {
            return "模型服务出错了"
        }
        return "没发出去"
    }

    static func appendDiagnostic(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: statusLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: statusLogURL)
        }
    }

    /// 上一轮失败后可以原样重发的那一条;清掉草稿就不还字(Ato 定的)。
    var failedPrompt: (String, [HarnessAttachment])?
    /// 失败行挂在产生它的那一条下面,不是永远挂在最后一条。
    var failedItemID: String?

    /// One local queue line per optimistically appended user message: the
    /// states official `QueueDock` distinguishes before a durable inbox row
    /// carries the submission (`queue/sending` plus its live/mutable row).
    enum NativeQueueLine: String, Equatable {
        case queued = "已排队"
        case sending = "发送中…"
        case steered = "已并入当前任务"
    }

    /// Local queue lines keyed by `ChatItem.id`, in submission order. The Host
    /// admits one queued input per turn, so only the oldest queued line becomes
    /// `sending` when its turn starts (see `promoteQueuedToSending`).
    private(set) var queueLines: [String: NativeQueueLine] = [:]
    private(set) var queueLineOrder: [String] = []
    /// Prompt RPC identity of each local queue line. Official `QueueDock`
    /// dedupes a local submission echo against the durable inbox row by this
    /// id; carrying it here lets the phone do the same when the projection
    /// exposes `source.rpcId`.
    private(set) var queueLineRequests: [String: String] = [:]
    /// Prompt RPC identity of the most recent successful `send`. The composer
    /// uses it to tie the local row to the durable queue/inbox row the same way
    /// official `QueueDock` ties `pendingSubmissions` by rpcId.
    private(set) var lastPromptRequestID: String?

    /// Read-only string view kept for previews and status logging.
    var queueLabel: [String: String] { queueLines.mapValues(\.rawValue) }

    func markQueued(itemID: String, requestID: String? = nil) {
        queueLines[itemID] = .queued
        if !queueLineOrder.contains(itemID) { queueLineOrder.append(itemID) }
        if let requestID, !requestID.isEmpty { queueLineRequests[itemID] = requestID }
    }

    func markSteered(itemID: String) {
        queueLines[itemID] = .steered
        if !queueLineOrder.contains(itemID) { queueLineOrder.append(itemID) }
    }

    /// Drop every local queue line (session switch, turn end, cancel).
    func clearQueueLines() {
        guard !queueLines.isEmpty else { return }
        queueLines.removeAll()
        queueLineOrder.removeAll()
        queueLineRequests.removeAll()
    }

    private func clearQueueLine(itemID: String) {
        queueLines[itemID] = nil
        queueLineOrder.removeAll { $0 == itemID }
        queueLineRequests[itemID] = nil
    }

    /// 回复一旦开始流式输出,这条消息就已经送达:「发送中…」必须收掉,
    /// 否则它会一直挂在用户消息下面(线上反馈)。
    private func clearSendingLabels() {
        for id in queueLineOrder where queueLines[id] == .sending {
            queueLines[id] = nil
            queueLineRequests[id] = nil
        }
        queueLineOrder.removeAll { queueLines[$0] == nil }
    }

    /// 宿主真正开始处理这一条时,把「已排队」换成「发送中…」。
    ///
    /// A turn admits exactly one queued input, so promoting every label turned
    /// three queued messages into three simultaneous 「发送中…」 rows (the
    /// duplicate-pending-row report). Only the oldest queued line advances.
    private func promoteQueuedToSending() {
        guard let next = queueLineOrder.first(where: { queueLines[$0] == .queued }) else { return }
        queueLines[next] = .sending
    }

    #if DEBUG
    func debugInstallNativeMetricsPreview() {
        sessionStats = NativeSessionStats(value: .object([
            "turns": .number(5), "steps": .number(17), "llmMs": .number(42_000),
            "toolMs": .number(8_000), "ttftMs": .number(6_000), "ttftSteps": .number(5),
            "decodeMs": .number(40_000), "decodeTokens": .number(2_160),
        ]))
        tokenUsage = NativeTokenUsage(uncachedInputTokens: 50_000, outputTokens: 8_000,
                                      cacheReadTokens: 750_000, cacheWriteTokens: 200_000)
        contextPressure = NativeContextPressure(value: .object([
            "projectedTokens": .number(100_000), "contextWindow": .number(1_000_000),
        ]))
        contextBreakdown = NativeContextBreakdown(value: .object([
            "systemTokens": .number(20_000), "toolsTokens": .number(30_000), "messageTokens": .number(50_000),
        ]))
    }

    /// 确定性状态:一条失败消息加下面那行「没发出去 · 重试」。
    func debugInjectFailure(text: String = "整理一下这周的日志") {
        let id = "debug-failure-\(UUID().uuidString.prefix(4))"
        items.append(ChatItem(id: id, kind: .user, title: "You", text: text))
        failedItemID = id
        failedPrompt = (text, [])
        userFacingError = "没发出去"
    }

    /// 确定性状态:一条带工具行、代码块和两段正文的助手回复。
    func debugInjectAssistant() {
        items.append(ChatItem(id: "debug-assistant-tool", kind: .toolCall, title: "工具",
                              text: "Read · Package.swift"))
        let body = """
        先看了工程的入口,`.build` 目录已经在忽略列表里。

        ```swift
        let scheme = "PhoneDSHProbe"
        let destination = "platform=iOS Simulator"
        ```

        接下来我会把这一段改动落到 `ChatPage.swift`,然后重新编译验证。
        """
        items.append(ChatItem(id: "debug-assistant-body", kind: .assistant, title: "DSH", text: body))
    }

    /// 确定性状态:一段多轮工具调用(含一条失败),用来验收收纳后的行高。
    func debugInjectToolRun() {
        let calls: [(String, String, Bool?)] = [
            ("bash", "ls -la /dsh/workspace", nil),
            ("", "total 12 drwxr-xr-x 3 user staff 96 demo", false),
            ("bash", "rg --json TODO Sources/", nil),
            ("", "{\"path\":\"Sources/PhoneDSH/PhoneDSH.swift\",\"line\":12}", false),
            ("open_page", "https://example.com/news", nil),
            ("", "403 forbidden: upstream refused the request", true),
            ("bash", "cat /dsh/workspace/demo/native-ui.md", nil),
            ("", "# 标题\n正文第一段", false),
        ]
        for (index, entry) in calls.enumerated() {
            let id = "debug-tools-\(index)"
            if entry.2 == nil {
                items.append(ChatItem(id: id, kind: .toolCall, title: "Tool call: \(entry.0)", text: entry.1))
            } else {
                items.append(ChatItem(id: id, kind: .toolResult(isError: entry.2 == true),
                                      title: entry.2 == true ? "Tool error" : "Tool result", text: entry.1))
            }
        }
    }

    /// 确定性状态:一条排队中的消息。
    func debugInjectQueued(text: String = "把这周的日志按天归档") {
        let id = "debug-queued-\(UUID().uuidString.prefix(4))"
        items.append(ChatItem(id: id, kind: .user, title: "You", text: text))
        markQueued(itemID: id)
    }
    #endif

    /// 重试失败的这一轮:同一条内容重新入队。
    func retryFailedPrompt() async -> Bool {
        guard let (text, attachments) = failedPrompt else { return false }
        let pendingID = failedItemID
        // 重试期间那条下面只留一个状态:先把失败行摘掉、挂上「发送中…」,
        // 失败回来再把它挂回去——两行同时出现,人会以为消息发出去又没发。
        if let pendingID {
            failedItemID = nil
            queueLines[pendingID] = .sending
            if !queueLineOrder.contains(pendingID) { queueLineOrder.append(pendingID) }
        }
        clearError()
        let ok = await send(text, attachments: attachments, reusing: pendingID)
        if let pendingID { clearQueueLine(itemID: pendingID) }
        failedItemID = ok ? nil : pendingID
        if ok { failedPrompt = nil } else { failedPrompt = (text, attachments) }
        return ok
    }

    private func reportError(_ text: String) {
        userFacingError = text
        statusLine = text
        appendStatus(text)
    }

    /// Status rows also go to `Documents/chat-status.log` so a host error can
    /// be read back from the device container after the fact (the transcript
    /// itself lives only in memory).
    static let statusLogURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("chat-status.log")

    private static func persistStatus(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(text)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: statusLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: statusLogURL)
        }
    }

    private static func render(_ arguments: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(arguments), let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "\(arguments)"
    }

    /// Keep DSH's idempotency key across an ambiguous transport failure so a
    /// user retry cannot append the same prompt a second time. Only the digest
    /// and opaque request ID are persisted; prompt and attachment contents are
    /// never written to defaults by this retry path.
    private static func retryableRequest(operation: String, text: String,
                                         attachments: [HarnessAttachment]) -> (String, String) {
        var material = Data()
        func append(_ bytes: Data) {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
            material.append(bytes)
        }
        append(Data(operation.utf8))
        append(Data(text.utf8))
        for attachment in attachments {
            append(Data(attachment.name.utf8))
            append(Data(attachment.mimeType.utf8))
            append(attachment.data)
        }
        let fingerprint = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        var stored = UserDefaults.standard.dictionary(forKey: retryableRequestIDsDefaultsKey) as? [String: String] ?? [:]
        let requestID: String
        if let existing = stored[fingerprint] {
            requestID = existing
        } else {
            requestID = UUID().uuidString
            stored[fingerprint] = requestID
            if stored.count > 64 {
                let stale = stored.keys.sorted().prefix(stored.count - 64)
                for key in stale { stored[key] = nil }
            }
            UserDefaults.standard.set(stored, forKey: retryableRequestIDsDefaultsKey)
        }
        return (fingerprint, requestID)
    }

    private static func completeRetryableRequest(fingerprint: String, requestID: String) {
        var stored = UserDefaults.standard.dictionary(forKey: retryableRequestIDsDefaultsKey) as? [String: String] ?? [:]
        guard stored[fingerprint] == requestID else { return }
        stored[fingerprint] = nil
        UserDefaults.standard.set(stored, forKey: retryableRequestIDsDefaultsKey)
    }

    private static func describe(_ reason: HarnessTurnEnd) -> String {
        switch reason {
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed(let message): return "failed — \(message)"
        case .budgetExhausted(let message): return "budget exhausted — \(message)"
        }
    }

    /// The wire `turn/end.reason.kind` used by the official turn-process row.
    /// Fallbacks only matter for backends that do not preserve the raw kind.
    private static func rawTurnEndKind(_ reason: HarnessTurnEnd) -> String {
        switch reason {
        case .completed: return "completed"
        case .cancelled: return "aborted"
        case .failed: return "error"
        case .budgetExhausted: return "max-tokens"
        }
    }

    // MARK: Workspace files

    func refreshFiles() {
        let root = materializedWorkspace.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path + "/"
        var found: [WorkspaceFile] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                // A path outside the materialized root is not a workspace file;
                // an absolute path here would break the list grouping and every
                // preview/share decision downstream.
                guard path.hasPrefix(rootPrefix) else { continue }
                found.append(WorkspaceFile(relativePath: String(path.dropFirst(rootPrefix.count)),
                                           size: values.fileSize ?? 0))
            }
        }
        files = found.sorted { $0.relativePath < $1.relativePath }
        if let previewPath, !files.contains(where: { $0.relativePath == previewPath }) {
            self.previewPath = nil; previewText = nil
        }
    }

    func preview(_ file: WorkspaceFile) {
        let url = materializedWorkspace.appendingPathComponent(file.relativePath)
        previewPath = file.relativePath
        guard let data = try? Data(contentsOf: url) else { previewText = "(unreadable)"; return }
        let limit = 24 * 1024
        let slice = data.prefix(limit)
        if let text = String(data: slice, encoding: .utf8) {
            previewText = text + (data.count > limit ? "\n… (\(data.count) bytes, truncated)" : "")
        } else {
            previewText = "(binary, \(data.count) bytes)"
        }
    }

    func clearTranscript() {
        items.removeAll()
        inputTokens = 0; outputTokens = 0; modelRequests = 0
    }
}

#if DEBUG
extension ChatModel {
    /// Preview-only: park a message state that normally comes from a live turn
    /// so the failure and queued screens can be reviewed without a model.
    func debugInstallPreviewState(failedItemID itemID: String?, error: String?, queue: [String: String]) {
        failedItemID = itemID
        userFacingError = error
        clearQueueLines()
        for (id, label) in queue {
            let line = NativeQueueLine(rawValue: label) ?? .queued
            queueLines[id] = line
            if !queueLineOrder.contains(id) { queueLineOrder.append(id) }
        }
    }

    /// Debug-only sample conversation, opened with `-uiPreview sample`. It never
    /// touches the network or the host: the items are fabricated here so a
    /// reviewer can see a full thread (markdown, a tool result, a failed message
    /// and a pending card) on a machine with no model configured. Release builds
    /// do not contain this code, and the launch argument is ignored there.
    static var sampleRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiPreview"),
              arguments.count > index + 1 else { return false }
        return arguments[index + 1] == "sample"
    }

    static func installSampleConversationIfRequested() {
        guard sampleRequested else { return }
        let model = ChatModel.shared
        // Never cover a conversation that is actually running: the sample only
        // fills an idle, empty debug surface.
        guard !model.turnRunning, !model.busy, !model.keepingAlive else { return }
        model.items = [
            ChatItem(kind: .user, title: "", text: "把示例项目的测试跑一遍，失败的顺手修掉"),
            ChatItem(kind: .assistant, title: "", text: """
            先看一下它现在有什么测试。

            | 目标 | 用例 | 上次结果 |
            | --- | --- | --- |
            | ProbeKit | 42 | 通过 |
            | PhoneDSHProbe | 18 | 2 个失败 |

            失败的两个都在格式化这一层：
            ```swift
            func relative(_ date: Date) -> String {
                if seconds < 60 { return "刚刚" }
                return minuteText(seconds)
            }
            ```
            """),
            ChatItem(kind: .toolCall, title: "运行测试", text: "swift test --filter SessionTime"),
            ChatItem(kind: .toolResult(isError: false), title: "运行测试", text: "18 tests, 2 failures"),
            ChatItem(kind: .toolResult(isError: true), title: "运行测试", text: "第二个断言失败：期望「刚刚」，实际「0 分钟前」"),
            ChatItem(kind: .assistant, title: "", text: """
            第二个用例的边界写错了：不到一分钟的分支没有命中，落到了按分钟计算那一支。改法是把这个判断提前，并且给 59 秒和 60 秒各加一条用例。

            改完我会再跑一遍全量，把两个失败一起验证，然后把 diff 贴上来。
            """),
            ChatItem(kind: .toolCall, title: "读取文件", text: "Tests/SessionTimeTests.swift"),
            ChatItem(kind: .toolResult(isError: false), title: "读取文件", text: "42 行"),
            ChatItem(kind: .assistant, title: "", text: "已经改好了，正在跑最后一遍。", streaming: true)
        ]
        model.pendingPermission = ChatPermission(
            id: "sample-permission",
            tool: "run_command",
            summary: "运行 swift test --filter SessionTime")
        model.pendingQuestion = HarnessQuestion(
            requestID: "sample-question",
            prompt: "两个失败的用例怎么处理？",
            options: ["都修掉", "先跳过"])
    }
}
#endif
