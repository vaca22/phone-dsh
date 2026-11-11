# TonoLink board phone-control interface, v1

Status: `implemented` for the channels below, including consumer-control volume on both ends (real iPhone and board runtime evidence recorded 2026-11-11; old-firmware rejection is covered by firmware host tests only, no downgrade flash). Owner: P07.

A TonoLink board (`tonolink.m21r4`, firmware `agent_s3`) plugs into an iPhone's
USB-C port. It is the phone's **hands** (Bluetooth HID keyboard and absolute mouse)
and its **eyes** (an AirPlay receiver that the phone mirrors its screen to). Phone
DSH on the same phone runs the UI-Venus agent against it, with no computer.

The producer is the board firmware, outside this repository:
`tonolink-m21-r4-firmware` at `9ff0260` (`main/http/route_v1.c`, `main/link_tools.c`).
The consumer is `Sources/PhoneDSHBLE/TonoLink*.swift` plus
`Sources/PhoneDSHVenus/IPhoneAgent*.swift`. Android and HarmonyOS have no consumer.

## 1. Which channel carries what

| Need | Channel | Contract |
| --- | --- | --- |
| LED, Home HTTP | BLE Link Tools profile (`light.set`, `light.get`, `home.http`) | [ble-link.md](ble-link.md); reached by the agent through native MCP `ble_link_call` ([native-mcp.md](../../v1/native-mcp.md)) |
| Taps, swipes, typing, system media volume keys | Board HTTP over USB NCM (§2), emitted as BLE HID reports | this document |
| Screen | APV1 stream over USB NCM (§3) | this document |
| Pairing, console, BLE OTA (DEBUG) | TonoLink ctrl GATT service (§4) | this document |

Phone control does not use the Link Tools profile in v1: that profile excludes HID
([ble-link.md](ble-link.md)), and a screen frame cannot fit its 4096-byte RPC. Moving
HID actions into Link tools is a separate, not yet frozen change (phase 2); until it
is frozen, no end may send HID through Link.

## 2. Board HTTP over USB NCM

The board serves `http://192.168.247.1:8767` on the USB network it presents to
the phone (the phone takes `192.168.247.2`). Requests use `Connection: close`;
`auth` is `none` on these routes (the USB cable is the trust boundary).

| Route | Consumer use |
| --- | --- |
| `GET /v1/info` | `model`, `fw.version`, `features` (display only) |
| `GET /v1/phone/status` | `hid.{keyboard,absolute,input_mode}` must all be true before input; `airplay.{mirror_active,viewer_connected}` |
| `POST /v1/hid/enable {"on":true|false}` | Attaches or hides HID; the consumer waits ≥6 s before asking again after enabling |
| `POST /v1/hid/batch {"steps":[…],"wait":true}` | One gesture per batch; the consumer's HTTP timeout is 15 s plus the batch's planned duration |
| `POST /v1/usb {"action":"enable"}` | Brings NCM and the AirPlay receiver up (RAM-only on the board) |

A batch that times out or fails is reported to the model as "not executed: …" and
is **not retried**: the outcome on the phone is unknown. The agent re-observes the
screen before the next step. The one exception is `503` with `busy_exec`: the board's HID executor
was still finishing the previous batch and ran nothing of this one, so the consumer resends it
every 300 ms for up to about 3 s.

### 2.1 System media volume keys

`GET /v1/phone/status` adds `hid.consumer_control` (boolean): true only when the BLE HID service is
enabled, the encrypted iPhone connection has read the Report Map, and the Consumer Control input
report notification is subscribed. Older firmware omits this member; a consumer must treat the
missing member as unsupported firmware, not as a ready state.

`POST /v1/hid/batch` accepts one additional step shape:

```json
{"op":"consumer","key":"volume_up"}
```

`key` is exactly `volume_up` or `volume_down`; additional fields are rejected. The step emits one
Consumer Page (0x0C) HID input report press followed by its release, through the existing queue,
controller lease, backpressure, abort, and release-all behavior. Report ID is 4; the report payload
is one byte, with bit 0 asserting Volume Increment (Usage 0xE9) or bit 1 asserting Volume Decrement
(Usage 0xEA). A release report has both bits clear. These are the USB-IF Consumer Control usages;
they are relative media output volume keys, not a ringer/Silent-mode control.

One accepted step is one relative increment or decrement. There is no absolute-volume field or
percentage guarantee. Firmware success means the report was accepted by the HID queue, not that
the iPhone confirmed a volume change. If the call times out or is interrupted after submission,
the outcome is unknown and must not be retried. The existing `503 busy_exec` response remains safe
to retry because the batch executor did not accept the step.

Compatibility: old consumers and old operations work unchanged on new firmware. A new consumer
calling an old firmware with this step receives the old parser's `400 bad_request` before any HID
report is queued; the app must report that the Link firmware needs an update and must not fall back
to blind screen taps. No persisted data is affected. The board API remains v1 because this adds one
step to the existing closed operation set.

The exact step shape and invalid cases are in
[tonolink-hid-consumer-step.schema.json](schema/tonolink-hid-consumer-step.schema.json); the shared
request/report vectors are in [tonolink-hid-consumer-control.json](golden/tonolink-hid-consumer-control.json).

### 2.2 Return control to the iPhone

`POST /v1/hid/enable {"on":false}` is the existing desired-state operation, not a new route.
It releases all held reports and hides the HID service. After a UI-Venus task or a local
Consumer Control volume command, the iOS consumer must call it before returning control to
the person. Hiding the external keyboard lets iOS present its software keyboard the next time
the person focuses a text field. The next board-controlled task calls `{"on":true}` through
`ensureHID`, then waits for HID subscriptions before sending input. The Control GATT
connection and wake-word audio path remain separate from the HID service.

The consumer treats this as best-effort cleanup: a detach error is logged but does not replace
the already-observed task or volume outcome. This operation sets a state and is safe to repeat;
it does not replay the previous key or pointer action. The request body and API version are
unchanged. Shared lifecycle requests are recorded in
[tonolink-hid-consumer-control.json](golden/tonolink-hid-consumer-control.json).

## 3. Screen stream (APV1)

The phone keeps one TCP connection to `192.168.247.1:8769`. The board sends the
mirrored screen as APV1 records (H.264 or HEVC), which `TonoLinkScreen` decodes in
software so it keeps working with the app in the background. iOS sends a keyframe
only when mirroring starts; the board caches the last GOP and replays it to a new
viewer, so the consumer may connect lazily. Each agent step observes a frame
decoded after the previous step's frame (`snapshot(newerThan:)`), never a stale one.

## 4. Ctrl GATT service

Service `5DBD66EC-9E78-42D4-854F-DE5EBBFFA363`: `cmd` `2D0EA61C-DCAC-48A2-816C-8DFF5022E6DE`
(write), `status` `4DF6DE7E-42FA-4F5E-92DE-BAD8AC1DE887` (notify, requires
encryption), optional `audio` `7A1C9E52-3B6D-4F08-9C2E-5D4B8A61F0A3`. Console lines
and BLE OTA framing are defined by `TonoLinkBLEDebugProtocol.swift` and
`TonoLinkUSBOTAProtocol.swift`, matching the firmware's `pa_ctrl_core.c`.

### 4.2 GATT database changes

The firmware keeps a persistent local GATT layout revision. Any addition, removal, or
reordering of a service or characteristic increments that revision. When the revision
differs from the saved value, the board emits the standard Generic Attribute Service
Service Changed indication for handles `0x0001`–`0xFFFF` on the next encrypted BLE
connection, then saves the running revision. A bonded iPhone must rediscover the GATT
database before its next control write. This also applies after OTA rollback: a version
change in either direction triggers another Service Changed indication. This revision is
local firmware state; it adds no HTTP field, BLE command, or alternate control path.

The consumer-control report in §2.1 changes the HID service layout. The board firmware
therefore moves its local GATT layout revision from 4 to 5. Existing control-service UUIDs,
permissions, and command encoding remain unchanged.

### 4.1 Voice turn (board wake word → phone)

Producer: `tonolink-m21-r4-firmware` at `4763811` (`main/wake.c`, `main/voice.c`,
`main/ctrl_svc.c`), present when `/v1/info` `features` has the `wake` bit. Consumer:
`Sources/PhoneDSHBLE/TonoLinkVoice.swift` and the app's `TonoLinkVoiceHost.swift`.
Shared cases: [golden/tonolink-voice.json](golden/tonolink-voice.json), the judge where
this text could be read two ways.

| Direction | Bytes | Meaning |
| --- | --- | --- |
| `status` notify | `ev wake n=<u32> up=<u32>` | The board heard 你好小智. `n` counts hits from 1; `n=0` is the console's simulated wake. A new wake cancels the board's current recording. |
| `cmd` write | `<seq> listen <id>` (decimal, `id` 1…2³²−1) | Start one recording turn, numbered `id`. Answer `ack <seq> ok`; `ack <seq> err …` means no turn starts (nothing is recorded). |
| `audio` notify (`…F0A3`) | `[seq u16 LE][flags u8][id & 0xFF][Opus]` | One packet per 20 ms frame: Opus 16 kHz mono, VBR, DTX off, 0…160 bytes. `flags` bit0 first packet, bit1 last packet (the last may carry no Opus). `seq` restarts at 0 per turn. |
| `status` notify | `ev listen_end n=<id> frames=<u32> reason=vad\|no_speech\|max\|cancel\|error` | The turn ended (800 ms silence after speech, 5 s without speech, 12 s cap, a new wake, or an encoder/mic failure). |

Unknown `key=value` members after the known ones are ignored; any other `ev …` line, an
`ev wake`/`ev listen_end` missing a member or with a non-decimal value, and an unknown
`reason` are **not** events (ignored). An audio packet shorter than 4 bytes, longer than
164 bytes, without Opus and without the last flag, or whose id byte is not the low 8 bits of
the current turn's id is dropped.

Consumer rules: subscribe `audio` only while voice is enabled. The phone speaks 「我在」
**before** writing `listen` (the board would record it), and writes `listen` as soon as 「我在」
has played, not after the cloud ASR is ready. Each packet's Opus body is
forwarded unchanged and in order to the cloud ASR ([cloud-voice.md](../../v1/cloud-voice.md));
the 4-byte header never leaves the phone. A `seq` gap is counted, not filled. The turn's
audio ends at the last-flag packet or `ev listen_end`, whichever comes first. A wake while
a turn is recording, recognising or speaking stops that turn (its ASR is cancelled, its
playback stopped) and starts a new one. The phone keeps this link while in the background: a
restorable CoreBluetooth central with a parked reconnect, so `ev wake` wakes a suspended app
(`spec/platform/whitelist.json` `platform.tonolink-voice-background-wake`). The firmware is unchanged by
this registration.

## 5. DEBUG relay (developer builds only)

DEBUG builds can serve `TonoLinkRelay` on the phone's Wi-Fi at `:8780` and forward
`:8767` and `:8769`, so a computer can reach the board through the phone. The relay
has **no authentication**: anyone on that Wi-Fi can drive the phone and flash the
board while it is on. It is compiled only under `#if DEBUG`, listens only after a
user (or the `PDSH_TONOLINK_USB_OTA=relay` launch variable) turns it on, and is never
part of a release build.

DEBUG builds also answer developer test routes on the same relay, each mirroring a user action
or a read-only view, so a device check is one `curl` instead of a rebuild and UI taps:
`POST /debug/chat` (send one message, as the composer does), `GET /debug/transcript?n=`,
`GET /debug/native-mcp` (the last 20 native MCP requests: method, tool, whether the journal key
arrived, arguments, result), `GET /debug/ble`, `POST /debug/ble/scan` and
`POST /debug/ble/connect?name=` (the Bluetooth page's scan and 连接 buttons), `GET /debug/voice`
(the voice turn's state and last turn), `POST /debug/voice/wake` (as if the board heard 你好小智),
`POST /debug/voice/say` (speak a text) and `POST /debug/voice/opus[?chat=1]` (run recognition, and
optionally the chat turn, on `[len u16 LE][Opus]…` packets as if the board sent them).

## 6. Agent

`iphone_agent_run` ([native-mcp.md](../../v1/native-mcp.md)) runs one UI-Venus task:
screen in, one action out, executed through §2, up to the step limit. The model
endpoint, model name and key come from the app's UI-Venus settings (key in the
Keychain service `dev.phone-dsh.ui-venus`, never in preferences). The task result is
the model's assessment, not proof; `finished=false` must not be reported as success.

The agent does not trust its own actions blindly. Before each step it compares the new
screenshot with the previous one (36×52 grayscale, mean difference below 2/255 = unchanged);
when a tap, swipe, Home, launch, Enter or typing left the screen unchanged, the model is told
so. A run that repeats the same action three times, or goes back and forth between two actions
twice, gets one nudge, and that repeat is not performed (finish if the screen already shows
the answer, otherwise try something else). If it repeats itself again, the run stops with
`finished=false` and an answer starting 「卡住了」, instead of using every step. LaunchApp presses
Return a second time when Spotlight is still on screen, because the Pinyin keyboard's candidate
bar took the first one. For a read or check task the agent answers as soon as the screen shows the
information and never navigates away first; the tool's usage note tells the calling model to
describe what to report rather than "then go back" steps, and not to restart a task that ended
「卡住了」. Home taps 主屏幕 only after the AssistiveTouch menu is seen to open (the screen changes
by at least 6/255); otherwise it retries once, then looks for the button, and finally fails with a hint.
It never taps blind, which used to open whatever app sat under the menu item. A system permission
or privacy prompt ends the run with `CallUser`: the agent never chooses for the user.
