// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the TonoLink voice turn (spec/device/v1/tonolink-board.md §4.1,
// spec/v1/cloud-voice.md): the board hears 你好小智 → the phone says 我在 → the board
// records → its Opus goes to the cloud ASR → the text is sent to the current chat →
// the reply is spoken. The board's microphone does all recording; the phone only plays.

import AVFoundation
import UIKit
import Foundation
import PhoneDSH
import PhoneDSHBLE
import ProbeKit

@MainActor final class TonoLinkVoiceHost {
    static let shared = TonoLinkVoiceHost()

    /// Shown by `GET /debug/voice`.
    private(set) var state = "off"
    private(set) var lastTurn: [String: Any] = [:]

    private var ctrl: TonoLinkCtrlBLE?
    private var supervisor: Task<Void, Never>?
    private var turn: Task<Void, Never>?
    private var turnID: UInt32 = UInt32.random(in: 1...1_000_000)
    private var audio: AsyncStream<Data>.Continuation?
    private var asr: CloudASRSession?
    private var tally = TonoLinkVoiceTally()
    private var seq: UInt16 = 40_000
    private var holdsKeepAlive = false
    private let player = VoicePCMPlayer()
    private let tts = CloudTTSClient()
    private var hereAudio: Data?
    /// Spoken the moment a command is recognised, before the (possibly long) chat turn.
    static let acknowledgement = "好的，马上处理"
    private var ackAudio: Data?
    private static let keepAliveOwner = "tonolink-voice"

    /// Keeps a ctrl link to the user's board and listens for its wake word.
    func start() {
        guard supervisor == nil else { return }
        supervisor = Task { [weak self] in await self?.supervise() }
    }

    /// One long-lived, restorable link to the user's board (callmate's recipe): iOS keeps a
    /// parked connect while the app is suspended and wakes it for the board's `ev wake`.
    private func supervise() async {
        let board = BLEDeviceTrustMemory().rememberedBoards().first
        let link = TonoLinkCtrlBLE(nameHint: "PhoneAgent", peripheralID: board, restoreIdentifier: Self.restoreIdentifier)
        link.onAudio = { [weak self] data in self?.receiveAudio(data) }
        link.onLine = { [weak self] line in self?.receive(line) }
        link.onReady = { [weak self] in self?.linkReady(link) }
        ctrl = link
        var beat = 0
        while !Task.isCancelled {
            if !link.isConnected {
                if let token = armedSpeaker { PhoneAudioSessionLease.releaseSpeakerOutput(token); armedSpeaker = nil }
                setKeepAlive(false)
                do { try await link.connect(timeout: .seconds(20)) }
                catch {
                    state = "没有连上板子：\(error.localizedDescription)"
                    log("connect failed: \(error.localizedDescription) parked=\(link.peripheralID != nil)")
                }
            }
            armSpeakerIfForeground()
            beat += 1
            if beat % 20 == 1 {
                log("alive app=\(UIApplication.shared.applicationState.rawValue) connected=\(link.isConnected) "
                    + "keepalive=\(SilentAudioKeepAlive.shared.isRendering) remaining=\(Int(min(UIApplication.shared.backgroundTimeRemaining, 99_999)))")
            }
            try? await Task.sleep(for: .seconds(link.isConnected ? 3 : 10))
        }
    }

    static let restoreIdentifier = "dev.phone-dsh.tonolink-voice"

    /// True while the board's link is up: a wake may arrive, so the chat host stays alive in the background.
    var isArmed: Bool { ctrl?.isConnected == true }

    /// Taken while the app is in the foreground and kept while armed: iOS refuses to switch a
    /// background app to the playAndRecord profile ('!int'), so a background turn must find it set.
    private var armedSpeaker: PhoneAudioSessionLease.SpeakerToken?

    private func linkReady(_ link: TonoLinkCtrlBLE) {
        state = "等待「你好小智」（\(link.peripheralName ?? "board")）"
        log("connected \(link.peripheralName ?? "?") app=\(UIApplication.shared.applicationState.rawValue)")
        setKeepAlive(true)
        armSpeakerIfForeground()
        // The board is back (this link only comes up when it is present): bring its Link tools back too.
        BLEDeviceStore.shared.reconnectRemembered()
        Task { await prefetchHere() }
    }

    func armSpeakerIfForeground() {
        guard armedSpeaker == nil, ctrl?.isConnected == true, UIApplication.shared.applicationState == .active else { return }
        do {
            armedSpeaker = try PhoneAudioSessionLease.acquireSpeakerOutput()
            log("speaker armed outputs=\(PhoneAudioSessionLease.outputPorts)")
        } catch {
            log("speaker arm failed: \(error.localizedDescription)")
        }
    }

    private func setKeepAlive(_ on: Bool) {
        guard on != holdsKeepAlive else { return }
        if on {
            do { try SilentAudioKeepAlive.shared.start(owner: Self.keepAliveOwner); holdsKeepAlive = true }
            catch { state += "（后台保活失败：\(error.localizedDescription)）" }
        } else {
            SilentAudioKeepAlive.shared.stop(owner: Self.keepAliveOwner)
            holdsKeepAlive = false
        }
    }

    // MARK: - Board events

    private func receive(_ line: TonoLinkCtrlLine) {
        guard case .other(let text) = line else { return }
        if text.hasPrefix("ev ") { log("line \(text) app=\(UIApplication.shared.applicationState.rawValue)") }
        guard let event = TonoLinkVoiceEvent.parse(text) else { return }
        switch event {
        case .wake(let n, _):
            beginTurn(wake: n, source: n == 0 ? "board (simulated)" : "board")
        case .listenEnd(let n, let frames, let reason):
            guard n == turnID else { return }
            lastTurn["listen_end"] = ["frames": Int(frames), "reason": reason.rawValue]
            endAudio()
        }
    }

    private func receiveAudio(_ data: Data) {
        guard audio != nil else { return }
        let packet = TonoLinkVoicePacket.parse(data, turnID: turnID)
        tally.record(packet)
        guard let packet else { return }
        if !packet.opus.isEmpty { audio?.yield(packet.opus) }
        if packet.last { endAudio() }
    }

    private func endAudio() {
        audio?.finish()
        audio = nil
    }

    // MARK: - The turn

    /// A wake stops whatever turn is recording, recognising or speaking and starts a new one (§4.1).
    func beginTurn(wake: UInt32, source: String) {
        turn?.cancel()
        player.stop()
        endAudio()
        if let asr { Task { await asr.cancel() } }
        asr = nil
        turnID = turnID &+ 1
        if turnID == 0 { turnID = 1 }
        tally = TonoLinkVoiceTally()
        let id = turnID
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(700))
        audio = continuation
        lastTurn = ["id": Int(id), "wake": Int(wake), "source": source, "at": ISO8601DateFormatter().string(from: Date())]
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "tonolink-voice-turn") { [weak self] in
                self?.log("background time expired")
                self?.endBackgroundTask()
            }
        }
        turn = Task { [weak self] in
            let speaker = self?.acquireSpeaker()
            await self?.runTurn(id: id, audio: stream)
            if let speaker { PhoneAudioSessionLease.releaseSpeakerOutput(speaker) }
            self?.turnEnded(id)
        }
    }

    private func note(_ key: String, _ value: Any) {
        lastTurn[key] = value
        log("turn \(turnID) \(key)=\(value)")
    }

    /// One line per event in `Documents/tonolink-voice.log` (DEBUG), readable over USB without Wi-Fi.
    func log(_ line: String) {
        #if DEBUG
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = folder.appendingPathComponent("tonolink-voice.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: file) }
        #endif
    }

    private func turnEnded(_ id: UInt32) {
        guard id == turnID else { return }
        turn = nil
        asr = nil
        endAudio()
        endBackgroundTask()
    }

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func runTurn(id: UInt32, audio: AsyncStream<Data>) async {
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        guard var credential = await credential() else {
            note("error", "语音需要登录 Tono 账号，或在「模型服务」里使用云端（pdsh.tonoai.cn）密钥")
            return
        }
        // Recognition connects while 我在 plays. The board records right after 我在 (people start
        // talking at once); its packets wait in this turn's stream (700 = 14 s, more than the board's
        // 12 s turn) and are forwarded only after `started`, so they never run ahead of real time.
        var session = CloudASRSession(credential: credential, turnID: id)
        asr = session
        await session.open()
        do { try await speakHere(credential: credential, timing: { self.note("here_fetch_ms", ms()) }) }
        catch { note("here_error", error.localizedDescription) }
        note("here_ms", ms())
        guard !Task.isCancelled else { await session.cancel(); return }
        guard let ctrl, ctrl.isConnected else { await session.cancel(); note("error", "板子已断开"); return }
        do {
            seq = seq &+ 1
            let ack = try await ctrl.command(TonoLinkVoiceCommand.listen(seq: seq, id: id), seq: seq, timeout: .seconds(3))
            guard ack.ok else { await session.cancel(); note("error", "板子拒绝录音：\(ack.error ?? "?")"); return }
        } catch {
            await session.cancel(); note("error", "listen 失败：\(error.localizedDescription)"); return
        }
        note("listen_ms", ms())
        if !(await session.ready()), await session.handshakeStatus == 401,
           let renewed = await renewedCredential(after: credential) {
            credential = renewed
            session = CloudASRSession(credential: credential, turnID: id)
            asr = session
            await session.open()
        }
        let up = await session.ready()
        note("asr_connect", ["connect_ms": await session.connectMs ?? -1, "started_ms": await session.startedMs ?? -1,
                             "handshake": await session.handshakeStatus ?? 0])
        guard up, !Task.isCancelled else {
            let why = await session.outcome()
            note("error", "语音识别没有连上（\(why)）")
            return
        }
        note("asr_ready_ms", ms())
        let forward = Task {
            for await opus in audio { await session.send(opus) }
            await session.finish()
        }
        let outcome = await withTaskCancellationHandler {
            await session.outcome()
        } onCancel: {
            Task { await session.cancel() }
        }
        forward.cancel()
        note("asr_ms", ms())
        note("packets", ["forwarded": await session.sentPackets, "received": tally.packets, "gaps": tally.gaps, "dropped": tally.dropped])
        guard !Task.isCancelled else { return }
        switch outcome {
        case .text(let text):
            note("heard", text)
            // Say at once that the command was understood; the reply follows when the turn ends
            // (same player, so it plays after this, never over it).
            await acknowledge(credential: credential)
            note("ack_ms", ms())
            await answer(text, credential: credential, start: start)
        case .silent:
            note("heard", "")
        case .failed(let why):
            note("error", "语音识别失败：\(why)")
        case .pending:
            break
        }
    }

    /// Sends the heard text to the current chat and speaks the turn's last assistant text (§4).
    private func answer(_ text: String, credential: String, start: Date) async {
        if let direction = TonoLinkVolumeIntent.direction(for: text) {
            await answerVolumeCommand(direction, credential: credential, start: start)
            return
        }
        let chat = ChatModel.shared
        guard await chat.send(text) else { note("error", "当前对话没有接受这条消息"); return }
        var waited = 0
        while !chat.turnRunning && waited < 300 {   // up to 30 s: the engine may be resuming
            try? await Task.sleep(for: .milliseconds(100)); waited += 1
            if Task.isCancelled { return }
        }
        guard chat.turnRunning else { note("error", "聊天没有开始运行（引擎暂停或忙）"); return }
        while chat.turnRunning {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let userIndex = chat.items.lastIndex(where: { $0.kind == .user && $0.text.contains(text) }),
              let reply = chat.items[(userIndex + 1)...].last(where: { $0.kind == .assistant && !$0.text.isEmpty }) else {
            note("reply", ""); return
        }
        note("reply", String(reply.text.prefix(500)))
        note("reply_ms", Int(Date().timeIntervalSince(start) * 1000))
        do { try await speak(reply.text, credential: credential) } catch { note("speak_error", error.localizedDescription) }
    }

    /// A clear one-step volume command is handled locally, without the LLM or UI-Venus screen loop.
    private func answerVolumeCommand(_ direction: TonoLinkVolumeDirection, credential: String, start: Date) async {
        let before = AVAudioSession.sharedInstance().outputVolume
        let hands = IPhoneAgentHost.shared.hands
        do {
            try await hands.adjustOutputVolume(direction)
        } catch {
            do { try await hands.disableHID() }
            catch { note("keyboard_restore_error", error.localizedDescription) }
            let reply = "没能调整手机音量：\(error.localizedDescription)"
            note("volume_error", error.localizedDescription)
            note("reply", reply)
            note("reply_ms", Int(Date().timeIntervalSince(start) * 1000))
            do { try await speak(reply, credential: credential) } catch { note("speak_error", error.localizedDescription) }
            return
        }
        do { try await hands.disableHID() }
        catch { note("keyboard_restore_error", error.localizedDescription) }

        // Read-only outputVolume is the only public iOS observation available to confirm the
        // hardware-style key. Never resend after a missing change: the key may already have landed.
        try? await Task.sleep(for: .milliseconds(250))
        let after = AVAudioSession.sharedInstance().outputVolume
        let changed = direction == .up ? after > before + 0.001 : after < before - 0.001
        let atLimit = direction == .up ? before >= 0.999 : before <= 0.001
        let reply = changed ? (direction == .up ? "手机媒体音量已调高。" : "手机媒体音量已调低。")
            : atLimit ? (direction == .up ? "手机媒体音量已经最大。" : "手机媒体音量已经最小。")
            : "音量键已发送，但系统音量没有可观察到的变化；我没有重复发送。"
        note("volume", ["direction": direction == .up ? "up" : "down", "before": before, "after": after,
                         "changed": changed, "at_limit": atLimit])
        note("reply", reply)
        note("reply_ms", Int(Date().timeIntervalSince(start) * 1000))
        do { try await speak(reply, credential: credential) } catch { note("speak_error", error.localizedDescription) }
    }

    // MARK: - Speech

    /// The phone's speech must come out of the phone: while the screen mirrors to the board,
    /// the output is AirPlay and the board drops AirPlay audio (xiaozhi-link USB_AIRPLAY_LESSONS).
    private func acquireSpeaker() -> PhoneAudioSessionLease.SpeakerToken? {
        let before = PhoneAudioSessionLease.outputPorts
        do {
            let token = try PhoneAudioSessionLease.acquireSpeakerOutput()
            note("output", ["before": before, "after": PhoneAudioSessionLease.outputPorts])
            return token
        } catch {
            note("output_error", "\(before) \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetches 我在 and the acknowledgement once, so neither waits for TTS during a turn.
    private func prefetchHere() async {
        guard let credential = await credential() else { return }
        if hereAudio == nil, let pcm = await synthesize("我在", credential: credential) { hereAudio = pcm }
        if ackAudio == nil, let pcm = await synthesize(Self.acknowledgement, credential: credential) { ackAudio = pcm }
    }

    private func synthesize(_ text: String, credential: String) async -> Data? {
        var pcm = Data()
        do { for try await chunk in tts.stream(text, credential: credential) { pcm.append(chunk) } } catch { return nil }
        return pcm.isEmpty ? nil : pcm
    }

    /// Queues 「好的，马上处理」 and returns without waiting for it to finish.
    private func acknowledge(credential: String) async {
        if ackAudio == nil { ackAudio = await synthesize(Self.acknowledgement, credential: credential) }
        guard let ackAudio else { return }
        do { try player.play(ackAudio) } catch { note("ack_error", error.localizedDescription) }
    }

    private func speakHere(credential: String, timing: () -> Void) async throws {
        if hereAudio == nil {
            var pcm = Data()
            for try await chunk in tts.stream("我在", credential: credential) { pcm.append(chunk) }
            hereAudio = pcm
        }
        timing()
        try player.play(hereAudio ?? Data())
        await player.waitUntilDrained()
    }

    /// Reads `text` aloud, chunk by chunk, playing each as it streams (cloud-voice.md §3).
    func speakAloud(_ text: String, credential: String) async throws {
        let speaker = acquireSpeaker()
        defer { if let speaker { PhoneAudioSessionLease.releaseSpeakerOutput(speaker) } }
        try await speak(text, credential: credential)
    }

    func speak(_ text: String, credential: String) async throws {
        for chunk in CloudVoiceSpeech.chunks(CloudVoiceSpeech.speakable(text)) {
            try Task.checkCancellation()
            var current = credential
            do {
                for try await pcm in tts.stream(chunk, credential: current) { try player.play(pcm) }
            } catch let error as CloudVoiceError where error.isCredentialExpired {
                guard let renewed = await renewedCredential(after: current) else { throw error }
                current = renewed
                for try await pcm in tts.stream(chunk, credential: current) { try player.play(pcm) }
            }
        }
        await player.waitUntilDrained()
    }

    func stopSpeaking() {
        turn?.cancel()
        player.stop()
    }

    // MARK: - Credential (cloud-voice.md §1)

    func credential() async -> String? {
        let account: CloudVoiceCredential.Account
        do { account = try await TonoAccountSession.shared.accessToken().map { .token($0) } ?? .signedOut }
        catch { account = .unavailable }
        let settings = PhoneModelProviderSettings()
        let profile = (try? settings.load())?.selected
        let key = profile.flatMap { (try? settings.apiKey(for: $0.id)) ?? nil }
        return CloudVoiceCredential.resolve(account: account, profileBaseURL: profile?.baseURL, profileKey: key)
    }

    /// tono-account §5: invalidate an expired token once; use the new value only if it differs.
    private func renewedCredential(after old: String) async -> String? {
        await TonoAccountSession.shared.invalidate(accessToken: old)
        guard let fresh = await credential(), fresh != old else { return nil }
        return fresh
    }

    #if DEBUG
    // MARK: - DEBUG relay hooks

    var debugSnapshot: [String: Any] {
        ["state": state, "connected": ctrl?.isConnected == true, "audio_subscribed": ctrl?.isAudioSubscribed == true,
         "keep_alive": holdsKeepAlive, "turn_active": turn != nil, "last_turn": lastTurn]
    }

    /// Runs the ASR → chat → speech part on Opus packets the developer supplies
    /// (`[len u16 LE][Opus]…`), exactly as if the board had sent them.
    func debugRecognize(_ body: Data, chat: Bool) async -> [String: Any] {
        guard let credential = await credential() else { return ["error": "no cloud credential"] }
        var packets: [Data] = []
        var bytes = [UInt8](body)[...]
        while bytes.count >= 2 {
            let length = Int(bytes[bytes.startIndex]) | Int(bytes[bytes.startIndex + 1]) << 8
            bytes = bytes.dropFirst(2)
            guard length > 0, bytes.count >= length else { break }
            packets.append(Data(bytes.prefix(length)))
            bytes = bytes.dropFirst(length)
        }
        turnID = turnID &+ 1
        let session = CloudASRSession(credential: credential, turnID: turnID)
        await session.open()
        guard await session.ready() else {
            let why = await session.outcome()
            return ["error": "asr not ready: \(why)", "packets": packets.count]
        }
        for packet in packets {
            await session.send(packet)
            try? await Task.sleep(for: .milliseconds(20))   // real time, as the board sends them
        }
        await session.finish()
        let outcome = await session.outcome()
        var result: [String: Any] = ["packets": packets.count, "outcome": "\(outcome)"]
        if chat, case .text(let text) = outcome {
            lastTurn = ["id": Int(turnID), "source": "debug opus", "heard": text]
            await answer(text, credential: credential, start: Date())
            result["turn"] = lastTurn
        }
        return result
    }

    /// Hosted device tests call the same local command path the voice turn uses, without ASR.
    func debugAnswer(_ text: String) async -> [String: Any] {
        guard let credential = await credential() else { return ["error": "no cloud credential", "heard": text] }
        lastTurn = ["source": "debug answer", "heard": text, "at": ISO8601DateFormatter().string(from: Date())]
        await answer(text, credential: credential, start: Date())
        return ["heard": text, "last_turn": lastTurn]
    }
    #endif
}

/// Plays 16 kHz mono s16le PCM through its own engine. It never sets the audio-session
/// category or activates it (spec/platform/ios-audio-session.md): the keep-alive owns that.
@MainActor final class VoicePCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var attached = false
    private var scheduled = 0
    private var generation = 0
    private var drained: [CheckedContinuation<Void, Never>] = []
    /// Audio scheduled since the last drain, so a wait cannot outlive it if the engine is stopped
    /// by a route or category change (completion handlers are then not guaranteed).
    private var pendingSeconds: Double = 0

    func play(_ pcm: Data) throws {
        let samples = pcm.count / 2
        guard samples > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples)
        let out = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Int16.self)
            for i in 0..<samples { out[i] = Float(Int16(littleEndian: input[i])) / 32768 }
        }
        if !attached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            attached = true
        }
        if !engine.isRunning { try engine.start() }
        scheduled += 1
        pendingSeconds += Double(samples) / 16_000
        let mine = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(generation: mine) }
        }
        if !node.isPlaying { node.play() }
    }

    func waitUntilDrained() async {
        if scheduled == 0 { return }
        let limit = pendingSeconds + 2
        let mine = generation
        let guardTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self, self.generation == mine else { return }
            self.scheduled = 0
            self.release()
        }
        await withCheckedContinuation { drained.append($0) }
        guardTask.cancel()
    }

    func stop() {
        generation += 1
        node.stop()
        scheduled = 0
        release()
    }

    private func finished(generation: Int) {
        guard generation == self.generation else { return }
        scheduled = max(0, scheduled - 1)
        if scheduled == 0 { release() }
    }

    private func release() {
        pendingSeconds = 0
        let waiters = drained; drained = []
        waiters.forEach { $0.resume() }
    }
}
