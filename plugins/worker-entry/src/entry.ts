// SPDX-License-Identifier: MIT
/**
 * Worker entry for DSH on the phone: boot the unmodified runtime host over a
 * packed image, mirror its VFS into the ordered channel, feed the captured
 * webserver listener from remote API frames, and publish the host control
 * globals the DSH plugins read.
 *
 * The entry is driven by the page's opening `{t:'init', image, overlays,
 * xl:{channelURL, token, env, fence}}` message. It loads the pinned runtime
 * through `./runtime-binding.ts` at that point, so this module's pure logic
 * (sink encoding, API synthesis, console mirror) is testable without the DSH
 * checkout.
 *
 * Boot order:
 *  1. read the init frame, create the channel and expose it before DSH boots;
 *  2. connect the ordered WebSocket and exchange HELLO (D1, D3);
 *  3. create the runtime host and start the tree;
 *  4. install the single path authority: wrap the mounted VFS, seed the
 *     namespace roots, probe both volatile spellings and apply the exec read
 *     policy (`namespace-boot.ts`, D4/D15);
 *  5. subscribe the VFS sink and wrap `flush()` to wait for a level-1 ack;
 *  6. serve API_REQ frames through the captured request listener;
 *  7. forward console lines, mirror LIFECYCLE/FENCE and post `pdsh-ready`.
 * @module @phone-dsh/dsh-worker-entry
 */
// First, before the entry graph evaluates: the preludes below fill the platform
// gaps DSH 0.2.1's lowered code and its npm dependencies hit. All are
// feature-detected and idempotent.
//   jsc-compat.ts          Symbol.dispose / ReadableStream async iteration,
//                          Promise.withResolvers, Node's `global` (WKWebView)
//   es2023-compat.ts       Array/String ES2023 helpers (Chromium <110-111)
//   abort-signal-compat.ts AbortSignal.any (Chromium <116)
//   scheduler-compat.ts    scheduler.yield (Chromium <129)
import './jsc-compat.ts'
import './es2023-compat.ts'
import './abort-signal-compat.ts'
import './scheduler-compat.ts'
import {
  acceleratorsFromCaps,
  canonicalStringify, decodeApiAbort, decodeApiEnd, decodeApiRequest, decodeUtf8, decodeVfsAck,
  decodeVfsResync, encodeApiAbort, encodeApiEnd, encodeApiResponse, encodeUtf8, encodeVfsMutation,
  DEFAULT_SINGLE_FILE_LIMIT, FrameType, MAX_MUTATION_DATA, MAX_SINGLE_FILE_LIMIT, VfsOp,
  parseVfsRefusedDiagnostic, VfsRefusedError,
  type ChannelClient, type Fence, type FencePayload, type Frame, type LifecyclePayload,
  type VfsRefusedDiagnostic,
} from '../../channel/src/index.ts'
import {
  resolveDurabilityAckTimeoutMs, withDurabilityAckTimeout,
} from '../../channel/src/ack-tracker.ts'
import {
  WebSocketChannelClient,
  type WebSocketChannelOptions,
  type WebSocketLike,
} from '../../channel/src/ws-client.ts'
import {
  WORKER_VFS_NAMESPACE,
  combineWorkerToolboxes,
  configureSingleFileLimit,
  getWorkerToolbox,
  resolveVfsFlowControlTimeoutMs,
  setWorkerToolbox,
  singleFileLimitFromEnvironment,
  VfsWriteOutcomes,
} from '../../wasi-toolbox/src/index.ts'
import { REMOTE_MUX_PATH, WorkerEntryMuxBridge } from './mux-bridge.ts'
import {
  VfsRefusalError, vfsRefusalHint, vfsRefusalRecordFromChannelError,
  vfsRefusalRecordFromDiagnostic, vfsRefusalRecordFromError,
  vfsRefusalConsoleText, vfsRefusedPayload,
  type VfsRefusalRecord,
} from './refusal.ts'
import {
  createTunnelMuxSessionFactory, createTunnelPort,
  type WorkerEntryTunnelPort,
} from './mux-tunnel.ts'
import {
  bootFailureError,
  bootTransportSecretValues,
  redactBootFailureDetail,
  type BootTransportFrame,
} from './boot-redaction.ts'
import { installModelRouteGuard, modelRouteOf } from './model-route.ts'
import { installPhoneMcpKeyFetch } from './mcp-journal-key.ts'
import { installNamespaceAuthority, type NamespaceRuntimeHooks } from './namespace-boot.ts'
import { createPhoneProfileOverlay } from './profile-overlay.ts'
import {
  buildCapabilityManifest,
  publishCapabilityManifest,
  workerCommandSurface,
  workerUnavailableCommands,
  PHONE_V1_LIMITS,
  type CapabilityLimits,
} from './capabilities.ts'
import { pythonToolboxLifecycle, readPythonModuleProbe } from './python-toolbox.ts'
import type { PythonToolboxOptions, PythonToolboxWiring } from './python-toolbox.ts'
import { jqToolboxLifecycle } from './jq-toolbox.ts'
import type { JqToolboxOptions, JqToolboxWiring } from './jq-toolbox.ts'
import { probeUbuntuHost } from './ubuntu-probe.ts'
import { setUbuntuCapability } from '../../shell-ext/src/index.ts'

export type { VfsRefusalRecord, VfsResourceErrorCode } from './refusal.ts'
export {
  VfsRefusalError, isVfsRefusalError, vfsRefusalRecordFromError,
  vfsRefusalRecordFromDiagnostic, vfsRefusalRecordFromChannelError, vfsRefusalReason,
  vfsRefusalHint, vfsRefusalTrailer, vfsRefusalMessage, vfsRefusalConsoleText, vfsRefusedPayload,
} from './refusal.ts'

/** Largest body a single API_RES chunk may carry (channel.md §3.7). */
const MAX_API_RESPONSE_CHUNK = 4 * 1024 * 1024
/** Host header synthesized for the captured webserver listener. */
const SYNTHETIC_HOST = '127.0.0.1'
/**
 * D22 authentication marker: the host already verified the ordered channel's
 * bearer, so the Worker entry stamps every forwarded request with this header
 * after removing any inbound copy. Only this module may set it.
 */
export const CHANNEL_AUTHENTICATED_HEADER = 'x-pdsh-channel-authenticated'
/**
 * Worker global through which an in-Worker execution surface flushes the VFS
 * sink at a command boundary (G2-FIX-61). `worker-entry` installs it after
 * {@link installSink}; `subprocess-xl` awaits it before it reports a Worker
 * shell command as completed, so a successful `bash -c` has its mutations in
 * the host WAL exactly like a WASI dispatch that flushed its backend.
 */
export const WORKER_VFS_FLUSH_GLOBAL = '__PDSH_VFS_FLUSH__'
/**
 * Worker global holding the bounded recent `vfs.flush()` hop samples
 * (G2-FIX-83). Each sample pairs the emitted mseq with the flush-start and
 * ack-arrival timestamps, so an artifact that already carries the host's step
 * `at_ms` values can tell an event-driven ack wait from a timer cadence.
 */
export const VFS_FLUSH_TIMINGS_GLOBAL = '__PDSH_VFS_FLUSH_TIMINGS__'
/** Most recent flush hop samples retained on the Worker global. */
const VFS_FLUSH_TIMING_SAMPLES = 64
/**
 * A level-1 VFS flush wait at or above this bound is a boundary-cadence defect:
 * the ack is due right after the 2 ms group-commit write (D8), never from a
 * timer. The value is reported on the CONSOLE stream for artifact reconciliation
 * and is the same 1 s gate the G2-FIX-83 regression test applies.
 */
export const SLOW_VFS_FLUSH_MILLISECONDS = 1_000
/** Console lines buffered while the channel is still connecting. */
const CONSOLE_BUFFER_LINES = 256
/** Longest console line forwarded in one CONSOLE frame. */
const CONSOLE_LINE_LIMIT = 32 * 1024

// ---------------------------------------------------------------- public types

/** One mutation as the runtime's `MemoryVfs` publishes it (storage/types). */
export type WorkerEntryMutation =
  | {
    readonly kind: 'write'
    readonly path: string
    readonly bytes: Uint8Array
    readonly mode: number
    readonly entryChanged: boolean
    readonly appendedFrom?: number
  }
  | { readonly kind: 'mkdir'; readonly path: string; readonly mode: number }
  | { readonly kind: 'remove'; readonly path: string }
  | { readonly kind: 'chmod'; readonly path: string; readonly mode: number }

/** Structural face of the runtime's `MemoryVfs` that the entry uses. */
export interface WorkerEntryVfs {
  subscribe(listener: (mutation: WorkerEntryMutation) => void): () => void
  flush(): Promise<void>
  readFileSync?(path: string, options?: unknown): string | Uint8Array
  statSync?(path: string, options?: unknown): { readonly mode: number; isFile(): boolean }
  /**
   * The VFS's own promise face (`MemoryVfs.promises`, instance-bound).
   *
   * The Worker's `node:fs/promises` module proxy reads the module-global
   * `storage/active.ts` slot; this face is pinned to *this* filesystem object.
   * The WASI toolbox binds to it so a rebuilt Worker's `python3` follows the
   * host that published it instead of whatever the global slot holds
   * (G2-FIX-54).
   */
  promises?: HostVfsPromises
}

/**
 * Structural `node:fs/promises` face the runtime VFS exposes. The subset is
 * what `NodeFsBackend` in `@phone-dsh/dsh-wasi-toolbox` calls; the runtime's
 * `Vfs.promises` satisfies it.
 */
export interface HostVfsPromises {
  stat(path: string): Promise<unknown>
  lstat?(path: string): Promise<unknown>
  readdir(path: string, options: { withFileTypes: true }): Promise<readonly (string | unknown)[]>
  readFile(path: string): Promise<Uint8Array | string>
  writeFile(path: string, data: Uint8Array, options?: { readonly mode?: number }): Promise<void>
  mkdir(path: string, options?: { readonly recursive?: boolean; readonly mode?: number }): Promise<unknown>
  unlink(path: string): Promise<void>
  rmdir?(path: string): Promise<void>
  rm?(path: string, options?: { readonly recursive?: boolean; readonly force?: boolean }): Promise<void>
  rename(from: string, to: string): Promise<void>
  truncate(path: string, length?: number): Promise<void>
  chmod?(path: string, mode: number): Promise<void>
}

/** The channel face the entry uses; `ChannelClient` plus an optional transport hook. */
export interface WorkerEntryChannel extends ChannelClient {
  /** Called when an established transport is lost (before a reconnect). */
  onTransportLost?(handler: () => void): () => void
}

/** Request listener captured by the runtime's fake `node:http`. */
export type WorkerEntryRequestListener = (req: unknown, res: unknown) => void

/** Response sink shape of the runtime's `transport/synthetic-http.ts`. */
export interface WorkerEntryResponseSink {
  head(status: number, headers: Record<string, string>): void
  chunk(bytes: Uint8Array): void
  end(payload?: { status: number; headers: Record<string, string>; body?: Uint8Array | undefined }): void
  fail(message: string): void
}

/** One request fed to the captured listener. */
export interface WorkerEntrySyntheticRequest {
  readonly method: string
  readonly path: string
  readonly headers: Record<string, string>
  readonly body: Uint8Array
}

/** The request/response pair a captured listener consumes. */
export interface WorkerEntrySyntheticExchange {
  readonly req: unknown
  readonly res: unknown
  readonly aborted: boolean
  abort(): void
}

/** Build the IncomingMessage/ServerResponse pair for one API_REQ. */
export type WorkerEntrySynthesize = (
  request: WorkerEntrySyntheticRequest,
  sink: WorkerEntryResponseSink,
) => WorkerEntrySyntheticExchange

/** Host handle the entry needs from the runtime. */
export interface PhoneWorkerHostLike {
  handleMessage(data: unknown): void
  start(): Promise<void>
  stop?(): Promise<void>
  readonly vfs: WorkerEntryVfs | undefined
}

/** Inputs passed to the runtime host factory. */
export interface PhoneWorkerHostOptions {
  readonly image: string
  /** Ordered overlays applied after the base image; bytes or fetchable URLs. */
  readonly overlays: readonly (string | Uint8Array)[]
  readonly env?: Readonly<Record<string, string>> | undefined
  /**
   * Tunnel port the runtime host posts page-facing frames through. The entry
   * also observes the outbound stream frames to serve `/api/remote.mux`.
   */
  readonly channel?: WorkerEntryTunnelPort | undefined
}

/**
 * Injection seam for tests and for a deployment that supplies its own host.
 * Production resolves this from the pinned DSH checkout.
 */
export interface PhoneWorkerRuntime extends NamespaceRuntimeHooks {
  createHost(options: PhoneWorkerHostOptions): PhoneWorkerHostLike
  whenRequestListener(): Promise<WorkerEntryRequestListener>
  createChannel?(options: WebSocketChannelOptions): WorkerEntryChannel
  synthesize?: WorkerEntrySynthesize | undefined
  /**
   * Repair the pinned runtime's encoding-ignoring string writes on the shared
   * `node:fs` promise face (see `write-encoding.ts`). Optional so a pure test
   * runtime keeps its own filesystem behavior.
   */
  installByteFaithfulWrites?(): () => void
  /**
   * Add the pinned runtime's missing numeric open capability (`O_EXCL`) to its
   * virtual `fs.constants` table before the tree boots
   * (see `numeric-open-flags.ts`). Optional for pure test runtimes.
   */
  installNumericOpenFlags?(): () => void
}

/** Construction inputs the page supplies in its init frame. */
export interface PhoneWorkerOptions {
  /** Packed image URL (gzip); `imageURL` is the newer spelling. */
  readonly image?: string
  readonly imageURL?: string
  /** Ordered overlays applied after the base image. */
  readonly overlays?: readonly string[]
  readonly overlayURLs?: readonly string[]
  /** Loopback channel URL; `channelURL` is the newer spelling. */
  readonly channelUrl?: string
  readonly channelURL?: string
  /** Per-start loopback token. */
  readonly token?: string
  /** Environment passed to the runtime process shim. */
  readonly env?: Readonly<Record<string, string>>
  /**
   * Egress host allow-list the App passed in the init message (`xl.egressAllow`).
   * It is model-facing truth only: `/v1/http` still enforces the list on the
   * host side (W1-GATEWAY), and the Worker never opens a socket itself.
   */
  readonly egressAllow?: readonly string[]
  /** Execution authority this worker was given. */
  readonly fence?: Fence
  /** 32 lowercase hex characters; generated per process when absent. */
  readonly bootId?: string
  /** Host session incarnation. */
  readonly sessionEpoch?: bigint | number
  /** Highest mseq this worker process already assigned. */
  readonly lastMseq?: bigint
  /** In-memory transport factory for tests; the global WebSocket otherwise. */
  readonly socketFactory?: (url: string) => WebSocketLike
  /** Test/deployment runtime override; the pinned DSH checkout otherwise. */
  readonly runtime?: PhoneWorkerRuntime
  /**
   * VFS sink policy from the host's budget table (PLAN §2.5). `maxFileBytes`
   * is the per-device single-file bound; the sink clamps it to the 256 MiB
   * host maximum. Omitted, the host environment's value then the 128 MiB
   * 8 GiB-tier default applies (`spec/v1/budgets.md:104`).
   */
  readonly limits?: VfsSinkLimits
  /**
   * Python-on-WASI wiring seams. The production boot reads the image's
   * `/dsh/bin/python` artifacts and publishes `python3`; a test or a host with
   * its own tool worker may inject the VFS backend and worker factory here.
   * `false` disables the wiring for an image that deliberately has no python.
   */
  readonly python?: Omit<PythonToolboxOptions, 'vfs'> | false
  /**
   * jq-on-WASI wiring seams. The production boot reads `/dsh/bin/jq/jq.wasm`
   * and registers `jq-wasi`; `false` keeps the shell on its fail-loud shim.
   */
  readonly jq?: Omit<JqToolboxOptions, 'vfs'> | false
  /** Page port; the worker global scope's `postMessage` otherwise. */
  readonly pagePost?: (message: unknown) => void
}

/** The running phone worker. */
export interface PhoneWorkerHandle {
  readonly channel: WorkerEntryChannel
  readonly host: PhoneWorkerHostLike
  readonly vfs: WorkerEntryVfs
  /**
   * The published python3 runtime, when the image carried the CPython
   * artifacts. `stop()` disposes it and unpublishes the toolbox.
   */
  readonly python: PythonToolboxWiring | undefined
  /** The published jq WASI engine, when the image carried `jq.wasm`. */
  readonly jq: JqToolboxWiring | undefined
  /**
   * Ordered-channel outcome tracker shared by the sink and the WASI VFS
   * backends for this boot. Exposed for diagnostics and component tests.
   */
  readonly writeOutcomes: VfsWriteOutcomes
  stop(): Promise<void>
}

/** Options for {@link serveApiRequests}. */
export interface ServeApiRequestsOptions {
  /** Injected IncomingMessage/ServerResponse synthesis; the runtime helper otherwise. */
  readonly synthesize?: WorkerEntrySynthesize | undefined
  /** Worker-side bridge for DSH's `/api/remote.mux` upgrade endpoint (D23). */
  readonly mux?: WorkerEntryMuxBridge | undefined
}

/**
 * Event target carrying `pdsh-lifecycle` and `pdsh-fence` events. Also installed as
 * `globalThis.__PDSH_EVENTS__` so plugins that only see worker globals can listen.
 */
export const workerEvents = new EventTarget()

/** Console forwarding handle. */
export interface ConsoleForwarder {
  /** Send buffered lines now, in order; stops at the first transport failure. */
  flush(): void
  /** Restore the original console methods. */
  dispose(): void
}

// ------------------------------------------------------------------- entry API

/**
 * Exact init values a failed `startPhoneWorker` may repeat in its reason.
 *
 * Used by the outer catch before `normalizeOptions` produced the fully parsed
 * frame, so every field is read defensively from the caller's options.
 * @param options - page init values passed to the boot.
 * @returns the shape {@link bootTransportSecretValues} consumes.
 */
function bootOptionsSecretFrame(options: PhoneWorkerOptions): BootTransportFrame {
  return {
    image: options.imageURL ?? options.image,
    overlays: options.overlayURLs ?? options.overlays,
    xl: {
      channelURL: options.channelURL ?? options.channelUrl,
      token: options.token,
      env: options.env,
      fence: options.fence,
      bootId: options.bootId,
      sessionEpoch: options.sessionEpoch?.toString(),
      egressAllow: options.egressAllow,
    },
  }
}

/**
 * Boot the phone worker: channel, DSH host, VFS sink and API bridge.
 *
 * Every failure, including one before the host object exists, is posted as a
 * bounded, redacted `pdsh-error`. The page needs that frame because without a
 * host there is no `TunnelServer` to answer `/__boot__`.
 * @param options - Image, overlay, channel and fence inputs.
 * @returns The running handle after the tree is active and `pdsh-ready` was posted.
 */
export async function startPhoneWorker(options: PhoneWorkerOptions): Promise<PhoneWorkerHandle> {
  try {
    return await startPhoneWorkerInternal(options)
  } catch (error) {
    if (typeof error === 'object' && error !== null && reportedPageErrors.has(error)) throw error
    const failure = bootFailureError(
      error,
      bootTransportSecretValues(bootOptionsSecretFrame(options)),
    )
    reportPageError(failure, options.pagePost ?? defaultPagePost)
    throw failure
  }
}

/** Inner boot body; the exported wrapper owns the pre-host failure report. */
async function startPhoneWorkerInternal(options: PhoneWorkerOptions): Promise<PhoneWorkerHandle> {
  ensurePageMessagePump()
  const normalized = normalizeOptions(options)
  // The tier's hot-instance ceiling reaches the tool workers and the
  // capability manifest; the single-file budget keeps its own env.
  const hotInstanceBytes = hotInstanceBytesFromEnvironment(normalized.env)
  const vfsLimits = vfsLimitsFromEnvironment(normalized.env)
  // The WASI VFS backends read the process-wide single-file budget rather than
  // the sink policy object; publish the same host value there before any host
  // code can write (budgets.md §4, channel.md §6).
  configureSingleFileLimit(Math.min(
    normalized.limits.maxFileBytes ?? DEFAULT_SINGLE_FILE_LIMIT,
    MAX_SINGLE_FILE_LIMIT,
  ))
  const pagePost = normalized.pagePost
  // Hand the loopback coordinates to the plugins before DSH boots: the Worker
  // subprocess-xl/exec-bridge fetch route and llm-bridge's /v1/http route both
  // read these from the process environment, and exec-bridge's transport
  // selection uses PDSH_CHANNEL_URL/PDSH_CHANNEL_TOKEN to pick the ordered channel.
  const channelEnv = channelEnvironment(normalized)
  applyProcessEnvironment(channelEnv)
  const runtime = normalized.runtime ?? await loadDefaultRuntime()
  const channelOptions: WebSocketChannelOptions = {
    url: normalized.channelURL,
    bootId: normalized.bootId,
    sessionEpoch: normalized.sessionEpoch,
    fence: normalized.fence,
    lastMseq: normalized.lastMseq,
    ...normalized.token === undefined ? {} : { token: normalized.token },
    ...normalized.socketFactory === undefined ? {} : { createSocket: normalized.socketFactory },
    ...normalized.limits.ackTimeoutMs === undefined
      ? {}
      : { ackTimeoutMs: normalized.limits.ackTimeoutMs },
  }
  const channel = runtime.createChannel?.(channelOptions) ?? new WebSocketChannelClient(channelOptions)
  const globals = globalThis as {
    __PDSH_CHANNEL__?: ChannelClient
    __PDSH_FENCE__?: FencePayload
    __PDSH_LIFECYCLE__?: LifecyclePayload
  }
  globals.__PDSH_CHANNEL__ = channel
  globals.__PDSH_FENCE__ = { fence: normalized.fence, admission: 'open' }
  globals.__PDSH_LIFECYCLE__ = { state: 'run', budget: 0n, admission: 'open', reason: 'boot' }

  const disposers: (() => void)[] = []
  // Before DSH boots: the MCP SDK binds `fetch` when a transport is built, which
  // can precede llm-bridge's activation, so the journal key is attached beneath
  // every binding (mcp-journal-key.ts, native-mcp.md).
  disposers.push(installPhoneMcpKeyFetch())
  const consoleForwarder = installConsoleForwarding(channel)
  disposers.push(installChannelGlobals(channel))
  // The pinned runtime's `node:fs` bridge stores the UTF-8 encoding of any
  // string write and ignores Node's declared string encodings (upstream
  // contract gap). The Worker shell supplies byte encodings — just-bash
  // redirections write a latin1-shaped ByteString with `{encoding: 'binary'}`
  // — so install the byte-faithful write shim on the same shared promise face
  // before the tree boots and before the exec policy wraps it. Without this,
  // non-ASCII and binary bytes are double-encoded before the sink sees them
  // (G2-FIX-80; the persistence chain then faithfully persists the damage).
  const disposeByteFaithfulWrites = runtime.installByteFaithfulWrites?.()
  if (disposeByteFaithfulWrites !== undefined) disposers.push(disposeByteFaithfulWrites)
  // The pinned runtime's virtual `fs.constants` omits O_EXCL, so DSH's
  // numeric O_CREAT|O_EXCL|O_WRONLY staging open became NaN and failed with
  // ATTACHMENT_WRITE_FAILED. Add the virtual bit before the tree boots; the
  // namespace wrapper installs the matching interpreter on the mounted VFS.
  const disposeNumericOpenFlags = runtime.installNumericOpenFlags?.()
  if (disposeNumericOpenFlags !== undefined) disposers.push(disposeNumericOpenFlags)
  const tunnelPort = createTunnelPort(pagePost)
  let hostStarted = false
  let bootHost: PhoneWorkerHostLike | undefined
  let pythonWiring: PythonToolboxWiring | undefined
  let jqWiring: JqToolboxWiring | undefined
  try {
    await channel.connect()
    consoleForwarder.flush()
    // Design §4.3: the Agent-facing `ubuntu` command exists only when the host
    // answered this probe. The answer goes through `globalThis` because the
    // image's plugin bundle builds the shell table from its own copy of
    // shell-ext; a module-local value would not cross that boundary.
    //
    // A failed probe is not a boot failure: the command simply stays
    // unregistered and the shell answers `ubuntu: command not found` / 127.
    const ubuntu = await probeUbuntuHost(channel)
    setUbuntuCapability(ubuntu)
    disposers.push(() => setUbuntuCapability(undefined))

    // The packed image records the `web` profile template, which names the
    // browser bundle the image deliberately omits. The stub manifest keeps
    // app-boot from reporting that bundle as skipped on every boot; deployment
    // overlays are applied after it and therefore still win.
    const profileOverlay = await createPhoneProfileOverlay()
    const host = runtime.createHost({
      image: normalized.imageURL,
      overlays: [profileOverlay, ...normalized.overlayURLs],
      env: { ...normalized.env, ...channelEnv },
      channel: tunnelPort,
    })
    bootHost = host
    activeHost = host
    role = 'host'
    for (const pending of pendingPageFrames.splice(0)) host.handleMessage(pending)
    await host.start()
    hostStarted = true
    // P27: arm the model-route refusal **after** the tree booted. `llm-bridge`
    // may replace `globalThis.fetch` with its own transport while the plugins
    // activate (`plugins/llm-bridge/src/index.ts`), and a guard installed before
    // it would wrap the transport that is about to be replaced. The guard only
    // fires when the host declared `PDSH_MODEL_ROUTE=none`: a launch with a
    // route keeps the platform fetch untouched (the disposer is a no-op), and
    // an undeclared route is not refused by omission.
    const modelRoute = modelRouteOf(normalized.env)
    if (modelRoute.notice !== undefined) console.warn(modelRoute.notice)
    disposers.push(installModelRouteGuard({ decision: modelRoute }))
    if (host.vfs === undefined) throw new Error('worker entry: the DSH host started without a VFS')
    // G2-D05/G2-D01: install the single path authority before the first
    // API_REQ. Every node:fs caller — DSH tools, the Worker shell, the WASI
    // backends and git — then resolves through one table: /tmp and /dsh/tmp
    // are one volatile store, and the exec read policy covers session state.
    // The root probe is loud; the upstream sandbox promises both spellings.
    const authority = installNamespaceAuthority({ vfs: host.vfs, runtime })
    disposers.push(authority.dispose)
    const vfs = authority.vfs
    const mux = new WorkerEntryMuxBridge({
      createSession: createTunnelMuxSessionFactory({
        handleHostMessage: (message) => { host.handleMessage(message) },
        tunnel: tunnelPort,
      }),
    })
    // One outcome tracker per boot: the sink publishes the mseq and the ack or
    // refusal into it, and the WASI VFS backend awaits it inside the guest's
    // write syscall (G2-FIX-103). D3's window is validated here.
    const writeOutcomes = new VfsWriteOutcomes({
      timeoutMs: resolveVfsFlowControlTimeoutMs(normalized.limits.flowControlTimeoutMs),
    })
    // G2-FIX-83: retain the flush hop samples on a bounded global. An artifact
    // that already carries the host step `at_ms` values can compare them with
    // the Worker's ack-arrival timestamps; the 1 s slow-boundary line goes to
    // the CONSOLE stream, so no extra artifact format is needed.
    const flushTimings: VfsFlushTiming[] = []
    ;(globalThis as { __PDSH_VFS_FLUSH_TIMINGS__?: VfsFlushTiming[] })
      .__PDSH_VFS_FLUSH_TIMINGS__ = flushTimings
    disposers.push(() => {
      const target = globalThis as { __PDSH_VFS_FLUSH_TIMINGS__?: VfsFlushTiming[] }
      if (target.__PDSH_VFS_FLUSH_TIMINGS__ === flushTimings) {
        delete target.__PDSH_VFS_FLUSH_TIMINGS__
      }
    })
    disposers.push(installSink(vfs, channel, {
      ...normalized.limits,
      writeOutcomes,
      onFlushTiming: (timing) => {
        flushTimings.push(timing)
        if (flushTimings.length > VFS_FLUSH_TIMING_SAMPLES) flushTimings.shift()
      },
    }))
    // The command-boundary durability fence shared by every in-Worker
    // execution surface (G2-FIX-61). The sink publishes VFS_MUT asynchronously,
    // so a shell command that returns before the host has acked its mutations
    // can lose them to a Worker kill. `subprocess-xl` reads this hook and
    // awaits it after each `bash -c`; the WASI toolbox flushes its backend
    // directly. The hook is the sink-wrapped `flush()`, so a resource refusal
    // fails the command instead of being swallowed.
    const flushVfs = (): Promise<void> => vfs.flush()
    const workerGlobals = globalThis as { __PDSH_VFS_FLUSH__?: () => Promise<void> }
    workerGlobals[WORKER_VFS_FLUSH_GLOBAL] = flushVfs
    disposers.push(() => {
      if (workerGlobals[WORKER_VFS_FLUSH_GLOBAL] === flushVfs) {
        delete workerGlobals[WORKER_VFS_FLUSH_GLOBAL]
      }
    })
    // W7 python goes live before `pdsh-ready`: createWorkerCommands() reads the
    // published toolbox when the first command runs, so an image that carries
    // python.wasm/python313.zip must have `python3` installed by then. Reading
    // the staged artifacts and publishing the toolbox is not optional wiring;
    // without it every python3 step answered 127 in the Worker shell.
    // One wiring lifecycle for every boot path: a rebuild whose host VFS is a
    // new object re-binds (and disposes the stale wiring) instead of publishing
    // a `python3` that still answers for the parked host's filesystem
    // (G2-FIX-54).
    pythonWiring = normalized.python === false
      ? undefined
      : await pythonToolboxLifecycle.bind({
          ...normalized.python, vfs, writeOutcomes,
          ...hotInstanceBytes === undefined ? {} : { memoryLimitBytes: hotInstanceBytes },
        })
    if (pythonWiring !== undefined) {
      // Image-loaded modules have file:///dsh/... import.meta.url values. Their
      // isolated Python forks still need the real page-served tool worker,
      // which lives beside this entry bundle, not beside the image module.
      const key = Symbol.for('@phone-dsh/worker-entry/python-worker-url')
      const target = globalThis as Record<symbol, unknown>
      const previous = target[key]
      const configured = normalized.python === false ? undefined : normalized.python?.workerUrl
      const workerUrl = String(configured ?? new URL('./tool-worker-python.js', import.meta.url))
      target[key] = workerUrl
      disposers.push(() => {
        if (target[key] !== workerUrl) return
        if (previous === undefined) delete target[key]
        else target[key] = previous
      })
    }
    jqWiring = normalized.jq === false
      ? undefined
      : await jqToolboxLifecycle.bind({
          ...normalized.jq, vfs, writeOutcomes,
          ...hotInstanceBytes === undefined ? {} : { memoryLimitBytes: hotInstanceBytes },
        })
    // Both runtimes live in one command table; publish only what this boot
    // actually registered. Replacing the python toolbox with a composite is
    // what lets `jq` and `python3` share the one global slot.
    setWorkerToolbox(combineWorkerToolboxes([pythonWiring?.toolbox, jqWiring?.toolbox]))
    // G2-ENG-05: publish the environment priors before the first API_REQ.
    // The unmodified upstream `agent-instructions` row reads
    // $DSH_HOME/AGENTS.md on the first request; the JSON is the exact
    // machine-readable copy the shell-ext 127 trailer already points at
    // (ENG-02). The writes go through the subscribed VFS, so the host WAL
    // persists them, and `publishCapabilityManifest` skips an unchanged file:
    // a restart with the same environment emits no VFS_MUT.
    const pythonProbe = pythonWiring === undefined ? undefined : await readPythonModuleProbe(vfs)
    const pythonModules = pythonProbe?.modules ?? []
    const surface = workerCommandSurface({
      accelerators: acceleratorsFromCaps(channel.hostHello?.caps),
      toolbox: getWorkerToolbox(),
    })
    await publishCapabilityManifest(vfs, buildCapabilityManifest({
      commands: surface.commands,
      accelerators: surface.accelerators,
      ...ubuntu === undefined ? {} : { ubuntu },
      // A command the table carries but this boot cannot run is not a
      // capability: `curl` needs the host `/v1/http` origin *and* token, and
      // the Android engine injects only the origin. The row keeps the reason
      // in the manifest instead of declaring a command that cannot execute.
      unavailable: workerUnavailableCommands({
        PDSH_CHANNEL_ORIGIN: process.env.PDSH_CHANNEL_ORIGIN,
        PDSH_EXEC_BRIDGE_URL: process.env.PDSH_EXEC_BRIDGE_URL,
        PDSH_CHANNEL_TOKEN: process.env.PDSH_CHANNEL_TOKEN,
        PDSH_EXEC_BRIDGE_TOKEN: process.env.PDSH_EXEC_BRIDGE_TOKEN,
      }),
      hostCaps: channel.hostHello?.caps ?? [],
      pythonModules,
      ...jqWiring === undefined ? {} : {
        jq: {
          available: true,
          program: 'jq-wasi',
          ...jqWiring.probe?.engine === undefined ? {} : { engine: jqWiring.probe.engine },
        },
      },
      python: pythonWiring === undefined
        ? { available: false }
        : {
            available: true,
            ...pythonProbe?.version === undefined ? {} : { version: pythonProbe.version },
            // The compression block comes only from the build probe staged in
            // modules.json (build.sh's compression.json). Never infer it from
            // the stdlib ZIP: a `zlib.py` wrapper can be present while the
            // native extension is absent (G2-FIX-27 regression point). An old
            // image without the block reports null, not "linked".
            ...pythonProbe?.compression === undefined
              ? {}
              : { compression: {
                  zlib: pythonProbe.compression.modules.includes('zlib'),
                  bz2: pythonProbe.compression.modules.includes('bz2'),
                  lzma: pythonProbe.compression.modules.includes('lzma'),
                  tarfileGzip: pythonProbe.compression.tarfileGzip,
                } },
          },
      limits: {
        ...PHONE_V1_LIMITS,
        ...vfsLimits,
        singleFileBytes: Math.min(
          normalized.limits.maxFileBytes ?? DEFAULT_SINGLE_FILE_LIMIT,
          MAX_SINGLE_FILE_LIMIT,
        ),
        ...hotInstanceBytes === undefined ? {} : { wasiHotInstanceBytes: hotInstanceBytes },
      },
      egressAllow: normalized.egressAllow,
    }))
    disposers.push(serveApiRequests(channel, runtime.whenRequestListener, {
      ...runtime.synthesize === undefined ? {} : { synthesize: runtime.synthesize },
      mux,
    }))
    disposers.push(installResyncHandler(vfs, channel, normalized.limits))
    consoleForwarder.flush()
    pagePost({ t: 'pdsh-ready' })

    let stopped = false
    const handle: PhoneWorkerHandle = {
      channel,
      host,
      vfs,
      python: pythonWiring,
      jq: jqWiring,
      writeOutcomes,
      async stop(): Promise<void> {
        if (stopped) return
        stopped = true
        // Hard-stop any interpreter dispatch before the sink flush below: an
        // orderly stop must not wait for a WASI run blocked in a proxied
        // syscall, and its partial writes must reach the WAL with a terminal
        // marker (G2-FIX-104). The entry is the last owner that can still
        // settle when the LIFECYCLE frame did not reach the subprocess layer.
        const toolbox = getWorkerToolbox()
        toolbox?.terminate?.('drain')
        // Give the marker writes their chance to reach the sink before the
        // flush below closes the drain window; the worker itself is already
        // settled, so this never waits for the interpreter.
        try {
          await toolbox?.partialWritesSettled?.()
        } catch (error) {
          console.error('worker entry: the WASI partial-write markers could not be flushed on stop', error)
        }
        // An orderly stop (park / planned restart) must not leave accepted
        // writes unacknowledged: flush the sink while the channel is still
        // alive, before the disposers detach it (G2-FIX-61).
        try {
          await vfs.flush()
        } catch (error) {
          console.error('worker entry: the VFS sink could not be flushed on stop', error)
        }
        for (const dispose of disposers.splice(0).reverse()) dispose()
        if (pythonWiring !== undefined && pythonToolboxLifecycle.current() === pythonWiring) {
          await pythonToolboxLifecycle.unbind()
        }
        if (jqWiring !== undefined && jqToolboxLifecycle.current() === jqWiring) {
          await jqToolboxLifecycle.unbind()
        }
        // A composite is not equal to either member, so the lifecycle helpers
        // cannot clear the published slot; the entry owns the final release.
        setWorkerToolbox(undefined)
        consoleForwarder.dispose()
        try { await channel.close() } catch { /* already closed */ }
        if (activeHost === host) activeHost = undefined
        if (activeHandle === handle) activeHandle = undefined
        await host.stop?.()
      },
    }
    activeHandle = handle
    return handle
  } catch (error) {
    // The runtime's image fetch error repeats the whole image URL, and the
    // Native page URL appends `?token=`. Keep the exact init values here so the
    // operator-facing page error and CONSOLE frame are bounded and redacted;
    // never hand the raw reason to the caller either.
    const secrets = bootTransportSecretValues({
      image: normalized.imageURL,
      overlays: normalized.overlayURLs,
      xl: {
        token: normalized.token,
        channelURL: normalized.channelURL,
        env: normalized.env,
        fence: {
          owner: normalized.fence.owner,
          generation: normalized.fence.generation.toString(),
          wal_seq: normalized.fence.wal_seq.toString(),
        },
        bootId: normalized.bootId,
        sessionEpoch: normalized.sessionEpoch.toString(),
        egressAllow: normalized.egressAllow,
      },
    })
    const failure = bootFailureError(error, secrets)
    for (const dispose of disposers.splice(0).reverse()) dispose()
    if (pythonWiring !== undefined && pythonToolboxLifecycle.current() === pythonWiring) {
      await pythonToolboxLifecycle.unbind()
    }
    if (jqWiring !== undefined && jqToolboxLifecycle.current() === jqWiring) {
      await jqToolboxLifecycle.unbind()
    }
    setWorkerToolbox(undefined)
    activeHost = undefined
    if (hostStarted && bootHost !== undefined) {
      // A boot failure after the tree is up must not leave it running behind a
      // closed channel; the page has already been told the boot failed.
      try { await bootHost.stop?.() } catch (stopError) {
        console.error(
          'worker entry: failed to stop the host after a boot error',
          redactBootFailureDetail(stopError, secrets),
        )
      }
    }
    // Report while the forwarder is still attached: the sanitized failure is
    // the one line the Native console/diagnostics should see.
    reportPageError(failure, pagePost)
    consoleForwarder.dispose()
    try { await channel.close() } catch { /* already closed */ }
    throw failure
  }
}

/**
 * Mirror every committed VFS mutation into VFS_MUT frames and make
 * `vfs.flush()` wait for the level-1 ack of the last emitted mutation.
 *
 * Only `/dsh/home/**` and `/dsh/workspace/**` are sent (D4); `/dsh/tmp/**` and
 * every other root stay volatile. One mutation carries at most 15 MiB, so a
 * complete write larger than that is published as one complete write plus
 * appended suffixes, each at the next normal mseq (channel.md §3.1). The sink
 * separates two failure classes:
 *
 * - **Structural/protocol** (`BAD_PATH`, `BAD_MSEQ`, `BAD_PAYLOAD`, an
 *   out-of-range append offset) fails loud: the sink sends one ERROR and closes
 *   the ordered channel, and every later `flush()` rejects with that error.
 * - **Resource** (`EFBIG`, `ENOSPC`, quota) is a bounded-phone-filesystem
 *   condition, not a corrupt protocol. The refused mutation consumes no mseq;
 *   the sink sends one `ERROR VFS_REFUSED` diagnostic (`path`/`limit`/`reason`)
 *   plus a CONSOLE audit line, and keeps the channel open. `flush()` is then
 *   poisoned with a node-errno-shaped `VfsRefusalError` whose message ends in
 *   the shared `pdsh-shell:` trailer. A later legal write or remove of the
 *   refused path clears the poison, so the model can delete the file or rewrite
 *   it in chunks (G2-ENG-03).
 *
 * This is the last-resort backstop, not the primary D4 limit: both Worker
 * write surfaces refuse an over-limit write with `EFBIG` before the VFS
 * publishes it. The shell uses `VfsFileSystem.writeFile`/`appendFile` in
 * `@phone-dsh/dsh-shell-ext`; WASI guests (including `python3`) use
 * `NodeFsBackend`/`MemoryVfsBackend` in `@phone-dsh/dsh-wasi-toolbox`, so
 * an over-limit Python write fails as the command's own error and the channel
 * stays open (G2-FIX-29). The `write` tool uses the runtime's atomic
 * write+fsync path, so it reaches this sink guard and now fails the tool step
 * with the trailer instead of hanging the session.
 * @param vfs - In-memory filesystem authority (D8).
 * @param channel - Connected ordered channel.
 * @param limits - Optional policy override; `maxFileBytes` defaults to the
 *   128 MiB 8 GiB-tier single-file budget (`spec/v1/budgets.md:104`).
 * @returns A disposer that unsubscribes and restores the original flush.
 */
export interface VfsSinkLimits {
  /** Single-file bound from the budget table; never above the 256 MiB host maximum. */
  readonly maxFileBytes?: number
  /**
   * Bound for the level-1 VFS ack wait in the wrapped `flush()`. Defaults to
   * the channel package's validated env/constant window; a lost 0x11 rejects
   * the flush instead of hanging the tool command that awaits it.
   */
  readonly ackTimeoutMs?: number
  /**
   * Validated bound for one proxied write's level-1 outcome wait (D3's 30 s
   * fail-loud window). The entry builds the {@link VfsWriteOutcomes} with this
   * value and the WASI VFS backend rejects the guest write with a typed
   * `VfsFlowControlError` when no ack arrives inside it. Omitted means the
   * env/constant window.
   */
  readonly flowControlTimeoutMs?: number
  /**
   * Ordered-channel outcome tracker shared with the WASI VFS backends. The
   * entry creates one per Worker boot so a proxied write can await the host's
   * ack or resource refusal instead of returning success before either exists.
   */
  readonly writeOutcomes?: VfsWriteOutcomes
  /**
   * Observe each flush wait's hop timestamps (G2-FIX-83). Diagnostic only; the
   * sink never changes ack handling based on the sample.
   */
  readonly onFlushTiming?: (timing: VfsFlushTiming) => void
}

/**
 * Per-hop timing of one `vfs.flush()` level-1 wait (G2-FIX-83).
 *
 * The worker emits VFS_MUT frames as the VFS publishes them and `flush()` waits
 * for the cumulative level-1 ack of the highest emitted mseq. `waitMilliseconds`
 * therefore measures the durability chain from the flush call to the ack frame
 * arriving, not a polling interval. When the ack is already known the wait is
 * skipped (`alreadyAcked`), which is the normal case for a second command
 * boundary after the first flush.
 */
export interface VfsFlushTiming {
  /** Highest mseq the sink had emitted when the flush started. */
  readonly mseq: bigint
  /** True when the ack was already known and no ack frame was awaited. */
  readonly alreadyAcked: boolean
  readonly startedAtMilliseconds: number
  /** When the level-1 ack covering `mseq` was observed (or the flush start). */
  readonly ackedAtMilliseconds: number
  readonly resolvedAtMilliseconds: number
  readonly waitMilliseconds: number
}

export function installSink(
  vfs: WorkerEntryVfs,
  channel: WorkerEntryChannel,
  limits: VfsSinkLimits = {},
): () => void {
  const requestedLimit = limits.maxFileBytes ?? DEFAULT_SINGLE_FILE_LIMIT
  if (!Number.isSafeInteger(requestedLimit) || requestedLimit < 0) {
    throw new RangeError('worker entry: maxFileBytes must be a non-negative safe integer')
  }
  const maxFileBytes = Math.min(requestedLimit, MAX_SINGLE_FILE_LIMIT)
  const ackTimeoutMs = resolveDurabilityAckTimeoutMs(limits.ackTimeoutMs)
  const writeOutcomes = limits.writeOutcomes
  let lastEmittedMseq = 0n
  let sinkFailure: Error | undefined
  let refusal: VfsRefusalRecord | undefined

  const sendDiagnostic = (payload: unknown): void => {
    try {
      channel.send(FrameType.ERROR, encodeUtf8(canonicalStringify(payload)))
    } catch (error) {
      // The channel is already gone; the poisoned flush still fails loud.
      console.error('worker entry: could not send VFS_REFUSED diagnostic', error)
    }
  }
  const failLoud = (error: Error): void => {
    sinkFailure ??= error
    // Nothing may stay parked on a proxied write when the channel goes down.
    writeOutcomes?.noteFailure(error)
    console.error('worker entry: VFS mutation refused; closing the ordered channel', error)
    sendDiagnostic({ code: 'BAD_PAYLOAD', message: error.message })
    void channel.close()
  }
  const reportRefusal = (record: VfsRefusalRecord): void => {
    refusal = record
    // The refused mutation never reached the channel, so no mseq names it; the
    // pending proxied write for that path still settles with the same errno.
    writeOutcomes?.noteRefusal({ code: record.code, path: record.path, limit: record.limit, hint: record.hint })
    console.error('worker entry: VFS resource refusal; keeping the ordered channel open', record.code, record.path)
    sendDiagnostic(vfsRefusedPayload(record))
    try {
      channel.send(FrameType.CONSOLE, encodeUtf8(canonicalStringify({
        level: 'error',
        text: vfsRefusalConsoleText(record),
      })))
    } catch (error) {
      console.error('worker entry: could not send VFS refusal console line', error)
    }
  }
  // A host budget refusal is already on the wire in the other direction: do not
  // echo a diagnostic. Poison flush() the same way a local guard does and clamp
  // the emitted watermark so the next flush does not wait for an ack the host
  // will never send for the refused (unconsumed) mseq.
  const noteHostRefusal = (record: VfsRefusalRecord, refusedMseq: bigint | undefined): void => {
    refusal = record
    // A proxied write that published the refused mutation observes the same
    // structured errno error the guest's write syscall turns into EFBIG/ENOSPC
    // (G2-FIX-103). The refusal consumes no mseq and keeps the channel open.
    writeOutcomes?.noteRefusal(
      { code: record.code, path: record.path, limit: record.limit, hint: record.hint },
      refusedMseq,
    )
    console.error('worker entry: host VFS resource refusal; keeping the ordered channel open', record.code, record.path)
    if (refusedMseq !== undefined && lastEmittedMseq >= refusedMseq) {
      lastEmittedMseq = refusedMseq - 1n
    }
  }
  // A legal write or a remove (including a recursive staging-directory
  // cleanup) repairs the condition and ends the poison. The mutation is then
  // encoded and sent normally at the next mseq.
  const repairRefusal = (mutation: WorkerEntryMutation): void => {
    if (refusal === undefined) return
    if (mutation.kind === 'remove') {
      if (mutation.path === refusal.path || refusal.path.startsWith(`${mutation.path}/`)) refusal = undefined
    } else if (
      mutation.kind === 'write'
      && mutation.path === refusal.path
      && mutation.bytes.byteLength <= maxFileBytes
    ) {
      refusal = undefined
    }
  }

  const disposeObserver = vfs.subscribe((mutation) => {
    if (!isSinkPath(mutation.path)) return
    repairRefusal(mutation)
    let bodies: ReturnType<typeof mutationToBodies>
    try {
      bodies = mutationToBodies(mutation, maxFileBytes)
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(String(error))
      const record = vfsRefusalRecordFromError(failure, maxFileBytes)
      if (record !== undefined) {
        reportRefusal(record)
      } else {
        failLoud(failure)
      }
      // The runtime logs (and swallows) observer exceptions; the poisoned
      // flush rejection above is what actually stops the failing tool step.
      throw failure
    }
    try {
      for (const body of bodies) {
        const mseq = channel.nextMseq()
        const payload = encodeVfsMutation({ mseq, ...body })
        // Attach the mutation to the proxied write that produced it before the
        // frame leaves: a scripted host can answer synchronously from send().
        writeOutcomes?.notePublished(mutation.path, mseq, body.data.byteLength)
        channel.send(FrameType.VFS_MUT, payload)
        if (mseq > lastEmittedMseq) lastEmittedMseq = mseq
      }
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(String(error))
      failLoud(failure)
      throw failure
    }
  })

  const previousFlush = vfs.flush
  const wrappedFlush = async (): Promise<void> => {
    await previousFlush.call(vfs)
    if (sinkFailure !== undefined) throw sinkFailure
    if (refusal !== undefined) throw new VfsRefusalError(refusal)
    // A proxied write already failed loud on the D3 flow-control window; do not
    // make the command boundary wait a second window for the same missing ack.
    const flowFailure = writeOutcomes?.failure
    if (flowFailure !== undefined) throw flowFailure
    if (lastEmittedMseq > 0n) {
      const startedAtMilliseconds = Date.now()
      const alreadyAcked = channel.ackedMseq(1) >= lastEmittedMseq
      // The client's own tracker bound fails the connection loud (ERROR,
      // close, reconnect-replay); this call-site backstop rejects the flush
      // even for an injected channel that ignores the bound. The 30 s bound is
      // the fail-loud flow-control deadline, never the wait cadence: the wait
      // itself resolves the moment the cumulative level-1 ack arrives.
      try {
        await withDurabilityAckTimeout(
          channel.waitAck(1, lastEmittedMseq, undefined, { timeoutMs: ackTimeoutMs }),
          ackTimeoutMs,
          `worker sink VFS_ACK level 1 for mseq ${String(lastEmittedMseq)}`,
        )
      } catch (error) {
        // A host budget refusal is a structured tool error, not a dead
        // channel: route it through the same VfsRefusalError a local EFBIG
        // produces so bash/python/write report it like the pre-check does.
        if (error instanceof VfsRefusedError) {
          const record = vfsRefusalRecordFromChannelError(error)
          noteHostRefusal(record, error.refusedMseq)
          throw new VfsRefusalError(record)
        }
        throw error
      }
      const ackedAtMilliseconds = Date.now()
      const timing: VfsFlushTiming = {
        mseq: lastEmittedMseq,
        alreadyAcked,
        startedAtMilliseconds,
        ackedAtMilliseconds,
        resolvedAtMilliseconds: ackedAtMilliseconds,
        waitMilliseconds: ackedAtMilliseconds - startedAtMilliseconds,
      }
      limits.onFlushTiming?.(timing)
      if (timing.waitMilliseconds >= SLOW_VFS_FLUSH_MILLISECONDS) {
        // A tool-call boundary that pays a fixed multi-second durability wait
        // is the G2-FIX-83 defect. Report it on the CONSOLE stream so the
        // transcript carries the hop next to the host's step `at_ms` values.
        try {
          channel.send(FrameType.CONSOLE, encodeUtf8(canonicalStringify({
            level: 'error',
            text: `pdsh-vfs-flush: mseq ${String(timing.mseq)} level-1 ack after ${String(timing.waitMilliseconds)} ms (started_at_ms=${String(timing.startedAtMilliseconds)} acked_at_ms=${String(timing.ackedAtMilliseconds)} alreadyAcked=${String(timing.alreadyAcked)})`,
          })))
        } catch {
          // The channel is already gone; the timing sample still exists.
        }
      }
    }
  }
  vfs.flush = wrappedFlush

  // The refused write's mseq is released by the channel when the refusal
  // frame arrives; poisoning here (before any waiter resumes) keeps every
  // later boundary flush failing until the refused path is repaired.
  const disposeFrames = channel.onFrame((frame) => {
    if (frame.type === FrameType.VFS_ACK) {
      try {
        const ack = decodeVfsAck(frame.payload)
        writeOutcomes?.noteAck(ack.level, ack.uptoMseq)
      } catch {
        // The channel already validated the frame; a malformed frame is a
        // protocol failure it reports itself. Nothing to settle here.
      }
      return
    }
    if (frame.type !== FrameType.ERROR) return
    let diagnostic: VfsRefusedDiagnostic | undefined
    try {
      diagnostic = parseVfsRefusedDiagnostic(JSON.parse(decodeUtf8(frame.payload)) as unknown)
    } catch {
      return
    }
    if (diagnostic === undefined) return
    noteHostRefusal(vfsRefusalRecordFromDiagnostic(diagnostic), diagnostic.mseq)
  })
  // A reconnect HELLO reports the host's accepted tail: resolve writes that
  // were published on the lost connection but already exist in the host WAL.
  const disposeHello = channel.onHostHello((hello) => {
    writeOutcomes?.noteAck(1, hello.acked_mseq)
  })

  return () => {
    disposeFrames()
    disposeHello()
    disposeObserver()
    writeOutcomes?.close()
    // Never drop a later wrapper; restore only our own flush.
    if (vfs.flush === wrappedFlush) vfs.flush = previousFlush
  }
}

/**
 * Feed API_REQ frames into the captured DSH webserver listener and stream its
 * response as API_RES chunks followed by API_END (API_ABORT on failure).
 *
 * `/api/remote.mux` is an HTTP upgrade route, so when a mux bridge is supplied
 * those requests are served by the bridge instead of the request listener
 * (D23). Every request handed to the listener is stamped with the D22
 * `x-pdsh-channel-authenticated: 1` marker after any inbound copy is removed.
 * @param channel - Connected ordered channel.
 * @param whenRequestListener - Resolves the listener captured by the runtime.
 * @param options - Synthesis override and the `/api/remote.mux` bridge.
 * @returns A disposer that aborts in-flight exchanges and closes mux sessions.
 */
export function serveApiRequests(
  channel: WorkerEntryChannel,
  whenRequestListener: () => Promise<WorkerEntryRequestListener>,
  options: ServeApiRequestsOptions = {},
): () => void {
  const inFlight = new Map<number, { abort(): void }>()
  const synthesizeWait = options.synthesize === undefined
    ? loadDefaultSynthesize()
    : Promise.resolve(options.synthesize)
  let listenerPromise: Promise<WorkerEntryRequestListener> | undefined

  const listener = async (): Promise<WorkerEntryRequestListener> => {
    listenerPromise ??= whenRequestListener()
    return await listenerPromise
  }

  const send = (type: FrameType, payload: Uint8Array): boolean => {
    try {
      channel.send(type, payload)
      return true
    } catch (error) {
      console.debug('worker entry: API frame dropped', error)
      return false
    }
  }

  const handleRequest = async (frame: Frame): Promise<void> => {
    let request
    try {
      request = decodeApiRequest(frame.payload)
    } catch (error) {
      console.error('worker entry: malformed API_REQ', error)
      return
    }
    const reqId = request.reqId
    let headSent = false
    let pendingHead: { status: number; headers: Record<string, string> } | undefined
    let finished = false
    const finish = (): void => {
      finished = true
      inFlight.delete(reqId)
    }
    const sendRemainder = (offset: number, body: Uint8Array): void => {
      while (offset < body.byteLength && !finished) {
        const end = Math.min(offset + MAX_API_RESPONSE_CHUNK, body.byteLength)
        send(FrameType.API_RES, encodeApiResponse({ reqId, head: undefined, body: body.subarray(offset, end) }))
        offset = end
      }
    }
    const sendHead = (body: Uint8Array): void => {
      headSent = true
      const head = pendingHead ?? { status: 200, headers: {} }
      pendingHead = undefined
      const first = body.subarray(0, Math.min(MAX_API_RESPONSE_CHUNK, body.byteLength))
      send(FrameType.API_RES, encodeApiResponse({ reqId, head, body: first }))
      sendRemainder(first.byteLength, body)
    }
    const sink: WorkerEntryResponseSink = {
      head(status, headers) {
        if (finished || headSent) return
        pendingHead = { status, headers }
      },
      chunk(bytes) {
        if (finished) return
        if (headSent) {
          sendRemainder(0, bytes)
          return
        }
        sendHead(bytes)
      },
      end(payload) {
        if (finished) return
        if (!headSent) {
          if (payload !== undefined) pendingHead ??= { status: payload.status, headers: payload.headers }
          sendHead(payload?.body ?? new Uint8Array(0))
        } else if (payload?.body !== undefined) {
          sendRemainder(0, payload.body)
        }
        send(FrameType.API_END, encodeApiEnd(reqId))
        finish()
      },
      fail(message) {
        if (finished) return
        send(FrameType.API_ABORT, encodeApiAbort(reqId, message))
        finish()
      },
    }

    if (options.mux !== undefined && isRemoteMuxRequest(request.head.path)) {
      serveMuxRequest(options.mux, {
        method: request.head.method,
        path: request.head.path,
        headers: request.head.headers,
        body: request.body,
      }, sink, reqId, inFlight)
      return
    }

    try {
      const synthesize = await synthesizeWait
      const exchange = synthesize({
        method: request.head.method,
        path: request.head.path,
        headers: withChannelAuthentication({ ...request.head.headers, host: SYNTHETIC_HOST }),
        body: request.body,
      }, sink)
      if (!finished) inFlight.set(reqId, exchange)
      const resolvedListener = await listener()
      resolvedListener(exchange.req, exchange.res)
    } catch (error) {
      sink.fail(error instanceof Error ? error.message : String(error))
    }
  }

  const disposeFrames = channel.onFrame((frame) => {
    switch (frame.type) {
      case FrameType.API_REQ:
        void handleRequest(frame)
        break
      case FrameType.API_ABORT: {
        try {
          const abort = decodeApiAbort(frame.payload)
          const exchange = inFlight.get(abort.reqId)
          inFlight.delete(abort.reqId)
          exchange?.abort()
        } catch {
          // The channel's own decoder reports malformed API_ABORT frames.
        }
        break
      }
      default:
        break
    }
  })
  const disposeTransport = channel.onTransportLost?.(() => {
    for (const exchange of inFlight.values()) exchange.abort()
    inFlight.clear()
    options.mux?.closeAll()
  })

  return () => {
    disposeFrames()
    disposeTransport?.()
    for (const exchange of inFlight.values()) exchange.abort()
    inFlight.clear()
    options.mux?.closeAll()
  }
}

/**
 * Apply D22: drop every inbound `x-pdsh-channel-authenticated` header and set the
 * single entry-owned marker value. The host verified the channel bearer before
 * the frame reached this Worker, so the marker is the only authentication the
 * phone surface needs on this path.
 * @param headers - Headers of the forwarded request.
 * @returns A copy carrying exactly one marker set to `1`.
 */
export function withChannelAuthentication(
  headers: Readonly<Record<string, string>>,
): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [name, value] of Object.entries(headers)) {
    if (name.toLowerCase() === CHANNEL_AUTHENTICATED_HEADER) continue
    out[name] = value
  }
  out[CHANNEL_AUTHENTICATED_HEADER] = '1'
  return out
}

/** Whether an API path addresses the Remote stream mux (query string ignored). */
function isRemoteMuxRequest(path: string): boolean {
  const query = path.indexOf('?')
  return (query === -1 ? path : path.slice(0, query)) === REMOTE_MUX_PATH
}

/**
 * Serve one `/api/remote.mux` operation through the in-process mux bridge. The
 * bridge owns the response sink; this wrapper only releases the channel
 * req_id when the bridge finishes (or when the host aborts a receive).
 */
function serveMuxRequest(
  mux: WorkerEntryMuxBridge,
  request: WorkerEntrySyntheticRequest,
  sink: WorkerEntryResponseSink,
  reqId: number,
  inFlight: Map<number, { abort(): void }>,
): void {
  let done = false
  const muxSink: WorkerEntryResponseSink = {
    head(status, headers) {
      if (!done) sink.head(status, headers)
    },
    chunk(bytes) {
      if (!done) sink.chunk(bytes)
    },
    end(payload) {
      if (done) return
      done = true
      inFlight.delete(reqId)
      sink.end(payload)
    },
    fail(message) {
      if (done) return
      done = true
      inFlight.delete(reqId)
      sink.fail(message)
    },
  }
  let exchange: { abort(): void }
  try {
    exchange = mux.handle(request, muxSink)
  } catch (error) {
    muxSink.fail(error instanceof Error ? error.message : String(error))
    return
  }
  if (!done) inFlight.set(reqId, exchange)
}

/**
 * Forward `console.log/info/debug/warn/error` as CONSOLE frames in addition to
 * the local console. Lines produced while the channel is connecting are held in
 * a small bounded buffer and flushed on connect.
 *
 * The `XL_DSH_READY <port>` readiness line is also captured when it is written
 * directly to `process.stdout` (the surface prints it that way), because the
 * host needs it as a 0x60 CONSOLE frame. Other stdout output is not mirrored.
 * @param channel - Ordered channel.
 * @returns A forwarder with `flush()` and `dispose()`.
 */
export function installConsoleForwarding(channel: WorkerEntryChannel): ConsoleForwarder {
  const buffered: LifecycleConsoleLine[] = []
  let active = true
  let forwarding = false
  let stdoutSuppressed = 0
  let stdoutPartial = ''
  /**
   * Readiness lines just emitted from raw stdout. The Worker's `process.stdout`
   * shim replays writes through `console.log`; the console hook skips one
   * matching line so that replay does not produce a second CONSOLE frame.
   */
  let pendingStdoutLines: string[] = []
  const sendLine = (line: LifecycleConsoleLine): boolean => {
    try {
      channel.send(FrameType.CONSOLE, encodeUtf8(canonicalStringify({ level: line.level, text: line.text })))
      return true
    } catch {
      return false
    }
  }
  const emit = (line: LifecycleConsoleLine): void => {
    if (!active) return
    forwarding = true
    try {
      if (!sendLine(line) && buffered.length < CONSOLE_BUFFER_LINES) buffered.push(line)
    } finally {
      forwarding = false
    }
  }
  const forward = (level: LifecycleConsoleLine['level'], args: readonly unknown[]): void => {
    if (!active || forwarding) return
    const text = formatConsoleArgs(args)
    const replay = pendingStdoutLines.indexOf(text)
    if (replay >= 0) {
      pendingStdoutLines.splice(replay, 1)
      return
    }
    emit({ level, text })
  }
  /** Capture the `XL_DSH_READY` line when it is written straight to stdout. */
  const appendStdout = (chunk: unknown): void => {
    if (!active || stdoutSuppressed > 0 || forwarding) return
    // Only a string write can be the readiness line. Binary writes (a test
    // runner's protocol frames, a Buffer from a plugin) must not poison the
    // partial-line buffer: a protocol frame can carry newlines and would hide
    // the next text line. Treat one as a line boundary.
    if (typeof chunk !== 'string') {
      stdoutPartial = ''
      return
    }
    const text = chunk
    if (text === '') return
    stdoutPartial += text
    for (;;) {
      const newline = stdoutPartial.indexOf('\n')
      if (newline < 0) {
        // Do not accumulate unbounded non-newline output.
        if (stdoutPartial.length > 4096) stdoutPartial = ''
        return
      }
      const line = stdoutPartial.slice(0, newline).replace(/\r$/, '')
      stdoutPartial = stdoutPartial.slice(newline + 1)
      if (line.startsWith('XL_DSH_READY ')) {
        emit({ level: 'info', text: line })
        pendingStdoutLines.push(line)
      }
    }
  }

  const originalLog = console.log.bind(console)
  const originalInfo = console.info.bind(console)
  const originalDebug = console.debug.bind(console)
  const originalWarn = console.warn.bind(console)
  const originalError = console.error.bind(console)
  // Console methods write through `process.stdout` themselves; suppress the
  // stdout hook around them so one console line is not forwarded twice.
  const throughConsole = (write: (...args: unknown[]) => void, args: readonly unknown[]): void => {
    stdoutSuppressed += 1
    try { write(...args) } finally { stdoutSuppressed -= 1 }
  }
  const wrapped = {
    log: (...args: unknown[]): void => { throughConsole(originalLog, args); forward('info', args) },
    info: (...args: unknown[]): void => { throughConsole(originalInfo, args); forward('info', args) },
    debug: (...args: unknown[]): void => { throughConsole(originalDebug, args); forward('debug', args) },
    warn: (...args: unknown[]): void => { throughConsole(originalWarn, args); forward('warn', args) },
    error: (...args: unknown[]): void => { throughConsole(originalError, args); forward('error', args) },
  }
  console.log = wrapped.log
  console.info = wrapped.info
  console.debug = wrapped.debug
  console.warn = wrapped.warn
  console.error = wrapped.error

  const stdout = typeof process === 'undefined' ? undefined : process.stdout
  const stdoutPrevious = stdout === undefined ? undefined : Object.getOwnPropertyDescriptor(stdout, 'write')
  const originalStdoutWrite = stdout === undefined ? undefined : stdout.write.bind(stdout) as (...args: unknown[]) => boolean
  if (stdout !== undefined && originalStdoutWrite !== undefined) {
    try {
      stdout.write = ((chunk: unknown, ...rest: unknown[]): boolean => {
        try { appendStdout(chunk) } catch { /* a CONSOLE failure must not break stdout */ }
        try {
          return originalStdoutWrite(chunk, ...rest)
        } finally {
          // The runtime shim replays the write through console synchronously.
          // Anything left is a desktop stdout that does not touch console.
          pendingStdoutLines = []
        }
      }) as typeof stdout.write
    } catch {
      // A frozen stdout is fine: the runtime's own write still reaches console.
    }
  }

  return {
    flush(): void {
      while (buffered.length > 0) {
        const line = buffered[0]!
        if (!sendLine(line)) return
        buffered.shift()
      }
    },
    dispose(): void {
      active = false
      if (console.log === wrapped.log) console.log = originalLog
      if (console.info === wrapped.info) console.info = originalInfo
      if (console.debug === wrapped.debug) console.debug = originalDebug
      if (console.warn === wrapped.warn) console.warn = originalWarn
      if (console.error === wrapped.error) console.error = originalError
      if (stdout === undefined) return
      if (stdoutPrevious === undefined) Reflect.deleteProperty(stdout, 'write')
      else Object.defineProperty(stdout, 'write', stdoutPrevious)
    },
  }
}

// ---------------------------------------------------------------- page boots

/** The runtime binding is loaded only when the entry actually boots DSH. */
type RuntimeBinding = typeof import('./runtime-binding.ts')
let runtimeBinding: Promise<RuntimeBinding> | undefined
let bindingForSynthesize: RuntimeBinding | undefined

function loadRuntimeBinding(): Promise<RuntimeBinding> {
  runtimeBinding ??= import('./runtime-binding.ts').then((binding) => {
    bindingForSynthesize = binding
    return binding
  })
  return runtimeBinding
}

async function loadDefaultRuntime(): Promise<PhoneWorkerRuntime> {
  const binding = await loadRuntimeBinding()
  return {
    createHost: (options) => binding.createPhoneWorkerHost({
      image: options.image,
      overlays: options.overlays,
      ...options.env === undefined ? {} : { env: options.env },
      ...options.channel === undefined ? {} : { channel: options.channel },
    }),
    whenRequestListener: () => binding.whenRequestListener(),
    synthesize: synthesizeFromBinding,
    activateVfs: (vfs) => { binding.activateWorkerVfs(vfs) },
    installExecFsPolicy: (namespace) => binding.installWorkerExecFsPolicy(namespace),
    installBoundedDirectoryOpener: (vfs) => binding.installWorkerBoundedDirectoryOpener(vfs),
    installByteFaithfulWrites: () => binding.installWorkerByteFaithfulWrites(),
    installNumericOpenFlags: () => binding.installWorkerNumericOpenFlags(),
  }
}

function synthesizeFromBinding(
  request: WorkerEntrySyntheticRequest,
  sink: WorkerEntryResponseSink,
): WorkerEntrySyntheticExchange {
  // The binding is already loaded whenever this function is reachable.
  const binding = bindingForSynthesize
  if (binding === undefined) throw new Error('worker entry: the runtime binding is not loaded yet')
  return binding.createSyntheticExchange({
    t: 'req',
    id: 0,
    method: request.method,
    url: request.path,
    headers: request.headers,
    body: request.body,
  }, sink)
}

function loadDefaultSynthesize(): Promise<WorkerEntrySynthesize> {
  return loadRuntimeBinding().then(() => synthesizeFromBinding)
}

let activeHost: PhoneWorkerHostLike | undefined
let activeHandle: PhoneWorkerHandle | undefined
let role: 'unknown' | 'host' | 'shell' = 'unknown'
const pendingPageFrames: unknown[] = []
let pumpInstalled = false

/** Install the page message pump once per Worker global scope. */
function ensurePageMessagePump(): void {
  if (pumpInstalled) return
  pumpInstalled = true
  const scope = (globalThis as { self?: { addEventListener?: (type: string, listener: (event: unknown) => void) => void } }).self
  if (typeof scope?.addEventListener !== 'function') return
  scope.addEventListener('message', (event: unknown) => {
    try {
      handlePageMessage((event as { data?: unknown }).data)
    } catch (error) {
      console.error('worker entry: page message failed', error)
    }
  })
}

function handlePageMessage(data: unknown): void {
  if (role === 'shell') return
  if (activeHost !== undefined) {
    activeHost.handleMessage(data)
    return
  }
  let init: InitFrame | undefined
  try {
    init = parseInitFrame(data)
  } catch (error) {
    reportPageError(error, defaultPagePost)
    return
  }
  if (init !== undefined) {
    if (role === 'host') {
      console.error('worker entry: duplicate init frame ignored')
      return
    }
    role = 'host'
    bootFromInit(init)
    return
  }
  if (isShellStartFrame(data)) {
    role = 'shell'
    void loadRuntimeBinding().then(
      (binding) => { binding.runShellRole(data) },
      (error: unknown) => { console.error('worker entry: shell role failed', error) },
    )
    return
  }
  pendingPageFrames.push(data)
}

/**
 * Start the Worker from a page init frame.
 *
 * The optional runtime is the same test seam `startPhoneWorker` already
 * accepts; the page path never supplies it. The catch redacts the init frame's
 * exact token/env/image/overlay values before the line reaches `console.error`,
 * because the Native console bridge forwards those lines into the app log, and
 * posts a terminal `pdsh-error` for failures that happen before any host exists.
 * @param frame - parsed page init frame.
 * @param runtime - runtime override for a focused boot test.
 */
export function bootFromInit(frame: InitFrame, runtime?: PhoneWorkerRuntime): void {
  const secrets = bootTransportSecretValues(frame)
  let options: PhoneWorkerOptions
  try {
    options = {
      ...initOptions(frame),
      ...runtime === undefined ? {} : { runtime },
    }
  } catch (error) {
    // The page's query can parse as JSON yet fail field validation before
    // startPhoneWorker is reached; the page still needs a terminal frame.
    const failure = bootFailureError(error, secrets)
    console.error('worker entry: boot failed', redactBootFailureDetail(failure))
    reportPageError(failure, defaultPagePost)
    return
  }
  void startPhoneWorker(options).catch((error: unknown) => {
    const reported = typeof error === 'object' && error !== null && reportedPageErrors.has(error)
    const failure = reported ? error : bootFailureError(error, secrets)
    console.error(
      'worker entry: boot failed',
      redactBootFailureDetail(failure),
    )
    // startPhoneWorker's wrapper reports its own early failures; this fallback
    // covers any failure that escaped without a page frame.
    if (!reported) reportPageError(failure, options.pagePost ?? defaultPagePost)
  })
}

/** Errors already posted as `pdsh-error`, so a second catch does not duplicate. */
const reportedPageErrors = new WeakSet<object>()

function reportPageError(error: unknown, pagePost: (message: unknown) => void): void {
  if (typeof error === 'object' && error !== null) reportedPageErrors.add(error)
  const message = error instanceof Error ? `${error.name}: ${error.message}` : String(error)
  console.error('worker entry:', message)
  pagePost({ t: 'pdsh-error', message })
}

function defaultPagePost(message: unknown): void {
  const scope = (globalThis as { self?: { postMessage?: (message: unknown, transfer?: Transferable[]) => void } }).self
  try {
    scope?.postMessage?.(message)
  } catch (error) {
    console.error('worker entry: failed to post to the page', error)
  }
}

/** Page `{t:'init'}` payload after structural validation. */
export interface InitFrame {
  readonly image: string
  readonly overlays: readonly string[]
  readonly xl: Record<string, unknown>
}

function parseInitFrame(data: unknown): InitFrame | undefined {
  if (data === null || typeof data !== 'object') return undefined
  const record = data as Record<string, unknown>
  if (record['t'] !== 'init') return undefined
  const image = record['image']
  if (typeof image !== 'string') throw new Error('worker entry: init frame needs a string image URL')
  const overlays = record['overlays']
  if (!Array.isArray(overlays) || overlays.some(overlay => typeof overlay !== 'string')) {
    throw new Error('worker entry: init frame needs an array of string overlay URLs')
  }
  const xl = record['xl']
  if (xl !== undefined && (xl === null || typeof xl !== 'object' || Array.isArray(xl))) {
    throw new Error('worker entry: init frame xl must be an object')
  }
  return { image, overlays: overlays as string[], xl: (xl ?? {}) as Record<string, unknown> }
}

function initOptions(frame: InitFrame): PhoneWorkerOptions {
  const xl = frame.xl
  const sessionEpoch = xl['sessionEpoch'] ?? xl['session_epoch']
  const lastMseq = xl['lastMseq'] ?? xl['last_mseq']
  return {
    image: frame.image,
    overlays: frame.overlays,
    channelURL: firstString(xl, ['channelURL', 'channelUrl']),
    token: firstString(xl, ['token']),
    env: stringRecord(xl['env']),
    fence: parseFenceInput(xl['fence']),
    bootId: firstString(xl, ['bootId', 'boot_id']),
    sessionEpoch: sessionEpoch === undefined ? undefined : toBigIntValue(sessionEpoch, 'session epoch'),
    lastMseq: lastMseq === undefined ? undefined : toBigIntValue(lastMseq, 'last mseq'),
    egressAllow: stringList(xl['egressAllow'] ?? xl['egress_allow'], 'egress allow-list'),
    pagePost: defaultPagePost,
  }
}

function isShellStartFrame(data: unknown): boolean {
  return data !== null && typeof data === 'object' && (data as { t?: unknown }).t === 'shell-start'
}

// ------------------------------------------------------------ normalization

interface NormalizedOptions {
  readonly imageURL: string
  readonly overlayURLs: readonly string[]
  readonly channelURL: string
  readonly token: string | undefined
  readonly env: Readonly<Record<string, string>> | undefined
  readonly fence: Fence
  readonly bootId: string
  readonly sessionEpoch: bigint
  readonly lastMseq: bigint
  readonly socketFactory: ((url: string) => WebSocketLike) | undefined
  readonly runtime: PhoneWorkerRuntime | undefined
  /** Budget-table sink policy; `{}` applies the host environment or the 128 MiB tier default. */
  readonly limits: VfsSinkLimits
  readonly python: Omit<PythonToolboxOptions, 'vfs'> | false | undefined
  readonly jq: Omit<JqToolboxOptions, 'vfs'> | false | undefined
  /** Egress host allow-list from the init message; undefined means not reported. */
  readonly egressAllow: readonly string[] | undefined
  readonly pagePost: (message: unknown) => void
}

function normalizeOptions(options: PhoneWorkerOptions): NormalizedOptions {
  const imageURL = options.imageURL ?? options.image
  if (imageURL === undefined || imageURL === '') throw new Error('worker entry: image URL is required')
  const overlayURLs = options.overlayURLs ?? options.overlays ?? []
  const channelURL = options.channelURL ?? options.channelUrl
  if (channelURL === undefined || channelURL === '') throw new Error('worker entry: channel URL is required')
  const fence = parseFenceInput(options.fence)
  return {
    imageURL,
    overlayURLs,
    channelURL,
    token: options.token,
    env: options.env,
    fence,
    bootId: options.bootId ?? randomBootId(),
    sessionEpoch: toBigIntValue(options.sessionEpoch ?? fence.generation, 'session epoch'),
    lastMseq: toBigIntValue(options.lastMseq ?? 0n, 'last mseq'),
    socketFactory: options.socketFactory,
    runtime: options.runtime,
    limits: normalizeSinkLimits(options.limits, options.env),
    python: options.python,
    jq: options.jq,
    egressAllow: normalizeEgressAllow(options.egressAllow ?? egressAllowFromEnvironment(options.env)),
    pagePost: options.pagePost ?? defaultPagePost,
  }
}

/** Worker environment variable that carries the host `/v1/http` allow-list. */
export const EGRESS_ALLOW_ENV = 'PDSH_EGRESS_ALLOW'

/**
 * Read the egress allow-list from the D24 Worker environment.
 *
 * The init message's `xl.env` is the same host-supplied map the process shim
 * reads. Accepting a comma/whitespace list here means the App can wire the
 * gateway allow-list without changing the init schema; an explicit
 * `xl.egressAllow` still wins.
 * @param env - init-message environment, if supplied.
 * @returns The hosts, or undefined when the host did not report a list.
 */
function egressAllowFromEnvironment(
  env: Readonly<Record<string, string>> | undefined,
): readonly string[] | undefined {
  const raw = env?.[EGRESS_ALLOW_ENV]
  if (raw === undefined) return undefined
  return raw.split(/[\s,]+/u).filter(entry => entry !== '')
}

/**
 * Normalize the init-message egress allow-list.
 *
 * The list is display truth only, but a non-string entry is a host bug: a
 * silently coerced `[object Object]` host would make the manifest lie. Reject
 * it before the host boots.
 * @param value - init-message list, if supplied.
 * @returns The list in its configured order.
 */
function normalizeEgressAllow(value: readonly string[] | undefined): readonly string[] | undefined {
  if (value === undefined) return undefined
  if (!Array.isArray(value) || value.some(entry => typeof entry !== 'string')) {
    throw new TypeError('worker entry: egressAllow must be an array of strings')
  }
  return [...value]
}

/**
 * Resolve the host budget-table sink policy early, before the VFS boots.
 *
 * An explicit `maxFileBytes` (tests, a host that injects the policy directly)
 * wins; otherwise the host's `PDSH_SINGLE_FILE_LIMIT_BYTES` is clamped and used,
 * and no value means the built-in 8 GiB tier default applies downstream. The
 * durability ack window is validated (with its env override) once, here.
 * @param limits - explicit policy, if any.
 * @param env - the page-supplied Worker environment.
 * @returns the effective sink policy.
 */
/** Host-published WASI hot-instance ceiling for tool workers (budgets.md §4). */
const WASI_HOT_INSTANCE_ENV = 'PDSH_WASI_HOT_INSTANCE_BYTES'
/** Contract range of a configured hot-instance ceiling: 96 MiB ... 640 MiB. */
const MIN_HOT_INSTANCE_BYTES = 96 * 1024 * 1024
const MAX_HOT_INSTANCE_BYTES = 640 * 1024 * 1024

/**
 * Reads the host's hot-instance ceiling. A missing, non-decimal or
 * non-positive value yields undefined (the 8 GiB default applies); an
 * out-of-range value is clamped, never a start failure (budgets.md §4).
 */
export function hotInstanceBytesFromEnvironment(
  env: Readonly<Record<string, string>> | undefined,
): number | undefined {
  const raw = env?.[WASI_HOT_INSTANCE_ENV]
  if (raw === undefined || raw === '' || !/^[0-9]+$/u.test(raw)) return undefined
  const parsed = Number(raw)
  if (!Number.isSafeInteger(parsed) || parsed <= 0) return undefined
  return Math.min(MAX_HOT_INSTANCE_BYTES, Math.max(MIN_HOT_INSTANCE_BYTES, parsed))
}

/** Environment names of the host VFS tier quotas (budgets.md §4). */
const VFS_LIMIT_ENV = {
  vfsLogicalBytes: 'PDSH_VFS_LOGICAL_BYTES',
  vfsWorkspaceBytes: 'PDSH_VFS_WORKSPACE_BYTES',
  vfsSessionsBytes: 'PDSH_VFS_SESSIONS_BYTES',
  vfsTmpBytes: 'PDSH_VFS_TMP_BYTES',
} as const

/**
 * Reads the host's VFS tier quotas so the published capability manifest and
 * the host's write-time quota carry one set of numbers. A missing, non-decimal
 * or non-positive value yields undefined and the published prior applies.
 */
export function vfsLimitsFromEnvironment(
  env: Readonly<Record<string, string>> | undefined,
): Partial<Record<'vfsLogicalBytes' | 'vfsWorkspaceBytes' | 'vfsSessionsBytes' | 'vfsTmpBytes', number>> {
  const result: Partial<Record<'vfsLogicalBytes' | 'vfsWorkspaceBytes' | 'vfsSessionsBytes' | 'vfsTmpBytes', number>> = {}
  const fields = ['vfsLogicalBytes', 'vfsWorkspaceBytes', 'vfsSessionsBytes', 'vfsTmpBytes'] as const
  for (const field of fields) {
    const raw = env?.[VFS_LIMIT_ENV[field]]
    if (raw === undefined || raw === '' || !/^[0-9]+$/u.test(raw)) continue
    const parsed = Number(raw)
    if (!Number.isSafeInteger(parsed) || parsed <= 0) continue
    result[field] = parsed
  }
  return result
}

function normalizeSinkLimits(
  limits: VfsSinkLimits | undefined,
  env: Readonly<Record<string, string>> | undefined,
): VfsSinkLimits {
  const explicit = limits?.maxFileBytes
  if (explicit !== undefined && (!Number.isSafeInteger(explicit) || explicit < 0)) {
    throw new RangeError('worker entry: maxFileBytes must be a non-negative safe integer')
  }
  const maxFileBytes = explicit !== undefined ? explicit : singleFileLimitFromEnvironment(env)
  const ackTimeoutMs = limits?.ackTimeoutMs
  // The resolver validates the flow-control window (and its env override) once,
  // here, so a typo fails the boot instead of surfacing mid-write.
  const flowControlTimeoutMs = limits?.flowControlTimeoutMs === undefined
    ? undefined
    : resolveVfsFlowControlTimeoutMs(limits.flowControlTimeoutMs)
  if (maxFileBytes === undefined && ackTimeoutMs === undefined && flowControlTimeoutMs === undefined) return {}
  // The resolver validates the ack window (and the env override) once, here.
  const resolvedAckTimeoutMs = resolveDurabilityAckTimeoutMs(ackTimeoutMs)
  return {
    ...maxFileBytes === undefined ? {} : { maxFileBytes },
    ackTimeoutMs: resolvedAckTimeoutMs,
    ...flowControlTimeoutMs === undefined ? {} : { flowControlTimeoutMs },
  }
}

/** The loopback HTTP origin of the channel URL (ws/wss → http/https). */
function loopbackOrigin(channelURL: string): string | undefined {
  try {
    const url = new URL(channelURL, (globalThis as { location?: { href: string } }).location?.href)
    if (url.protocol === 'ws:' || url.protocol === 'http:') url.protocol = 'http:'
    else if (url.protocol === 'wss:' || url.protocol === 'https:') url.protocol = 'https:'
    else return undefined
    return url.origin
  } catch {
    return undefined
  }
}

/**
 * Environment names the Worker plugins consume (see the worker profile):
 * `PDSH_CHANNEL_URL` / `PDSH_CHANNEL_TOKEN` are the ordered channel coordinates,
 * `PDSH_CHANNEL_ORIGIN` is the same host's loopback HTTP origin for `/v1/http`.
 */
function channelEnvironment(options: NormalizedOptions): Record<string, string> {
  const env: Record<string, string> = { PDSH_CHANNEL_URL: options.channelURL }
  if (options.token !== undefined && options.token !== '') env.PDSH_CHANNEL_TOKEN = options.token
  const origin = loopbackOrigin(options.channelURL)
  if (origin !== undefined) env.PDSH_CHANNEL_ORIGIN = origin
  return env
}

function applyProcessEnvironment(env: Record<string, string>): void {
  const target = (globalThis as { process?: { env?: Record<string, string | undefined> } }).process
  if (target?.env === undefined) return
  Object.assign(target.env, env)
}

function firstString(record: Record<string, unknown>, names: readonly string[]): string | undefined {
  for (const name of names) {
    const value = record[name]
    if (typeof value === 'string') return value
  }
  return undefined
}

/**
 * Parse an optional init-message string list.
 * @param value - init field value (`undefined` means the host did not send it).
 * @param what - field name for the failure message.
 * @returns The strings, or undefined when absent.
 */
function stringList(value: unknown, what: string): string[] | undefined {
  if (value === undefined) return undefined
  if (!Array.isArray(value) || value.some(entry => typeof entry !== 'string')) {
    throw new Error(`worker entry: ${what} must be an array of strings`)
  }
  return [...value as string[]]
}

function stringRecord(value: unknown): Readonly<Record<string, string>> | undefined {
  if (value === undefined) return undefined
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('worker entry: env must be an object of strings')
  }
  const out: Record<string, string> = {}
  for (const [key, member] of Object.entries(value as Record<string, unknown>)) {
    if (typeof member !== 'string') throw new Error(`worker entry: env.${key} must be a string`)
    out[key] = member
  }
  return out
}

function parseFenceInput(value: unknown): Fence {
  if (value === undefined) {
    return { owner: 'phone', generation: 0n, wal_seq: 0n }
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('worker entry: fence must be an object')
  }
  const record = value as Record<string, unknown>
  const owner = record['owner']
  if (typeof owner !== 'string' || owner.length === 0) throw new Error('worker entry: fence.owner is required')
  return {
    owner,
    generation: toBigIntValue(record['generation'] ?? 0n, 'fence.generation'),
    wal_seq: toBigIntValue(record['wal_seq'] ?? record['walSeq'] ?? 0n, 'fence.wal_seq'),
  }
}

function toBigIntValue(value: unknown, what: string): bigint {
  if (typeof value === 'bigint') {
    if (value < 0n) throw new Error(`worker entry: ${what} must be non-negative`)
    return value
  }
  if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) return BigInt(value)
  if (typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value)) return BigInt(value)
  throw new Error(`worker entry: ${what} must be a non-negative integer`)
}

function randomBootId(): string {
  const bytes = new Uint8Array(16)
  const cryptoObject = (globalThis as { crypto?: { getRandomValues?: (array: Uint8Array) => Uint8Array } }).crypto
  if (cryptoObject?.getRandomValues !== undefined) {
    cryptoObject.getRandomValues(bytes)
  } else {
    for (let index = 0; index < bytes.length; index++) bytes[index] = Math.floor(Math.random() * 256)
  }
  let hex = ''
  for (const byte of bytes) hex += byte.toString(16).padStart(2, '0')
  return hex
}

// --------------------------------------------------------------- VFS helpers

/**
 * D4 sink predicate: the namespace owns it, so the channel stream and the
 * budget accounting cannot disagree about what is durable.
 * @param path - mutation path the runtime published.
 * @returns whether the change belongs in the VFS_MUT stream.
 */
function isSinkPath(path: string): boolean {
  return WORKER_VFS_NAMESPACE.sinkEligible(path)
}

/** One encoded VFS_MUT body, before the host-allocated mseq is prepended. */
interface MutationBodyShape {
  op: VfsOp
  mode: number
  mflags: number
  appendFrom: bigint
  path: string
  data: Uint8Array
}

/**
 * Split one logical file write into wire-sized mutation bodies.
 *
 * A mutation carries at most {@link MAX_MUTATION_DATA}; a larger suffix is a
 * chain of appended bodies whose `appendFrom` is the accepted logical length
 * (channel.md §3.1). The first body of a complete write is the complete write
 * itself (bit1 clear) so the host replaces the file base; every later body is
 * appended. An append mutation keeps its original base offset on the first
 * body instead of re-sending the prefix.
 * @param path - mutation target.
 * @param mode - permission bits.
 * @param data - the suffix bytes to publish.
 * @param baseAppendFrom - logical length the suffix starts at.
 * @param appended - whether the logical mutation is already an append.
 * @param entryChanged - whether the directory entry changed.
 * @returns one or more bodies, each at most {@link MAX_MUTATION_DATA} bytes.
 */
function writeMutationBodies(
  path: string,
  mode: number,
  data: Uint8Array,
  baseAppendFrom: number,
  appended: boolean,
  entryChanged: boolean,
): MutationBodyShape[] {
  const firstFlags = (appended ? 2 : 0) | (entryChanged ? 1 : 0)
  if (data.byteLength <= MAX_MUTATION_DATA) {
    return [{
      op: VfsOp.WRITE,
      mode,
      mflags: firstFlags,
      appendFrom: appended ? BigInt(baseAppendFrom) : 0n,
      path,
      data,
    }]
  }
  const bodies: MutationBodyShape[] = []
  let offset = 0
  let first = true
  while (offset < data.byteLength) {
    const end = Math.min(offset + MAX_MUTATION_DATA, data.byteLength)
    const bodyAppended = appended || !first
    bodies.push({
      op: VfsOp.WRITE,
      mode,
      // Only the first body preserves the original entryChanged bit; the
      // appended suffix does not change the directory entry again.
      mflags: (bodyAppended ? 2 : 0) | (first && entryChanged ? 1 : 0),
      appendFrom: bodyAppended ? BigInt(baseAppendFrom + offset) : 0n,
      path,
      data: data.subarray(offset, end),
    })
    offset = end
    first = false
  }
  return bodies
}

/**
 * Convert one runtime VFS mutation into the wire bodies that publish it.
 *
 * The runtime publishes the *complete post-write bytes* plus the offset an
 * append started at (storage/types.ts `VfsMutation`), while 0x10 carries only
 * the suffix from `append_from` (channel.md §3.1). Take the suffix; sending the
 * whole file would make the host append a duplicate prefix. A post-write file
 * above the single-file budget is the resource-refusal class: the channel
 * stays open and `flush()` carries the diagnostic trailer.
 * @param mutation - runtime mutation.
 * @param maxFileBytes - active single-file budget.
 * @returns one body per wire mutation, in ascending append order.
 */
function mutationToBodies(mutation: WorkerEntryMutation, maxFileBytes: number): MutationBodyShape[] {
  switch (mutation.kind) {
    case 'write': {
      const appendedFrom = mutation.appendedFrom
      const appended = appendedFrom !== undefined
      if (appended && (!Number.isSafeInteger(appendedFrom) || appendedFrom < 0 || appendedFrom > mutation.bytes.byteLength)) {
        throw mutationRefusal(
          mutation.path,
          'EINVAL',
          `append offset ${String(appendedFrom)} is outside the ${mutation.bytes.byteLength}-byte post-write file`,
        )
      }
      if (mutation.bytes.byteLength > maxFileBytes) {
        throw new VfsRefusalError({
          code: 'EFBIG',
          path: mutation.path,
          limit: maxFileBytes,
          hint: vfsRefusalHint('EFBIG', maxFileBytes, mutation.path),
        })
      }
      const data = appended ? mutation.bytes.subarray(appendedFrom) : mutation.bytes
      return writeMutationBodies(
        mutation.path,
        mutation.mode,
        data,
        appended ? appendedFrom : 0,
        appended,
        mutation.entryChanged,
      )
    }
    case 'mkdir':
      return [{ op: VfsOp.MKDIR, mode: mutation.mode, mflags: 0, appendFrom: 0n, path: mutation.path, data: new Uint8Array(0) }]
    case 'remove':
      return [{ op: VfsOp.REMOVE, mode: 0, mflags: 0, appendFrom: 0n, path: mutation.path, data: new Uint8Array(0) }]
    case 'chmod':
      return [{ op: VfsOp.CHMOD, mode: mutation.mode, mflags: 0, appendFrom: 0n, path: mutation.path, data: new Uint8Array(0) }]
  }
}

function mutationRefusal(path: string, code: string, message: string): Error {
  const error = new Error(`worker entry: ${message}`) as Error & { code: string; path: string; syscall: string }
  error.code = code
  error.path = path
  error.syscall = 'write'
  return error
}

/**
 * Answer a host VFS_RESYNC by re-publishing the whole file.
 *
 * A file larger than one mutation is answered exactly like a large write: one
 * complete write at the next normal mseq plus appended suffixes at the
 * following mseqs (channel.md §3.1, §3.4). The old path compared the file
 * against the 15 MiB mutation bound and answered VFS_CONFLICT, which closed
 * the ordered channel and hung the session for every legal file above that
 * bound; that branch is now a resource diagnostic for a file over the
 * single-file budget, which also keeps the channel open.
 *
 * D8: the repair re-sends the bytes the live VFS currently holds, so this read
 * is the persistence chain's last byte boundary before the WAL. It must stay
 * byte-exact for every payload class: the Worker's VFS convention for a string
 * value is just-bash's latin1-shaped `ByteString` (one JS character per byte),
 * never decoded text, so re-encoding such a string as UTF-8 would silently
 * double-encode every byte ≥ 0x80 and write the corrupted content back to the
 * WAL, the materialized copy and the resume overlay. A Node-shaped VFS is
 * asked for raw bytes explicitly (`{ encoding: null }`); a string a VFS
 * implementation returns anyway is converted one character per byte.
 * @param vfs - in-memory filesystem authority (D8).
 * @param channel - connected ordered channel.
 * @param limits - sink policy; defaults to the 8 GiB tier single-file budget.
 * @returns a disposer for the frame listener.
 */
export function installResyncHandler(
  vfs: WorkerEntryVfs,
  channel: WorkerEntryChannel,
  limits: VfsSinkLimits = {},
): () => void {
  const requestedLimit = limits.maxFileBytes ?? DEFAULT_SINGLE_FILE_LIMIT
  if (!Number.isSafeInteger(requestedLimit) || requestedLimit < 0) {
    throw new RangeError('worker entry: maxFileBytes must be a non-negative safe integer')
  }
  const maxFileBytes = Math.min(requestedLimit, MAX_SINGLE_FILE_LIMIT)
  return channel.onFrame((frame) => {
    if (frame.type !== FrameType.VFS_RESYNC) return
    let path: string
    try {
      path = decodeVfsResync(frame.payload).path
    } catch (error) {
      console.error('worker entry: malformed VFS_RESYNC', error)
      return
    }
    const sendConflict = (message: string): void => {
      try {
        channel.send(FrameType.ERROR, encodeUtf8(canonicalStringify({ code: 'VFS_CONFLICT', message })))
      } catch {
        // The channel is already gone; the failure is still loud in the console.
      }
      void channel.close()
    }
    const reader = vfs.readFileSync
    if (reader === undefined) {
      sendConflict(`${path} cannot be re-read: this VFS exposes no readFileSync`)
      return
    }
    let contents: string | Uint8Array
    try {
      // `{ encoding: null }` is Node's explicit byte request: no decoded text
      // can enter the repair when the VFS honours it.
      contents = reader.call(vfs, path, { encoding: null })
    } catch {
      sendConflict(`${path} is no longer a regular file`)
      return
    }
    const stat = vfs.statSync?.call(vfs, path)
    if (stat !== undefined && !stat.isFile()) {
      sendConflict(`${path} is no longer a regular file`)
      return
    }
    const data = typeof contents === 'string' ? byteStringToBytes(contents) : contents
    if (data.byteLength > maxFileBytes) {
      // Resource refusal, not a protocol error: consume no mseq, keep the
      // channel open, and name the budget so the repair is diagnosable.
      const record: VfsRefusalRecord = {
        code: 'EFBIG',
        path,
        limit: maxFileBytes,
        hint: vfsRefusalHint('EFBIG', maxFileBytes, path),
      }
      try {
        channel.send(FrameType.ERROR, encodeUtf8(canonicalStringify(vfsRefusedPayload(record))))
        channel.send(FrameType.CONSOLE, encodeUtf8(canonicalStringify({
          level: 'error',
          text: vfsRefusalConsoleText(record),
        })))
      } catch (error) {
        console.error('worker entry: could not send the VFS_RESYNC refusal', error)
      }
      return
    }
    const mode = stat === undefined ? 0o644 : stat.mode & 0o7777
    const bodies = writeMutationBodies(path, mode, data, 0, false, true)
    try {
      for (const body of bodies) {
        const mseq = channel.nextMseq()
        channel.send(FrameType.VFS_MUT, encodeVfsMutation({ mseq, ...body }))
      }
    } catch (error) {
      console.error('worker entry: VFS_RESYNC re-publish failed', error)
    }
  })
}

/**
 * Convert a VFS byte string (one JS character per byte) to bytes.
 *
 * The Worker's VFS surfaces carry shell-style byte strings, and the runtime's
 * `node:fs` replacement stores the UTF-8 encoding of whatever a caller passes
 * as a string. Reading a repair through that convention is therefore only
 * byte-exact when the conversion is one character per byte (see
 * `shell-ext/src/encoding.ts`, which owns the shared shell ↔ WASI conversion).
 * @param value - latin1-shaped byte string.
 * @returns the exact bytes it represents.
 */
function byteStringToBytes(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length)
  for (let index = 0; index < value.length; index += 1) bytes[index] = value.charCodeAt(index) & 0xff
  return bytes
}

// ------------------------------------------------------------ channel globals

function installChannelGlobals(channel: WorkerEntryChannel): () => void {
  return channel.onFrame((frame) => {
    if (frame.type === FrameType.LIFECYCLE) {
      const payload = parseLifecycle(frame.payload)
      if (payload === undefined) return
      ;(globalThis as { __PDSH_LIFECYCLE__?: LifecyclePayload }).__PDSH_LIFECYCLE__ = payload
      dispatchWorkerEvent('pdsh-lifecycle', payload)
    } else if (frame.type === FrameType.FENCE) {
      const payload = parseFencePayload(frame.payload)
      if (payload === undefined) return
      ;(globalThis as { __PDSH_FENCE__?: FencePayload }).__PDSH_FENCE__ = payload
      dispatchWorkerEvent('pdsh-fence', payload)
    }
  })
}

function parseLifecycle(payload: Uint8Array): LifecyclePayload | undefined {
  try {
    const value = JSON.parse(decodeJson(payload)) as Record<string, unknown>
    const state = value['state']
    const admission = value['admission']
    const reason = value['reason']
    const budget = value['budget']
    if ((state !== 'run' && state !== 'pause' && state !== 'stop')
      || (admission !== 'open' && admission !== 'closed')
      || typeof reason !== 'string'
      || typeof budget !== 'number' || !Number.isSafeInteger(budget) || budget < 0) {
      return undefined
    }
    return { state, budget: BigInt(budget), admission, reason }
  } catch {
    return undefined
  }
}

function parseFencePayload(payload: Uint8Array): FencePayload | undefined {
  try {
    const value = JSON.parse(decodeJson(payload)) as Record<string, unknown>
    const admission = value['admission']
    const fenceValue = value['fence']
    if ((admission !== 'open' && admission !== 'closed')
      || fenceValue === null || typeof fenceValue !== 'object' || Array.isArray(fenceValue)) {
      return undefined
    }
    const fenceRecord = fenceValue as Record<string, unknown>
    const owner = fenceRecord['owner']
    if (typeof owner !== 'string') return undefined
    return {
      fence: {
        owner,
        generation: toBigIntValue(fenceRecord['generation'] ?? 0n, 'fence.generation'),
        wal_seq: toBigIntValue(fenceRecord['wal_seq'] ?? 0n, 'fence.wal_seq'),
      },
      admission,
    }
  } catch {
    return undefined
  }
}

function decodeJson(payload: Uint8Array): string {
  return new TextDecoder('utf-8', { fatal: true }).decode(payload)
}

function dispatchWorkerEvent(type: string, detail: unknown): void {
  const EventConstructor = (globalThis as { CustomEvent?: new (type: string, init?: { detail?: unknown }) => Event }).CustomEvent
  if (EventConstructor === undefined) return
  const event = new EventConstructor(type, { detail })
  try {
    workerEvents.dispatchEvent(event)
  } catch (error) {
    console.debug('worker entry: lifecycle event listener failed', error)
  }
  const scope = globalThis as { dispatchEvent?: (event: Event) => boolean }
  if (typeof scope.dispatchEvent === 'function') {
    try {
      scope.dispatchEvent(event)
    } catch (error) {
      console.debug('worker entry: worker-global event listener failed', error)
    }
  }
}

;(globalThis as { __PDSH_EVENTS__?: EventTarget }).__PDSH_EVENTS__ = workerEvents

// -------------------------------------------------------------- console text

interface LifecycleConsoleLine {
  readonly level: 'debug' | 'info' | 'warn' | 'error'
  readonly text: string
}

function formatConsoleArgs(args: readonly unknown[]): string {
  let text = args.map(formatConsoleArg).join(' ')
  if (text.length > CONSOLE_LINE_LIMIT) text = `${text.slice(0, CONSOLE_LINE_LIMIT)}…`
  return text
}

function formatConsoleArg(value: unknown): string {
  if (typeof value === 'string') return value
  if (value instanceof Error) return value.stack ?? `${value.name}: ${value.message}`
  if (typeof value === 'bigint') return value.toString(10)
  try {
    return JSON.stringify(value, (_key, member: unknown) => typeof member === 'bigint' ? member.toString(10) : member) ?? String(value)
  } catch {
    return String(value)
  }
}

// --------------------------------------------------------------- entry start

/** Auto-install the page pump in a real Worker global scope. */
ensurePageMessagePump()
