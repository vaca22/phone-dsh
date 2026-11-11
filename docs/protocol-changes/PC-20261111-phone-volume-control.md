# Voice control of iPhone output volume

```yaml
change: PC-20261111-phone-volume-control
contracts: [P05]
status: implemented
breaking: false
version_decision: Add task guidance to the existing iOS-only iphone_agent_run tool. Keep MCP methods, names, schema, results, errors, deadlines, receipts and version unchanged.
base: 3d1c9ef08da9e553a31421e08256fe9b768358c9
contract_revision: spec/v1/native-mcp.md@sha256:3a5b58047bc5730a4a9c758371269eab907897fa81a1f1d4aac3cea9c298980b; spec/v1/golden/native-mcp/iphone-agent-volume-policy.json@sha256:48a80943ddfe30d3b767de84e09b9a96c57d0ad40f20de8e9825443d58686c7f
```

Protocol impact: P05; P07: none — the existing TonoLink screen/HID endpoints and command semantics are unchanged; P08: none — the app does not use audio-session or private volume APIs.

## 1. Trigger and roles

- **Trigger → current → expected:** A voice turn such as “你好小智，调大音量” reaches the DSH session, but its generic phone-task instructions do not define the volume target or confirmation. The existing `iphone_agent_run` tool will guide the iOS UI agent to adjust current media/output volume and verify the visible result.
- **Coordinator, contract owner, implementer, reviewer/integrator:** one owner for this change; all roles held by the coordinator.
- **Owning contract and fixtures:** `spec/v1/native-mcp.md`, “Current output-volume tasks”; shared examples and invalid MCP arguments in `spec/v1/golden/native-mcp/iphone-agent-volume-policy.json`. The existing `task` input schema is unchanged.
- **Producer/consumer ends:** `IPhoneAgentMCPServer` publishes the tool description and initialize instructions; the Worker MCP client and DSH model consume them; `IPhoneAgent` executes the task through the existing TonoLink screen/HID path. Android does not serve this iOS-only tool. No board firmware, Worker protocol, or other platform implementation changes.

## 2. Contract delta

| Item | Before → after |
| --- | --- |
| Fields, encoding, limits | No change. `iphone_agent_run` still accepts only `{"task": string}`. |
| Tool capability and version | Existing tool and MCP version remain unchanged; its task guidance now defines output-volume behavior. |
| Correlation and terminal outcome | Existing JSON-RPC IDs and `finished` result are unchanged. Completion requires the agent's fresh screenshot to visibly confirm the target. |
| Errors, cancellation, retry, deadline | No change. Existing error set, timeout, cancellation and `automatic_retry: false` behavior remain authoritative. |
| Side effects and durability | Same receipt is written before the UI task; uncertain operations are not replayed. No new persisted data. |
| Authentication and device scope | Same authenticated endpoint and already-connected TonoLink board; no additional grant, path or credential. |
| Clause status | No `target` or `draft` clause changes status. |

Self-check: no second representation, field, error, method, tool name or version is added. No existing accepted MCP input becomes invalid or newly valid.

## 3. Compatibility and release

| Producer → consumer | Compatibility behavior |
| --- | --- |
| Old host → new Worker/model | The existing tool may be absent on old hosts; the caller must treat it as unavailable and must not call an alias. |
| New host → old Worker/model | The MCP tool shape is unchanged. Older consumers that ignore the added description continue to use the same task input and result. |
| New → new | Same MCP request and receipt behavior, with the frozen volume instructions visible in both `tools/list` and `initialize`. |
| Old receipts → new / rollback | The receipt format and path do not change; old results remain readable. Repeating an uncertain operation remains prohibited. |

- **Version decision:** additive instructions on the existing tool; no MCP protocol/version bump is needed because all wire shapes and state transitions are unchanged.
- **Release order:** build the updated app with its current Worker image and install it together. Rolling back to the November 6 image also rolls back the MCP egress header and leaves the phone MCP mount unavailable under the current host gate; the egress fix is tracked separately in `PC-20261110-bot-mcp-egress-capability.md`.
- **Target/draft differences:** none for this change.

## 4. Ownership and acceptance

- **Contract owner paths:** `spec/v1/native-mcp.md`, `spec/v1/golden/native-mcp/iphone-agent-volume-policy.json`, this change record.
- **iOS implementer paths:** `Sources/PhoneDSHVenus/IPhoneAgentMCPServer.swift`, `Tests/PhoneDSHVenusTests/IPhoneAgentMCPTests.swift`. The test reads the shared fixture and calls the real MCP server with its positive and negative arguments.
- **Conformance checker paths:** `spec/v1/tools/native_mcp_check.py`, `spec/v1/tools/test_native_mcp_check.py`.
- **Acceptance commands:** `swift test --filter IPhoneAgentMCPTests`; `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`; signed iPhone app build/install. A real spoken volume adjustment is not part of acceptance because it changes the user's system volume.
- **Unverified/remaining risks:** UI-Venus reports a model assessment; visual UI layout and device lock state can prevent adjustment. A fresh screenshot is required before reporting success. No physical volume adjustment is claimed by this change.

## 5. Handoff evidence

Base / head: `3d1c9ef08da9e553a31421e08256fe9b768358c9` / `3d1c9ef08da9e553a31421e08256fe9b768358c9` (changes are uncommitted in the worktree)

Protocol impact: P05; P07: none — existing TonoLink screen/HID protocol unchanged; P08: none — no audio-session API changes.

Contract revision: `spec/v1/native-mcp.md@sha256:3a5b58047bc5730a4a9c758371269eab907897fa81a1f1d4aac3cea9c298980b`; `spec/v1/golden/native-mcp/iphone-agent-volume-policy.json@sha256:48a80943ddfe30d3b767de84e09b9a96c57d0ad40f20de8e9825443d58686c7f`

Changed files by end: contract — spec, shared fixture and change record; iOS — native MCP guidance and its real-server regression; checker — native-MCP fixture validator and mutation test. The updated Worker image is an ignored generated app resource; no Worker source was changed for volume behavior.

Status per end: P05 contract implemented; iOS MCP guidance and real-server tests implemented; Worker MCP mount observed reachable in a voice task after installing the refreshed image; Android does not serve this iOS-only tool. Physical volume adjustment remains unverified because the board's Bluetooth HID input is not connected.

Commands → result:

- `python3 -m unittest spec.v1.tools.test_native_mcp_check` → PASS, 6 tests.
- `swift test --skip-build --filter IPhoneAgentMCPTests` → PASS, 10 tests.
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` → `phone-spec` PASS; `phone-p0-conformance` FAIL because page-structure reports 7 divergences outside its baseline across `connected-computer`, `files`, `home-drawer`, `pc-pairing` and `settings` (none of those files changed here); `phone-cross-tree` PASS.
- `PDSH_DSH_CHECKOUT=/Users/macbook/Documents/tonolink-artifacts/dsh-upstream-66491b05 PDSH_PNPM_STORE=/tmp/phone-dsh-pnpm-store examples/probe-app/scripts/copy-bundle-assets.sh --checkout /Users/macbook/Documents/tonolink-artifacts/dsh-upstream-66491b05 --force` → PASS; DSH `0.2.2-rc.1`, and the packed `mcp-phone` profile contains `X-PDSH-MCP-Egress`.
- `PDSH_WITH_XZSHELL=1 xcodebuild -quiet -project examples/probe-app/PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -destination 'platform=iOS,id=00008160-00023D1C2240000A' -derivedDataPath /Users/macbook/Library/Developer/Xcode/DerivedData/PhoneDSHProbe-alqzbsreltgljaewqoctxbcaoouf -configuration Debug build DEVELOPMENT_TEAM=Q322S2LD93 CODE_SIGN_STYLE=Automatic` → exit 0; fresh signed app bundle verified.
- `xcrun devicectl device install app --device 00008160-00023D1C2240000A /Users/macbook/Library/Developer/Xcode/DerivedData/PhoneDSHProbe-alqzbsreltgljaewqoctxbcaoouf/Build/Products/Debug-iphoneos/PhoneDSHProbe.app` → PASS; `xcrun devicectl device process launch --device 00008160-00023D1C2240000A --terminate-existing com.tono.phonedsh.probe` → PASS.
- Device log evidence: after the refreshed image, a voice task reached UI-Venus and returned the Bluetooth HID-not-connected limitation; the prior `unknown tool` result was not repeated. No volume command was issued.

Not verified: the physical volume slider was not moved; the MCP tool was observed running a different voice UI task and returning the missing-HID limitation.

Remaining risks: connect the PhoneAgent board's Bluetooth HID keyboard/mouse to the iPhone before using voice volume control; then UI-Venus must still confirm the slider in a fresh screenshot.

## 6. Revision record

| Revision | Owner | Reason | Notified ends |
| --- | --- | --- | --- |
| 1 | Coordinator | Frozen volume task semantics and shared examples before implementation. | iOS native MCP consumer; spec/checker |
| 2 | Coordinator | Recorded implementation and observed MCP reachability; actual volume action remains pending the board HID connection. | iOS native MCP consumer; Worker MCP client; device user |
