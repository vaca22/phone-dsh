# Native Android MCP endpoint

The optional `PhoneDSHConfiguration.nativeMCP` serves `/mcp/native` directly on
the existing authenticated origin. This additive HTTP endpoint changes no
binary channel frames. `PDSH_PHONE_MCP_URL` and `PDSH_PHONE_MCP_TOKEN` select
the existing official `mcp-phone` Worker plugin. Only this exact same-origin
path bypasses `/v1/http`; authorization and `X-PDSH-Idempotency-Key` are preserved.

The Worker attaches `X-PDSH-Idempotency-Key` to a JSON-RPC `tools/call` POST to the
phone endpoint (`PDSH_PHONE_MCP_URL`, or the same-origin `/mcp/native`) by exact
correlation: while the tool journal runs an `mcp__<server>__<tool>` call it registers that
call's key, tool name and canonical arguments (`exec-bridge` `call-context.ts`), and the
transport sends the key of the single matching registration. No match or several matches
fall back to the ambient tool-call context. The MCP SDK binds `fetch` when a transport is
built, which can precede `llm-bridge`'s activation, so `worker-entry` installs this keying
beneath every `fetch` binding before DSH boots (`mcp-journal-key.ts`); `llm-bridge`'s
routed transport applies the same rule. The key's meaning and the endpoint's checks are
unchanged.

The native environment has one owner. When the App runs the Bot runtime, the Bot
MCP listener is the Worker's only `phone` server and `PhoneDSHHost` must keep the
App-supplied Bot URL instead of replacing it with `/mcp/native`. The Bot server
forwards non-Bot `tools/list` and `tools/call` in-process to the same native MCP
handler, so the Worker sees both tool families under one namespace (see
[bot/v1/mcp-endpoint.md](../bot/v1/mcp-endpoint.md)). `/mcp/native` remains
available for direct callers. Only a native-only configuration (no App-supplied
`PDSH_PHONE_MCP_URL`) keeps the legacy `/mcp/native` Worker environment.

The native server accepts single JSON-RPC POST requests (`initialize`, `ping`,
`tools/list`, `tools/call`) and notifications (`initialized`, `cancelled`).
Notifications receive empty 202 responses; GET receives 405 (no SSE stream).
Tool calls are rejected with 503 when admission is closed; cancellation remains
available while draining. Host shutdown cancels and settles pending native work.

`PhoneDSHADB` serializes Android operations and uses a dedicated persistent
receipt store, rather than the exec ledger, keyed by the journal's opaque
`X-PDSH-Idempotency-Key` header. It synchronizes an intent before device dispatch,
replays completed results and refuses unresolved/evicted outcomes without
repeating side effects. The fingerprint binds tool name, arguments and native
endpoint. JSON-RPC IDs are used only for response correlation and cancellation.
The existing tool journal remains the Worker/session recovery authority.
This is crash recovery, not an atomic transaction with the Android device.

The HTTP golden example is [golden/native-mcp/tap.json](golden/native-mcp/tap.json).
Package management vectors are [golden/native-mcp/package-management.json](golden/native-mcp/package-management.json).
The tool catalog contains 26 Android tools. Application mutations use the
current foreground Android user unless an explicit numeric `userId` is supplied.
`android_install_apk` requires `source=workspace|device` and an absolute `apkPath`.
Workspace paths are confined to `/dsh/workspace`, with no symlinks; their required
SHA-256 must match the copied host bytes before any ADB connection is opened.
This content check rejects stale materialization without claiming a WAL barrier.
Workspace files are regular APK/ZIP files, 4 bytes–128 MiB. Their bytes bypass
JSON and stream as shell_v2 stdin into `pm install -S <size> -`, with ADB WRTE
backpressure, a final close-stdin frame and a 120-second execution deadline.
The JSON request remains limited to 16 KiB. Remote-device paths never resolve
against the iPhone workspace. Install, uninstall and clear require both a zero
exit status and the package manager's `Success` acknowledgement.
See [Android ADB](../../docs/android-adb.md) for limits and tools.

`android_connect` accepts `host` and optional integer `port` (default 5555),
validates and persists an enabled target before checking model/OS/display. It
works while control is disabled, is serialized with other operations and uses
the same receipt rules. Failed connection checks retain the saved target.

Host status: the iOS host (`Sources/PhoneDSHADB`) and the Android host
(`android/net/src/main/kotlin/com/phonedsh/adb`, mounted by `WebViewEngine` behind
the loopback token gate and D14 admission) serve the same 26 Android tools, the
same receipt rules and the same `initialize` answer. `tap.json`, `connect.json`
and `package-management.json` run through both servers. The Android host does
not advertise accelerator `adb`, so the Worker file transfer bridge below and
`file-transfer.json` are iOS-only; the tool descriptions and `instructions`
still name the iPhone and that bridge (open request in
[PC-20261108-android-adb-host](../../docs/protocol-changes/PC-20261108-android-adb-host.md)).

## Worker ADB file transfer bridge

The host advertises accelerator `adb`. Worker commands `adb push LOCAL REMOTE`
and `adb pull REMOTE [LOCAL]` dispatch `argv=["adb","--pdsh-v1",
"push"|"pull",absoluteLocalPath,absoluteAndroidPath]` over the normal
revision-fenced, journaled exec bridge. Pull stdout uses the existing SCP NDJSON
file/data/end records; the Worker owns committing the destination via VFS/WAL.
Push reads a regular non-symlink workspace file and sends bytes as shell_v2
stdin into a temporary sibling, then renames it only after the byte count check.
Workspace transfers are bounded by the host device file budget, at most
128 MiB/120 seconds. `/dsh/transfers/NAME` uses the separate native on-disk store
under Documents/adb-transfers, up to 1 GiB/3600 seconds. The native transfer route
streams FileHandle input/output in bounded shell_v2 frames and returns only a
completion message, without SCP records or VFS writes. Native pulls commit a
sibling temporary file by rename only after success and fsync; failure removes
the partial. Pull without a local operand defaults to the native store.
Only individual regular files are supported. No native writes to the derived
workspace and no automatic side-effect retries are permitted.

`adb stat /dsh/transfers/NAME` dispatches
`argv=["adb","--pdsh-v1","stat",absoluteLocalPath]`. Its stdout is JSON:
`{"status":"running","path":"..."}` while a native transfer owns the path,
or `{"status":"saved","path":"...","size":N}` for a committed regular file.
Missing files return nonzero. Status does not require an Android connection.
Concurrent native transfers to the same local path are rejected before dispatch.
The app sets the independent Worker shell backstop to 3600000 ms; caller
timeouts/abort signals remain authoritative. Normal action replies summarize
the result and location; raw logs and repeated failure explanations are omitted
unless requested.

## BLE tools (implemented on iOS)

The existing authenticated native MCP endpoint may additionally expose `ble_devices`, `ble_read`, `ble_alert`, `ble_link_tools`, `ble_link_call` and `ble_link_result`. These are additive tool names; older servers do not advertise them. Device scans, connection and per-tool grants require user action. The Link call and result semantics, bounded frames, per-connection grants and side-effect journal rules are defined by [BLE Link](../device/v1/ble-link.md). An Immediate Alert write has no execution acknowledgement and is reported as submitted, never applied. Uncertain effects must not be automatically replayed. Android tools remain available on the same endpoint.

Status: implemented by the iOS host (`Sources/PhoneDSHBLE/DeviceMCPServer.swift`), verified by
`golden/native-mcp/ble-devices.json`, `BLEDeviceMCPTests` and `DeviceMCPNativeRegressionTests`; the
Android host does not serve these tools. The composed server answers `tools/call` for `ble_*` names and
cancel notifications for its own BLE requests; every other request is delegated unchanged to the Android
tool server, so the Android tool names, order, descriptions, schemas, errors and loopback admission are
identical to an endpoint without BLE tools. The BLE tools are listed after the Android tools. `initialize`
reports `serverInfo` `{"name":"phone-dsh-devices","version":"1.1.0"}` with the same protocol versions and
capabilities; clients must not key behaviour on `serverInfo`. Device tasks and identity proof are not
exposed here (see [task delegation](../device/v1/task-delegation.md), `target`).

## iPhone agent tool (implemented on iOS)

The same endpoint may additionally list `iphone_agent_run`, after the BLE tools. It is
additive; older servers do not advertise it. Input is `{"task": string}` (1–8192 UTF-8
bytes, no other keys). It runs one UI-Venus task on this iPhone through a TonoLink
board ([tonolink-board.md](../device/v1/tonolink-board.md)) and returns the model's
answer, `finished`, the executed steps and seconds as JSON text. `isError` is true with
`status` `invalid_arguments`, `journal_key_required`, `idempotency_conflict`, `busy`,
`outcome_unknown`, `timeout_outcome_unknown` or `cancelled_outcome_unknown`, always with `automatic_retry: false`.

The call requires the existing idempotency key (`X-PDSH-Idempotency-Key`). A receipt keyed
by its SHA-256 is written before the phone is touched; a repeat of a finished key returns
the stored result, a different task under the same key is `idempotency_conflict`, and an
interrupted run is `outcome_unknown` and is never replayed. One task runs at a time.
`initialize` appends the tool's usage note to `instructions`; `serverInfo` is unchanged.
LED and other board tools stay on `ble_link_call` (BLE Link profile).

With the Bot runtime the Bot listener forwards `iphone_agent_run` like every other native
tool, to the same server instance (`PhoneNativeMCP.server`), so both paths share one receipt
store and one in-flight guard.

Status: implemented by `Sources/PhoneDSHVenus/IPhoneAgentMCPServer.swift`, verified by
`IPhoneAgentMCPTests`; the Android host does not serve it.
