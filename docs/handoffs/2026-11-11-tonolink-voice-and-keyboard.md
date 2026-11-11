# TonoLink 语音调音量、OTA 与软键盘问题交接

日期：2026-11-11

关联仓库：`phone-dsh`、`tonolink-m21-r4-firmware`
计划分支：`codex/tonolink-volume-voice-keyboard-handoff`

## 交接摘要

- “调大音量 / 调小音量”有独立的本地语音命令路径：使用 TonoLink Consumer Control 音量键，不经过聊天模型、屏幕识别或 UI 操作；每次只发送一步，并以 iOS 公开的只读 `outputVolume` 观察结果，不确定时不重发。
- 固件加入音量 Consumer Control HID 报告与批处理步骤，并把 GATT 布局版本从 4 升到 5，避免 iPhone 继续使用旧特征句柄。OTA 已完成，板端报告 `ota_0`、`needs_usb_confirmation=false`、`hid.consumer_control=true`。`4e81bc6f2db5cb67e40ae7992819b2c22f012c8021d3247c7ab237c597c91ee6` 是 **ELF（app_elf_sha256）**，也就是板端 `/ota/state` 报的值，不是上传的 `.bin` 文件哈希（`tonolink-m21-r4-firmware/build/agent_s3.bin` 是 `7ff5ed7f…836f9f`）；`0.1.0-m21` 是编译期常量，不能用来识别构建，镜像内嵌的 app 描述为 `59fe866-dirty`。
- 语音任务回复策略已要求只用一句话说明结果或阻碍，不再向用户输出步骤数、耗时、`finished`、模型自评和 UI 导航过程。
- iOS 每次手机 UI 或音量控制结束后，都会尽力调用既有 HID 关闭接口，让外接键盘脱离；下一次 UI 任务仍通过既有 `ensureHID` 路径重新启用。这个改动针对“第二轮之后系统软键盘打不开”，真机点击验证结果见下文“真机核验”。
- 真机核验已完成音量链路：Consumer Control 音量键确实把 iPhone 媒体音量 0.55→0.50→0.55 改变，板子两次都以 200 接受单步批次。核验还复现并修复了一个 hide→show 竞态：紧随 `disableHID()` 的 show 会被 iOS 合并，板子此后 15 s 内报 `input_mode=true` 但所有订阅为 false；`ensureHID`/`ensureVolumeHID` 现在会强制一次可见性循环自愈。

## 问题与设备证据

### 唤醒、OTA 和回复

当前设备日志记录了 OTA 后的两次唤醒与任务：

| 日志时间 | 观察到的内容 |
| --- | --- |
| 2026-11-11 09:51:46 | wake 事件；随后识别到电量查询任务 |
| 2026-11-11 09:52:32 | 回复含步骤、耗时及“模型自评”内容 |
| 2026-11-11 09:52:44 | 第二次 wake 事件；识别到“打开小红书。” |
| 2026-11-11 09:53:37 | 回复“小红书已打开…”并包含过程统计与模型自评 |

因此，日志证明 OTA 后这些时点仍发生了唤醒；它不代表当前持续唤醒状态已经做过验证。简短回复约束已写入 P05 工具说明和共享 fixture，MCP 输入输出结构没有变。

### 第二轮对话后软键盘

设备截图显示输入框里保留草稿 `xiaohongshu`，截图时系统软键盘没有显示。PhoneAgent LAN MCP 的 Bonjour 查询没有发现 `_phoneagent._tcp` 服务，因此无法通过该工具在新版本上完整执行“语音任务完成 → 点击输入框 → 检查键盘”复现。截图能证明当时键盘不在屏幕上，但不能证明一次点击没有打开键盘。

实现已经在 UI 任务成功/失败和本地音量命令结束时 best-effort 调用 `POST /v1/hid/enable`，body 为 `{"on":false}`。调用失败只写诊断，不覆盖任务结果。设备在新包安装后的截图仍显示旧聊天和草稿；由于没有运行新的任务后点击输入框，该截图不算键盘修复的运行时验证。

## 合同与实现

**Protocol impact: P05; P07.** P09: none — 不改变页面结构或投影状态。P08: none — 音量读回只使用 iOS 公开只读属性，不经 AVAudioSession 写入系统音量。

| 边界 | 合同/记录 | 本次改动 |
| --- | --- | --- |
| P07 音量 HID | `spec/device/v1/tonolink-board.md`、`spec/device/v1/schema/tonolink-hid-consumer-step.schema.json`、`spec/device/v1/golden/tonolink-hid-consumer-control.json`；`PC-20261111-xiaozhi-volume-hid.md` | 闭合的 `volume_up` / `volume_down` 消费者控制步骤；Report ID 4；GATT revision 5 与 Service Changed 缓存失效。旧固件拒绝该新步骤，iOS 不回退到盲点屏幕操作。 |
| P05 简短任务回复 | `spec/v1/native-mcp.md`、`spec/v1/golden/native-mcp/iphone-agent-volume-policy.json`；`PC-20261111-phone-task-completion.md` | 只增加调用方的呈现指导；MCP 方法、schema、结果、错误、回执及版本不变。 |
| P07 HID 生命周期 | 同上 TonoLink board contract 与 golden | 复用现有 `POST /v1/hid/enable`；任务完成后关闭外接键盘/HID，下一次 UI 任务重新启用；没有新增 endpoint 或字段。 |
| P05 音量任务说明 | `PC-20261111-phone-volume-control.md` | 保留原 UI agent 工具与 schema，音量短命令走本地 HID。 |

兼容和重试语义：固件接受批处理只代表排队成功，不代表 iOS 音量改变；已接受但读回不确定时不重放。任务回执格式、MCP payload、HID 现有接口和旧数据都不变。HID 隐藏失败不会把已得到的任务结果改成失败。

## 变更文件概览

`phone-dsh`：

- Swift BLE 层和测试：`Sources/PhoneDSHBLE/TonoLinkPhoneHands.swift`（新增 hide→show 竞态的一次可见性循环恢复）、`Tests/PhoneDSHBLETests/TonoLinkVolumeCommandTests.swift`（新增旧固件守卫、请求序列、循环恢复三组用例）。
- MCP 和 iOS probe app：`Sources/PhoneDSHVenus/IPhoneAgentMCPServer.swift`、`Tests/PhoneDSHVenusTests/IPhoneAgentMCPTests.swift`、`examples/probe-app/PhoneDSHProbe/IPhoneAgentHost.swift`、`PhoneDSHProbeApp.swift`、`TonoLinkUSBOTAPage.swift`、`TonoLinkVoiceHost.swift`（DEBUG-only `debugAnswer` 测试入口）。
- 真机测试：`examples/probe-app/PhoneDSHDeviceTests/TonoLinkVolumeDeviceTests.swift`（新增）、`examples/probe-app/PhoneDSHDeviceTests/TonoLinkKeyboardDeviceTests.swift`（新增）、`examples/probe-app/PhoneDSHDeviceUITests/TonoLinkKeyboardRecoveryUITests.swift`（新增，XCUITest，本轮 NOT_RUN）；`examples/probe-app/project.yml` 补上 `PhoneDSHDeviceTests` 缺失的 `PhoneDSHPCLink` 依赖。
- 规范与门禁：P05/P07 owning contract、schema、golden、registry/checker，三个协议变更记录；P07 TonoLink board 状态由 `partial` 升为 `implemented`（`spec/device/v1/tonolink-board.md`、`spec/README.md`、`spec/registry.json`）。
- 本交接：`docs/handoffs/2026-11-11-tonolink-voice-and-keyboard.md`。

`tonolink-m21-r4-firmware`：

- HID Consumer Control descriptor、编码、批处理解析/执行、状态和 GATT revision 更新。
- 增加共享 golden 的固件宿主测试，并扩展 AG-05/AG-12 测试。

没有暂存或提交 `phone-dsh/docs/handoffs/2026-11-06-device-connectivity.md`、`phone-dsh/docs/integrator/`、固件仓库已有的整个 `docs/` 目录或 `tools/lib/__pycache__/`；这些工作树条目与本次变更无关。

## 验证结果

以下结果取自本次工作中的实际执行记录：

| 命令/动作 | 结果 |
| --- | --- |
| `swift test --filter TonoLinkVolume` | PASS，8 tests；共享请求/生命周期 golden、狭义意图匹配，以及新增的“旧固件缺 `consumer_control` 时不发任何 HID 请求”“一次音量命令的 status→batch→detach 请求序列”“hide→show 被合并时的一次可见性循环恢复”。 |
| 真机 `PhoneDSHDevice` / `TonoLinkVolumeDeviceTests`（`TEST_RUNNER_PDSH_TONOLINK_VOLUME_TEST=1`） | 修复后 PASS，2 tests / 0 failures / 26 s；音量键 0.55→0.50→0.55（两次运行），语音路径不再超时并如实回复。 |
| 真机 `PhoneDSHDevice` / `TonoLinkKeyboardDeviceTests`（`TEST_RUNNER_PDSH_TONOLINK_KEYBOARD_TEST=1`） | PASS，1 test / 16 s；HID 连接时软键盘不出现，detach 后立即出现，重新 ensureHID 后再次让位。 |
| 真机 `PhoneDSHDeviceUI` / `TonoLinkKeyboardRecoveryUITests` | NOT_RUN：UI-test runner 启动即退出（code 74），解锁后重试 3 次仍失败；用例本身已编译、签名、安装通过。 |
| `swift test --filter IPhoneAgentMCPTests` | PASS，10 tests。 |
| `python3 -m unittest spec.v1.tools.test_native_mcp_check && git diff --check` | PASS，6 个 checker 测试，diff check 通过。 |
| `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` | phone-spec PASS；phone-cross-tree PASS（8 invariants、87 tests）；整体 FAIL，因为 P0 conformance 有 7 个已存在页面结构差异，涉及 connected-computer、files、home-drawer、pc-pairing、settings，与本次修改路径无关。 |
| `bash host_tests/run.sh --filter ag12` | PASS，6 tests，真实固件 parser/encoder 使用共享 golden。 |
| `bash host_tests/run.sh --filter ag05` | PASS，AG-05 suite。 |
| `source /Users/macbook/esp/esp-idf-v6.1/export.sh && idf.py build` | PASS，ESP32-S3 固件镜像完成；ESP-IDF/Kconfig 输出依赖警告。 |
| `PDSH_WITH_XZSHELL=1 xcodebuild -quiet -project examples/probe-app/PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -destination 'platform=iOS,id=00008160-00023D1C2240000A' -derivedDataPath /Users/macbook/Library/Developer/Xcode/DerivedData/PhoneDSHProbe-alqzbsreltgljaewqoctxbcaoouf -configuration Debug build DEVELOPMENT_TEAM=Q322S2LD93 CODE_SIGN_STYLE=Automatic` | exit 0；签名产物通过 `codesign --verify --deep --strict --verbose=2`。Xcode 有既存 concurrency/deprecation warnings 和“exit code 0 but produced no further output”诊断。 |
| `xcrun devicectl device install app --device 00008160-00023D1C2240000A /Users/macbook/Library/Developer/Xcode/DerivedData/PhoneDSHProbe-alqzbsreltgljaewqoctxbcaoouf/Build/Products/Debug-iphoneos/PhoneDSHProbe.app` | PASS，安装成功；随后观察到 app 启动。 |
| TonoLink OTA | PASS；板端报告 slot `ota_0`、`needs_usb_confirmation=false`、`hid.consumer_control=true`，版本字符串 `0.1.0-m21`。`4e81bc6f…c91ee6` 是 app ELF SHA-256（板端 `/ota/state` 报的值），不是上传的 `.bin`。 |

## 真机核验（2026-11-11 追加）

设备：iPhone `00008160-00023D1C2240000A`（iOS 27.2），应用 `com.tono.phonedsh.probe`（签名 team `Q322S2LD93`），板子 `PhoneAgent-7356`：USB NCM 在线，BLE bonded/encrypted，`airplay.mirror_active=true`。本轮新增加两个真机测试与一处产品修复；所有命令都是在本机实际执行的结果。

### 1. Consumer Control 音量键确实改变 iPhone 媒体音量 —— PASS

`TonoLinkVolumeDeviceTests.testConsumerVolumeKeyChangesOutputVolume`（宿主在 app 进程内的真机单元测试）直接驱动 `TonoLinkPhoneHands.adjustOutputVolume`，用 100 ms 轮询 `AVAudioSession.outputVolume` 读回；两次独立运行结果一致：

| 运行 | start | `volume_down` 读回 | `volume_up` 读回 |
| --- | --- | --- | --- |
| 1 | 0.55 | `0ms=0.5500 → 100ms=0.5000` | `0ms=0.5000 → 100ms=0.5500` |
| 2 | 0.55 | 同上 | 同上 |

- 板子对两次单步 `{"op":"consumer","key":"volume_up|volume_down"}` 都回 200；`GET /v1/phone/status` 在 enable 后约 1 s 内给出 `consumer_control=true`、`keyboard=true`、`absolute=true`，20 s 内保持稳定。
- KVO 读回不可靠：一次运行漏掉两次真实变化，另一次在注册时先投递一个与当时读数不符的旧值（0.65）。因此产品代码继续用单次 `outputVolume` 读回是有风险的，见第 3 节。

### 2. hide→show 竞态：复现、修复、复验 —— PASS

- 复现：`disableHID()` 之后约 0.23 s 就进入下一次 `ensureVolumeHID()`，板子连续 15 s 报 `input_mode=true` 但 `consumer_control/keyboard/absolute/mouse` 全为 false；语音路径回“小智 Link 的音量按键没有连上手机…”。2/2 次复现；同样序列间隔 1–2 s 时约 1 s 恢复。
- 原因：iOS 会把紧随 hide 的 show 与 hide 合并，不再重读 HID Report Map；而板子对“已经 enabled”的重复 `{"on":true}` 是 no-op，因此重发 enable 永远救不回来（`main/hid_svc.c` 的 `s_host_read_map` 只在 host 读 map 时置位）。
- 修复：`TonoLinkPhoneHands.ensureHID` 与 `ensureVolumeHID` 在发出 enable 3 s 后仍未就绪时，强制一次 `{"on":false}` → 500 ms → `{"on":true}` 的可见性循环，之后重新等待；每个 3 s 窗口最多一次。两者都是 desired-state 调用（`tonolink-board.md` §2 明确 `on:false` 可重复），不重放任何 HID 按键/指针步骤。
- 复验：修复后同一份设备测试一次运行 **2 tests / 0 failures / 26 s**；语音路径不再超时。设备语音日志（`Documents/tonolink-voice.log`）记录该轮 `volume=["direction":"up","before":0.55,"after":0.55,"changed":false]` 并如实回复“音量键已发送，但系统音量没有可观察到的变化；我没有重复发送。”

### 3. 未决：语音路径的单次 250 ms 读回可能过早

同一次复验里，`up`/`down` 两次键都被板子接受，但 `answerVolumeCommand` 的 250 ms 单次读回看到的仍是 0.55，于是回复“没有可观察到的变化”；硬件测试在 +100 ms 就能看到变化。无法从这一次数据区分“读回窗口太早”和“那一轮键没有生效”。本轮没有改这个窗口。影响是假阴性（把已生效的键说成没变化），不会误报成功；修复方向是把 250 ms 单次读改为约 1–2 s 内的短轮询并保留 `changed` 的判定阈值。

### 4. 软键盘随 HID 可见性恢复 —— PASS（app 内探针；不是合成点击）

`TonoLinkKeyboardDeviceTests.testSoftwareKeyboardFollowsTheBoardHIDVisibility`（宿主在 app 内的真机测试，15.9 s，1 test / 0 failures）在 app 自己的 key window 里放一个可编辑文本视图、真实 `becomeFirstResponder()`，并用 `UIResponder.keyboardWillShowNotification` 与 `GCKeyboard.coalesced` 同时观察：

| 阶段 | 板端 `/v1/phone/status` | iOS 硬件键盘（GCKeyboard） | 焦点 | 软键盘 |
| --- | --- | --- | --- | --- |
| HID 已连接 | `keyboard=1 absolute=1 input_mode=1` | present | `isFirstResponder=true` | 3 s 内**不出现** |
| `disableHID()` 后 | `keyboard=0 input_mode=0` | absent | `isFirstResponder=true` | **立即出现**（同秒） |
| 下一次任务 `ensureHID()` 后 | `keyboard=1` | present | `isFirstResponder=true` | 不出现 |

即：真机上“任务结束后隐藏 HID → 系统软键盘恢复、下一任务重新接上外接键盘 → 软键盘再次让位”这条链路成立。独立证据在手机 `Documents/tonolink-keyboard-test.log`（已随本轮拉取）。

限制：这是**真实焦点 + 真实系统键盘状态**，但不是一次合成点击。更严格的 `TonoLinkKeyboardRecoveryUITests`（XCUITest：真实任务结束后合成 tap 输入框并断言键盘）已写好并在设备上编译、签名、安装通过，但本机 iPhone 上 UI-test runner 启动即退出（`Early unexpected exit … test runner exited with code 74 before establishing connection`，解锁并重试 3 次均如此），因此该用例状态是 **NOT_RUN / 环境阻塞**，不是通过。

### 5. 旧固件拒绝与板端镜像

- 固件宿主测试复核：`bash host_tests/run.sh --filter ag12` PASS（6/6 test binary，29 checks）；`bash host_tests/run.sh --filter ag05` PASS（`test_ctrl_core` 135 checks、`test_pa_cmd` 344430 checks，0 failed）。
- 旧固件的解析器在把任何报告排入 HID 队列之前返回 400 `bad_request`（`main/svc/hid_macro.c` 的 unknown-op 分支；旧版 `hid_macro.c` 的 op 表没有 consumer）。app 侧在 `hid.consumer_control` 缺失时不发任何 HID 请求，直接报“固件还不支持语音调音量”；本轮补了 Mac 单测 `testMissingConsumerControlFailsBeforeAnyHIDRequest` 覆盖这条路径（此前没有测试）。
- 硬件级旧固件拒绝仍未验证：本地没有 rev-4 镜像可刷（`build/agent_s3_flashed.bin` 是更旧的 `e15d80b-dirty`），本轮没有降级刷写。
- 板端 slot/`needs_usb_confirmation` 本轮没有直接重读；实时 `/v1/info` 返回 `slot":"ota_0"`、`version":"0.1.0-m21"`、`features` 含 `hid`，与交接一致。

### 6. 唤醒路径

- 固件有**受支持的合成唤醒**：console `wake` / `POST /cmd` body `wake` / BLE `<seq> con wake`，产生 `ev wake n=0`；`spec/device/v1/tonolink-board.md` §4 明确 n=0 是模拟唤醒。它验证固件事件→BLE notify→app 解析→`listen`，不验证 WakeNet。手机上可以用中继 `POST /board/cmd`（body `wake`）触发。
- 本轮没有执行合成唤醒（中继需要在手机上手动开启，且它的 BLE 连接与语音主机互斥）；`你好小智` 的持续唤醒仍需人说一次。

## 交接状态与后续验证

```text
Base:
  phone-dsh  3d1c9ef08da9e553a31421e08256fe9b768358c9
  firmware  59fe866a3398d2001dc6a79065381b36828d721
Implementation commit:
  phone-dsh  8edb4f35bbcdd5b1ceab59f497705945bf3bb26d
  firmware  67e723f8460736516d8fffa03fa471e20e3426a1
Protocol impact: P05: none — DEBUG-only test entry on the existing voice/MCP path, no method, schema or result change; P07: none — the visibility-cycle recovery only repeats the existing desired-state POST /v1/hid/enable calls, no new field, route, error or HID step; P09: none — no page projection/structure change; P08: none — outputVolume is read only
Contract revision: unchanged — P05 spec/v1/native-mcp.md + golden/native-mcp/iphone-agent-volume-policy.json; P07 spec/device/v1/tonolink-board.md + consumer-control schema/golden; frozen details in docs/protocol-changes/PC-20261111-{phone-volume-control,xiaozhi-volume-hid,phone-task-completion}.md
Status per end:
  iOS host/app: implemented; signed, installed and launched. Consumer Control volume key proven on the device (0.55→0.50→0.55, two runs); the hide→show recovery is implemented and the device suite re-ran green; software-keyboard state verified in-app (真机核验 §4)
  firmware: implemented; AG-05/AG-12 host tests pass; the OTA image in use reports hid.consumer_control and slot ota_0
  MCP/model presentation: guidance published and server tests pass; a live model reply after the update is still not verified
Commands → result: see 验证结果 and 真机核验 above. P0 conformance FAILs 7 divergences that also FAIL at base 3d1c9ef0, so they are unchanged by this work
Not verified: old-firmware hardware rejection (no rev-4 image flashed); a real spoken wake word with WakeNet/ASR; the XCUITest tap test (the runner exits 74 before bootstrapping on this iPhone)
Remaining risks: the voice path reads outputVolume once after 250 ms and can report “no observed change” for a key that did land (真机核验 §3); KVO readback is unreliable; a control action that starts <1 s after a detach now costs one visibility cycle (a few seconds) before HID is ready
```

现在只剩下自动化覆盖不到、必须由人说一次的部分：拿起手机，先说“你好小智”，听到“我在/好的，马上处理”后说“调大音量”，再点一下聊天输入框确认软键盘出现。若一句话被接受但系统音量没有可观察变化，不要自动重发（`answerVolumeCommand` 已按这个策略回复）；唤醒词与真实 ASR（WakeNet + 云端识别 → 本地音量路由）是唯一仍未在真机上跑过的环节。合成唤醒（`POST /cmd` body `wake`，或中继 `POST /board/cmd`）可以在不说话的验证里证明“固件事件 → BLE notify → app → listen”，但不能替代 WakeNet；本轮未执行合成唤醒。

## 分支与提交记录

```text
phone-dsh:  branch codex/tonolink-volume-voice-keyboard-handoff
            base 3d1c9ef08da9e553a31421e08256fe9b768358c9
            implementation commit 8edb4f35bbcdd5b1ceab59f497705945bf3bb26d
            handoff commit a694c0b2cba51d5cbfc149e894d32d7a806025bd
            verification commit = this commit (真机核验、HID 可见性循环恢复、P07 状态关闭); pushed to `vaca22`.
firmware:    branch codex/tonolink-volume-voice-keyboard-handoff
            base 59fe866a3398d2001dc6a79065381b36828d721
            commit 67e723f8460736516d8fffa03fa471e20e3426a1; pushed to `origin`.
```
