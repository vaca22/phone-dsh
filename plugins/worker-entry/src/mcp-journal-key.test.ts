// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { registerMcpCall } from '../../exec-bridge/src/call-context.ts'
import { installPhoneMcpKeyFetch, phoneMcpKeyFetch } from './mcp-journal-key.ts'

const PHONE = 'http://127.0.0.1:51819/mcp'
const call = (name: string, args: unknown): string =>
  JSON.stringify({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name, arguments: args } })

function recorder(): { platform: typeof fetch, seen: Request[] } {
  const seen: Request[] = []
  const platform = (async (input: RequestInfo | URL, init?: RequestInit) => {
    seen.push(new Request(input, init))
    return new Response('{}', { headers: { 'content-type': 'application/json' } })
  }) as typeof fetch
  return { platform, seen }
}

test('a fetch bound before any later replacement still carries the journal key (device regression)', async () => {
  const saved = Object.getOwnPropertyDescriptor(globalThis, 'fetch')
  const { platform, seen } = recorder()
  Object.defineProperty(globalThis, 'fetch', { value: platform, writable: true, configurable: true, enumerable: true })
  const restore = installPhoneMcpKeyFetch(() => PHONE)
  // The MCP SDK: `createFetchWithInit(baseFetch = fetch)` at transport construction.
  const boundBySdk = globalThis.fetch
  // llm-bridge activates later and replaces the global; the SDK keeps its binding.
  Object.defineProperty(globalThis, 'fetch', { value: (() => { throw new Error('not used by the SDK') }) as unknown as typeof fetch, writable: true, configurable: true, enumerable: true })
  const release = registerMcpCall('mcp__phone__ble_link_call', { device_id: 'd', name: 'light.set', args: { on: true } }, 'light-on')
  try {
    await boundBySdk(PHONE, { method: 'POST', headers: { authorization: 'Bearer t', 'content-type': 'application/json' },
      body: call('ble_link_call', { args: { on: true }, device_id: 'd', name: 'light.set' }) })
    assert.equal(seen[0]?.url, PHONE)
    assert.equal(seen[0]?.headers.get('x-pdsh-idempotency-key'), 'light-on')
    assert.equal(seen[0]?.headers.get('authorization'), 'Bearer t')
  } finally {
    release()
    Object.defineProperty(globalThis, 'fetch', { value: boundBySdk, writable: true, configurable: true, enumerable: true })
    restore()
    assert.equal(globalThis.fetch, platform, 'the disposer restores the platform fetch')
    if (saved !== undefined) Object.defineProperty(globalThis, 'fetch', saved)
  }
})

test('only phone MCP tools/call POSTs are touched; existing keys and bodies are preserved', async () => {
  const { platform, seen } = recorder()
  const keyed = phoneMcpKeyFetch(platform, () => PHONE)
  const body = call('ble_link_call', { device_id: 'd', name: 'light.set', args: { on: true } })
  const release = registerMcpCall('mcp__phone__ble_link_call', { device_id: 'd', name: 'light.set', args: { on: true } }, 'k')
  try {
    await keyed('http://127.0.0.1:51820/v1/http', { method: 'POST', body })
    await keyed('http://127.0.0.1:51819/other', { method: 'POST', body })
    await keyed(PHONE)
    await keyed(PHONE, { method: 'POST', body: call('ble_link_call', { device_id: 'd', name: 'light.set', args: { on: false } }) })
    for (const request of seen) assert.equal(request.headers.has('x-pdsh-idempotency-key'), false)
    await keyed(new Request(PHONE, { method: 'POST', body, headers: { 'x-pdsh-idempotency-key': 'own' } }))
    assert.equal(seen[4]?.headers.get('x-pdsh-idempotency-key'), 'own')
    assert.equal(await seen[4]?.text(), body)
    await keyed(new Request(PHONE, { method: 'POST', body }))
    assert.equal(seen[5]?.headers.get('x-pdsh-idempotency-key'), 'k')
    assert.equal(await seen[5]?.text(), body)
  } finally {
    release()
  }
})

test('without a registration the ambient tool-call key is used; two matching registrations fail closed to it', async () => {
  const contextKey = Symbol.for('phone-dsh.dsh.tool-call-context')
  const scope = globalThis as unknown as Record<symbol, unknown>
  const previous = scope[contextKey]
  scope[contextKey] = { getStore: () => ({ key: 'ambient' }) }
  const { platform, seen } = recorder()
  const keyed = phoneMcpKeyFetch(platform, () => PHONE)
  const a = registerMcpCall('mcp__phone__iphone_agent_run', { task: 't' }, 'a')
  const b = registerMcpCall('mcp__phone__iphone_agent_run', { task: 't' }, 'b')
  try {
    await keyed(PHONE, { method: 'POST', body: call('iphone_agent_run', { task: 't' }) })
    await keyed(PHONE, { method: 'POST', body: call('ble_devices', {}) })
    assert.equal(seen[0]?.headers.get('x-pdsh-idempotency-key'), 'ambient')
    assert.equal(seen[1]?.headers.get('x-pdsh-idempotency-key'), 'ambient')
  } finally {
    a(); b()
    if (previous === undefined) delete scope[contextKey]
    else scope[contextKey] = previous
  }
})
