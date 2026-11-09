// SPDX-License-Identifier: MIT
// P0-1: the Worker install path must never resolve the node:https transport.
// The runtime's module table only carries a structural TLS mock (no usable
// `Agent`), and a Worker has no node:http client at all. llm-bridge therefore
// carries every request over the host `/v1/http` route with the channel bearer,
// and the node:http implementation is a lazy desktop-only fallback.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import type { IncomingHttpHeaders } from 'node:http'
import { registerHooks } from 'node:module'
import type { AddressInfo } from 'node:net'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const INSTALL_SOURCE = fileURLToPath(new URL('../llm-bridge/src/install.ts', import.meta.url))

test('install.ts has no static node:http(s) transport import', () => {
  const source = readFileSync(INSTALL_SOURCE, 'utf8')
  // A value import re-exports nothing: only `import type` may mention the file.
  assert.doesNotMatch(source, /^import (?!type\b)[^;]*from '\.\/node-fetch\.ts'/m)
  assert.doesNotMatch(source, /from 'node:https'/)
  assert.doesNotMatch(source, /from 'node:http'/)
})

test('the Worker host route installs while node:https is unresolvable', async () => {
  const seen: IncomingHttpHeaders[] = []
  const server = createServer((req, res) => {
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => chunks.push(chunk))
    req.on('end', () => {
      seen.push(req.headers)
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
      res.end(JSON.stringify({ target: req.headers['x-pdsh-target-url'], body: Buffer.concat(chunks).toString() }))
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  const token = 'llm-install-token-0123456789'
  const previousLocation = Object.getOwnPropertyDescriptor(globalThis, 'location')
  const previous = { PDSH_CHANNEL_TOKEN: process.env.PDSH_CHANNEL_TOKEN, PDSH_CHANNEL_ORIGIN: process.env.PDSH_CHANNEL_ORIGIN }
  // Simulate the DSH Worker module table: resolving node:https is a load-time
  // failure, exactly like a table without the mock entry.
  const hooks = registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier === 'node:https') throw new Error('node:https is not in the Worker module table')
      return nextResolve(specifier, context)
    },
  })
  Object.defineProperty(globalThis, 'location', { value: { origin: base }, configurable: true, writable: true })
  process.env.PDSH_CHANNEL_TOKEN = token
  process.env.PDSH_CHANNEL_ORIGIN = base
  try {
    // Cache-bust so this test evaluates install.ts afresh under the hook.
    const specifier = `${new URL('../llm-bridge/src/install.ts', import.meta.url).href}?worker-install-probe`
    const module = await import(specifier) as typeof import('../llm-bridge/src/install.ts')
    const restore = module.installNodeFetch({ mode: 'auto' })
    try {
      const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{"prompt":"hi"}' })
      assert.equal(response.status, 200)
      assert.equal(response.headers.get('cache-control'), 'no-store')
      const body = await response.json() as Record<string, string>
      assert.equal(body.target, 'https://model.example/v1/messages')
      assert.equal(body.body, '{"prompt":"hi"}')
      assert.equal(seen.length, 1)
      assert.equal(seen[0]?.authorization, `Bearer ${token}`)
    } finally {
      restore()
    }
  } finally {
    hooks.deregister()
    server.closeAllConnections()
    server.close()
    if (previousLocation === undefined) delete (globalThis as { location?: unknown }).location
    else Object.defineProperty(globalThis, 'location', previousLocation)
    for (const key of ['PDSH_CHANNEL_TOKEN', 'PDSH_CHANNEL_ORIGIN'] as const) {
      const value = previous[key]
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
  }
})

test('a cookie-authenticated Worker routes official web tools with its launch bearer', async t => {
  const keys = [
    'PDSH_CHANNEL_TOKEN', 'PDSH_EXEC_BRIDGE_TOKEN', 'PDSH_CHANNEL_ORIGIN',
    'PDSH_DSH_LAUNCH_TOKEN', 'PDSH_WEB_SEARCH_PROVIDER', 'DEEPSEEK_SEARCH_API_BASE_URL',
  ] as const
  const previous = keys.map(key => [key, process.env[key]] as const)
  const channel = Object.getOwnPropertyDescriptor(globalThis, '__PDSH_CHANNEL__')
  const origin = 'http://127.0.0.1:23456'
  const base = 'https://api.deepseek.com/v1/tools'
  const token = 'cookie-launch-fixture'
  delete process.env.PDSH_CHANNEL_TOKEN
  delete process.env.PDSH_EXEC_BRIDGE_TOKEN
  process.env.PDSH_CHANNEL_ORIGIN = origin
  process.env.PDSH_DSH_LAUNCH_TOKEN = token
  process.env.PDSH_WEB_SEARCH_PROVIDER = 'deepseek-search-api'
  process.env.DEEPSEEK_SEARCH_API_BASE_URL = base
  Object.defineProperty(globalThis, '__PDSH_CHANNEL__', { configurable: true, value: {} })

  const calls: Request[] = []
  const platformFetch: typeof fetch = async (input, init) => {
    calls.push(new Request(input, init))
    return new Response('ok')
  }
  t.mock.method(globalThis, 'fetch', platformFetch)
  try {
    const { installNodeFetch } = await import('../llm-bridge/src/install.ts')
    const restore = installNodeFetch()
    try {
      for (const operation of ['search', 'fetch']) {
        await fetch(`${base}/${operation}`, { method: 'POST', body: '{}' })
        const request = calls.at(-1)
        assert.equal(request?.url, origin + '/v1/http')
        assert.equal(request?.headers.get('authorization'), `Bearer ${token}`)
        assert.equal(request?.headers.get('x-pdsh-target-url'), `${base}/${operation}`)
        assert.equal(request?.headers.get('x-pdsh-target-method'), 'POST')
      }

      const model = origin + '/v1/messages'
      await fetch(model, { method: 'POST', body: '{}' })
      assert.equal(calls.at(-1)?.url, model)
      assert.equal(calls.at(-1)?.headers.get('authorization'), null)
    } finally {
      restore()
    }

    delete process.env.PDSH_DSH_LAUNCH_TOKEN
    assert.throws(() => installNodeFetch(), /official web tools need the host gateway/)
  } finally {
    if (channel === undefined) Reflect.deleteProperty(globalThis, '__PDSH_CHANNEL__')
    else Object.defineProperty(globalThis, '__PDSH_CHANNEL__', channel)
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
  }
})

// The frozen independent Search/Fetch contract
// (spec/v1/gateway-independent-search.md) is judged by the shared cases that the
// Kotlin gateway test also reads.
const INDEPENDENT_CASES = JSON.parse(readFileSync(fileURLToPath(new URL(
  '../../spec/v1/golden/gateway/independent-search/cases.json', import.meta.url)), 'utf8')) as {
  bases: Array<{ input: string, canonical: string | null }>
  requests: Array<{ base: string, method: string, url: string, allowed: boolean }>
}

test('independent Search/Fetch bases normalize exactly as the shared cases', async () => {
  const { canonicalIndependentSearchBase } = await import('../llm-bridge/src/install.ts')
  for (const { input, canonical } of INDEPENDENT_CASES.bases) {
    assert.equal(canonicalIndependentSearchBase(input) ?? null, canonical, JSON.stringify(input))
    if (canonical !== null) assert.equal(canonicalIndependentSearchBase(canonical), canonical)
  }
})

/** Run `body` as a cookie-authenticated Worker whose platform fetch is recorded. */
async function withCookieWorker(
  env: Record<string, string | undefined>,
  body: (calls: Request[], origin: string) => Promise<void>,
): Promise<void> {
  const keys = [
    'PDSH_CHANNEL_TOKEN', 'PDSH_EXEC_BRIDGE_TOKEN', 'PDSH_CHANNEL_ORIGIN', 'PDSH_EXEC_BRIDGE_URL',
    'PDSH_CHANNEL_URL', 'PDSH_DSH_LAUNCH_TOKEN', 'PDSH_WEB_SEARCH_PROVIDER', 'DEEPSEEK_SEARCH_API_BASE_URL',
  ] as const
  const previous = keys.map(key => [key, process.env[key]] as const)
  const channel = Object.getOwnPropertyDescriptor(globalThis, '__PDSH_CHANNEL__')
  const origin = 'http://127.0.0.1:23457'
  for (const key of keys) delete process.env[key]
  process.env.PDSH_CHANNEL_ORIGIN = origin
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) delete process.env[key]
    else process.env[key] = value
  }
  Object.defineProperty(globalThis, '__PDSH_CHANNEL__', { configurable: true, value: {} })
  const calls: Request[] = []
  // Replaced by hand (not `t.mock`): one test runs this helper many times, and
  // stacked mocks of the same property would not restore the original fetch.
  const platformFetch = Object.getOwnPropertyDescriptor(globalThis, 'fetch')
  Object.defineProperty(globalThis, 'fetch', {
    configurable: true, enumerable: true, writable: true,
    value: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push(new Request(input, init))
      return new Response('ok')
    }) as typeof fetch,
  })
  try {
    await body(calls, origin)
  } finally {
    if (platformFetch === undefined) Reflect.deleteProperty(globalThis, 'fetch')
    else Object.defineProperty(globalThis, 'fetch', platformFetch)
    if (channel === undefined) Reflect.deleteProperty(globalThis, '__PDSH_CHANNEL__')
    else Object.defineProperty(globalThis, '__PDSH_CHANNEL__', channel)
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
  }
}

test('a cookie Worker carries exactly the independent operations with its launch bearer', async () => {
  const { installNodeFetch } = await import('../llm-bridge/src/install.ts')
  const token = 'cookie-launch-independent'
  for (const request of INDEPENDENT_CASES.requests) {
    await withCookieWorker({
      PDSH_DSH_LAUNCH_TOKEN: token,
      PDSH_WEB_SEARCH_PROVIDER: 'deepseek-search-api',
      DEEPSEEK_SEARCH_API_BASE_URL: request.base,
    }, async (calls, origin) => {
      const restore = installNodeFetch()
      try {
        await fetch(request.url, {
          method: request.method,
          headers: { authorization: 'Bearer phone-host-injects-search-key' },
          ...(request.method === 'GET' ? {} : { body: '{}' }),
        })
      } finally {
        restore()
      }
      const sent = calls.at(-1)
      const label = `${request.method} ${request.url} on ${request.base}`
      // The bridge routes by URL; the host owns the method check (§4). An
      // operation URL is therefore never sent directly, whatever its method.
      const operation = request.url === `${request.base}/search` || request.url === `${request.base}/fetch`
      if (request.allowed) assert.ok(operation, `${label}: an allowed case names an operation URL`)
      if (operation) {
        assert.equal(sent?.url, origin + '/v1/http', label)
        assert.equal(sent?.headers.get('authorization'), `Bearer ${token}`, label)
        assert.equal(sent?.headers.get('x-pdsh-upstream-authorization'), 'Bearer phone-host-injects-search-key', label)
        assert.equal(sent?.headers.get('x-pdsh-target-url'), request.url, label)
        assert.equal(sent?.headers.get('x-pdsh-target-method'), request.method, label)
      } else {
        // Everything else keeps its existing transport and never gets the bearer.
        assert.notEqual(sent?.url, origin + '/v1/http', label)
        assert.notEqual(sent?.headers.get('authorization'), `Bearer ${token}`, label)
      }
    })
  }
})

test('a cookie Worker routes a base only when it is already canonical', async () => {
  const { installNodeFetch } = await import('../llm-bridge/src/install.ts')
  const token = 'cookie-launch-independent'
  for (const { input, canonical } of INDEPENDENT_CASES.bases) {
    if (input === '') continue
    const routed = canonical !== null && input === canonical
    const base = input.replace(/\/+$/u, '')
    await withCookieWorker({
      PDSH_DSH_LAUNCH_TOKEN: token,
      PDSH_WEB_SEARCH_PROVIDER: 'deepseek-search-api',
      DEEPSEEK_SEARCH_API_BASE_URL: input,
    }, async (calls, origin) => {
      const restore = installNodeFetch()
      try {
        let target: URL
        try {
          target = new URL(`${base.trim()}/search`)
        } catch {
          return
        }
        await fetch(target, { method: 'POST', body: '{}' }).catch(() => undefined)
      } finally {
        restore()
      }
      assert.equal(calls.at(-1)?.url === origin + '/v1/http', routed, JSON.stringify(input))
    })
  }
})

test('independent web tools fail instead of going direct without the launch bearer', async () => {
  const { installNodeFetch } = await import('../llm-bridge/src/install.ts')
  await withCookieWorker({
    PDSH_WEB_SEARCH_PROVIDER: 'deepseek-search-api',
    DEEPSEEK_SEARCH_API_BASE_URL: 'https://pdsh.tonoai.cn/v1/web',
  }, async calls => {
    assert.throws(() => installNodeFetch(), /independent web tools need the host gateway/)
    assert.equal(calls.length, 0)
  })
  await withCookieWorker({
    PDSH_DSH_LAUNCH_TOKEN: 'cookie-launch-independent',
    PDSH_CHANNEL_ORIGIN: undefined,
    PDSH_WEB_SEARCH_PROVIDER: 'deepseek-search-api',
    DEEPSEEK_SEARCH_API_BASE_URL: 'https://pdsh.tonoai.cn/v1/web',
  }, async () => {
    const location = Object.getOwnPropertyDescriptor(globalThis, 'location')
    if (location !== undefined) Reflect.deleteProperty(globalThis, 'location')
    try {
      assert.throws(() => installNodeFetch(), /independent web tools need the host gateway/)
    } finally {
      if (location !== undefined) Object.defineProperty(globalThis, 'location', location)
    }
  })
})

test('a channel-token Worker keeps routing every request with the channel bearer', async () => {
  const { installNodeFetch } = await import('../llm-bridge/src/install.ts')
  await withCookieWorker({
    PDSH_CHANNEL_TOKEN: 'channel-bearer',
    PDSH_DSH_LAUNCH_TOKEN: 'cookie-launch-independent',
    PDSH_WEB_SEARCH_PROVIDER: 'deepseek-search-api',
    DEEPSEEK_SEARCH_API_BASE_URL: 'https://pdsh.tonoai.cn/v1/web',
  }, async (calls, origin) => {
    const restore = installNodeFetch()
    try {
      for (const url of ['https://pdsh.tonoai.cn/v1/web/search', 'https://model.example/v1/messages']) {
        await fetch(url, { method: 'POST', body: '{}' })
        assert.equal(calls.at(-1)?.url, origin + '/v1/http')
        assert.equal(calls.at(-1)?.headers.get('authorization'), 'Bearer channel-bearer')
      }
    } finally {
      restore()
    }
  })
})

// --- Response-delivery deadline (G2-FIX-1) --------------------------------

test('native MCP stays on the authenticated origin and keeps tool idempotency', async () => {
  const key = Symbol.for('phone-dsh.dsh.tool-call-context')
  const scope = globalThis as unknown as Record<symbol, unknown>
  const previous = scope[key]
  scope[key] = { getStore: () => ({ key: 'android-tap-once' }) }
  const seen: Request[] = []
  const fake = (async (input, init) => {
    const request = new Request(input, init)
    seen.push(request)
    return new Response('{}', { headers: { 'content-type': 'application/json' } })
  }) as typeof fetch
  try {
    await withWorkerHostRoute(fake, 1000, async () => {
      const controller = new AbortController()
      await fetch('http://127.0.0.1:9/mcp/native', {
        method: 'POST', headers: { authorization: 'Bearer launch-token' },
        body: '{"method":"tools/call"}', signal: controller.signal,
      })
      assert.equal(seen[0]?.url, 'http://127.0.0.1:9/mcp/native')
      assert.equal(seen[0]?.headers.get('authorization'), 'Bearer launch-token')
      assert.equal(seen[0]?.headers.get('x-pdsh-idempotency-key'), 'android-tap-once')
      assert.equal(seen[0]?.headers.has('x-pdsh-target-url'), false)
      assert.equal(await seen[0]?.text(), '{"method":"tools/call"}')
      controller.abort()
      assert.equal(seen[0]?.signal.aborted, true)
      await fetch('http://127.0.0.1:10/mcp/native', { method: 'POST', body: '{}' })
      assert.equal(seen[1]?.url, 'http://127.0.0.1:9/v1/http')
      assert.equal(seen[1]?.headers.get('x-pdsh-target-url'), 'http://127.0.0.1:10/mcp/native')
    })
  } finally {
    if (previous === undefined) delete scope[key]
    else scope[key] = previous
  }
})
//
// The host gateway can receive a complete model response while the last bytes
// never reach the Worker's platform fetch (a frozen WebKit page, a broken
// stream hop). Before the fix nothing owned a delivery deadline, so the model
// client waited until the scenario budget expired. The wrapper now arms an
// inactivity interval when the response is handed over and for every pending
// body read; it fails with a typed `LlmError` the DSH adapter rethrows
// unchanged, so the retry policy sees the non-retryable delivery code.

let deliveryProbe = 0

/** Installs the Worker host route over a fake platform fetch for one test. */
test('MCP tools/call carries its own journal key even when the ambient context is wrong or missing', async () => {
  const { registerMcpCall } = await import('../exec-bridge/src/call-context.ts')
  const contextKey = Symbol.for('phone-dsh.dsh.tool-call-context')
  const scope = globalThis as unknown as Record<symbol, unknown>
  const previous = scope[contextKey]
  let ambient: { key: string } | undefined = { key: 'unrelated-call' }
  scope[contextKey] = { getStore: () => ambient }
  const seen: Request[] = []
  const fake = (async (input, init) => {
    seen.push(new Request(input, init))
    return new Response('{}', { headers: { 'content-type': 'application/json' } })
  }) as typeof fetch
  const call = (name: string, args: unknown) => JSON.stringify({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name, arguments: args } })
  const release = registerMcpCall('mcp__phone__ble_link_call', { device_id: 'd', name: 'light.set', args: { on: true } }, 'light-on-once')
  try {
    await withWorkerHostRoute(fake, 1000, async () => {
      // Bot MCP listener: a loopback URL routed through the host /v1/http hop.
      await fetch('http://127.0.0.1:55001/mcp', { method: 'POST', body: call('ble_link_call', { args: { on: true }, name: 'light.set', device_id: 'd' }) })
      assert.equal(seen[0]?.headers.get('x-pdsh-target-url'), 'http://127.0.0.1:55001/mcp')
      assert.equal(seen[0]?.headers.get('x-pdsh-idempotency-key'), 'light-on-once')
      // Same-origin native endpoint, and no ambient context at all.
      ambient = undefined
      await fetch('http://127.0.0.1:9/mcp/native', { method: 'POST', body: call('ble_link_call', { device_id: 'd', name: 'light.set', args: { on: true } }) })
      assert.equal(seen[1]?.url, 'http://127.0.0.1:9/mcp/native')
      assert.equal(seen[1]?.headers.get('x-pdsh-idempotency-key'), 'light-on-once')
      // Different arguments do not borrow the key; nothing is attached.
      await fetch('http://127.0.0.1:9/mcp/native', { method: 'POST', body: call('ble_link_call', { device_id: 'd', name: 'light.set', args: { on: false } }) })
      assert.equal(seen[2]?.headers.has('x-pdsh-idempotency-key'), false)
      // Two in-flight calls with identical arguments are ambiguous: fail closed to the ambient context.
      const twin = registerMcpCall('mcp__phone__ble_link_call', { device_id: 'd', name: 'light.set', args: { on: true } }, 'light-on-twin')
      ambient = { key: 'ambient-only' }
      await fetch('http://127.0.0.1:9/mcp/native', { method: 'POST', body: call('ble_link_call', { device_id: 'd', name: 'light.set', args: { on: true } }) })
      assert.equal(seen[3]?.headers.get('x-pdsh-idempotency-key'), 'ambient-only')
      twin()
      // A body that is not tools/call keeps the ambient behaviour.
      await fetch('http://127.0.0.1:9/mcp/native', { method: 'POST', body: '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' })
      assert.equal(seen[4]?.headers.get('x-pdsh-idempotency-key'), 'ambient-only')
    })
  } finally {
    release()
    if (previous === undefined) delete scope[contextKey]
    else scope[contextKey] = previous
  }
})

test('registerMcpCall parses only mcp__<server>__<tool> names and releases its entry', async () => {
  const { mcpCallKey, registerMcpCall } = await import('../exec-bridge/src/call-context.ts')
  const release = registerMcpCall('mcp__phone__iphone_agent_run', { task: '打开设置' }, 'k1')
  assert.equal(mcpCallKey('iphone_agent_run', { task: '打开设置' }), 'k1')
  assert.equal(mcpCallKey('iphone_agent_run', { task: 'other' }), undefined)
  release()
  assert.equal(mcpCallKey('iphone_agent_run', { task: '打开设置' }), undefined)
  for (const name of ['bash', 'mcp__phone', 'mcp____x', 'phone__x']) {
    registerMcpCall(name, {}, 'k2')()
    assert.equal(mcpCallKey(name.split('__').pop() ?? '', {}), undefined)
  }
  assert.doesNotThrow(() => registerMcpCall('mcp__phone__x', {}, '')())
})

async function withWorkerHostRoute<T>(
  fake: typeof fetch,
  idleMs: number,
  run: (module: typeof import('../llm-bridge/src/install.ts')) => Promise<T>,
  origin = 'http://127.0.0.1:9',
): Promise<T> {
  const scope = globalThis as { __PDSH_CHANNEL__?: unknown }
  const previousChannel = scope.__PDSH_CHANNEL__
  const previousToken = process.env.PDSH_CHANNEL_TOKEN
  const previousOrigin = process.env.PDSH_CHANNEL_ORIGIN
  scope.__PDSH_CHANNEL__ = { deliveryProbe: true }
  process.env.PDSH_CHANNEL_TOKEN = 'delivery-probe-token'
  process.env.PDSH_CHANNEL_ORIGIN = origin
  deliveryProbe += 1
  const specifier = `${new URL('../llm-bridge/src/install.ts', import.meta.url).href}?delivery-probe-${deliveryProbe}`
  const module = await import(specifier) as typeof import('../llm-bridge/src/install.ts')
  const restore = module.installNodeFetch({
    mode: 'auto',
    proxyFetch: fake,
    deliveryIdleTimeoutMs: idleMs,
  })
  try {
    return await run(module)
  } finally {
    restore()
    if (previousChannel === undefined) delete scope.__PDSH_CHANNEL__
    else scope.__PDSH_CHANNEL__ = previousChannel
    if (previousToken === undefined) delete process.env.PDSH_CHANNEL_TOKEN
    else process.env.PDSH_CHANNEL_TOKEN = previousToken
    if (previousOrigin === undefined) delete process.env.PDSH_CHANNEL_ORIGIN
    else process.env.PDSH_CHANNEL_ORIGIN = previousOrigin
  }
}

/** Fails a test that would otherwise hang past its own guard interval. */
async function settleWithin<T>(promise: Promise<T>, milliseconds: number,
                               label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const guard = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error(`test guard: ${label} did not settle`)), milliseconds)
  })
  try {
    return await Promise.race([promise, guard])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

/** A monotonic clock the test advances by hand. */
interface FakeActiveClock {
  /** Moves the active clock forward. */
  advance(milliseconds: number): void
  /** Restores the real clock. */
  restore(): void
}

/**
 * Replaces `performance.now()` with a hand-driven monotonic clock.
 *
 * The delivery watchdogs decide "frozen process vs upstream stall" by comparing
 * the wall clock a fired window proves to have spent against the active clock.
 * With this fake the test controls the active clock alone: leaving it still
 * while a real timer fires is a freeze, advancing it past half the window first
 * is a genuine stall.
 */
function installFakeActiveClock(start = 1_000): FakeActiveClock {
  const clock = globalThis.performance
  assert.ok(clock !== undefined, 'the suspension tests need a performance object')
  const original = Object.getOwnPropertyDescriptor(clock, 'now')
  let current = start
  Object.defineProperty(clock, 'now', { value: () => current, configurable: true, writable: true })
  return {
    advance(milliseconds: number): void {
      current += milliseconds
    },
    restore(): void {
      if (original === undefined) delete (clock as { now?: unknown }).now
      else Object.defineProperty(clock, 'now', original)
    },
  }
}

/** A host-route response that hands over its chunks and never closes. */
function neverClosingBody(chunks: readonly Uint8Array[], headers: Record<string, string> = {}): Response {
  return new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk)
      // Never closes: the delivery leg holds the remaining bytes.
    },
  }), { status: 200, headers: { 'content-type': 'text/event-stream', ...headers } })
}

/** Asserts that `error` is the module's typed delivery timeout for `stage`. */
function assertDeliveryTimeout(error: unknown,
                               module: typeof import('../llm-bridge/src/install.ts'),
                               stage: 'head' | 'body', timeoutMs: number): void {
  assert.ok(error instanceof module.DeliveryTimeoutError,
    `expected DeliveryTimeoutError, got ${String(error)}`)
  const timeout = error as InstanceType<typeof module.DeliveryTimeoutError>
  assert.equal(timeout.code, 'PDSH_DELIVERY_TIMEOUT')
  assert.equal(timeout.stage, stage)
  assert.equal(timeout.timeoutMs, timeoutMs)
  assert.match(timeout.message, /delivery stalled for \d+ ms \(PDSH_DELIVERY_TIMEOUT\)/)
}

test('a stalled host-route body fails with a typed delivery timeout', async () => {
  const fake = (async () => new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('event: ping\ndata: {}\n\n'))
      // Never closes: the delivery leg holds the remaining SSE bytes.
    },
  }), { status: 200, headers: { 'content-type': 'text/event-stream' } })) as typeof fetch
  const observed = await withWorkerHostRoute(fake, 120, async (module) => {
    const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
    assert.equal(response.status, 200)
    const reader = response.body?.getReader()
    assert.ok(reader !== undefined)
    await reader.read()
    try {
      await settleWithin(reader.read(), 2_000, 'stalled body read')
      return { error: undefined, module }
    } catch (error) {
      return { error, module }
    }
  })
  const errorType = observed.module.DeliveryTimeoutError
  assert.ok(errorType !== undefined && observed.error instanceof errorType,
    `expected DeliveryTimeoutError, got ${String(observed.error)}`)
  assert.equal((observed.error as InstanceType<typeof observed.module.DeliveryTimeoutError>).code,
    'PDSH_DELIVERY_TIMEOUT')
  assert.equal((observed.error as InstanceType<typeof observed.module.DeliveryTimeoutError>).stage, 'body')
  // DSH's adapter rethrows a thrown `LlmError` instead of re-classifying it as
  // TRANSPORT; the stable code is not in the default retryable set, so a
  // stalled delivery ends the request instead of retrying the same frozen leg.
  const { LlmError } = await import('@deepseek-ai/dsh-llm')
  assert.ok(observed.error instanceof LlmError,
    'the delivery timeout must reach the adapter as a DSH LlmError')
  assert.equal((observed.error as InstanceType<typeof LlmError>).failure.code,
    'PDSH_DELIVERY_TIMEOUT')
})

test('a stalled host-route response head fails with a typed delivery timeout', async () => {
  const fake = (() => new Promise<Response>(() => {})) as typeof fetch
  const observed = await withWorkerHostRoute(fake, 120, async (module) => {
    try {
      await settleWithin(fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' }),
        2_000, 'stalled head fetch')
      return { error: undefined, module }
    } catch (error) {
      return { error, module }
    }
  })
  const errorType = observed.module.DeliveryTimeoutError
  assert.ok(errorType !== undefined && observed.error instanceof errorType,
    `expected DeliveryTimeoutError, got ${String(observed.error)}`)
  assert.equal((observed.error as InstanceType<typeof observed.module.DeliveryTimeoutError>).code,
    'PDSH_DELIVERY_TIMEOUT')
  assert.equal((observed.error as InstanceType<typeof observed.module.DeliveryTimeoutError>).stage, 'head')
})

test('a healthy host-route response streams every chunk without a timeout', async () => {
  const chunks = [new TextEncoder().encode('event: a\n\n'),
    new TextEncoder().encode('event: b\n\n'),
    new TextEncoder().encode('event: c\n\n')]
  const fake = (async () => new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk)
      controller.close()
    },
  }), { status: 200, headers: { 'content-type': 'text/event-stream' } })) as typeof fetch
  const body = await withWorkerHostRoute(fake, 5_000, async () => {
    const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
    assert.equal(response.status, 200)
    const bytes = new Uint8Array(await response.arrayBuffer())
    return bytes
  })
  assert.deepEqual(Buffer.from(body), Buffer.concat(chunks.map(chunk => Buffer.from(chunk))))
})

// --- Delivery-window resume (G2-FIX-20) -----------------------------------
//
// The real-model batch showed the host response log holding complete SSE
// bodies while the Worker's platform fetch stopped receiving them once the
// consumer had not pulled for a while (a suspended WebKit page). Abandoning
// the response is what lost the turn: the host already owns the bytes. The
// wrapper now counts what it actually delivered and re-fetches the same host
// route from that byte offset; the host serves the suffix from its committed
// response log and never re-contacts the upstream.

test('a body that stops mid-stream resumes from the host delivery window', async () => {
  const first = new TextEncoder().encode('a'.repeat(120))
  const rest = new TextEncoder().encode('b'.repeat(180))
  const resumeHeaders: Array<string | null> = []
  const fake = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers)
    resumeHeaders.push(headers.get('x-pdsh-resume-from'))
    if (resumeHeaders.length === 1) {
      let phase = 0
      return new Response(new ReadableStream<Uint8Array>({
        pull(controller) {
          phase += 1
          if (phase === 1) {
            controller.enqueue(first)
            return
          }
          // The downstream consumer stopped pulling after the first chunk:
          // the platform fetch fails with the bytes it already delivered.
          controller.error(new Error('delivery consumer suspended'))
        },
      }), { status: 200, headers: { 'content-type': 'text/event-stream' } })
    }
    return new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(rest)
        controller.close()
      },
    }), {
      status: 200,
      headers: { 'content-type': 'text/event-stream', 'x-pdsh-resumed': '1' },
    })
  }) as typeof fetch

  const observed = await withWorkerHostRoute(fake, 200, async (module) => {
    const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
    assert.equal(response.status, 200)
    const bytes = new Uint8Array(await response.arrayBuffer())
    return { bytes, metrics: module.deliveryMetricsSnapshot() }
  })

  assert.deepEqual(resumeHeaders, [null, String(first.byteLength)],
    'the second attempt must ask for the suffix at the delivered offset')
  assert.deepEqual(Buffer.from(observed.bytes), Buffer.concat([Buffer.from(first), Buffer.from(rest)]))
  assert.equal(observed.metrics.resumes, 1)
  assert.equal(observed.metrics.stalls, 0)
  assert.equal(observed.metrics.attempts, 2)
  assert.equal(observed.metrics.resumedBytes, rest.byteLength)
})

test('a delivery that the host cannot resume still fails with PDSH_DELIVERY_TIMEOUT', async () => {
  const first = new TextEncoder().encode('a'.repeat(64))
  let calls = 0
  const fake = (async () => {
    calls += 1
    if (calls === 1) {
      return new Response(new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(first)
          // Never closes: the host body was not committed, so the resume
          // request below is refused.
        },
      }), { status: 200, headers: { 'content-type': 'text/event-stream' } })
    }
    return new Response('the response is not committed', {
      status: 502,
      headers: { 'content-type': 'application/json', 'x-pdsh-proxy-error': 'upstream' },
    })
  }) as typeof fetch

  const observed = await withWorkerHostRoute(fake, 120, async (module) => {
    const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
    const reader = response.body?.getReader()
    assert.ok(reader !== undefined)
    await reader.read()
    try {
      await settleWithin(reader.read(), 2_000, 'irrecoverable body read')
      return { error: undefined, module }
    } catch (error) {
      return { error, module }
    }
  })

  assert.equal(calls, 2, 'exactly one bounded resume attempt')
  const errorType = observed.module.DeliveryTimeoutError
  assert.ok(observed.error instanceof errorType,
    `expected DeliveryTimeoutError, got ${String(observed.error)}`)
  assert.equal((observed.error as InstanceType<typeof observed.module.DeliveryTimeoutError>).code,
    'PDSH_DELIVERY_TIMEOUT')
})

test('a request already addressed to the host /v1/http route passes through untouched', async () => {
  // The Worker `curl` shim builds the host-route request itself: target in
  // `X-PDSH-Target-*`, the channel bearer in `Authorization`. Re-routing that
  // request would move its bearer into `x-pdsh-upstream-authorization` and make
  // the host call its own loopback, which answers 401 "missing token".
  const seen: { url: string; headers: Headers }[] = []
  const fake: typeof fetch = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init)
    seen.push({ url: request.url, headers: new Headers(request.headers) })
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } })
  }) as typeof fetch
  await withWorkerHostRoute(fake, 5_000, async () => {
    await globalThis.fetch('http://127.0.0.1:9/v1/http', {
      method: 'POST',
      headers: {
        authorization: 'Bearer curl-shim-token',
        'x-pdsh-target-url': 'https://weather.example/city?format=3',
        'x-pdsh-target-method': 'GET',
      },
    })
    const routed = await globalThis.fetch('https://model.example/v1/messages', {
      method: 'POST',
      headers: { authorization: 'Bearer upstream-key' },
      body: '{}',
    })
    await routed.arrayBuffer()
  })
  assert.equal(seen.length, 2)
  // 1. the host-route request itself: same URL, same headers, nothing rewritten
  assert.equal(seen[0]?.url, 'http://127.0.0.1:9/v1/http')
  assert.equal(seen[0]?.headers.get('authorization'), 'Bearer curl-shim-token')
  assert.equal(seen[0]?.headers.get('x-pdsh-upstream-authorization'), null)
  assert.equal(seen[0]?.headers.get('x-pdsh-target-url'), 'https://weather.example/city?format=3')
  // 2. an ordinary upstream request still travels through the host route
  assert.equal(seen[1]?.url, 'http://127.0.0.1:9/v1/http')
  assert.equal(seen[1]?.headers.get('authorization'), 'Bearer delivery-probe-token')
  assert.equal(seen[1]?.headers.get('x-pdsh-upstream-authorization'), 'Bearer upstream-key')
  assert.equal(seen[1]?.headers.get('x-pdsh-target-url'), 'https://model.example/v1/messages')
})

// --- Bodyless host responses (MCP Streamable HTTP) -------------------------
//
// A Streamable HTTP client registers with `initialize`, then posts
// `notifications/initialized`, which a compliant server answers with 204 and
// no body. The installed host route must hand that bodyless response through
// without reconstructing a `Response` around a stream: WebKit throws
// "Response cannot have a body with the given status." for a 204 that carries
// any body, including the terminating chunk of a chunked response.

test('a host 204 notification response stays bodyless through the installed route', async () => {
  const seen: Array<{ method?: string | undefined; headers: IncomingHttpHeaders; body: string }> = []
  const server = createServer((req, res) => {
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => chunks.push(chunk))
    req.on('end', () => {
      const target = String(req.headers['x-pdsh-target-url'] ?? '')
      seen.push({ method: req.method, headers: req.headers, body: Buffer.concat(chunks).toString() })
      if (target === 'https://mcp.example.test/mcp') {
        res.writeHead(204, { 'mcp-session-id': 'session-204', 'cache-control': 'no-store' })
        res.end()
        return
      }
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
      res.end('{"ok":true}')
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  const nativeFetch = globalThis.fetch
  const hostFetch = ((input: RequestInfo | URL, init?: RequestInit) =>
    nativeFetch(input, init)) as typeof fetch
  const notification = '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  try {
    await withWorkerHostRoute(hostFetch, 5_000, async () => {
      const response = await globalThis.fetch('https://mcp.example.test/mcp', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: notification,
      })
      assert.equal(response.status, 204)
      assert.equal(response.body, null, 'a 204 fetch response must have a null body')
      assert.equal(response.headers.get('mcp-session-id'), 'session-204')
      assert.equal(await response.text(), '')

      // The same keep-alive host route must still carry the next JSON request.
      const next = await globalThis.fetch('https://model.example.test/v1/messages', {
        method: 'POST',
        body: '{"prompt":"hi"}',
      })
      assert.equal(next.status, 200)
      assert.deepEqual(await next.json(), { ok: true })
    }, base)
  } finally {
    server.closeAllConnections()
    server.close()
  }
  assert.equal(seen.length, 2)
  assert.equal(seen[0]?.method, 'POST')
  assert.equal(seen[0]?.headers.authorization, 'Bearer delivery-probe-token')
  assert.equal(seen[0]?.headers['x-pdsh-target-url'], 'https://mcp.example.test/mcp')
  assert.equal(seen[0]?.headers['x-pdsh-target-method'], 'POST')
  assert.equal(seen[0]?.body, notification)
  assert.equal(seen[1]?.headers['x-pdsh-target-url'], 'https://model.example.test/v1/messages')
})

test('a bodyless status is never re-wrapped around a stray body', async () => {
  // A platform fetch is expected to expose a null body for 204/205/304, but
  // the delivery wrapper is the last Response constructor on the host route.
  // If a platform hands back a stream anyway, it must be cancelled instead of
  // being passed to `new Response(stream, { status: 204 })`.
  let cancelled = false
  const stray = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('must not reach the caller'))
    },
    cancel() {
      cancelled = true
    },
  })
  const fake = (async () => ({
    status: 204,
    statusText: 'No Content',
    headers: new Headers({ 'mcp-session-id': 'session-stray' }),
    body: stray,
    url: 'https://mcp.example.test/mcp',
    redirected: false,
  } as unknown as Response)) as typeof fetch
  const observed = await withWorkerHostRoute(fake, 5_000, async () => {
    const response = await globalThis.fetch('https://mcp.example.test/mcp', {
      method: 'POST',
      body: '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    })
    return {
      status: response.status,
      body: response.body,
      headers: response.headers,
      url: response.url,
      text: await response.text(),
    }
  })
  assert.equal(observed.status, 204)
  assert.equal(observed.body, null)
  assert.equal(observed.headers.get('mcp-session-id'), 'session-stray')
  assert.equal(observed.url, 'https://mcp.example.test/mcp')
  assert.equal(observed.text, '')
  await new Promise(resolve => setTimeout(resolve, 0))
  assert.equal(cancelled, true, 'the stray body stream must be cancelled')
})

// --- Suspension-aware delivery watchdogs (P5 / I7) ------------------------
//
// iOS freezes the WebContent process — and the Worker inside it — while the App
// is in the background. A `setTimeout` armed before the freeze fires the moment
// the process is thawed, so a 60 s wall-clock window can expire although the
// process ran for milliseconds of it; the thaw used to kill a whole turn with
// `PDSH_DELIVERY_TIMEOUT`. The watchdogs now also read `performance.now()`: a
// window the active clock did not spend is a suspension, not an upstream stall,
// and is recovered through the delivery window (body) or renewed (head).
//
// These tests drive the active clock by hand. The real timer supplies the wall
// clock, the fake supplies the active clock: leaving it still while the window
// fires is a freeze, advancing it past half the window is a genuine stall.

test('a body window that expired while the process was frozen resumes from the host log', async () => {
  const first = new TextEncoder().encode('a'.repeat(120))
  const rest = new TextEncoder().encode('b'.repeat(180))
  const resumeHeaders: Array<string | null> = []
  const fake = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers)
    resumeHeaders.push(headers.get('x-pdsh-resume-from'))
    if (resumeHeaders.length === 1) return neverClosingBody([first])
    return new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(rest)
        controller.close()
      },
    }), {
      status: 200,
      headers: { 'content-type': 'text/event-stream', 'x-pdsh-resumed': '1' },
    })
  }) as typeof fetch

  const clock = installFakeActiveClock()
  try {
    const observed = await withWorkerHostRoute(fake, 200, async (module) => {
      const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
      assert.equal(response.status, 200)
      const bytes = new Uint8Array(await response.arrayBuffer())
      return { bytes, metrics: module.deliveryMetricsSnapshot() }
    })
    assert.deepEqual(resumeHeaders, [null, String(first.byteLength)],
      'the thawed delivery must ask for the suffix at the delivered offset')
    assert.deepEqual(Buffer.from(observed.bytes), Buffer.concat([Buffer.from(first), Buffer.from(rest)]),
      'the model client must see one continuous body across the freeze')
    assert.equal(observed.metrics.suspends, 1, 'the frozen window is not an upstream stall')
    assert.equal(observed.metrics.stalls, 0)
    assert.equal(observed.metrics.resumes, 1)
    assert.equal(observed.metrics.attempts, 2)
    assert.equal(observed.metrics.resumedBytes, rest.byteLength)
  } finally {
    clock.restore()
  }
})

test('a body stall that consumed the active window still fails as a delivery timeout', async () => {
  const first = new TextEncoder().encode('a'.repeat(64))
  let calls = 0
  const fake = (async () => {
    calls += 1
    if (calls === 1) return neverClosingBody([first])
    return new Response('the response is not committed', {
      status: 502,
      headers: { 'content-type': 'application/json', 'x-pdsh-proxy-error': 'upstream' },
    })
  }) as typeof fetch

  const clock = installFakeActiveClock()
  // 200 ms window: 150 ms of active time is a real stall (>= half the window).
  const advance = setTimeout(() => clock.advance(150), 100)
  try {
    const observed = await withWorkerHostRoute(fake, 200, async (module) => {
      const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
      const reader = response.body?.getReader()
      assert.ok(reader !== undefined)
      await reader.read()
      try {
        await settleWithin(reader.read(), 2_000, 'stalled body read')
        return { error: undefined, module, metrics: module.deliveryMetricsSnapshot() }
      } catch (error) {
        return { error, module, metrics: module.deliveryMetricsSnapshot() }
      }
    })
    assert.equal(calls, 2)
    assert.ok(observed.error !== undefined)
    assertDeliveryTimeout(observed.error, observed.module, 'body', 200)
    assert.equal(observed.metrics.suspends, 0, 'active time was spent, so this is no suspension')
    assert.equal(observed.metrics.stalls, 1)
  } finally {
    clearTimeout(advance)
    clock.restore()
  }
})

test('a frozen body window the host cannot resume still fails with the typed timeout', async () => {
  const first = new TextEncoder().encode('a'.repeat(48))
  let calls = 0
  const fake = (async () => {
    calls += 1
    if (calls === 1) return neverClosingBody([first])
    return new Response('the response is not committed', { status: 502 })
  }) as typeof fetch

  const clock = installFakeActiveClock()
  try {
    const observed = await withWorkerHostRoute(fake, 120, async (module) => {
      const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
      const reader = response.body?.getReader()
      assert.ok(reader !== undefined)
      await reader.read()
      try {
        await settleWithin(reader.read(), 2_000, 'unresumable frozen body read')
        return { error: undefined, module, metrics: module.deliveryMetricsSnapshot() }
      } catch (error) {
        return { error, module, metrics: module.deliveryMetricsSnapshot() }
      }
    })
    assert.equal(calls, 2)
    assert.ok(observed.error !== undefined)
    assertDeliveryTimeout(observed.error, observed.module, 'body', 120)
    assert.equal(observed.metrics.suspends, 1)
    assert.equal(observed.metrics.stalls, 0)
    assert.equal(observed.metrics.resumes, 0, 'a refused resume does not spend the resume meter')
  } finally {
    clock.restore()
  }
})

test('the resume budget still bounds how many frozen windows a body may recover', async () => {
  const first = new TextEncoder().encode('a'.repeat(64))
  const rest = new TextEncoder().encode('b'.repeat(96))
  let calls = 0
  const fake = (async () => {
    calls += 1
    if (calls === 1) return neverClosingBody([first])
    if (calls === 2) return neverClosingBody([rest], { 'x-pdsh-resumed': '1' })
    return new Response('unexpected third attempt', { status: 502 })
  }) as typeof fetch

  const clock = installFakeActiveClock()
  try {
    const observed = await withWorkerHostRoute(fake, 120, async (module) => {
      const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
      const reader = response.body?.getReader()
      assert.ok(reader !== undefined)
      const chunks: Uint8Array[] = []
      try {
        for (;;) {
          const result = await settleWithin(reader.read(), 2_000, 'frozen body read')
          if (result.done === true) break
          chunks.push(result.value)
        }
        return { chunks, error: undefined, module, metrics: module.deliveryMetricsSnapshot() }
      } catch (error) {
        return { chunks, error, module, metrics: module.deliveryMetricsSnapshot() }
      }
    })
    assert.equal(calls, 2, 'MAX_DELIVERY_RESUMES is 1, so the second freeze cannot resume again')
    assert.equal(observed.chunks.length, 2, 'the bytes before the second freeze were delivered')
    assert.ok(observed.error !== undefined)
    assertDeliveryTimeout(observed.error, observed.module, 'body', 120)
    assert.ok(observed.metrics.suspends >= 2)
    assert.equal(observed.metrics.stalls, 0, 'neither window was an upstream stall')
    assert.equal(observed.metrics.resumes, 1)
  } finally {
    clock.restore()
  }
})

test('a head window that expired while the process was frozen keeps waiting for the head', async () => {
  const chunk = new TextEncoder().encode('event: a\n\n')
  let calls = 0
  const fake = (async () => {
    calls += 1
    // The upstream is still working: the head arrives after the 120 ms window.
    await new Promise(resolve => setTimeout(resolve, 350))
    return new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(chunk)
        controller.close()
      },
    }), { status: 200, headers: { 'content-type': 'text/event-stream' } })
  }) as typeof fetch

  const clock = installFakeActiveClock()
  try {
    const observed = await withWorkerHostRoute(fake, 120, async (module) => {
      const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
      return {
        status: response.status,
        body: await response.text(),
        metrics: module.deliveryMetricsSnapshot(),
      }
    })
    assert.equal(observed.status, 200)
    assert.equal(observed.body, 'event: a\n\n')
    assert.equal(calls, 1, 'a suspended head wait keeps the in-flight request instead of re-issuing it')
    assert.ok(observed.metrics.suspends >= 2, `expected renewed windows, got ${observed.metrics.suspends}`)
    assert.equal(observed.metrics.stalls, 0)
  } finally {
    clock.restore()
  }
})

test('a head stall that consumed the active window still fails as a delivery timeout', async () => {
  const fake = (() => new Promise<Response>(() => {})) as typeof fetch
  const clock = installFakeActiveClock()
  // 120 ms window: 90 ms of active time is a real stall (>= half the window).
  const advance = setTimeout(() => clock.advance(90), 40)
  try {
    const observed = await withWorkerHostRoute(fake, 120, async (module) => {
      try {
        await settleWithin(fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' }),
          2_000, 'stalled head fetch')
        return { error: undefined, module }
      } catch (error) {
        return { error, module }
      }
    })
    assert.ok(observed.error !== undefined)
    assertDeliveryTimeout(observed.error, observed.module, 'head', 120)
  } finally {
    clearTimeout(advance)
    clock.restore()
  }
})

test('an idle consumer is not failed by a window that expired while the process was frozen', async () => {
  const chunk = new TextEncoder().encode('event: a\n\n')
  const fake = (async () => new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(chunk)
      // The body completes only after the first watchdog window has expired.
      setTimeout(() => {
        try { controller.close() } catch { /* already closed */ }
      }, 260)
    },
  }), { status: 200, headers: { 'content-type': 'text/event-stream' } })) as typeof fetch

  const clock = installFakeActiveClock()
  try {
    const observed = await withWorkerHostRoute(fake, 120, async (module) => {
      const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
      // The consumer is frozen too: it does not pull for longer than a window.
      await new Promise(resolve => setTimeout(resolve, 200))
      const bytes = new Uint8Array(await response.arrayBuffer())
      return { bytes, metrics: module.deliveryMetricsSnapshot() }
    })
    assert.deepEqual(Buffer.from(observed.bytes), Buffer.from(chunk))
    assert.ok(observed.metrics.suspends >= 1, 'the idle window must be classified as a suspension')
    assert.equal(observed.metrics.stalls, 0)
    assert.equal(observed.metrics.resumes, 0, 'nothing was stalled, so no host resume is spent')
  } finally {
    clock.restore()
  }
})

test('an idle consumer cannot renew a frozen clock forever', async () => {
  const chunk = new TextEncoder().encode('event: a\n\n')
  // `neverClosingBody` already answers with a 200 event-stream Response; wrapping
  // it in another one is a type error and would double-wrap the stream.
  const fake = (async () => neverClosingBody([chunk])) as typeof fetch

  const clock = installFakeActiveClock()
  try {
    const observed = await withWorkerHostRoute(fake, 80, async (module) => {
      const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
      // Initial window + three renewals. The next expiry must settle the body.
      await new Promise(resolve => setTimeout(resolve, 400))
      try {
        await settleWithin(response.arrayBuffer(), 500, 'idle consumer with a frozen clock')
        return { error: undefined, module, metrics: module.deliveryMetricsSnapshot() }
      } catch (error) {
        return { error, module, metrics: module.deliveryMetricsSnapshot() }
      }
    })
    assert.ok(observed.error !== undefined)
    assertDeliveryTimeout(observed.error, observed.module, 'body', 80)
    assert.equal(observed.metrics.suspends, 3)
    assert.equal(observed.metrics.stalls, 1)
    assert.equal(observed.metrics.resumes, 0)
  } finally {
    clock.restore()
  }
})

test('without a usable active clock the watchdog keeps the wall-clock verdict', async () => {
  const chunk = new TextEncoder().encode('event: a\n\n')
  let calls = 0
  const fake = (async () => {
    calls += 1
    return neverClosingBody([chunk])
  }) as typeof fetch
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'performance')
  // A Worker without `performance`: the fallback must be exactly the previous
  // wall-clock behaviour, i.e. a body without progress still fails the turn.
  Object.defineProperty(globalThis, 'performance', { value: undefined, configurable: true, writable: true })
  try {
    const observed = await withWorkerHostRoute(fake, 120, async (module) => {
      const response = await fetch('https://model.example/v1/messages', { method: 'POST', body: '{}' })
      const reader = response.body?.getReader()
      assert.ok(reader !== undefined)
      await reader.read()
      try {
        await settleWithin(reader.read(), 2_000, 'stalled body read')
        return { error: undefined, module, metrics: module.deliveryMetricsSnapshot() }
      } catch (error) {
        return { error, module, metrics: module.deliveryMetricsSnapshot() }
      }
    })
    assert.equal(calls, 2, 'the wall-clock behaviour still spends its one resume')
    assert.ok(observed.error !== undefined)
    assertDeliveryTimeout(observed.error, observed.module, 'body', 120)
    assert.equal(observed.metrics.suspends, 0)
    assert.equal(observed.metrics.stalls, 1)
  } finally {
    if (descriptor !== undefined) Object.defineProperty(globalThis, 'performance', descriptor)
    else delete (globalThis as { performance?: unknown }).performance
  }
})
