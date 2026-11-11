# Concise iPhone task replies and HID handoff

```yaml
change: PC-20261111-phone-task-completion
contracts: [P05, P07]
status: frozen
breaking: false
version_decision: Keep the MCP payload, HID route and request body unchanged. Add caller guidance and use the already-supported POST /v1/hid/enable {"on":false} desired state after phone actions.
base: 3d1c9ef08da9e553a31421e08256fe9b768358c9
contract_revision: spec/v1/native-mcp.md@sha256:c1c049b410e2ee9f1cd7c134549548ea5e25f5d9148700a019f2751a69ff1fc2; spec/v1/golden/native-mcp/iphone-agent-volume-policy.json@sha256:2d95a894112f2e88dc0484c6af67d99e625d02a944d24b786e38bcd842ba8961; spec/device/v1/tonolink-board.md@sha256:da4473272da6ab08009839232baf9ea7ed2e4fe462c42ec4fcee94cb19e3e87f; spec/device/v1/golden/tonolink-hid-consumer-control.json@sha256:eaee8612ecdd2a2eddca41f4461f6bab99c94dfe0a8f86bd873ccae1565785f5
```

Protocol impact: P05; P07. P09: none — the task reply and HID cleanup do not change page structure or projected UI state.

## 1. Trigger and roles

- **Trigger → current → expected:** Voice task replies include execution counts, elapsed time and model self-assessment. The TonoLink board remains exposed as an external keyboard after a task, and the user reported that the iPhone software keyboard would not open on the next conversation. Keep the MCP result shape, tell the calling model to report only the result or blocker in one short sentence, and hide the existing HID service when phone control finishes.
- **Coordinator / contract owner / implementer / reviewer-integrator:** one coordinator holds all roles; implementation is sequential in the iOS host. The firmware endpoint already implements the `on:false` desired state and requires no source change for this contract.
- **Owning contracts and fixtures:** `spec/v1/native-mcp.md` plus `spec/v1/golden/native-mcp/iphone-agent-volume-policy.json`; `spec/device/v1/tonolink-board.md` plus `spec/device/v1/golden/tonolink-hid-consumer-control.json`.
- **Producer and consumer ends:** P05 iOS `IPhoneAgentMCPServer` publishes the completion guidance consumed by the Worker/model; P07 firmware implements the existing HID visibility endpoint and the iOS `TonoLinkPhoneHands`, `IPhoneAgentHost`, and `TonoLinkVoiceHost` use it. Android and HarmonyOS do not serve this iPhone-only tool or board path.

## 2. Contract delta

| Item | Before → after |
| --- | --- |
| MCP result fields | No change: `answer`, `finished`, `steps`, and `seconds` remain available to the consumer. Caller guidance says to omit counts, durations, `finished`, model self-assessment and UI navigation detail from the user-facing summary. |
| HID route and body | No change: the existing `POST /v1/hid/enable {"on":false}` releases held reports and hides the HID service; the golden now records detach after a task and reattach before the next task. |
| Task completion lifecycle | After UI-Venus success or failure, the iOS host best-effort hides HID without replacing the task result. The local voice volume path does the same after its one Consumer Control report. A later UI task re-enables HID and waits for subscriptions through the existing `ensureHID` path. |
| Correlation, errors, retry, persistence | Unchanged. MCP receipts and retry rules remain authoritative. `on:false` sets desired state and is safe to repeat; no previous key/pointer action is replayed. Cleanup failure is logged and does not convert an observed task result into a failure. |
| Authentication and scope | Unchanged authenticated USB-NCM route, `X-Controller` ownership, BLE connection, and firmware permissions. Control GATT and wake-word audio remain separate from HID visibility. |
| Version | No MCP, HTTP, HID report or firmware API version bump. No field, operation, endpoint, capability or error is added. |

Compatibility matrix:

| Producer → consumer | Behavior |
| --- | --- |
| Old host → new model | The old result shape remains accepted; only the new one-sentence instruction is absent. |
| New host → old model | Tool schema and result shape remain unchanged; an older model may ignore the new presentation guidance. |
| New → new | Shared MCP fixture reaches the real server; completed tool calls request a concise user-facing response. UI and volume actions release HID, and a later UI task re-enables it. |
| Old firmware → new app | Existing firmware with `/v1/hid/enable` accepts `on:false`; if detach fails, the task result is preserved and the cleanup error is logged. A board firmware lacking the HID route cannot provide this handoff and must be upgraded. |
| New firmware → old app | No behavior change; old apps do not issue the new cleanup call. |
| Old data → new / rollback | Receipt format and contents are unchanged; no migration or rollback data change. |

## 3. Ownership and acceptance

- **Contract owner paths:** `spec/v1/native-mcp.md`, `spec/v1/golden/native-mcp/iphone-agent-volume-policy.json`, `spec/device/v1/tonolink-board.md`, `spec/device/v1/golden/tonolink-hid-consumer-control.json`, this change record.
- **iOS implementation paths:** `Sources/PhoneDSHVenus/IPhoneAgentMCPServer.swift`, `Sources/PhoneDSHBLE/TonoLinkPhoneHands.swift`, `examples/probe-app/PhoneDSHProbe/IPhoneAgentHost.swift`, `examples/probe-app/PhoneDSHProbe/TonoLinkVoiceHost.swift`, and their tests.
- **Firmware producer paths:** unchanged. The installed board image already implements the HID visibility endpoint; the current change does not alter its protocol or firmware image.
- **Shared positive and negative fixtures:** the MCP volume-policy vector covers valid and invalid tool arguments and carries the completion guidance; the P07 consumer-control vector covers valid and invalid consumer reports and records detach/reattach request shapes. No input validation is loosened.
- **Acceptance commands:** `swift test --filter IPhoneAgentMCPTests`; `swift test --filter TonoLinkVolumeCommandTests`; `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`; signed iPhone app build/install. A user-facing keyboard recovery claim requires a real tap test after an actual voice task.
- **Remaining risks:** HID detach is best-effort: a detach failure is logged and does not change the task result. A control action that starts within about 1 s of the detach needs one visibility cycle (a few seconds) before the board reports its HID subscriptions ready; the consumer does that cycle itself.

Revision 2 runtime evidence (2026-11-11, iPhone `00008160-00023D1C2240000A`, iOS 27.2, board `PhoneAgent-7356`): after a real task the board's HID service is hidden and the iPhone presents its software keyboard again; the next `ensureHID()` reattaches the HID keyboard and the software keyboard yields again. The probe focuses a real text view in the app's key window, asserts `isFirstResponder`, and observes both `keyboardWillShow` and `GCKeyboard.coalesced`: HID attached → hardware keyboard present, no software keyboard for 3 s; `disableHID()` → hardware keyboard absent and the software keyboard appears immediately; `ensureHID()` → hardware keyboard present and the software keyboard stays away. Independent log: `Documents/tonolink-keyboard-test.log` on the device, quoted in `docs/handoffs/2026-11-11-tonolink-voice-and-keyboard.md` §“真机核验”. This is a real focus and the real system keyboard, **not** a synthesized tap: the stricter XCUITest (`examples/probe-app/PhoneDSHDeviceUITests/TonoLinkKeyboardRecoveryUITests.swift`) is committed but its runner exits before bootstrapping on this iPhone (code 74), so the tap assertion remains NOT_RUN.

## 4. Revision record

| Revision | Owner | Reason | Notified ends |
| --- | --- | --- | --- |
| 1 | Coordinator | Freeze concise completion guidance and reuse of the existing HID detach state before implementation. | P05 iOS host/model consumer; P07 iOS consumer and existing firmware producer |
| 2 | Coordinator | Added physical-device evidence for the HID detach / software-keyboard recovery, the pre-existing no-op enable failure it exposed, and the one-cycle visibility recovery. No contract, schema, fixture or version change; the visibility cycle repeats the already-frozen desired-state calls only. | P05 iOS host; P07 iOS consumer and firmware producer; device user |
