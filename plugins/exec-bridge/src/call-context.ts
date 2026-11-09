// SPDX-License-Identifier: MIT
/**
 * The tool-call context that ties a spawned command or an outgoing HTTP
 * request to the DSH tool call that caused it. The tool journal opens one
 * context per top-level tool call; the subprocess provider and the fetch
 * transport read it to derive deterministic `exec_id`s and `idem_key`s and to
 * attach `XL_IDEMPOTENCY_KEY` / `X-PDSH-Idempotency-Key`.
 *
 * The AsyncLocalStorage instance lives under a global symbol so the packages
 * stay independent: any of them may be loaded without the others.
 * @module @phone-dsh/dsh-exec-bridge/call-context
 */

import { AsyncLocalStorage } from 'node:async_hooks'

/** Global registry key; part of the cross-package contract. */
export const TOOL_CALL_CONTEXT_KEY = Symbol.for('phone-dsh.dsh.tool-call-context')

export interface ToolCallContext {
  readonly sessionId: string
  readonly callId: string
  /** `XL_IDEMPOTENCY_KEY` for this call. */
  readonly key: string
  /** DSH turn number of the call, decimal ASCII (exec.md §1 fallback). */
  readonly turnId?: string
  /** D20 ordinal of the tool call within its turn, decimal ASCII without leading zeros. */
  readonly stepId?: string
  /** Number of spawns already issued by this call; the next spawn uses this index. */
  spawns: number
}

type Registry = { [TOOL_CALL_CONTEXT_KEY]?: AsyncLocalStorage<ToolCallContext> }

/** Return the shared storage, creating and registering it on first use. */
export function toolCallStorage(): AsyncLocalStorage<ToolCallContext> {
  const registry = globalThis as Registry
  registry[TOOL_CALL_CONTEXT_KEY] ??= new AsyncLocalStorage<ToolCallContext>()
  return registry[TOOL_CALL_CONTEXT_KEY]
}

/** The context of the tool call currently executing on this async path, if any. */
export function currentToolCall(): ToolCallContext | undefined {
  return (globalThis as Registry)[TOOL_CALL_CONTEXT_KEY]?.getStore()
}

/**
 * Registry of in-flight MCP tool calls; part of the cross-package contract.
 *
 * The Worker's AsyncLocalStorage is best-effort: a native `await` inside code
 * its loader did not rewrite (the MCP SDK transport) resumes from a stack
 * ordered by nesting, not causality, so the store read at `fetch` time can be
 * missing or belong to another call. A JSON-RPC `tools/call` therefore carries
 * its journal key by exact correlation instead: the journal registers the call
 * here for its whole extent and the fetch transport looks it up by tool name
 * and arguments. No match, or more than one, attaches nothing (fail closed).
 */
export const MCP_CALL_KEYS_KEY = Symbol.for('phone-dsh.dsh.mcp-call-keys')

export interface McpCallKeyEntry {
  /** The server's own tool name (`params.name` on the wire). */
  readonly tool: string
  /** Journal idempotency key of the DSH tool call. */
  readonly key: string
  /** True when `args` are the call's arguments (canonical JSON equality). */
  readonly matches: (args: unknown) => boolean
}

type KeyRegistry = { [MCP_CALL_KEYS_KEY]?: Set<McpCallKeyEntry> }

function mcpCallKeys(): Set<McpCallKeyEntry> {
  const registry = globalThis as KeyRegistry
  registry[MCP_CALL_KEYS_KEY] ??= new Set<McpCallKeyEntry>()
  return registry[MCP_CALL_KEYS_KEY]
}

/** Canonical JSON: object keys sorted, so equal arguments compare equal. */
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(',')}}`
  }
  return JSON.stringify(value) ?? 'null'
}

/**
 * Register an in-flight MCP tool call. `publicName` is DSH's
 * `mcp__<server>__<tool>`; anything else registers nothing.
 * @returns the disposer that removes the entry.
 */
export function registerMcpCall(publicName: string, args: unknown, key: string): () => void {
  const match = /^mcp__[^_](?:[^_]|_(?!_))*__(.+)$/.exec(publicName)
  if (match === null || key === '') return () => {}
  const expected = canonicalJson(args ?? {})
  const entry: McpCallKeyEntry = { tool: match[1]!, key, matches: (value) => canonicalJson(value ?? {}) === expected }
  const keys = mcpCallKeys()
  keys.add(entry)
  return () => { keys.delete(entry) }
}

/** The single registered key for this `tools/call`, or undefined when none or several match. */
export function mcpCallKey(tool: string, args: unknown): string | undefined {
  const found = new Set<string>()
  for (const entry of (globalThis as KeyRegistry)[MCP_CALL_KEYS_KEY] ?? []) {
    if (entry.tool === tool && entry.matches(args)) found.add(entry.key)
  }
  return found.size === 1 ? [...found][0] : undefined
}
