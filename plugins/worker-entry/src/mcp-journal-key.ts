// SPDX-License-Identifier: MIT
/**
 * Journal key for the phone MCP endpoint, beneath every `fetch` binding.
 *
 * The MCP SDK transport binds `fetch` when it is constructed
 * (`createFetchWithInit(baseFetch = fetch, …)`). DSH can build the `phone`
 * transport before the llm-bridge plugin has replaced `globalThis.fetch`, so
 * its `tools/call` POSTs went out on the platform fetch and reached the native
 * tools without `X-PDSH-Idempotency-Key` (native-mcp.md promises the key). This
 * wrapper is installed before DSH boots, so whatever binds `fetch` later still
 * passes through it.
 *
 * It touches only a JSON-RPC `tools/call` POST to the phone MCP endpoint
 * (`PDSH_PHONE_MCP_URL`, or the same-origin `/mcp/native`) that does not
 * already carry a key. The key is the single in-flight registration from the
 * tool journal (exec-bridge `call-context.ts`), else the ambient tool-call
 * context read before any await. Every other request goes to the platform
 * fetch unchanged.
 * @module @phone-dsh/dsh-worker-entry/mcp-journal-key
 */

const TOOL_CALL_CONTEXT_KEY = Symbol.for('phone-dsh.dsh.tool-call-context')
const MCP_CALL_KEYS_KEY = Symbol.for('phone-dsh.dsh.mcp-call-keys')
const KEY_HEADER = 'x-pdsh-idempotency-key'

interface McpCallKeyEntry { readonly tool: string, readonly key: string, readonly matches: (args: unknown) => boolean }
type Scope = {
  [TOOL_CALL_CONTEXT_KEY]?: { getStore(): { key: string } | undefined }
  [MCP_CALL_KEYS_KEY]?: Set<McpCallKeyEntry>
  location?: { origin?: string }
}

/** The single registered key for this JSON-RPC body, or undefined (none, several, or not tools/call). */
export function registeredToolCallKey(body: Uint8Array | undefined): string | undefined {
  const entries = (globalThis as Scope)[MCP_CALL_KEYS_KEY]
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

function parseUrl(value: string | undefined): URL | undefined {
  if (!value) return undefined
  try { return new URL(value) } catch { return undefined }
}

function isPhoneMcpEndpoint(url: URL, configured: URL | undefined): boolean {
  if (configured !== undefined && url.origin === configured.origin && url.pathname === configured.pathname) return true
  const origin = (globalThis as Scope).location?.origin
  return origin !== undefined && url.origin === origin && url.pathname === '/mcp/native'
}

/** Wrap `platform` so phone MCP tool calls carry their journal key. */
export function phoneMcpKeyFetch(platform: typeof fetch, phoneMcpUrl: () => string | undefined): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const ambient = (globalThis as Scope)[TOOL_CALL_CONTEXT_KEY]?.getStore()?.key
    const method = (init?.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase()
    let url: URL
    try { url = new URL(input instanceof Request ? input.url : String(input)) } catch { return await platform(input, init) }
    if (method !== 'POST' || !isPhoneMcpEndpoint(url, parseUrl(phoneMcpUrl()))) return await platform(input, init)
    const request = new Request(input instanceof Request ? input.clone() : input, init)
    if (request.headers.has(KEY_HEADER)) return await platform(input, init)
    const body = request.body === null ? undefined : new Uint8Array(await request.clone().arrayBuffer())
    const key = registeredToolCallKey(body) ?? ambient
    if (key === undefined) return await platform(request)
    const headers = new Headers(request.headers)
    headers.set(KEY_HEADER, key)
    return await platform(new Request(request, { headers }))
  }) as typeof fetch
}

/** Install the wrapper over the current `globalThis.fetch`; returns the disposer. */
export function installPhoneMcpKeyFetch(phoneMcpUrl: () => string | undefined = () => process.env.PDSH_PHONE_MCP_URL): () => void {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'fetch')
  if (typeof globalThis.fetch !== 'function') return () => {}
  const wrapped = phoneMcpKeyFetch(globalThis.fetch.bind(globalThis), phoneMcpUrl)
  Object.defineProperty(globalThis, 'fetch', { value: wrapped, writable: true, configurable: true, enumerable: true })
  return () => {
    if (globalThis.fetch !== wrapped) return
    if (previous === undefined) Reflect.deleteProperty(globalThis, 'fetch')
    else Object.defineProperty(globalThis, 'fetch', previous)
  }
}
