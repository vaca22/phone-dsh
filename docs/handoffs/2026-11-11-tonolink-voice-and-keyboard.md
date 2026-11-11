# TonoLink 语音调音量、OTA 与软键盘问题交接

日期：2026-11-11

关联仓库：`phone-dsh`、`tonolink-m21-r4-firmware`
计划分支：`codex/tonolink-volume-voice-keyboard-handoff`

## 交接摘要

- “调大音量 / 调小音量”有独立的本地语音命令路径：使用 TonoLink Consumer Control 音量键，不经过聊天模型、屏幕识别或 UI 操作；每次只发送一步，并以 iOS 公开的只读 `outputVolume` 观察结果，不确定时不重发。
- 固件加入音量 Consumer Control HID 报告与批处理步骤，并把 GATT 布局版本从 4 升到 5，避免 iPhone 继续使用旧特征句柄。OTA 已完成，板端报告 `ota_0`、`needs_usb_confirmation=false`、`hid.consumer_control=true`；固件 SHA-256 为 `4e81bc6f2db5cb67e40ae7992819b2c22f012c8021d3247c7ab237c597c91ee6`，板端版本字符串仍为 `0.1.0-m21`。
- 语音任务回复策略已要求只用一句话说明结果或阻碍，不再向用户输出步骤数、耗时、`finished`、模型自评和 UI 导航过程。
- iOS 每次手机 UI 或音量控制结束后，都会尽力调用既有 HID 关闭接口，让外接键盘脱离；下一次 UI 任务仍通过既有 `ensureHID` 路径重新启用。这个改动针对“第二轮之后系统软键盘打不开”，但恢复效果尚未完成真机点击验证。
- iOS 新构建已签名、安装并启动。静态/自动测试已执行；真实音量是否改变和软键盘是否恢复仍需在手机上验证。

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

- Swift BLE 层和测试：`Sources/PhoneDSHBLE/TonoLinkPhoneHands.swift`、新增音量意图/请求 helper 与对应测试。
- MCP 和 iOS probe app：`Sources/PhoneDSHVenus/IPhoneAgentMCPServer.swift`、`Tests/PhoneDSHVenusTests/IPhoneAgentMCPTests.swift`、`examples/probe-app/PhoneDSHProbe/IPhoneAgentHost.swift`、`PhoneDSHProbeApp.swift`、`TonoLinkUSBOTAPage.swift`、`TonoLinkVoiceHost.swift`。
- 规范与门禁：P05/P07 owning contract、schema、golden、registry/checker，以及三个协议变更记录。
- 本交接：`docs/handoffs/2026-11-11-tonolink-voice-and-keyboard.md`。

`tonolink-m21-r4-firmware`：

- HID Consumer Control descriptor、编码、批处理解析/执行、状态和 GATT revision 更新。
- 增加共享 golden 的固件宿主测试，并扩展 AG-05/AG-12 测试。

没有暂存或提交 `phone-dsh/docs/handoffs/2026-11-06-device-connectivity.md`、`phone-dsh/docs/integrator/`、固件仓库已有的整个 `docs/` 目录或 `tools/lib/__pycache__/`；这些工作树条目与本次变更无关。

## 验证结果

以下结果取自本次工作中的实际执行记录：

| 命令/动作 | 结果 |
| --- | --- |
| `swift test --filter TonoLinkVolumeCommandTests` | PASS，5 tests；包括共享请求/生命周期 golden 与狭义意图匹配。 |
| `swift test --filter IPhoneAgentMCPTests` | PASS，10 tests。 |
| `python3 -m unittest spec.v1.tools.test_native_mcp_check && git diff --check` | PASS，6 个 checker 测试，diff check 通过。 |
| `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` | phone-spec PASS；phone-cross-tree PASS（8 invariants、87 tests）；整体 FAIL，因为 P0 conformance 有 7 个已存在页面结构差异，涉及 connected-computer、files、home-drawer、pc-pairing、settings，与本次修改路径无关。 |
| `bash host_tests/run.sh --filter ag12` | PASS，6 tests，真实固件 parser/encoder 使用共享 golden。 |
| `bash host_tests/run.sh --filter ag05` | PASS，AG-05 suite。 |
| `source /Users/macbook/esp/esp-idf-v6.1/export.sh && idf.py build` | PASS，ESP32-S3 固件镜像完成；ESP-IDF/Kconfig 输出依赖警告。 |
| `PDSH_WITH_XZSHELL=1 xcodebuild -quiet -project examples/probe-app/PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -destination 'platform=iOS,id=00008160-00023D1C2240000A' -derivedDataPath /Users/macbook/Library/Developer/Xcode/DerivedData/PhoneDSHProbe-alqzbsreltgljaewqoctxbcaoouf -configuration Debug build DEVELOPMENT_TEAM=Q322S2LD93 CODE_SIGN_STYLE=Automatic` | exit 0；签名产物通过 `codesign --verify --deep --strict --verbose=2`。Xcode 有既存 concurrency/deprecation warnings 和“exit code 0 but produced no further output”诊断。 |
| `xcrun devicectl device install app --device 00008160-00023D1C2240000A /Users/macbook/Library/Developer/Xcode/DerivedData/PhoneDSHProbe-alqzbsreltgljaewqoctxbcaoouf/Build/Products/Debug-iphoneos/PhoneDSHProbe.app` | PASS，安装成功；随后观察到 app 启动。 |
| TonoLink OTA | PASS；板端报告 slot `ota_0`、`needs_usb_confirmation=false`、`hid.consumer_control=true`，版本字符串 `0.1.0-m21`。镜像 SHA-256 见摘要。 |

## 交接状态与后续验证

```text
Base:
  phone-dsh  3d1c9ef08da9e553a31421e08256fe9b768358c9
  firmware  59fe866a3398d2001dc6a79065381b36828d721
Protocol impact: P05; P07; P09: none — no page projection/structure change; P08: none — outputVolume is read only
Contract revision:
  P05 spec/v1/native-mcp.md + spec/v1/golden/native-mcp/iphone-agent-volume-policy.json
  P07 spec/device/v1/tonolink-board.md + consumer-control schema/golden
  frozen details: docs/protocol-changes/PC-20261111-{phone-volume-control,xiaozhi-volume-hid,phone-task-completion}.md
Status per end:
  iOS host/app: implemented; signed, installed, and launched; actual volume event and post-task keyboard recovery not verified
  firmware: implemented; AG-05/AG-12 and full ESP-IDF build pass; OTA completed
  MCP/model presentation: guidance published and server tests pass; live model reply after update not verified
Commands → result: see verification table above; P0 conformance remains FAIL for 7 unrelated divergences
Not verified: a real “调大音量” / “调小音量” changing iPhone outputVolume; old-firmware hardware rejection; a post-task composer tap reopening the software keyboard; ongoing wake-word E2E after this app update
Remaining risks: keyboard recovery is best-effort HID detachment until the real tap check passes; no confirmed volume step means user reply must continue to distinguish accepted key from observed level change.
```

下次连接真机后的最小核验：先完成一条普通语音 UI 任务，再点输入框确认系统键盘出现；然后单独说一次“调大音量”，核对系统输出音量或 UI 指示确实变化。若命令被接受但没有可观察变化，不要自动重发。也要确认 `你好小智` 能再次唤醒。PhoneAgent LAN MCP 当前不可用时，可用已授权的直接设备调试渠道完成这几个观察并把结果追加到此交接。

## 分支与提交记录

```text
phone-dsh:  branch codex/tonolink-volume-voice-keyboard-handoff
            base 3d1c9ef08da9e553a31421e08256fe9b768358c9
            commit/push: 待记录
firmware:    branch codex/tonolink-volume-voice-keyboard-handoff
            base 59fe866a3398d2001dc6a79065381b36828e721
            commit/push: 待记录
```
