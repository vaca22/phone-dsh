# TonoLink 板子控制 iPhone：端內 UI-Venus agent（P07／P05，第一階段）

```yaml
change: PC-20261109-tonolink-phone-agent
contracts: [P03, P05, P07, P08, P09, P12]
status: implemented
breaking: false
version_decision: Additive. One new native MCP tool name (iphone_agent_run) listed after the BLE tools, one new SwiftPM library (PhoneDSHVenus), one registered existing device boundary (TonoLink board HTTP/APV1/GATT, consumer only). No existing tool, field, error code, header, UserDefaults key or persisted format changes.
base: 3781dbdc
contract_revision: spec/device/v1/tonolink-board.md + spec/v1/native-mcp.md#iphone-agent-tool-implemented-on-ios @ this PR head
```

Protocol impact: P03; P05; P07; P08; P09; P12. P03 — tool journal 在 MCP 呼叫期間登記其 idempotency key 供傳輸關聯（rev 2）。 P05 — 新增 additive native MCP 工具 `iphone_agent_run`。P07 — 登記既有 TonoLink 板子邊界（USB NCM HTTP、APV1 螢幕流、ctrl GATT），LED 走既有 BLE Link profile，不改 Link wire。P08 — keep-alive 在 AVAudioEngine 配置／路由變更時恢復渲染，並成為單一具名 owner 實例。P09 — 設定頁新增「視覺模型」入口與 DEBUG「板子固件（USB）」入口。P12 — `Package.swift` 新增 `PhoneDSHVenus` library，不動 FFI／C ABI。

## 1. 識別與角色

- **Trigger → 現況 → 期望.** 給老闆演示「手機自己控制自己」：TonoLink 板子插在 iPhone 上，Phone DSH 在手機上跑 UI-Venus，看板子回傳的鏡像畫面、用板子的藍牙 HID 點擊。現況：這套只存在於 longshu 本機分支 `codex/device-fixed-sessions`（107dd4c3，未推送、與 main 分叉約 2000 檔）。期望：以最小、受契約約束的方式進 main；LED 經通用設備協議（BLE Link `light.set`）控制。
- **Roles.** 單一 agent 兼任 coordinator／contract owner／implementer／reviewer，依 AGENTS.md §3 產出凍結與證據。
- **Owning contracts.** P07 [tonolink-board.md](../../spec/device/v1/tonolink-board.md)（新登記）與 [ble-link.md](../../spec/device/v1/ble-link.md)（不變）；P05 [native-mcp.md](../../spec/v1/native-mcp.md)；P08 [ios-audio-session.md](../../spec/platform/ios-audio-session.md)。
- **Ends.** Producer：倉外韌體 `tonolink-m21-r4-firmware@9ff0260`（不改）。Consumer：`Sources/PhoneDSHBLE/TonoLink*.swift`、`Sources/PhoneDSHVenus/**`、`examples/probe-app/PhoneDSHProbe/{IPhoneAgentHost,TonoLinkUSBOTAPage,VisionSettingsPage}.swift`。Worker 只經既有 native MCP 呼叫工具，無新 Worker 代碼。Android／Harmony／Rust 無 consumer，不變。

## 2. 契約 delta

| 項目 | Before → After |
| --- | --- |
| Native MCP tools | BLE tools 之後 → 追加 `iphone_agent_run {"task"}`；必須帶既有 `X-PDSH-Idempotency-Key`；結果 JSON 文字；`automatic_retry:false`；中斷為 `outcome_unknown`，絕不重放。`serverInfo` 不變。 |
| TonoLink 板子邊界 | 未登記 → 登記為 P07 consumer-only 邊界：`192.168.247.1:8767` 的 `/v1/{info,phone/status,hid/enable,hid/batch,usb}`、`:8769` APV1、ctrl GATT UUID。韌體不變。 |
| LED | 既有 `ble_link_call` → `light.set`／`light.get`，不變；本變更只做裝置驗證。 |
| HID over Link | 不存在 → 仍不存在。第二階段另立變更單凍結後才可實作；凍結前任何一端不得經 Link 發 HID。 |
| DEBUG relay | 不存在 → 僅 `#if DEBUG` 編譯的無認證 Wi-Fi relay `:8780`（轉發 `:8767`／`:8769`、`/agent/*` 除錯路由）。Release 不含。 |
| Keep-alive | 每個呼叫者各自 `SilentAudioKeepAlive()` → `SilentAudioKeepAlive.shared` 加具名 owner；AVAudioEngine 配置變更、路由變更、5 s watchdog 時恢復渲染，麥克風持有時不改 category。 |
| UI-Venus 設定 | 不存在 → 新 Keychain service `dev.phone-dsh.ui-venus`、UserDefaults `phone-dsh.ui-venus.configuration.v1`（只存 https baseURL 與模型名，不存 key）。 |

自檢：沒有第二種 envelope、別名或錯誤碼；新工具名 additive，舊 server 不列出；沒有收緊或放寬兩端都讀的訊息；沒有重用名稱或編號。移出分支上的 `VenusMCPServer`（Android 視覺）—— 它對 ADB server 送出 main 不檢查的 `X-PDSH-Expected-ADB-Target`，屬單端修改，違反 AGENTS.md §2.2。

## 3. 相容性與發佈

| Producer → Consumer | 支援方式 |
| --- | --- |
| old Worker → new host | Worker 只在 `tools/list` 看到多一個工具；未使用即無影響。 |
| new host → old Worker | 同上，工具清單是 additive。 |
| 任意韌體 → new app | 沒有板子時 `iphone_agent_run` 回 `看不到手机画面` 類錯誤，不觸碰手機；`DeviceMCPServer` 行為不變。 |
| persisted data → rollback | 新 Keychain／UserDefaults 鍵與 receipt 目錄 `Application Support/iphone-agent-tool-receipts` 對舊版不可見，回滾無影響。 |

## 4. 分工與證據

- 獨占路徑：上列 consumer 檔案、`spec/device/v1/tonolink-board.md`、`spec/v1/native-mcp.md` 新節、`spec/platform/ios-audio-session.md` 新段、`spec/README.md` 登記。
- Tests：`swift test --filter 'PhoneDSHVenusTests|PhoneDSHBLETests.TonoLink'`（真實 encoder／parser／MCP server）；app build；longshu iPhone 實機（見 PR）。
- 未驗證：Android／Harmony（無 consumer）；長時間背景與鎖屏；其他 iPhone 機型的 AssistiveTouch 位置（agent 用 UI-Venus 定位）。
- 剩餘風險：自動開啟螢幕鏡像依賴各機型控制中心佈局，longshu「iPhone」上需手動開一次；第二階段（HID 經 Link tools）未凍結。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | Claude | 初版 | iOS consumer（本 PR）；韌體不變 |
| 2 | Claude | 裝置驗證發現：Chat 經 Bot listener 呼叫 `ble_link_call`／原生工具一律缺 `X-PDSH-Idempotency-Key`（Worker 的 AsyncLocalStorage 在 MCP SDK 自身 await 後不可靠；`llm-bridge` 也在自己的 await 之後才讀）。改為 `tools/call` 依 tool journal 登記的（工具名、canonical 參數）精確關聯取 key，歧義則退回 await 前讀到的環境 context；另修 Bot 路徑未接上 `iphone_agent_run`（`PhoneNativeMCP.server` 單例）。key 語義與端點檢查不變。 | Worker（llm-bridge、tool-journal、exec-bridge call-context）；iOS app 接線 |
