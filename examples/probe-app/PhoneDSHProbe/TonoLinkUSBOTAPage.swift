// SPDX-License-Identifier: MIT
// Updates the TonoLink board's firmware through the iPhone's wired USB link
// (BLE `usb_net` → USB NCM → POST /ota → confirm after reboot), and sets the
// board's Wi-Fi the same way. No Wi-Fi and no computer are needed; the
// board's USB-C stays on the iPhone. The LAN token is only needed once, for
// boards whose firmware predates USB-session auth (venus-demo a0a95ef).
// DEBUG only: the relay below is an unauthenticated listener on the Wi-Fi network.
#if DEBUG
import SwiftUI
import UniformTypeIdentifiers
import PhoneDSH
import PhoneDSHBLE

@MainActor @Observable final class TonoLinkUSBOTAModel {
    static let shared = TonoLinkUSBOTAModel()
    private static let secrets = KeychainModelProviderSecretStore(service: "dev.phone-dsh.tonolink.lan")
    private static let nameKey = "tonolink.ota.nameHint", peripheralKey = "tonolink.ota.peripheral"

    var image: TonoLinkFirmwareImage?
    var imageName = ""
    var nameHint = UserDefaults.standard.string(forKey: nameKey) ?? "PhoneAgent" {
        didSet { UserDefaults.standard.set(nameHint, forKey: Self.nameKey) }
    }
    private(set) var hasLANToken = false
    private(set) var running = false
    private(set) var progress: Double?
    private(set) var log: [String] = []
    private(set) var boardState: TonoLinkOTAState?
    private(set) var wifi: TonoLinkWiFiState?
    private(set) var result = ""

    private(set) var relayState = "stopped"
    private(set) var relayLog: [String] = []
    private var relayServer: TonoLinkRelayServer?
    private var forwards: [TonoLinkPortForward] = []
    /// "8767→8767 listening", one line per board port.
    private(set) var forwardStates: [UInt16: String] = [:]
    private let keepAlive = SilentAudioKeepAlive.shared
    private(set) var keepAliveState = "off"
    /// 1 s heartbeat while the relay runs: a large gap means iOS suspended the app.
    private var heartbeat: Task<Void, Never>?
    private(set) var lastTick = Date()
    private(set) var maxTickGap: TimeInterval = 0
    private(set) var lastGapAt = ""
    /// Timestamped listener state changes, for diagnosing outages from the computer.
    private(set) var netEvents: [String] = []

    private func noteNet(_ text: String) {
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        netEvents.append("\(time) \(text)"); if netEvents.count > 30 { netEvents.removeFirst() }
    }

    init() { hasLANToken = lanToken != nil }

    var relayURL: String { "http://\(TonoLinkNetworkInfo.wifiIPv4() ?? "<iPhone Wi-Fi IP>"):8780" }
    var relayRunning: Bool { relayServer != nil }

    /// Board ports forwarded raw from the phone's Wi-Fi IP (HTTP, AirPlay viewer).
    /// A taken port falls back to 10000 + port.
    static let forwardedPorts: [UInt16] = [8767, 8769]

    var forwardSummary: String {
        Self.forwardedPorts.map { "\($0): \(forwardStates[$0] ?? "off")" }.joined(separator: " · ")
    }

    /// Serves the Mac relay (`TonoLinkRelay`) and the raw port forwards on
    /// Wi-Fi until stopped. A silent audio session (`UIBackgroundModes` audio)
    /// keeps the process scheduled in the background, so the phone can be used
    /// for other apps (e.g. Settings) while the computer keeps reaching the board.
    func startRelay() {
        guard relayServer == nil else { return }
        let name = nameHint
        let relay = TonoLinkRelay(
            http: TonoLinkURLSessionHTTP(),
            makeBLE: { TonoLinkBLEDebug(link: TonoLinkCtrlBLE(nameHint: name)) },
            makeUSB: { TonoLinkUSBOTA(ctrl: TonoLinkCtrlBLE(nameHint: name), network: TonoLinkUSBSocketNetwork(), http: TonoLinkURLSessionHTTP()) })
        relay.onLog = { [weak self] line in
            guard let self else { return }
            self.relayLog.append(line); if self.relayLog.count > 50 { self.relayLog.removeFirst() }
        }
        relay.extraRoutes = { request in await IPhoneAgentHost.shared.route(request) }
        relay.statusExtras = { [weak self] in
            guard let self else { return [:] }
            return ["max_tick_gap_s": (self.maxTickGap * 10).rounded() / 10, "last_gap_at": self.lastGapAt,
                    "net_events": Array(self.netEvents.suffix(12)),
                    "forward_stats": Dictionary(uniqueKeysWithValues: self.forwards.map { forward -> (String, [String: Int]) in
                        let stats = forward.stats()
                        return ("\(forward.listenPort)", ["active": stats.active, "accepted": stats.accepted, "up": stats.bytesUp,
                                                         "down": stats.bytesDown, "restarts": stats.restarts])
                    }),
                    "keep_alive": self.keepAliveState, "audio_rendering": self.keepAlive.isRendering,
                    "audio_restarts": self.keepAlive.restarts, "forwards": self.forwardSummary,
                    "app_state": ["active", "inactive", "background"][min(UIApplication.shared.applicationState.rawValue, 2)]]
        }
        keepAlive.onEvent = { [weak self] message in
            guard let self else { return }
            self.keepAliveState = message
            self.relayLog.append(message); if self.relayLog.count > 50 { self.relayLog.removeFirst() }
        }
        let server = TonoLinkRelayServer(relay: relay)
        server.onStateChange = { [weak self] state in self?.relayState = state; self?.noteNet("8780 \(state)") }
        do {
            try server.start()
            relayServer = server
            UIApplication.shared.isIdleTimerDisabled = true
        } catch { relayState = "failed: \(error.localizedDescription)"; return }
        for port in Self.forwardedPorts { startForward(board: port, listen: port) }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let now = Date(), gap = now.timeIntervalSince(self.lastTick)
                if gap > self.maxTickGap { self.maxTickGap = gap }
                if gap > 3 { self.lastGapAt = "\(ISO8601DateFormatter().string(from: now)) gap \(Int(gap))s" }
                self.lastTick = now
            }
        }
        do { try keepAlive.start(owner: "tonolink-relay") }
        catch { keepAliveState = "background audio failed: \(error)" }
    }

    private func startForward(board: UInt16, listen: UInt16) {
        let forward = TonoLinkPortForward(listenPort: listen, targetPort: board)
        forward.onState = { [weak self, weak forward] state in
            Task { @MainActor in
                guard let self, let forward, self.forwards.contains(where: { $0 === forward }) else { return }
                self.forwardStates[board] = "\(listen) \(state)"
                self.noteNet("\(listen) \(state)")
                // Port taken on this phone: fall back once to 10000 + port.
                if state.hasPrefix("failed"), listen == board {
                    self.forwards.removeAll { $0 === forward }
                    self.startForward(board: board, listen: board + 10_000)
                }
            }
        }
        do { try forward.start(); forwards.append(forward) }
        catch {
            forwardStates[board] = "\(listen) failed: \(error)"
            if listen == board { startForward(board: board, listen: board + 10_000) }
        }
    }

    func stopRelay() {
        relayServer?.stop(); relayServer = nil
        forwards.forEach { $0.stop() }; forwards = []; forwardStates = [:]
        heartbeat?.cancel(); heartbeat = nil
        keepAlive.stop(owner: "tonolink-relay"); keepAliveState = "off"
        if !running { UIApplication.shared.isIdleTimerDisabled = false }
    }

    var lanToken: String? {
        (try? Self.secrets.secret(for: "lan-token")) ?? nil
    }

    func saveLANToken(_ text: String) throws {
        guard let token = TonoLinkTokens.normalizedLANToken(text) else { throw TonoLinkUSBOTAError(NativeText("LAN 令牌应为 64 位十六进制", "The LAN token must be 64 hex characters")) }
        try Self.secrets.setSecret(token, for: "lan-token")
        hasLANToken = true
    }

    func forgetLANToken() { try? Self.secrets.deleteSecret(for: "lan-token"); hasLANToken = false }

    func load(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        image = try TonoLinkFirmwareImage(data: Data(contentsOf: url))
        imageName = url.lastPathComponent
    }

    enum Action { case update, confirm, state, wifi, setWiFi(TonoLinkWiFiCredentials) }

    @discardableResult
    func perform(_ action: Action) async -> Bool {
        guard !running else { return false }
        running = true; progress = nil; log = []; result = ""
        UIApplication.shared.isIdleTimerDisabled = true
        defer { running = false; UIApplication.shared.isIdleTimerDisabled = false }
        let ctrl = TonoLinkCtrlBLE(nameHint: nameHint, peripheralID: UserDefaults.standard.string(forKey: Self.peripheralKey).flatMap(UUID.init))
        let flow = TonoLinkUSBOTA(ctrl: ctrl, network: TonoLinkUSBSocketNetwork(), http: TonoLinkURLSessionHTTP())
        flow.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .step(let text): self.log.append(text)
            case .uploadProgress(let value): self.progress = value
            case .state(let state): self.boardState = state
            case .wifi(let state): self.wifi = state
            }
        }
        do {
            switch action {
            case .state:
                _ = try await flow.readStateOverUSB()
                result = NativeText("已读取板子状态", "Board state read")
            case .confirm:
                let state = try await flow.confirmRunning(lanToken: lanToken)
                result = NativeText("已确认 \(state.version)", "Confirmed \(state.version)")
            case .update:
                guard let image else { throw TonoLinkUSBOTAError(NativeText("请先选择固件文件", "Choose a firmware file first")) }
                switch try await flow.run(image: image, lanToken: lanToken) {
                case .confirmed(let state): result = NativeText("更新完成：\(state.version) 已确认（\(state.slot)）", "Updated: \(state.version) confirmed (\(state.slot))")
                case .alreadyRunning(let state): result = NativeText("板子已在运行此固件（\(state.version)）", "The board already runs this image (\(state.version))")
                }
            case .wifi:
                let state = try await flow.readWiFi()
                result = NativeText("Wi-Fi：\(state.ssid)", "Wi-Fi: \(state.ssid)")
            case .setWiFi(let credentials):
                let state = try await flow.setWiFi(credentials, lanToken: lanToken)
                result = NativeText("已保存 Wi-Fi \(state.ssid)，板子正在重连", "Saved Wi-Fi \(state.ssid); the board is reconnecting")
            }
            if let id = ctrl.peripheralID { UserDefaults.standard.set(id.uuidString, forKey: Self.peripheralKey) }
            return true
        } catch {
            result = NativeText("失败：", "Failed: ") + error.localizedDescription
            return false
        }
    }
}

struct TonoLinkUSBOTAPage: View {
    @State private var model = TonoLinkUSBOTAModel.shared
    @State private var importing = false
    @State private var tokenDraft = ""
    @State private var message = ""
    @State private var wifiName = ""
    @State private var wifiPassword = ""

    var body: some View {
        List {
            Section {
                Text(NativeText("板子的 USB-C 接在这台 iPhone 上即可：经蓝牙打开 USB 网络，通过 USB 上传固件，板子重启后在 120 秒内自动确认，否则板子会回滚到旧固件。更新期间请保持本页在前台。",
                                "Keep the board's USB-C on this iPhone. Bluetooth enables the USB network, the image is uploaded over USB, and after the reboot it is confirmed within 120 s or the board rolls back. Keep this page in the foreground."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(NativeText("固件", "Firmware")) {
                Button(NativeText("选择 agent_s3.bin", "Choose agent_s3.bin")) { importing = true }
                if let image = model.image {
                    LabeledContent(NativeText("文件", "File"), value: "\(model.imageName) · \(image.data.count) B")
                    LabeledContent(NativeText("版本", "Version"), value: "\(image.projectName) \(image.version)")
                    LabeledContent(NativeText("构建时间", "Built"), value: image.buildDate)
                    LabeledContent("ELF SHA-256", value: String(image.elfSHA256.prefix(16)) + "…")
                    LabeledContent("CRC32", value: TonoLinkCRC32.header(image.crc32))
                }
            }
            Section(NativeText("板子", "Board")) {
                TextField(NativeText("蓝牙名称", "Bluetooth name"), text: $model.nameHint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if model.hasLANToken {
                    LabeledContent(NativeText("LAN 令牌", "LAN token"), value: NativeText("已保存在钥匙串", "Saved in Keychain"))
                    Button(NativeText("删除 LAN 令牌", "Forget LAN token"), role: .destructive) { model.forgetLANToken() }
                } else {
                    Text(NativeText("新固件只凭 USB 会话即可更新；旧固件第一次更新需要 LAN 令牌。", "Current firmware needs only the USB session; older firmware needs the LAN token once."))
                        .font(.footnote).foregroundStyle(.secondary)
                    SecureField(NativeText("粘贴 LAN 令牌（可选，64 位十六进制）", "Paste LAN token (optional, 64 hex)"), text: $tokenDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(NativeText("保存 LAN 令牌", "Save LAN token")) {
                        do { try model.saveLANToken(tokenDraft); tokenDraft = ""; message = "" }
                        catch { message = error.localizedDescription }
                    }.disabled(tokenDraft.isEmpty)
                }
            }
            Section {
                Button(NativeText("经 USB 更新固件", "Update firmware over USB")) { Task { await model.perform(.update) } }
                    .disabled(model.running || model.image == nil)
                Button(NativeText("读取板子状态", "Read board state")) { Task { await model.perform(.state) } }
                    .disabled(model.running)
                Button(NativeText("确认当前运行的固件", "Confirm the running image")) { Task { await model.perform(.confirm) } }
                    .disabled(model.running)
                if model.running {
                    if let progress = model.progress { ProgressView(value: progress) { Text(NativeText("上传中", "Uploading")) } }
                    else { ProgressView() }
                }
                if !model.result.isEmpty { Text(model.result).textSelection(.enabled) }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            Section(NativeText("Mac 中继", "Mac relay")) {
                Toggle(NativeText("开启中继", "Serve relay"), isOn: Binding(
                    get: { model.relayRunning }, set: { $0 ? model.startRelay() : model.stopRelay() }))
                if model.relayRunning {
                    LabeledContent("URL", value: model.relayURL).textSelection(.enabled)
                    Text(model.relayState).font(.caption)
                    LabeledContent(NativeText("端口转发", "Port forwards"), value: model.forwardSummary).font(.caption)
                    Text(model.keepAliveState).font(.caption)
                    ForEach(Array(model.relayLog.suffix(8).enumerated()), id: \.offset) { Text($0.element).font(.caption2) }
                }
                Text(NativeText("同一 Wi-Fi 的电脑可经本机访问板子：/board/…（USB HTTP）、/ble/con、/ble/log、/ble/ota、/usb/ota；本机 8767、8769 端口原样转发到板子，板子的工具把地址换成本机即可。中继不设口令，开启期间同一 Wi-Fi 的任何设备都能访问并刷写板子；用完请关闭。中继开启时会保持一个静音音频会话，App 切到后台也继续服务。",
                                "A computer on the same Wi-Fi reaches the board through this phone: /board/… (USB HTTP), /ble/con, /ble/log, /ble/ota, /usb/ota. Raw TCP ports 8767 and 8769 on this phone forward to the board, so its tools work with host = this phone. There is no password: while it is on, any device on this Wi-Fi can reach and flash the board. Turn it off when done. While on, a silent audio session keeps it serving with the app in the background."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Wi-Fi") {
                if let wifi = model.wifi {
                    LabeledContent(NativeText("网络", "Network"), value: wifi.ssid)
                    LabeledContent(NativeText("状态", "Status"), value: wifi.connected ? "\(wifi.ip) · RSSI \(wifi.rssi)" : NativeText("未连接", "Not connected"))
                }
                Button(NativeText("读取板子 Wi-Fi", "Read board Wi-Fi")) { Task { await model.perform(.wifi) } }
                    .disabled(model.running)
                TextField(NativeText("Wi-Fi 名称", "Wi-Fi name"), text: $wifiName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(NativeText("Wi-Fi 密码", "Wi-Fi password"), text: $wifiPassword)
                Button(NativeText("保存到板子并重连", "Save to board and reconnect")) {
                    do {
                        let credentials = try TonoLinkWiFiCredentials(ssid: wifiName, password: wifiPassword)
                        wifiPassword = ""; message = ""
                        Task { await model.perform(.setWiFi(credentials)) }
                    } catch { message = error.localizedDescription }
                }.disabled(model.running || wifiName.isEmpty)
            }
            if let state = model.boardState {
                Section(NativeText("板子 /ota/state", "Board /ota/state")) {
                    LabeledContent(NativeText("版本", "Version"), value: state.version)
                    LabeledContent(NativeText("分区", "Slot"), value: state.slot)
                    LabeledContent(NativeText("状态", "State"), value: state.needsUSBConfirmation ? "\(state.state) · needs USB confirm" : state.state)
                    LabeledContent("ELF SHA-256", value: String(state.elfSHA256.prefix(16)) + "…")
                    LabeledContent(NativeText("启动 ID", "Boot"), value: state.boot)
                }
            }
            if !model.log.isEmpty {
                Section(NativeText("过程", "Steps")) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
                }
            }
        }
        .navigationTitle(NativeText("板子固件（USB）", "Board firmware (USB)"))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { picked in
            do { try model.load(try picked.get()); message = "" } catch { message = error.localizedDescription }
        }
    }
}

#if DEBUG
/// Headless entry for device verification: `PDSH_TONOLINK_USB_OTA=update|state|confirm|wifi|wifi-set`.
/// Inputs are copied into Documents/tonolink-ota/ (`agent_s3.bin`, optional `lan-token`,
/// `wifi.json` {"ssid","password"} for wifi-set); the token is moved into the Keychain
/// and token/Wi-Fi files are deleted after reading. The report goes to
/// Documents/tonolink-usb-ota.json.
@MainActor enum TonoLinkUSBOTADiagnostics {
    static func run(_ mode: String) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inputs = documents.appendingPathComponent("tonolink-ota", isDirectory: true)
        let output = documents.appendingPathComponent("tonolink-usb-ota.json")
        let model = TonoLinkUSBOTAModel.shared
        var report: [String: Any] = ["run_id": ProcessInfo.processInfo.environment["PDSH_HEADLESS_RUN_ID"] ?? "", "mode": mode, "status": "running"]
        func save() { if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output, options: .atomic) } }
        save()
        let tokenFile = inputs.appendingPathComponent("lan-token")
        let tokenText = try? String(contentsOf: tokenFile, encoding: .utf8)
        try? FileManager.default.removeItem(at: tokenFile)
        // An empty file means "no LAN token": current firmware needs only the USB session.
        if let text = tokenText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { try model.saveLANToken(text) } catch { report["status"] = "failed"; report["error"] = error.localizedDescription; save(); return }
        }
        if let name = ProcessInfo.processInfo.environment["PDSH_TONOLINK_NAME"] { model.nameHint = name }
        if mode == "update" {
            do { try model.load(inputs.appendingPathComponent("agent_s3.bin")) }
            catch { report["status"] = "failed"; report["error"] = error.localizedDescription; save(); return }
            report["image"] = ["version": model.image?.version ?? "", "elf_sha256": model.image?.elfSHA256 ?? "", "bytes": model.image?.data.count ?? 0]
        }
        if mode == "relay" {
            // Serves until the app is terminated.
            model.startRelay()
            try? await Task.sleep(for: .seconds(1))
            report["url"] = model.relayURL
            report["relay"] = model.relayState
            report["forwards"] = model.forwardSummary
            report["keep_alive"] = model.keepAliveState
            report["status"] = model.relayRunning ? "serving" : "failed"
            save(); return
        }
        if mode == "ble-con" || mode == "ble-log" {
            // Read-only over BLE: PDSH_TONOLINK_CON="info" / PDSH_TONOLINK_LOG_SINCE=0.
            let env = ProcessInfo.processInfo.environment
            let debug = TonoLinkBLEDebug(link: TonoLinkCtrlBLE(nameHint: model.nameHint))
            defer { debug.disconnect() }
            do {
                if mode == "ble-con" {
                    report["output"] = try await debug.console(env["PDSH_TONOLINK_CON"] ?? "info")
                } else {
                    let page = try await debug.log(since: UInt32(env["PDSH_TONOLINK_LOG_SINCE"] ?? "0") ?? 0)
                    report["log"] = page.lines.map { "\($0.index) \($0.text)" }
                    report["last"] = page.last
                }
                report["status"] = "passed"
            } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
            save(); return
        }
        if mode == "get" {
            // Read-only direct HTTP GETs over USB NCM; no BLE command or USB session is needed.
            let paths = (ProcessInfo.processInfo.environment["PDSH_TONOLINK_GET_PATHS"] ?? "/ota/state").split(separator: ",").map(String.init)
            let http = TonoLinkURLSessionHTTP()
            do {
                var results: [[String: Any]] = []
                for path in paths {
                    var request = URLRequest(url: TonoLinkUSB.baseURL.appendingPathComponent(path), timeoutInterval: 5)
                    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                    let (status, body) = try await http.send(request, body: nil, progress: nil)
                    results.append(["path": path, "status": status, "body": String(decoding: body, as: UTF8.self)])
                }
                report["responses"] = results
                report["status"] = "passed"
            } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
            save(); return
        }
        var action: TonoLinkUSBOTAModel.Action = mode == "update" ? .update : mode == "confirm" ? .confirm : mode == "wifi" ? .wifi : .state
        if mode == "wifi-set" {
            let file = inputs.appendingPathComponent("wifi.json")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let fields = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
                action = .setWiFi(try TonoLinkWiFiCredentials(ssid: fields["ssid"] ?? "", password: fields["password"] ?? ""))
            } catch { report["status"] = "failed"; report["error"] = error.localizedDescription; save(); return }
        }
        let started = ContinuousClock.now
        let ok = await model.perform(action)
        report["elapsed"] = String(describing: ContinuousClock.now - started)
        report["steps"] = model.log
        report["result"] = model.result
        if let state = model.boardState {
            report["board"] = ["version": state.version, "slot": state.slot, "boot": state.boot, "elf_sha256": state.elfSHA256,
                               "state": state.state, "transport": state.transport, "needs_usb_confirmation": state.needsUSBConfirmation]
        }
        if let wifi = model.wifi {
            report["wifi"] = ["ssid": wifi.ssid, "connected": wifi.connected, "ip": wifi.ip, "rssi": wifi.rssi]
        }
        report["status"] = ok ? "passed" : "failed"
        save()
    }
}
#endif
#endif
