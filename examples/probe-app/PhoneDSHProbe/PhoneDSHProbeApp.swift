// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Phase 0 probe app (PLAN W3-APP).
//
// Entry point. The app has five pages: Probes (the W3-PROBES suite on the
// device UI actor), Memory (real PhoneDSHHost boots with 20/50/100 MB
// synthetic overlays and a scripted session), Background (the background/lock
// matrix), Screen (the black low-brightness task screen) and Export (the
// aggregated JSON report).
//
// Every device-only number starts empty: nothing here claims iPhone behaviour
// until a run on a device records it.

import ProbeKit
import SwiftUI
import PhoneDSH
import PhoneDSHBLE
#if DEBUG
import PhoneDSHVenus
#endif

@main
struct PhoneDSHProbeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @State private var workspaceModels = WorkspaceModels.shared
    @State private var preferences = NativeChatPreferences.shared

    init() {
        // P18/D2: copy legacy bare-sessionID stores into the phone scope once.
        // The old keys stay readable so a rollback still finds the pre-D2 data.
        WorkspaceStorageMigration.runIfNeeded()
        // The board's wake word 你好小智 starts a voice turn (tonolink-board.md §4.1). Started here,
        // not in a scene task, so a background relaunch by Bluetooth state restoration listens too.
        #if DEBUG
        // USB OTA diagnostics need exclusive ownership of the board's BLE ctrl connection.
        // The normal voice listener is restarted on the next ordinary app launch.
        if ProcessInfo.processInfo.environment["PDSH_TONOLINK_USB_OTA"] == nil {
            Task { @MainActor in TonoLinkVoiceHost.shared.start() }
        }
        #else
        Task { @MainActor in TonoLinkVoiceHost.shared.start() }
        #endif
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["PDSH_APPEARANCE"],
           let value = NativeAppearance(rawValue: raw) {
            NativeChatPreferences.shared.setAppearance(value)
        }
        Self.seedProviderFromEnvironment()
        Self.seedVisionFromFile()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // The native shell is a light design (hard-coded ink and
                // surface colors); without this the system's dark appearance
                // turns the page background black under a light layout.
                .preferredColorScheme(preferences.appearance.colorScheme)
                .environment(model)
                .environment(\.workspaceModels, workspaceModels)
                // Single scene-phase observer. Chat keep-alive / park / resume
                // and the background-matrix runner each receive the phase once.
                // RootView and ChatPage do not observe scene phase.
                // `deliver` serializes and supersedes its own deliveries; the
                // Task here only leaves SwiftUI's synchronous callback.
                .onChange(of: scenePhase) { _, newPhase in
                    Task { @MainActor in
                        #if PDSH_ENABLE_DEVICE_TASKS
                        await DeviceTaskManager.shared.sceneActive(newPhase == .active)
                        #endif
                        await ProbeScenePhaseForwarding.deliver(
                            newPhase,
                            chat: { phase in
                                await ChatModel.shared.scenePhaseChanged(phase)
                                // The PC backend is a separate ChatModel; the
                                // foreground must also wake PCLinkClient and
                                // refill the follow stream.
                                if phase == .active {
                                    await workspaceModels.scenePhaseChanged(true)
                                }
                            },
                            backgroundMatrix: { phase in
                                await model.scenePhaseChanged(phase)
                            })
                    }
                }
                .task {
                    #if PDSH_ENABLE_DEVICE_TASKS
                    await DeviceTaskManager.shared.sceneActive(scenePhase == .active)
                    // Opt-in test builds may negotiate experimental task discovery.
                    // BLE task grants remain unavailable while GAP-16 is open.
                    BLEDeviceStore.shared.setDeviceTaskDiscoveryEnabled(true)
                    #endif
                    model.refreshLockdown()
                    // The user's own boards: connected once means trusted, and they reconnect by themselves.
                    #if DEBUG
                    let runningBoardDiagnostic = ProcessInfo.processInfo.environment["PDSH_TONOLINK_USB_OTA"] != nil
                    #else
                    let runningBoardDiagnostic = false
                    #endif
                    if !runningBoardDiagnostic {
                        BLEDeviceStore.shared.trustConnectedDevices = true
                        BLEDeviceStore.shared.reconnectRemembered()
                    }
                    await workspaceModels.startAtLaunch()
                    #if DEBUG
                    PCLinkDebugAutomation.shared.start(models: workspaceModels)
                    #endif
                    // Boot the phone engine only for the phone segment; the
                    // PC workspace starts its relay connection instead and the
                    // phone starts lazily when the user switches back.
                    if workspaceModels.isPhoneSelected {
                        await ChatModel.shared.start()
                    }
                }
                #if DEBUG
                .task {
                    guard ProcessInfo.processInfo.environment["PDSH_TONOLINK_USB_OTA"] == nil else { return }
                    await Self.bleAutoconnect()
                }
                .task {
                    if let mode = ProcessInfo.processInfo.environment["PDSH_TONOLINK_USB_OTA"] { await TonoLinkUSBOTADiagnostics.run(mode) }
                }
                #endif
        }
    }
}

#if DEBUG
extension PhoneDSHProbeApp {
    /// 调试用:从环境变量一次性写入模型服务与密钥,避免把密钥敲进界面。
    /// 只在值变化时写,正常启动什么都不做。
    static func seedProviderFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["PDSH_SEED_PROVIDER_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return }
        let base = env["PDSH_SEED_PROVIDER_BASE"] ?? "https://api.deepseek.com/anthropic"
        let model = env["PDSH_SEED_PROVIDER_MODEL"] ?? "deepseek-chat"
        let name = env["PDSH_SEED_PROVIDER_NAME"] ?? "DeepSeek"
        let store = PhoneModelProviderSettings.shared
        let profile = ProviderProfile(id: "deepseek", displayName: name, baseURL: base, model: model)
        do {
            try store.upsert(profile, apiKey: key)
            try store.select(id: profile.id)
            let status = try store.apiKeyStatus(for: profile.id)
            ChatModel.appendDiagnostic(
                "provider seed: \(profile.id), model=\(profile.model), key=\(String(describing: status))")
        } catch {
            ChatModel.appendDiagnostic("provider seed failed: \(error)")
        }
    }
}

extension PhoneDSHProbeApp {
    /// Seeds UI-Venus settings from Library/Caches/vision-bootstrap.json (`PDSH_VISION_IMPORT=1`) so a
    /// key never has to be typed into the UI on a test phone. The file is deleted after reading.
    static func seedVisionFromFile() {
        guard ProcessInfo.processInfo.environment["PDSH_VISION_IMPORT"] == "1" else { return }
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("vision-bootstrap.json")
        defer { try? FileManager.default.removeItem(at: file) }
        struct Import: Decodable { let baseURL: String; let model: String; let key: String }
        do {
            let value = try JSONDecoder().decode(Import.self, from: Data(contentsOf: file))
            try VenusSettings.shared.save(VenusConfiguration(baseURL: value.baseURL, model: value.model), key: value.key)
        } catch { /* Never log credential material. Settings supports correction. */ }
    }

    /// `PDSH_BLE_AUTOCONNECT=<name substring>` scans in-app and connects the first match through the
    /// ordinary BLE device store (Link tools such as light.set, and the board's HID bond).
    @MainActor static func bleAutoconnect() async {
        guard let want = ProcessInfo.processInfo.environment["PDSH_BLE_AUTOCONNECT"], !want.isEmpty else { return }
        let store = BLEDeviceStore.shared
        for _ in 0..<6 {
            store.scan()
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(500))
                if let device = store.devices.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) {
                    if device.state == "未连接" { store.connect(device.id) }
                    return
                }
            }
        }
    }
}
#endif
