# Direct XiaoZhi media-volume commands over BLE HID

```yaml
change: PC-20261111-xiaozhi-volume-hid
contracts: [P07]
status: frozen
breaking: false
version_decision: Add a closed consumer-control step to the existing TonoLink /v1/hid/batch contract; retain API v1 and reject it on old firmware before any HID output.
base: 3d1c9ef08da9e553a31421e08256fe9b768358c9
contract_revision: spec/device/v1/tonolink-board.md@consumer-control-volume-v1-gatt-layout-v5
```

Protocol impact: P07; P09: none — voice-host command dispatch and diagnostics do not change projected UI state or page structure. P08: none — this emits standard external Consumer Control HID reports; the app only reads iOS's outputVolume to describe an observed change and never writes system volume through AVAudioSession.

## 1. Identification and roles

- **Trigger → current → expected:** A wake-word command such as “调大音量” currently goes through the chat model and UI-Venus, where it depends on BLE keyboard/mouse readiness, screen mirroring, a vision model, and several UI actions. A narrow local voice path should send one Consumer Page Volume Increment or Decrement report through the existing TonoLink controller lease, with no LLM, screen, or vision dependency.
- **Coordinator / contract owner / implementer / reviewer-integrator:** one coordinator holds all roles; implementation is sequential across both ends.
- **Owning contract, schema, shared fixtures:** `spec/device/v1/tonolink-board.md` §2.1; `spec/device/v1/schema/tonolink-hid-consumer-step.schema.json`; `spec/device/v1/golden/tonolink-hid-consumer-control.json`.
- **Producer:** TonoLink M21-R4 firmware in `/Users/macbook/Documents/tonolink-m21-r4-firmware`, HID Report Map plus `/v1/hid/batch` parser/executor/status.
- **Consumer:** this repo's `Sources/PhoneDSHBLE/TonoLinkPhoneHands.swift` and the iOS probe app's `TonoLinkVoiceHost.swift`. Android and HarmonyOS are not consumers of the iPhone-only board path.

## 2. Contract delta

| Item | Before → after / clause |
| --- | --- |
| Fields and encoding | §2.1 adds `hid.consumer_control` to phone status and `{"op":"consumer","key":"volume_up"|"volume_down"}` to batch steps. HID Report ID 4 carries one byte; bit 0 is Volume Increment (Usage 0xE9), bit 1 Volume Decrement (Usage 0xEA); press is followed by an all-zero release. Golden fixture is authoritative for bytes and positive/negative cases. |
| Limits / unknown enum | Exactly one relative step per request; no repeat count, percentage, mute or other consumer usage. Unknown key is `invalid_argument`; extra or wrong-typed fields are `bad_request`. Missing `hid.consumer_control` means old firmware, not ready. |
| Version / compatibility | API stays v1. This is additive to the closed step set. Old firmware rejects the new op in parse before queueing reports; new app reports “update Link firmware” and does not fall back to blind taps. Existing operations remain unchanged. |
| Ordering / terminal outcome | Report press precedes report release on the existing HID queue. Existing controller lease, single executor, backpressure, abort and `release_all` semantics apply. HTTP success confirms queue acceptance only, not an iOS volume change. |
| Error / retry / cancellation | Existing `503 busy_exec` is safe to retry because it ran no step. After any accepted submission, timeout/cancellation is outcome-unknown and must not be replayed. No new error code, receipt, or persistence. |
| Security / ownership | Uses the existing authenticated USB-NCM `/v1/hid/batch` route and `X-Controller` lease. Only encrypted BLE HID notifications are eligible. No additional route, token, scope, or environment setting. |
| Status | Owning contract is frozen for implementation. It remains `partial` until the board firmware, iOS app, and real-device positive/negative evidence are complete. |

Compatibility matrix:

| Producer → consumer | Behavior |
| --- | --- |
| Old app → new firmware | Existing operation shapes and outputs unchanged. |
| New app → old firmware | Old parser returns `400 bad_request` before HID output; app identifies missing `hid.consumer_control` or the rejected operation as firmware-too-old and stops. |
| New app → new firmware | Both relative volume operations emit the two reports in the golden fixture. |
| Old data → new / rollback | No persistent data is added or migrated. |

## 3. Release and rollback

- **Version decision:** Keep API v1; the existing endpoint carries the additive step. No alias or second endpoint is added.
- **Release order:** Build and validate firmware first, then install the iOS app that can issue the new operation. If firmware cannot be updated, keep the local voice route disabled and return a clear unsupported message. Rollback to old app is safe. An old firmware does not accept the new operation.
- **No exact-volume promise:** iOS exposes `AVAudioSession.outputVolume` as read-only; commands are relative hardware-style volume keys. Percent requests remain on the existing general agent path and may not be exact.

## 4. Ownership and acceptance

- **Contract owner paths:** `spec/device/v1/tonolink-board.md`, the schema and golden above, and this change record.
- **Firmware producer paths:** `/Users/macbook/Documents/tonolink-m21-r4-firmware/main/hid_svc.c`, `main/shared/pa_hid.h`, `main/shared/pa_hid_encode.c`, `main/svc/hid_macro.{h,c}`, `main/svc/hid_exec.{h,c}`, `main/ctrl_svc.{h,c}`, `main/http/route_phone.c`, plus one firmware host test that consumes the shared golden.
- **iOS consumer paths:** `Sources/PhoneDSHBLE/TonoLinkPhoneHands.swift`, a `PhoneDSHBLE` volume-intent helper, its tests, `examples/probe-app/PhoneDSHProbe/TonoLinkVoiceHost.swift`, and the device spec documentation.
- **Shared fixture:** the golden above must drive the real firmware JSON expander and HID encoder, and the real Swift request builder / intent matcher. Include both valid directions, unsupported usage, extra field, wrong type, and unknown-outcome no-retry coverage.
- **Acceptance commands:** `swift test --filter TonoLinkVolumeCommandTests`; `swift test --filter IPhoneAgentMCPTests`; firmware `bash host_tests/run.sh --filter ag12` and `--filter ag05`; `idf.py build`; signed iPhone app build/install; real iPhone + TonoLink board check that output volume moves one step in each direction and old firmware fails without screen fallback.
- **Evidence status at freeze:** all acceptance commands were `NOT_RUN`; no physical volume event was claimed. See the execution evidence below for current results.

### Execution evidence

- `swift test --filter TonoLinkVolumeCommandTests`: **PASS**, 5 tests. This includes shared request/lifecycle fixtures, narrow intent matching, and non-retryable old-firmware / uncertain-outcome errors.
- `swift test --filter IPhoneAgentMCPTests`: **PASS**, 10 tests covering the native tool catalog, strict arguments, volume task dispatch, and uncertain result handling.
- `bash host_tests/run.sh --filter ag12`: **PASS**, 6 tests including the shared golden through the real firmware parser and encoder, report descriptor, executor readiness, and HID batch cases.
- `bash host_tests/run.sh --filter ag05`: **PASS**, delegated AG-05 suite.
- `source /Users/macbook/esp/esp-idf-v6.1/export.sh && idf.py build`: **PASS** — full ESP32-S3 image produced; ESP-IDF/Kconfig dependency warnings were emitted.
- `xcodebuild -project examples/probe-app/PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -configuration Debug -destination 'id=00008160-00023D1C2240000A' -derivedDataPath .build/PhoneDSHProbeDerived DEVELOPMENT_TEAM=Q322S2LD93 build`: **PASS**.
- `xcrun devicectl device install app --device 00008160-00023D1C2240000A .build/PhoneDSHProbeDerived/Build/Products/Debug-iphoneos/PhoneDSHProbe.app`: **PASS**, installation confirmed by `devicectl`.
- OTA update: **PASS**. The installed board reports slot `ota_0`, `needs_usb_confirmation=false`, `hid.consumer_control=true`, and version string `0.1.0-m21`; image SHA-256 `4e81bc6f2db5cb67e40ae7992819b2c22f012c8021d3247c7ab237c597c91ee6`.
- Real hardware volume movement and old-firmware negative test: **NOT_RUN**. OTA completion and capability status do not prove that a Consumer Control report changed iPhone output volume.
- PhoneAgent LAN discovery: **NOT AVAILABLE** — Bonjour returned no `_phoneagent._tcp` phone, so no screenshot-based app launch or runtime test was possible by that route.
- `bash scripts/ci/check.sh --only phone-cross-tree`: **PASS**, 8 invariants, registry, schema diff, and 87 mutation/unit tests.
- `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`: **FAIL** overall. `phone-spec` passed; `phone-p0-conformance` reported 7 UI page-structure divergences in settings and session pages, outside this change's edited paths; `phone-cross-tree` passed after registering the Swift golden reader and regenerating `spec/registry.json`.

## 5. Revision record

| Revision | Owner | Reason | Notified ends |
| --- | --- | --- | --- |
| consumer-control-volume-v1 | Coordinator | Frozen standard Consumer Control report and additive batch operation before either end implementation. | Firmware producer; iOS consumer |
| consumer-control-volume-v1-gatt-layout-v5 | Coordinator | Real OTA attempt showed iOS BLE write error `Writing is not permitted.` after the HID report map gained a characteristic while the local GATT layout revision remained 4. Freeze the requirement to advance the local revision and send a Service Changed indication so the iPhone drops stale handles, including after rollback. | Firmware producer; iOS CoreBluetooth consumer |

### Follow-on contract freeze: GATT cache invalidation

- **Trigger → current → expected:** The Consumer Control report adds a HID GATT characteristic. The firmware still reports local GATT layout revision 4, so the bonded iPhone retains old attribute handles and the OTA reconnect's control write is rejected. Advance to revision 5; on the next encrypted reconnect send the standard Service Changed indication for `0x0001`–`0xFFFF`, and have the iPhone rediscover before its next control write.
- **Owning clause / revision:** `spec/device/v1/tonolink-board.md` §4.2, `consumer-control-volume-v1-gatt-layout-v5`.
- **Delta:** local NVS layout revision `4 → 5`; no public field, new GATT service, command, or frame. The existing standard Service Changed indication is used. The same mismatch rule applies if OTA rolls back from 5 to 4.
- **Compatibility:** old board revision 4 → new app: unchanged control-service UUIDs and permissions; the board's indication invalidates cached handles. New board revision 5 → old app: existing controls still work and the old consumer ignores the additive status key. New board + new app: rediscovery precedes status/batch operations, then the Consumer Control step uses the existing HID report contract. Rollback 5 → 4: the persisted revision differs again, so the old image sends another indication; no user data is migrated.
- **Affected ends:** firmware `main/agent_ble.c` is the producer of the Service Changed indication; iOS CoreBluetooth in `TonoLinkCtrlBLE.swift` and the phone's USB-NCM HID consumer are the consumers. The iOS CoreBluetooth stack handles the standard indication; no app-specific alias is added.
- **Acceptance:** rebuild firmware; run the existing firmware HID host suite and full ESP-IDF build; OTA update the real board from the iPhone; verify the revision-change indication allows BLE reconnect and OTA confirmation; then run one real “调大音量” turn and read back changed iOS output volume. If the image rolls back, verify the board returns to revision 4 before retrying.

## 6. Handoff evidence

```text
Base / head:
  phone-dsh 3d1c9ef08da9e553a31421e08256fe9b768358c9 / same commit, working tree changes uncommitted
  firmware  59fe866a3398d2001dc6a79065381b36828d721 / same commit, working tree changes uncommitted
Protocol impact: P07; P09: none — local voice dispatch does not change page projection; P08: none — outputVolume is read only
Contract revision: spec/device/v1/tonolink-board.md@consumer-control-volume-v1
Status per end:
  iOS: implemented, signed build installed on the connected iPhone; runtime volume event not verified
  firmware: implemented, host tests and ESP-IDF build pass; not flashed to a board
  device: not verified; no Link USB serial device was present on this Mac or liguanghao Mac Studio
Commands → result:
  swift test --filter TonoLinkVolumeCommandTests → PASS (5)
  swift test --filter IPhoneAgentMCPTests → PASS (10)
  bash host_tests/run.sh --filter ag12 → PASS (6)
  bash host_tests/run.sh --filter ag05 → PASS (delegated suite)
  source ~/esp/esp-idf-v6.1/export.sh && idf.py build → PASS (IDF/Kconfig dependency warnings emitted)
  xcodebuild ... -scheme PhoneDSHProbe ... build → PASS
  xcrun devicectl device install app ... → PASS
  phone-spec → PASS; phone-cross-tree → PASS; phone-p0-conformance → FAIL (7 unrelated settings/session page-structure divergences)
Not verified: actual BLE Consumer Control delivery to this iPhone, volume up/down, old-firmware rejection on hardware.
Remaining risk: although OTA completed and capability status is present, a real volume step still needs verification on the phone.
```
