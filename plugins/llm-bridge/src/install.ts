// SPDX-License-Identifier: MIT
/**
 * Process-wide installation of the node:http fetch. DSH treats outbound HTTP
 * transport as a per-process fact (its own proxy support installs undici's
 * global dispatcher before any plugin mounts, covering model adapters, web
 * tools, MCP over HTTP and telemetry); this module swaps the transport at the
 * same level, so every fetch consumer works under `--jitless` unchanged.
 *
 * The transport is installed even when WebAssembly exists: in the phone Worker
 * the browser's WebAssembly is present, but no `node:http` client exists, so
 * external requests must go through the host loopback `POST /v1/http` with
 * the Worker's own fetch. `nativeFetchUsable` is retained as a diagnostic.
 *
 * `node:http` transport is loaded lazily: the Worker path never evaluates the
 * node:https client, so the runtime module table does not need a usable
 * `node:https` module and no `https.Agent` is constructed there. The desktop
 * implementation only resolves when a request actually needs it.
 *
 * The Worker host route is found from the environment the entry sets before
 * DSH boots: `PDSH_CHANNEL_TOKEN` (bearer) and `PDSH_CHANNEL_URL` /
 * `PDSH_CHANNEL_ORIGIN` (loopback origin), with the desktop names as fallbacks.
 * @module @phone-dsh/dsh-llm-bridge/install
 */

import type { HostProxyOptions, NodeFetchOptions } from './node-fetch.ts'
import { LlmError } from '@deepseek-ai/dsh-llm'

/** Marks a globalThis.fetch installed by this module. */
export const NODE_FETCH_MARK = Symbol.for('phone-dsh.dsh.node-fetch')

/**
 * Default inactivity interval for a host-route response, in milliseconds.
 *
 * The interval covers the wait for the response head and, once the stream is
 * open, the wait for the next body chunk. It is deliberately shorter than the
 * model adapter's own stream idle watchdog: a delivery stall (the response was
 * received by the host gateway but never reaches the Worker) must fail the
 * request with a typed error instead of silently consuming the turn budget.
 */
export const DEFAULT_DELIVERY_IDLE_TIMEOUT_MS = 60_000

/** Worker → host header asking for the suffix of a previously delivered body. */
export const RESUME_FROM_HEADER = 'x-pdsh-resume-from'
/** Host → Worker header marking a response served from the host response log. */
export const RESUMED_HEADER = 'x-pdsh-resumed'
/** Bounded host-route body resumes after the inactivity interval elapses. */
export const MAX_DELIVERY_RESUMES = 1
/**
 * Head/inactivity bound for a resume attempt, in milliseconds.
 *
 * A resume may reach the host before the original recording has committed
 * (the consumer aborted first); the host waits for the commit instead of
 * re-contacting the upstream, so the resume head can take longer than the
 * normal delivery inactivity interval. Bounded so the request still fails loud
 * when the host cannot serve the resume at all.
 */
export const RESUME_TIMEOUT_MS = 30_000

/**
 * Share of a watchdog window that must drain on the *active* clock for the
 * expiry to count as an upstream stall.
 *
 * A window is armed with `timeoutMs` of wall clock, so a fired timer proves the
 * wall clock advanced at least that far. A running process reports an active
 * delta close to `timeoutMs` (timers fire late, never early); a process that
 * iOS froze reports close to zero for the same window. Half the window keeps
 * the verdicts far from timer jitter, a busy main thread and the coarse
 * `performance.now()` resolutions some WebKit releases use, while still
 * honouring a genuine stall: the upstream must have swallowed half of the
 * window's active time before the request is failed.
 */
export const SUSPENSION_ACTIVE_RATIO = 0.5

/**
 * Bounds how many expired head or consumer-idle windows a suspension may renew.
 *
 * Renewing a suspended window spends no active budget, so without a bound a
 * clock that never advances (a stubbed or broken `performance.now()`) would
 * keep the wait alive forever. Three renewals cover repeated
 * background/foreground cycles inside one request and still end it in bounded
 * time. Body reads are bounded separately by `MAX_DELIVERY_RESUMES`, because
 * recovering a body also costs a host resume.
 */
export const MAX_SUSPENSION_RENEWALS = 3

/** Per-process delivery instrumentation (the Worker side of the three legs). */
export interface DeliveryMetricsSnapshot {
  /** Host-route responses whose head arrived. */
  readonly attempts: number
  /** Body bytes delivered to the model client. */
  readonly bodyBytes: number
  /** Inactivity intervals that expired on an open body. */
  readonly stalls: number
  /**
   * Watchdog windows that expired while the process itself was frozen.
   *
   * Counted separately from `stalls`: the wall clock drained without this
   * process running, so the upstream never got its inactivity interval and the
   * window was recovered instead of failing the request.
   */
  readonly suspends: number
  /** Resumes issued after a stalled body. */
  readonly resumes: number
  /** Body bytes that arrived through a resumed response. */
  readonly resumedBytes: number
}

const deliveryMetrics = { attempts: 0, bodyBytes: 0, stalls: 0, suspends: 0, resumes: 0, resumedBytes: 0 }

/** Snapshot of the Worker delivery counters. */
export function deliveryMetricsSnapshot(): DeliveryMetricsSnapshot {
  return { ...deliveryMetrics }
}

/**
 * A host-route model response stalled before its head or between body chunks.
 *
 * Extends DSH's provider-neutral `LlmError` so the adapter's own error path
 * rethrows it unchanged (`error instanceof LlmError`) instead of classifying
 * it as a transport failure. The stable code is not one of the default
 * retryable codes (`EMPTY_RESPONSE`, `RATE_LIMIT`, `SERVER`, `TIMEOUT`,
 * `TRANSPORT`): a frozen delivery leg repeats identically on every attempt, so
 * retrying would only burn the turn budget. The typed failure ends the model
 * request and reaches the session as an error event.
 */
export class DeliveryTimeoutError extends LlmError {
  /** Which leg of the delivery stalled. */
  readonly stage: 'head' | 'body'
  /** The inactivity interval that elapsed, in milliseconds. */
  readonly timeoutMs: number

  constructor(stage: 'head' | 'body', timeoutMs: number) {
    super(`llm-bridge: model response ${stage === 'head' ? 'headers' : 'body'} `
      + `delivery stalled for ${timeoutMs} ms (PDSH_DELIVERY_TIMEOUT)`, 'PDSH_DELIVERY_TIMEOUT')
    this.stage = stage
    this.timeoutMs = timeoutMs
  }
}

function resolveDeliveryIdleTimeout(explicit: number | undefined): number {
  const configured = explicit
    ?? Number((globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env?.PDSH_LLM_DELIVERY_IDLE_TIMEOUT_MS ?? '')
  if (Number.isFinite(configured) && configured > 0) return Math.trunc(configured)
  return DEFAULT_DELIVERY_IDLE_TIMEOUT_MS
}

const TOOL_CALL_CONTEXT_KEY = Symbol.for('phone-dsh.dsh.tool-call-context')
/** Mirrors `MCP_CALL_KEYS_KEY` in exec-bridge's call-context.ts (the owner). */
const MCP_CALL_KEYS_KEY = Symbol.for('phone-dsh.dsh.mcp-call-keys')
interface McpCallKeyEntry { readonly tool: string, readonly key: string, readonly matches: (args: unknown) => boolean }

function ambientToolKey(): string | undefined {
  return (globalThis as { [TOOL_CALL_CONTEXT_KEY]?: ToolCallStore })[TOOL_CALL_CONTEXT_KEY]?.getStore()?.key
}

/**
 * The journal key of a JSON-RPC `tools/call` body, by exact correlation with
 * the in-flight MCP calls the tool journal registered. Undefined for any other
 * body, and when no call or more than one call matches.
 */
export function correlatedMcpKey(body: Uint8Array | undefined): string | undefined {
  const entries = (globalThis as { [MCP_CALL_KEYS_KEY]?: Set<McpCallKeyEntry> })[MCP_CALL_KEYS_KEY]
  if (body === undefined || body.byteLength === 0 || entries === undefined || entries.size === 0) return undefined
  let message: unknown
  try { message = JSON.parse(new TextDecoder().decode(body)) } catch { return undefined }
  if (message === null || typeof message !== 'object' || Array.isArray(message)) return undefined
  const { method, params } = message as { method?: unknown, params?: { name?: unknown, arguments?: unknown } }
  if (method !== 'tools/call' || typeof params?.name !== 'string') return undefined
  const found = new Set<string>()
  for (const entry of entries) if (entry.tool === params.name && entry.matches(params.arguments)) found.add(entry.key)
  return found.size === 1 ? [...found][0] : undefined
}

const REDIRECT_STATUS = new Set([301, 302, 303, 307, 308])
const REDIRECT_STRIPPED = ['content-type', 'content-length', 'content-encoding', 'content-language', 'content-location']
/**
 * Final fetch null-body statuses (the Fetch standard also lists `101`/`103`,
 * which cannot be the final `Response` of a fetch): a `Response` for one of
 * these cannot carry a body. The host route re-wraps a streamed response for
 * resumable delivery; passing a body for `204`/`205`/`304` to the `Response`
 * constructor throws "Response cannot have a body with the given status." in
 * WebKit. A compliant MCP notification reply is exactly a 204, so the wrapper
 * must keep the null body instead of reconstructing one.
 */
const NULL_BODY_STATUS = new Set([204, 205, 304])

export type InstallMode = 'auto' | 'always' | 'never'

export interface InstallOptions {
  /** `auto` installs whenever the phone transport is needed; `never` keeps Node's fetch. */
  mode?: InstallMode
  /** Route matching requests through the host app's HTTP stack; defaults to the Worker route when detected. */
  proxy?: HostProxyOptions | undefined
  /** A fetch implementation for the host route; defaults to the pre-install global fetch. */
  proxyFetch?: typeof fetch | undefined
  /** Hosts that receive `X-PDSH-Idempotency-Key` inside a tool call; loopback and host-proxied requests always do. */
  idempotencyHosts?: readonly string[]
  /** Host-route response inactivity interval; defaults to `PDSH_LLM_DELIVERY_IDLE_TIMEOUT_MS` or 60 s. */
  deliveryIdleTimeoutMs?: number
}

/** Whether Node's own fetch can work in this process (WebAssembly present). Diagnostic only. */
export function nativeFetchUsable(): boolean {
  return typeof (globalThis as { WebAssembly?: unknown }).WebAssembly !== 'undefined'
}

/** True when this process is the phone Worker (ordered channel installed or its token present). */
export function workerRuntime(): boolean {
  if (typeof globalThis.__PDSH_CHANNEL__ !== 'undefined') return true
  return typeof process.env.PDSH_CHANNEL_TOKEN === 'string' && process.env.PDSH_CHANNEL_TOKEN !== ''
}

const OFFICIAL_SEARCH_API_BASE = 'https://api.deepseek.com/v1/tools'

const DNS_LABEL = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u
const PATH_SEGMENT = /^[A-Za-z0-9._~-]+$/u
const FORBIDDEN_BASE_CHARACTER = /[?#%\\@\s]|[^\x21-\x7e]/u

/**
 * The canonical independent Search/Fetch base, or `undefined` when invalid.
 *
 * `spec/v1/gateway-independent-search.md` §1 owns these rules and
 * `spec/v1/golden/gateway/independent-search/cases.json` is their judge.
 */
export function canonicalIndependentSearchBase(raw: string): string | undefined {
  const text = raw.replace(/^[\t\n\f\r ]+|[\t\n\f\r ]+$/gu, '')
  if (!/^https:\/\//iu.test(text)) return undefined
  const rest = text.slice('https://'.length)
  if (FORBIDDEN_BASE_CHARACTER.test(rest)) return undefined
  const slash = rest.indexOf('/')
  const host = (slash < 0 ? rest : rest.slice(0, slash)).toLowerCase()
  let path = slash < 0 ? '' : rest.slice(slash)
  if (host.length === 0 || host.length > 253 || /[:[\]]/u.test(host)) return undefined
  const labels = host.split('.')
  if (labels.length < 2 || !labels.every(label => DNS_LABEL.test(label))) return undefined
  if (!/[a-z]/u.test(labels.at(-1) ?? '')) return undefined
  if (path.endsWith('/')) path = path.slice(0, -1)
  const segments = path === '' ? [] : path.slice(1).split('/')
  if (!segments.every(segment => PATH_SEGMENT.test(segment) && segment !== '.' && segment !== '..')) return undefined
  const last = segments.at(-1)?.toLowerCase()
  if (last === 'search' || last === 'fetch') return undefined
  const canonical = `https://${host}${path}`
  return canonical.length <= 512 ? canonical : undefined
}

/** The base whose two operations the cookie Worker carries over `/v1/http`, if any. */
function cookieWebToolBase(env: NodeJS.ProcessEnv): string | undefined {
  if (env.PDSH_WEB_SEARCH_PROVIDER !== 'deepseek-search-api') return undefined
  const base = env.DEEPSEEK_SEARCH_API_BASE_URL
  if (base === undefined) return undefined
  if (base === OFFICIAL_SEARCH_API_BASE) return base
  return canonicalIndependentSearchBase(base) === base ? base : undefined
}

/** The implicit Worker host route on the same loopback origin as the channel. */
export function defaultHostProxy(): HostProxyOptions | undefined {
  const env = process.env
  const channelToken = env.PDSH_CHANNEL_TOKEN || env.PDSH_EXEC_BRIDGE_TOKEN
  // A cookie-authenticated launch has no channel bearer. The official and the
  // independent Search/Fetch operations still need the host to inject their key,
  // so exactly those two URLs ride /v1/http with the launch bearer.
  const webToolBase = channelToken ? undefined : cookieWebToolBase(env)
  const token = webToolBase !== undefined ? env.PDSH_DSH_LAUNCH_TOKEN : channelToken
  const origin = globalThis.location?.origin
  const url = env.PDSH_CHANNEL_ORIGIN
    ?? env.PDSH_EXEC_BRIDGE_URL
    ?? (origin !== undefined && (origin.startsWith('http://') || origin.startsWith('https://')) ? origin : undefined)
    ?? httpOriginFromChannelUrl(env.PDSH_CHANNEL_URL)
  if (!token || !url) {
    if (webToolBase === OFFICIAL_SEARCH_API_BASE) {
      throw new Error('llm-bridge: official web tools need the host gateway and launch bearer')
    }
    if (webToolBase !== undefined) {
      throw new Error('llm-bridge: independent web tools need the host gateway and launch bearer')
    }
    return undefined
  }
  if (webToolBase === undefined) return { url, token }
  const operations = new Set([`${webToolBase}/search`, `${webToolBase}/fetch`])
  return { url, token, match: target => operations.has(target.href) }
}

interface ToolCallStore { getStore(): { key: string } | undefined }

/**
 * Install the node:http fetch as `globalThis.fetch`.
 * @param options - install mode, host proxy route, and idempotency-header hosts.
 * @returns a restore function (a no-op when nothing was installed).
 */
export function installNodeFetch(options: InstallOptions = {}): () => void {
  const mode = options.mode ?? 'auto'
  if (mode === 'never') return () => {}
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'fetch')
  const previousFetch = typeof globalThis.fetch === 'function' ? globalThis.fetch : undefined
  const worker = workerRuntime()
  const explicit = options.proxy
  const proxy = explicit ?? (worker ? defaultHostProxy() : undefined)
  // In the Worker even a loopback URL has no node:http client: every request is
  // carried by the page's same-origin fetch to the host /v1/http route.
  const routed = proxy !== undefined && explicit === undefined && worker && proxy.match === undefined
    ? { ...proxy, match: () => true }
    : proxy
  if (!worker && mode === 'auto' && routed === undefined && nativeFetchUsable()) return () => {}
  const hosts = new Set(options.idempotencyHosts ?? [])
  const extraHeaders = (url: URL, viaProxy: boolean, key?: string): Record<string, string> | undefined => {
    const resolved = key ?? ambientToolKey()
    if (resolved === undefined) return undefined
    if (!viaProxy && !isLoopback(url) && !hosts.has(url.hostname)) return undefined
    return { 'x-pdsh-idempotency-key': resolved }
  }
  const proxyFetch = options.proxyFetch
    ?? (worker && routed !== undefined && previousFetch !== undefined ? previousFetch.bind(globalThis) : undefined)
  let implementation: typeof fetch
  if (routed !== undefined && proxyFetch !== undefined) {
    // The Worker's own fetch carries the loopback /v1/http request. URLs the
    // explicit match keeps local stay on the platform fetch in the Worker; only
    // a desktop process falls back to the node:http implementation.
    const fallback = worker ? previousFetch ?? unavailableFetch() : lazyNodeFetch({ proxy: routed, extraHeaders })
    implementation = hostRouteFetch(routed, proxyFetch, extraHeaders, fallback,
      resolveDeliveryIdleTimeout(options.deliveryIdleTimeoutMs))
  } else if (worker) {
    // No node:http client exists in the Worker. Without a host route there is
    // nothing to install, so keep the platform fetch untouched.
    return () => {}
  } else {
    implementation = lazyNodeFetch({ proxy: routed, extraHeaders })
  }
  Object.defineProperty(implementation, NODE_FETCH_MARK, { value: true })
  Object.defineProperty(globalThis, 'fetch', { value: implementation, writable: true, configurable: true, enumerable: true })
  return () => {
    if (globalThis.fetch !== implementation) return
    if (previous === undefined) Reflect.deleteProperty(globalThis, 'fetch')
    else Object.defineProperty(globalThis, 'fetch', previous)
  }
}

/** True when the current globalThis.fetch is this module's transport. */
export function nodeFetchInstalled(): boolean {
  return (globalThis.fetch as unknown as Record<symbol, unknown> | undefined)?.[NODE_FETCH_MARK] === true
}

/** True for a loopback host name (kept local so install.ts does not load node:http eagerly). */
function isLoopback(url: URL): boolean {
  return url.hostname === '127.0.0.1' || url.hostname === '[::1]' || url.hostname === '::1' || url.hostname === 'localhost'
}

/**
 * The desktop node:http transport, loaded on first use. Keeping the dynamic
 * import here is what removes `node:https` from the Worker's module graph: the
 * Worker branch above never calls this function.
 */
function lazyNodeFetch(options: NodeFetchOptions): typeof fetch {
  let pending: Promise<typeof fetch> | undefined
  const load = (): Promise<typeof fetch> => {
    pending ??= import('./node-fetch.ts').then(module => module.createNodeFetch(options))
    return pending
  }
  return (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const implementation = await load()
    return await implementation(input, init)
  }) as typeof fetch
}

/** A fetch that reports the Worker routing hole instead of silently opening a socket. */
function unavailableFetch(): typeof fetch {
  return (async (): Promise<Response> => {
    throw new Error('llm-bridge: this request is not covered by the host /v1/http route and the Worker has no node:http client')
  }) as typeof fetch
}

/**
 * Carry matching requests through the host `/v1/http` route with an underlying
 * fetch (the Worker's own, which needs no WebAssembly), falling back to the
 * node:http transport for everything else.
 */
function hostRouteFetch(
  proxy: HostProxyOptions,
  underlying: typeof fetch,
  extraHeaders: (url: URL, viaProxy: boolean, key?: string) => Record<string, string> | undefined,
  fallback: typeof fetch,
  deliveryIdleTimeoutMs: number,
): typeof fetch {
  const proxyUrl = new URL('/v1/http', proxy.url)
  if (proxyUrl.protocol !== 'http:' || !isLoopback(proxyUrl)) {
    throw new Error('llm-bridge: the host proxy must be the loopback exec bridge (http://127.0.0.1:<port>)')
  }
  const matches = proxy.match ?? (() => true)
  return (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init)
    // Read the journal context before any await (call-context.ts).
    const ambientKey = ambientToolKey()
    const signal = request.signal
    let url = new URL(request.url)
    // A request already addressed to the host route (the Worker `curl` shim
    // and any other caller that speaks the /v1/http protocol itself) carries
    // its own bearer and `X-PDSH-Target-*` headers. Re-routing it would move
    // that bearer into `x-pdsh-upstream-authorization` and point the host at
    // its own loopback, which the host then answers with 401 "missing token"
    // (or 403 when the loopback is not on the egress allow-list). Hand it to
    // the platform fetch untouched.
    if (url.origin === proxyUrl.origin && url.pathname === proxyUrl.pathname) {
      return await underlying(input, init)
    }
    // Native phone tools live on the same authenticated origin. Sending this
    // endpoint through external egress would strip its launch token and ask
    // the gateway to connect back to itself. Keep the tool journal identity.
    if (url.origin === proxyUrl.origin && url.pathname === '/mcp/native') {
      const headers = new Headers(request.headers)
      const bytes = request.body === null ? undefined : new Uint8Array(await request.clone().arrayBuffer())
      const extra = extraHeaders(url, false, correlatedMcpKey(bytes) ?? ambientKey)
      if (extra !== undefined) for (const [name, value] of Object.entries(extra)) headers.set(name, value)
      return await underlying(new Request(request, { headers }))
    }
    if (!matches(url)) return await fallback(input, init)
    let method = request.method
    const headers = new Headers(request.headers)
    let body: Uint8Array | undefined = request.body === null ? undefined : new Uint8Array(await request.arrayBuffer())
    const callKey = correlatedMcpKey(body) ?? ambientKey

    // One attempt at the host /v1/http route. A resume attempt is the same
    // request plus the byte offset the Worker already delivered, so the host
    // can answer from its committed response log without contacting the
    // upstream again.
    const sendHop = async (resumeFrom?: number): Promise<DeliveryAttempt> => {
      signal.throwIfAborted()
      const outgoing = new Headers(headers)
      const authorization = outgoing.get('authorization')
      if (authorization !== null) {
        outgoing.set('x-pdsh-upstream-authorization', authorization)
        outgoing.delete('authorization')
      }
      outgoing.set('x-pdsh-target-url', url.href)
      outgoing.set('x-pdsh-target-method', method)
      outgoing.set('authorization', `Bearer ${proxy.token}`)
      const extra = extraHeaders(url, true, callKey)
      if (extra !== undefined) for (const [name, value] of Object.entries(extra)) outgoing.set(name, value)
      if (resumeFrom !== undefined) outgoing.set(RESUME_FROM_HEADER, String(resumeFrom))
      const controller = new AbortController()
      const attemptSignal = anySignal([signal, controller.signal])
      try {
        const response = await withHeadDeadline(
          underlying(proxyUrl, {
            method: 'POST',
            headers: outgoing,
            body: body as BodyInit | undefined,
            signal: attemptSignal,
            cache: 'no-store',
            redirect: 'manual',
          }),
          resumeFrom === undefined ? deliveryIdleTimeoutMs : Math.max(deliveryIdleTimeoutMs, RESUME_TIMEOUT_MS),
          controller,
        )
        deliveryMetrics.attempts += 1
        return { response, controller }
      } catch (error) {
        controller.abort(error)
        throw error
      }
    }

    for (let hop = 0; ; hop++) {
      const attempt = await sendHop()
      const response = attempt.response
      const status = response.status
      const location = response.headers.get('location')
      if (!REDIRECT_STATUS.has(status) || request.redirect === 'manual' || location === null) {
        return resumableDelivery(attempt, {
          timeoutMs: deliveryIdleTimeoutMs,
          signal,
          maxResumes: MAX_DELIVERY_RESUMES,
          resume: async (offset: number) => {
            const next = await sendHop(offset)
            if (next.response.status !== 200 || next.response.headers.get(RESUMED_HEADER) !== '1') {
              await next.response.body?.cancel().catch(() => {})
              next.controller.abort(new Error('the host did not serve the resume from its response log'))
              return undefined
            }
            return next
          },
        }, method === 'HEAD')
      }
      await response.body?.cancel().catch(() => {})
      attempt.controller.abort(new Error('redirect'))
      if (request.redirect === 'error') throw new TypeError('fetch failed', { cause: new Error(`unexpected redirect to ${location}`) })
      if (hop + 1 > 20) throw new TypeError('fetch failed', { cause: new Error('redirect count exceeded') })
      const next = new URL(location, url)
      if (status === 303 || ((status === 301 || status === 302) && method === 'POST')) {
        method = 'GET'
        body = undefined
        for (const name of REDIRECT_STRIPPED) headers.delete(name)
      }
      if (next.origin !== url.origin) {
        headers.delete('authorization')
        headers.delete('cookie')
        headers.delete('proxy-authorization')
      }
      url = next
    }
  }) as typeof fetch
}

/** Combines the caller signal with the delivery-owned controller signal. */
function anySignal(signals: AbortSignal[]): AbortSignal {
  const defined = signals.filter(signal => signal !== undefined)
  if (defined.length === 1) return defined[0] as AbortSignal
  const combiner = (AbortSignal as unknown as {
    any?: (values: AbortSignal[]) => AbortSignal
  }).any
  if (typeof combiner === 'function') return combiner(defined)
  const controller = new AbortController()
  const abort = (event: Event): void => {
    controller.abort((event.target as AbortSignal | null)?.reason)
  }
  for (const signal of defined) {
    if (signal.aborted) {
      controller.abort(signal.reason)
      return controller.signal
    }
    signal.addEventListener('abort', abort, { once: true })
  }
  return controller.signal
}

/**
 * The only Worker-safe monotonic clock, or `undefined` when this runtime has
 * none.
 *
 * Read dynamically, never captured at module load: a host (or a test) that
 * replaces `performance.now` must be observed by every window. A clock that
 * throws or reports a non-finite value is treated as absent so the watchdogs
 * fall back to their original wall-clock behaviour instead of a timer callback
 * throwing.
 */
function activeClockNow(): number | undefined {
  const clock = (globalThis as { performance?: { now?: () => number } }).performance
  if (clock === undefined || typeof clock.now !== 'function') return undefined
  try {
    const now = clock.now.call(clock)
    return Number.isFinite(now) ? now : undefined
  } catch {
    return undefined
  }
}

/** Active milliseconds since `armedAt`, or `undefined` without a usable clock. */
function activeElapsedSince(armedAt: number | undefined): number | undefined {
  if (armedAt === undefined) return undefined
  const now = activeClockNow()
  if (now === undefined) return undefined
  const elapsed = now - armedAt
  // A backwards jump is not a suspension: keep the wall-clock verdict.
  return elapsed >= 0 ? elapsed : undefined
}

/**
 * Active milliseconds a watchdog window consumed if it expired while the
 * process itself was frozen; `undefined` when it expired for any other reason.
 *
 * The caller only asks once the wall-clock timer fired, so a value means: "the
 * wall clock drained the window while this process was not running". Without a
 * usable monotonic clock the answer is always `undefined`, which restores the
 * pre-existing wall-clock behaviour exactly.
 */
function frozenWindowActiveMs(armedAt: number | undefined, budgetMs: number): number | undefined {
  const active = activeElapsedSince(armedAt)
  if (active === undefined) return undefined
  return active < budgetMs * SUSPENSION_ACTIVE_RATIO ? active : undefined
}

/**
 * Waits for the response head under the delivery inactivity interval.
 *
 * The interval is measured on the active clock. When a window expires while the
 * process was frozen the window is renewed with the active budget it did not
 * spend, so a thawed Worker keeps waiting for the head its upstream is still
 * producing instead of failing the request for time it never ran. A genuine
 * stall — the active clock drained the window too — aborts the attempt with the
 * typed error exactly as before, and so does a suspension that exhausted the
 * bounded renewals.
 */
async function withHeadDeadline(
  request: Promise<Response>,
  timeoutMs: number,
  controller: AbortController,
): Promise<Response> {
  let timer: ReturnType<typeof setTimeout> | undefined
  let remainingMs = timeoutMs
  let renewals = 0
  const deadline = new Promise<never>((_resolve, reject) => {
    const fail = (): void => {
      const error = new DeliveryTimeoutError('head', timeoutMs)
      controller.abort(error)
      reject(error)
    }
    const arm = (): void => {
      const armedAt = activeClockNow()
      timer = setTimeout(() => {
        timer = undefined
        const frozenMs = frozenWindowActiveMs(armedAt, remainingMs)
        if (frozenMs !== undefined && renewals < MAX_SUSPENSION_RENEWALS) {
          // The wall clock drained the window, the active clock did not: this
          // process was frozen, so the upstream never got its interval. Spend
          // only the active time we actually observed and wait for the rest.
          deliveryMetrics.suspends += 1
          renewals += 1
          remainingMs -= frozenMs
          if (remainingMs > 0) {
            arm()
            return
          }
        }
        fail()
      }, remainingMs)
    }
    arm()
  })
  try {
    return await Promise.race([request, deadline])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

/** One in-flight host-route attempt and the controller that owns its socket. */
interface DeliveryAttempt {
  readonly response: Response
  readonly controller: AbortController
}

interface DeliveryOptions {
  timeoutMs: number
  signal: AbortSignal
  maxResumes: number
  resume: (offset: number) => Promise<DeliveryAttempt | undefined>
}

type DeliveryRead =
  | { readonly kind: 'chunk'; readonly value: Uint8Array }
  | { readonly kind: 'done' }
  | { readonly kind: 'failure'; readonly error: unknown; readonly timedOut: boolean }
  /**
   * The read window expired while the process was frozen: no byte ever arrived
   * because nothing here could run, not because the upstream stopped.
   */
  | { readonly kind: 'suspended' }

/**
 * Wraps a platform response so a suspended downstream consumer can resume.
 *
 * The host gateway may have received a complete model response while the
 * Worker's platform fetch stops receiving bytes (a suspended WebKit page, a
 * broken stream hop). The wrapper counts the bytes it actually delivered; when
 * an inactivity interval expires on an open body it asks the host for the same
 * response from that byte offset (``RESUME_FROM_HEADER``). The host serves the
 * suffix from its committed response log, so the model client sees one
 * continuous body and the delivery window is replenished instead of abandoned.
 *
 * The inactivity interval is measured on the active clock: a window that
 * expired because iOS froze the Worker is recovered the same way (a resume at
 * the delivered offset, which also re-arms the window) instead of failing the
 * turn for time the process never ran. The resume budget bounds both cases.
 *
 * The typed ``DeliveryTimeoutError`` is still the failure of last resort: with
 * no resumable host body, or after ``maxResumes``, the body errors with
 * `PDSH_DELIVERY_TIMEOUT` exactly as before.
 */
function resumableDelivery(initial: DeliveryAttempt, options: DeliveryOptions,
                           headRequest: boolean): Response {
  if (initial.response.body === null) return initial.response
  if (NULL_BODY_STATUS.has(initial.response.status) || headRequest) {
    // A null-body status (and a HEAD response) must never be reconstructed with
    // a body. Release the stray stream and keep the observable response fields.
    void initial.response.body.cancel(new Error('bodyless response')).catch(() => {})
    initial.controller.abort(new Error('bodyless response'))
    const bodyless = new Response(null, {
      status: initial.response.status,
      statusText: initial.response.statusText,
      headers: initial.response.headers,
    })
    Object.defineProperty(bodyless, 'url', { value: initial.response.url })
    Object.defineProperty(bodyless, 'redirected', { value: initial.response.redirected })
    return bodyless
  }
  let attempt = initial
  let reader = initial.response.body.getReader()
  let offset = 0
  let resumes = 0
  let onResumedAttempt = false
  let terminal = false
  let controller: ReadableStreamDefaultController<Uint8Array> | undefined
  let handoffTimer: ReturnType<typeof setTimeout> | undefined
  let handoffRemainingMs = options.timeoutMs
  let handoffRenewals = 0

  const clearHandoff = (): void => {
    if (handoffTimer !== undefined) {
      clearTimeout(handoffTimer)
      handoffTimer = undefined
    }
  }
  const settle = (error?: unknown): void => {
    if (terminal) return
    terminal = true
    clearHandoff()
    options.signal.removeEventListener('abort', onAbort)
    if (error !== undefined) {
      try { void reader.cancel(error).catch(() => {}) } catch { /* already closed */ }
      attempt.controller.abort(error)
      try { controller?.error(error) } catch { /* already errored */ }
    } else {
      try { controller?.close() } catch { /* already closed */ }
    }
  }
  const onAbort = (): void => {
    settle(options.signal.reason ?? new DOMException('The request was aborted', 'AbortError'))
  }
  const armHandoff = (renewBudget = true): void => {
    clearHandoff()
    if (terminal) return
    if (renewBudget) {
      handoffRemainingMs = options.timeoutMs
      handoffRenewals = 0
    }
    const armedAt = activeClockNow()
    handoffTimer = setTimeout(() => {
      handoffTimer = undefined
      if (terminal) return
      const frozenMs = frozenWindowActiveMs(armedAt, handoffRemainingMs)
      if (frozenMs !== undefined && handoffRenewals < MAX_SUSPENSION_RENEWALS) {
        deliveryMetrics.suspends += 1
        handoffRenewals += 1
        handoffRemainingMs -= frozenMs
        if (handoffRemainingMs > 0) {
          armHandoff(false)
          return
        }
      }
      deliveryMetrics.stalls += 1
      settle(new DeliveryTimeoutError('body', options.timeoutMs))
    }, handoffRemainingMs)
  }
  const readOnce = async (): Promise<DeliveryRead> => {
    let timer: ReturnType<typeof setTimeout> | undefined
    // A window cannot fire before a whole wall clock interval has passed, so the
    // active delta below answers "was this process running for the window the
    // upstream never got?".
    const armedAt = activeClockNow()
    const timeout = new Promise<DeliveryRead>(resolve => {
      timer = setTimeout(() => {
        if (frozenWindowActiveMs(armedAt, options.timeoutMs) !== undefined) {
          resolve({ kind: 'suspended' })
          return
        }
        resolve({
          kind: 'failure',
          error: new DeliveryTimeoutError('body', options.timeoutMs),
          timedOut: true,
        })
      }, options.timeoutMs)
    })
    const read = reader.read()
      .then(result => result.done === true
        ? ({ kind: 'done' } as DeliveryRead)
        : ({ kind: 'chunk', value: result.value } as DeliveryRead))
      .catch(error => ({ kind: 'failure', error, timedOut: false } as DeliveryRead))
    try {
      return await Promise.race([read, timeout])
    } finally {
      if (timer !== undefined) clearTimeout(timer)
    }
  }
  options.signal.addEventListener('abort', onAbort, { once: true })
  const body = new ReadableStream<Uint8Array>({
    start(value) {
      controller = value
      armHandoff()
    },
    async pull(value) {
      controller = value
      clearHandoff()
      while (true) {
        if (terminal) return
        const result = await readOnce()
        if (terminal) return
        if (result.kind === 'chunk') {
          offset += result.value.byteLength
          deliveryMetrics.bodyBytes += result.value.byteLength
          if (onResumedAttempt) deliveryMetrics.resumedBytes += result.value.byteLength
          value.enqueue(result.value)
          armHandoff()
          return
        }
        if (result.kind === 'done') {
          settle()
          return
        }
        if (options.signal.aborted) {
          settle(options.signal.reason)
          return
        }
        // A read window ended without a chunk. `suspended` means the process
        // itself was frozen for that window: the wall clock drained while
        // nothing here could run, so the upstream never got its inactivity
        // interval and this is not a delivery stall. Recover through the host
        // delivery window exactly like a stall; a genuine stall (the active
        // clock drained the window too) keeps its typed failure below.
        const suspended = result.kind === 'suspended'
        if (suspended) deliveryMetrics.suspends += 1
        else if (result.kind === 'failure' && result.timedOut) deliveryMetrics.stalls += 1
        const failure = result.kind === 'failure' && !result.timedOut
          ? result.error
          : new DeliveryTimeoutError('body', options.timeoutMs)
        if (resumes >= options.maxResumes) {
          settle(failure)
          return
        }
        resumes += 1
        // Release the abandoned attempt before asking the host for the suffix.
        // A suspension has no stalled upstream to report, so it aborts the old
        // attempt with its own reason instead of the typed delivery error.
        const abandoned = suspended
          ? new Error('llm-bridge: delivery window suspended; resuming from the host log')
          : failure
        attempt.controller.abort(abandoned)
        try { await reader.cancel(abandoned) } catch { /* already closed */ }
        let next: DeliveryAttempt | undefined
        try { next = await options.resume(offset) } catch { next = undefined }
        if (next === undefined || next.response.body === null) {
          settle(failure)
          return
        }
        deliveryMetrics.resumes += 1
        attempt = next
        reader = next.response.body.getReader()
        onResumedAttempt = true
      }
    },
    cancel(reason) {
      if (terminal) return
      terminal = true
      clearHandoff()
      options.signal.removeEventListener('abort', onAbort)
      try { void reader.cancel(reason).catch(() => {}) } catch { /* already closed */ }
      attempt.controller.abort(reason)
    },
  })
  return new Response(body, {
    status: initial.response.status,
    statusText: initial.response.statusText,
    headers: initial.response.headers,
  })
}

function httpOriginFromChannelUrl(raw: string | undefined): string | undefined {
  if (raw === undefined || raw === '') return undefined
  try {
    const url = new URL(raw)
    if (url.protocol !== 'ws:' && url.protocol !== 'wss:' && url.protocol !== 'http:' && url.protocol !== 'https:') return undefined
    url.protocol = url.protocol === 'ws:' || url.protocol === 'http:' ? 'http:' : 'https:'
    return url.origin
  } catch {
    return undefined
  }
}
