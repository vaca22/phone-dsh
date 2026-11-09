// SPDX-License-Identifier: MIT
/**
 * The journal key of an MCP tool call must reach the native endpoint without
 * relying on AsyncLocalStorage surviving the MCP SDK transport's own awaits
 * (the Worker's ALS is best-effort there). The real ToolJournal registers each
 * `mcp__<server>__<tool>` call for exactly the body's extent; the fetch
 * transport (llm-install.test.ts) resolves the key from that registry.
 */
import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { ToolJournal } from '../tool-journal/src/index.ts'
import { idempotencyKey } from '../tool-journal/src/journal.ts'
import { mcpCallKey } from '../exec-bridge/src/call-context.ts'

async function journalContext(): Promise<Context> {
  const ctx = new Context()
  ctx.provide('sessions', { flush: async () => {} })
  ctx.provide('tools', { get: () => undefined })
  await ctx.plugin(ToolJournal, {
    root: mkdtempSync(join(tmpdir(), 'pdsh-mcp-key-')),
    profile: 'pdsh-phone/1+mcp-call-key',
    classes: {},
    rerun: false,
    rerunTimeoutMs: 1_000,
    abortSettleMs: 100,
  })
  return ctx
}

test('the journal registers an MCP call key for the body extent only', { timeout: 10_000 }, async () => {
  const ctx = await journalContext()
  const sessionId = 'session-mcp-key'
  const callId = 'call_light_on'
  const args = { device_id: 'd', name: 'light.set', args: { on: true } }
  let during: string | undefined
  const dispatch = ctx.waterfall('tools/execute', {
    agent: { session: { id: sessionId } },
    parent: undefined,
    name: 'mcp__phone__ble_link_call',
    callId,
    arguments: args,
    signal: new AbortController().signal,
  } as never, (async () => {
    // What the SDK transport would send, with keys in another order.
    during = mcpCallKey('ble_link_call', { args: { on: true }, name: 'light.set', device_id: 'd' })
    return { isError: false, content: [] }
  }) as never) as unknown as Promise<unknown>
  await dispatch
  assert.equal(during, idempotencyKey(sessionId, callId))
  assert.equal(mcpCallKey('ble_link_call', args), undefined, 'released after the body settles')
})

test('a failing MCP body still releases its key; non-MCP tools register nothing', { timeout: 10_000 }, async () => {
  const ctx = await journalContext()
  const failing = ctx.waterfall('tools/execute', {
    agent: { session: { id: 's' } }, parent: undefined, name: 'mcp__phone__iphone_agent_run',
    callId: 'c1', arguments: { task: 't' }, signal: new AbortController().signal,
  } as never, (async () => { throw new Error('boom') }) as never) as unknown as Promise<unknown>
  await failing.catch(() => {})
  assert.equal(mcpCallKey('iphone_agent_run', { task: 't' }), undefined)
  let seen: string | undefined = 'unset'
  await (ctx.waterfall('tools/execute', {
    agent: { session: { id: 's' } }, parent: undefined, name: 'bash',
    callId: 'c2', arguments: { command: 'true' }, signal: new AbortController().signal,
  } as never, (async () => { seen = mcpCallKey('bash', { command: 'true' }); return { isError: false, content: [] } }) as never) as unknown as Promise<unknown>)
  assert.equal(seen, undefined)
})
