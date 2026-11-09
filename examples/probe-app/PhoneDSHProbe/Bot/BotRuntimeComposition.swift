// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHBot
import PhoneDSHDeviceTasks
#if canImport(PhoneDSHADB) && canImport(PhoneDSHLoopback)
import PhoneDSHADB
import PhoneDSHLoopback
#endif
#if canImport(PhoneDSHBLE)
import PhoneDSHBLE
#endif
#if canImport(ProbeKit)
import ProbeKit
#endif

actor BotDeferredVolatileContextProvider: BotVolatileContextProviding {
    private var provider: (any BotVolatileContextProviding)?

    func attach(_ provider: any BotVolatileContextProviding) {
        self.provider = provider
    }

    func snapshot(botId: String, sessionId: String, kind: BotSessionKind) async throws -> BotVolatileBlocks {
        guard let provider else { throw BotMCPError.unavailable("volatile provider is not connected") }
        return try await provider.snapshot(botId: botId, sessionId: sessionId, kind: kind)
    }
}

actor BotRuntimeTurnStopper: BotProductionTurnStopping {
    let remote: BotDSHRemoteRuntime
    init(remote: BotDSHRemoteRuntime) { self.remote = remote }
    func stopCurrentTurn(turnID: String?) async throws { try await remote.stopMainTurn(turnID: turnID) }
}

/// UI-visible connection state of the production Bot runtime. The Bot page
/// renders a disconnect banner for `recovering`/`failed` instead of silently
/// presenting stale rows after the Worker died.
enum BotRuntimeState: Equatable, Sendable {
    case idle
    case preparing
    case connecting
    case ready
    case recovering
    case failed(String)
    case stopped

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
final class BotRuntimeComposition {
    struct Launch {
        let composition: BotRuntimeComposition
        let environment: BotProductionEnvironment
        let workerEnvironment: [String: String]
    }

    let environment: BotProductionEnvironment
    let runtime: BotMCPRuntime
    let handler: BotMCPHandler
    let server: BotMCPHTTPServer
    let remote: BotDSHRemoteRuntime
    let scheduler: RoutineScheduler
    let planner: BotRemoteActionPlanner
    let wakeInbox: WakeInbox
    let outbox: BotProductionEffectRunner
    let routineOutbox: BotRoutineOutbox
    let rows: BotProductionRowService
    let info: BotProductionInfoService

    private var host: PhoneDSHHost?
    private var hostTask: Task<Void, Never>?
    /// The Host whose event stream `hostTask` is currently draining. Worker
    /// restart recovery runs *inside* that task, so rebinding the same Host
    /// must not cancel the observer it is running on.
    private var observedHost: PhoneDSHHost?
    private var tickTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var started = false
    /// True only while this composition owns the DeviceTaskManager settlement
    /// callback. Delivery is at-most-once: the terminal journal write and the
    /// held-inbox enqueue are separate steps, so a crash in between or a stopped
    /// Bot loses this notice. The journal itself is unaffected and is never
    /// replayed to synthesize a missing notice.
    private var deliversDeviceTaskResults = false

    /// The Worker never carries the real Bot bearer. The host egress route
    /// (`MCPEgressPolicy.grantBotRuntimeEndpoint`) injects it after stripping
    /// the placeholder, so neither the page URL (`?env=`) nor the Worker
    /// process ever sees it.
    static let workerTokenPlaceholder = "phone-host-injects-bot-mcp-token"

    /// Observed by `ChatModel`; the Bot page shows this state as a banner.
    private(set) var state: BotRuntimeState = .idle {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }
    var onStateChange: ((BotRuntimeState) -> Void)?

    /// Builds the one production composition: `BotMCPRuntime` owns the single
    /// `RoutineMachine` and `BotMemory`, and the environment receives those
    /// exact instances instead of constructing parallel stores.
    static func prepare(store: SQLiteDomainStore,
                        botID: String = "main",
                        sessionLogURL: URL? = nil) async throws -> Launch {
        let deferred = BotDeferredVolatileContextProvider()
        let runtime = BotMCPRuntime(store: store, volatileProvider: deferred)
        let machine = await runtime.routineMachine
        let memory = await runtime.memory
        let environment = BotProductionEnvironment(
            domain: store, botID: botID, sessionID: botID,
            routineMachine: machine, memory: memory, sessionLogURL: sessionLogURL)
        let language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        let volatile = await BotDomainVolatileContextProvider(
            memory: memory, routines: machine,
            personaAsync: { _, _ in
                let context = try await environment.context()
                let name = context.botName.replacingOccurrences(of: "\n", with: " ").prefix(80)
                return "你的名字是\(name)。用户问起名字时如实回答。"
            }, language: language)
        await deferred.attach(volatile)
        let handler = BotMCPHandler(runtime: runtime)
        let server = BotMCPHTTPServer(handler: handler)
        let url = try await server.start()
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: botID))
        let remote = try await BotDSHRemoteRuntime(
            transport: UnstartedBotTransport(), runtime: runtime,
            botId: botID, wakeInbox: inbox,
            botDataDirectory: BotSessionRegistry.botDataDirectory,
            onSessionRegistered: { sessionID in
                // The registry is UI-facing and MainActor-isolated. Registration
                // is an observability hint for legacy ids; `gb-` filtering never
                // waits for this hop.
                Task { @MainActor in BotSessionRegistry.shared.register(sessionID) }
            })
        let composition = await BotRuntimeComposition(
            environment: environment, runtime: runtime, handler: handler, server: server,
            remote: remote, wakeInbox: inbox, botID: botID)
        return Launch(composition: composition, environment: environment, workerEnvironment: [
            "PDSH_PHONE_MCP_URL": url.absoluteString,
            "PDSH_PHONE_MCP_TOKEN": workerTokenPlaceholder,
        ])
    }

    private init(environment: BotProductionEnvironment, runtime: BotMCPRuntime,
                 handler: BotMCPHandler, server: BotMCPHTTPServer,
                 remote: BotDSHRemoteRuntime, wakeInbox: WakeInbox, botID: String) async {
        self.environment = environment
        self.runtime = runtime
        self.handler = handler
        self.server = server
        self.remote = remote
        self.wakeInbox = wakeInbox
        let machine = await runtime.routineMachine
        planner = BotRemoteActionPlanner(remote: remote, runtime: runtime, handler: handler,
                                         store: environment.domain, botID: botID,
                                         wakeInbox: wakeInbox)
        routineOutbox = BotRoutineOutbox(
            store: environment.domain, machine: machine, botID: botID)
        outbox = BotProductionEffectRunner(store: environment.domain)
        rows = BotProductionRowService(environment: environment, remote: remote)
        info = BotProductionInfoService(environment: environment)
        scheduler = RoutineScheduler(
            botId: botID, machine: machine, inbox: wakeInbox,
            sink: routineOutbox,
            runner: { [remote] request in await remote.runRoutine(request) },
            cancelRunner: { [remote] cancellation in await remote.cancelRoutine(cancellation) },
            available: { [remote] _ in await remote.isAvailable() },
            busy: { [remote] _ in await remote.isMainTurnBusy() },
            leaseOwner: "bot-runtime-composition")
    }

    /// Attaches to `newHost` and rebinds every dependency the old Host owned.
    ///
    /// A different Host is no longer an error: `ChatModel.stop()` and
    /// `restartEngine()` build a new Host, so the composition detaches the old
    /// binding, attaches the new transport and re-runs recovery exactly once.
    func start(host newHost: PhoneDSHHost) async throws {
        if let current = host, current === newHost, started, !state.isFailure {
            return
        }
        if let current = host, current !== newHost {
            await detachBinding()
        }
        host = newHost
        try await bind(to: newHost, recovering: false)
    }

    /// One retry path the Bot page can call after a visible disconnect; the
    /// next `.restarted` Host event retries automatically as well.
    func retry() async {
        guard let host else { return }
        guard !started || state.isFailure else { return }
        do {
            try await bind(to: host, recovering: true)
        } catch {
            state = .failed("Bot 连接恢复失败：\(error.localizedDescription)")
            scheduleRecoveryRetry(host)
        }
    }

    /// The single recovery path for a fresh Host, a rebuilt Host after a
    /// Worker termination, a manual retry and the scheduled retry loop.
    ///
    /// Order is part of the contract: the replaced Worker incarnation is
    /// invalidated first, then the transport/session are rebound, durable work
    /// is recovered and only then the outbox and scheduler start.
    private func bind(to newHost: PhoneDSHHost, recovering: Bool) async throws {
        state = recovering ? .recovering : .connecting
        do {
            // 1. The old Worker process is gone: pending approvals, tool-call
            // registrations and in-flight tasks belong to that incarnation.
            // Invalidate them before the replacement Worker can claim anything.
            _ = await runtime.workerRestarted()

            // 2. Transport for the new Worker incarnation.
            try await newHost.start()
            let transport = try await newHost.makeTransport()
            await remote.attachTransport(transport)

            // 3. Main session, then the production environment that owns the
            // single routine/memory authority.
            let sessionID = try await remote.startMainSession()
            try await environment.connect(BotProductionComposition(
                sessionID: sessionID, planner: planner,
                turnStopping: BotRuntimeTurnStopper(remote: remote)))

            // 4. Durable routines, then 5. task wakes interrupted by the
            // previous Worker.
            _ = try await scheduler.recover()
            _ = await remote.deliverInterruptedTaskWakes()

            // Every bind also re-attaches the native MCP forwarder: one Bot
            // endpoint owns both Bot and native device tools. DeviceMCPServer
            // muxes the BLE tools and falls through to ADB; the E2E build has
            // no PhoneDSHBLE product, so it keeps the ADB-only endpoint.
            #if canImport(PhoneDSHADB) && canImport(PhoneDSHLoopback)
            #if canImport(PhoneDSHBLE) && canImport(PhoneDSHVenus)
            await attachNativeMCP(PhoneNativeMCP.server)
            #elseif canImport(PhoneDSHBLE)
            await attachNativeMCP(DeviceMCPServer.shared)
            #else
            await attachNativeMCP(ADBMCPServer.shared)
            #endif
            #endif

            await installOutboxHandlers()
            started = true
            observeHost(newHost)

            // 8. Publishes the shared outbox, then the scheduler. 9. ready.
            await outbox.start()
            await scheduler.start()
            startTick()
            installDeviceTaskResultDelivery()
            state = .ready
        } catch {
            state = .failed("Bot 连接失败：\(error.localizedDescription)")
            throw error
        }
    }

    private func installOutboxHandlers() async {
        await outbox.register(kind: BotRoutineOutbox.kind) { [routineOutbox] lease in
            try await routineOutbox.apply(lease)
        }
    }

    private func startTick() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = try? await self.remote.watchdogMonitor().tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    #if canImport(PhoneDSHADB) && canImport(PhoneDSHLoopback)
    /// The Bot MCP listener is the Worker's only `phone` server. Native device
    /// tools are forwarded in-process so one endpoint owns the env.
    func attachNativeMCP(_ server: any NativeMCPServing) async {
        await handler.attachNativeMCP(BotNativeMCPForwarder(server: server))
    }
    #endif

    /// Tears down the Host-bound half of the runtime. The MCP server, durable
    /// stores and the single routine/memory authority stay alive across Host
    /// rebuilds; a later `start(host:)` republishes scheduler and outbox.
    func stop() async {
        await detachBinding()
        await runtime.approvals.cancelAll(reason: "shutdown")
        _ = await runtime.gateway.attribution.prune()
        host = nil
        started = false
        state = .stopped
    }

    private func detachBinding() async {
        // Stop accepting device settlements before the rest of the binding is
        // torn down. A result persisted now is lost to the Bot (at-most-once)
        // rather than delivered by a composition that no longer runs.
        removeDeviceTaskResultDelivery()
        await scheduler.stop()
        await outbox.stop()
        tickTask?.cancel()
        tickTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        hostTask?.cancel()
        hostTask = nil
        observedHost = nil
        await remote.attachTransport(UnstartedBotTransport())
        started = false
    }

    /// Owns the one callback that turns a durable device task terminal record
    /// into a read-only held item. The callback is synchronous on the manager's
    /// actor; enqueueing is asynchronous and its failure is logged, never
    /// propagated into the task journal or the device report.
    private func installDeviceTaskResultDelivery() {
        guard !deliversDeviceTaskResults else { return }
        deliversDeviceTaskResults = true
        DeviceTaskManager.shared.installTaskSettlementHandler(owner: self) { [weak self] settlement, displayName in
            guard let self, self.deliversDeviceTaskResults else { return }
            self.enqueueDeviceTaskResult(settlement, displayName: displayName)
        }
    }

    private func removeDeviceTaskResultDelivery() {
        deliversDeviceTaskResults = false
        DeviceTaskManager.shared.removeTaskSettlementHandler(owner: self)
    }

    private func enqueueDeviceTaskResult(_ settlement: DeviceTaskSettlement, displayName: String) {
        let status: DeviceTaskResultNotice.Status
        let result: String
        switch settlement.outcome {
        case .completed(let output, _):
            status = .completed
            result = output
        case .failed(let kind, let message):
            status = DeviceTaskResultNotice.Status(rawValue: kind.rawValue) ?? .failed
            result = message
        }
        let notice = DeviceTaskResultNotice(
            deviceID: settlement.deviceID,
            deviceDisplayName: displayName,
            taskID: settlement.taskID,
            idempotencyKey: settlement.idempotencyKey,
            goal: settlement.goal,
            status: status,
            result: result,
            createdAt: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
        do {
            let item = try notice.wakeInboxItem()
            Task { [wakeInbox] in
                do { _ = try await wakeInbox.enqueue(item) }
                catch { print("[BotRuntimeComposition] device task result enqueue failed: \(error)") }
            }
        } catch {
            print("[BotRuntimeComposition] device task result notice invalid: \(error)")
        }
    }

    private func observeHost(_ host: PhoneDSHHost) {
        // `bind` is called from `hostTask` itself after `.restarted` /
        // `.webContentTerminated`; cancelling then would cancel the very task
        // that is recovering. Reuse the live observation of the same Host.
        if observedHost === host, hostTask != nil { return }
        hostTask?.cancel()
        observedHost = host
        hostTask = Task { [weak self, remote] in
            defer {
                if let self, self.observedHost === host {
                    self.observedHost = nil
                    self.hostTask = nil
                }
            }
            for await event in host.eventStream() {
                guard let self else { return }
                guard self.isAttached(host) else { return }
                switch event {
                case .webContentTerminated(let count):
                    _ = await remote.watchdogMonitor().observeMobile(
                        .webcontentTerminated, kind: .turn, id: "phone-host",
                        botId: await self.environment.botID,
                        evidence: ["count": .number(Double(count))])
                    await self.recoverAfterWorkerTermination(host)
                case .restarted:
                    await self.recoverAfterWorkerTermination(host)
                default:
                    break
                }
            }
        }
    }

    private func isAttached(_ host: PhoneDSHHost) -> Bool {
        self.host === host
    }

    private func recoverAfterWorkerTermination(_ host: PhoneDSHHost) async {
        guard self.host === host else { return }
        state = .recovering
        do {
            try await bind(to: host, recovering: true)
        } catch {
            state = .failed("Bot 连接恢复失败：\(error.localizedDescription)")
            scheduleRecoveryRetry(host)
        }
    }

    /// A transient transport failure must not strand the Bot page: retry while
    /// this Host is still the attached one, and let a later `.restarted` event
    /// (or the page's retry button) start a fresh attempt.
    private func scheduleRecoveryRetry(_ host: PhoneDSHHost) {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self.host === host else { return }
                do {
                    try await self.bind(to: host, recovering: true)
                    return
                } catch {
                    self.state = .failed("Bot 连接恢复失败：\(error.localizedDescription)")
                }
            }
        }
    }
}

#if canImport(PhoneDSHADB) && canImport(PhoneDSHLoopback)
/// Adapts any native JSON-RPC server to the Bot handler without adding a
/// PhoneDSHBot -> device module dependency. `DeviceMCPServer` handles the BLE
/// family itself and delegates every other call to `ADBMCPServer`.
struct BotNativeMCPForwarder: BotNativeMCPForwarding {
    let server: any NativeMCPServing

    func handle(_ request: PhoneDSHBot.BotJSONValue, headers: [String: String]) async -> PhoneDSHBot.BotJSONValue? {
        guard let body = try? request.encoded() else { return nil }
        let response = await server.handle(LoopbackRequest(
            method: "POST", path: "/mcp/native", headers: headers, body: body))
        guard response.status == 200 else { return nil }
        return try? PhoneDSHBot.BotJSONValue.parse(response.body)
    }
}
#endif

private struct UnstartedBotTransport: DSHRemoteTransport {
    func call(_ endpoint: String, args: PhoneDSHBot.BotJSONValue) async throws -> PhoneDSHBot.BotJSONValue {
        throw BotMCPError.unavailable("Host transport is not attached")
    }
    func openMux() async throws -> any DSHMuxConnection {
        throw BotMCPError.unavailable("Host transport is not attached")
    }
    func authenticationFailed() async {}
}
