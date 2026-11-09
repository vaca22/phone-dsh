// SPDX-License-Identifier: MIT
/**
 * `ctx.toolJournal`: a durable write-ahead journal of top-level tool calls for
 * crash-only resume on a phone, where the OS may kill the app at any moment.
 *
 * Write path (per top-level call):
 *   flush the session (the `tool/call` is durable) → journal `start` (fsync) →
 *   run the tool inside a tool-call context carrying `XL_IDEMPOTENCY_KEY` →
 *   journal `executed` (fsync) → … post-execute … → journal `done` (fsync)
 *   from `tools/result`, before the agent loop appends the `tool/result`.
 * The journal is therefore always at least as new as the session log; it is
 * compacted at the next `agent/pre-step`, once the previous step's results are
 * durable in the log.
 *
 * Resume path: the journaled JSONL persistence (`./persistence`) calls
 * {@link ToolJournal.reconcile} when a session is opened for writing — before
 * AgentLoop computes `interruptedTurnClosers` — and appends a `tool/result` for
 * every interrupted call the journal can settle (see `./reconcile`).
 *
 * Abort path (G2-FIX-84): a budget/cancel teardown closes admission and sends
 * `session/cancel`; the agent loop aborts the tool signal and waits for the
 * dispatch to settle, but a command that does not observe the signal would hold
 * the turn open until the process is killed, leaving `start` without an end and
 * a D13 step stuck at `tool_dispatched`. The wrapper therefore races the tool
 * body against the caller's abort signal. A body that settles inside the short
 * grace keeps its own cancellation result; one that does not is settled here
 * with a terminal `isError` result carrying the `AgentCancelCause` and a
 * journal `done`, before DSH appends the `tool/result` and closes the turn.
 * @module @phone-dsh/dsh-tool-journal
 */

import { Context, Service } from '@deepseek-ai/cordis'
import schema from '@deepseek-ai/schemastery'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import type { ToolDefinition, ToolExecutionResult } from '@deepseek-ai/dsh-tools'
import type {} from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-session'
import type { SessionHandle } from '@deepseek-ai/dsh-session-persistence'
import { registerMcpCall, toolCallStorage } from '@phone-dsh/dsh-exec-bridge/call-context'
import { createClassifier } from './classify.ts'
import { withResolvers } from './deferred.ts'
import type { ToolClass } from './classify.ts'
import {
  SLOW_JOURNAL_SYNC_MILLISECONDS, ToolJournalStore, canonicalHash, idempotencyKey,
} from './journal.ts'
import type { JournaledResult, JournalSyncTiming } from './journal.ts'
import { interruptedCalls, plan, reconciledCallIds, toolResultEvent, unknownOutcomeText } from './reconcile.ts'
import type { InterruptedCall, LogEvent } from './reconcile.ts'

export { createClassifier, DEFAULT_TOOL_CLASSES } from './classify.ts'
export type { ToolClass } from './classify.ts'
export { canonicalHash, idempotencyKey, ToolJournalStore } from './journal.ts'
export type { JournalSyncTiming } from './journal.ts'

/**
 * Worker global carrying the bounded recent `0x30` → `0x31` hop samples
 * (G2-FIX-83). The host's channel metrics retain the matching ack hop, so a
 * step record's `at_ms` pair can be split into Worker and host halves.
 */
export const JOURNAL_SYNC_TIMINGS_GLOBAL = '__PDSH_JOURNAL_SYNC_TIMINGS__'
/** Most recent journal sync hop samples retained on the Worker global. */
const JOURNAL_SYNC_TIMING_SAMPLES = 64
export { interruptedCalls, plan, unknownOutcomeText } from './reconcile.ts'

export interface Config {
  /** Journal directory (one file per session). */
  root: string
  /**
   * Identity of the running composition (profile + DSH version). A journal
   * written under another identity is never backfilled.
   */
  profile: string
  /** Tool classes over the defaults; `*` suffix matches a prefix. Unknown tools are non-idempotent. */
  classes: Record<string, ToolClass>
  /** Re-run interrupted read-only / idempotent calls on resume. */
  rerun: boolean
  /** Upper bound for one re-run during resume. */
  rerunTimeoutMs: number
  /**
   * How long an aborted tool body may take to settle on its own before the
   * wrapper settles it with a terminal cancellation result (G2-FIX-84).
   * A cooperative command returns its own SIGTERM/130 result inside this
   * window, so its result and diagnostics are preserved; a command that cannot
   * observe the abort is cut off at the deadline instead of holding the turn
   * open until the Worker is killed.
   */
  abortSettleMs?: number
}

declare module '@deepseek-ai/cordis' {
  interface Context { toolJournal: ToolJournal }
}

/** Durable projection of a tool result: what the `tool/result` event keeps. */
/**
 * Test-only fault injection for the crash-resume simulation: `after-start`
 * or `after-done` SIGKILLs this process right after that journal record is
 * durable, reproducing an OS kill inside a window too short to hit from
 * outside. Never set it in a deployment.
 */
const FAULT = process.env.PDSH_JOURNAL_FAULT

function injectFault(point: 'after-start' | 'after-done'): void {
  if (FAULT === point) process.kill(process.pid, 'SIGKILL')
}

function project(result: ToolExecutionResult): JournaledResult {
  return {
    content: result.content as unknown[],
    isError: result.isError,
    ...result.error?.info === undefined ? {} : { error: { ...result.error.info } },
    ...result.meta === undefined ? {} : { meta: result.meta },
  }
}

/** Outcome of racing one tool body against its caller's abort signal. */
type ToolBodyOutcome =
  | { readonly kind: 'settled'; readonly result: ToolExecutionResult }
  | { readonly kind: 'rejected'; readonly error: unknown }
  | { readonly kind: 'aborted' }

/**
 * Fuse two abort signals without requiring `AbortSignal.any` in the embedded
 * engine (the same class is used elsewhere in the Worker, but the tool path is
 * too hot to make a newer WebKit API a hard boot requirement).
 * @param first - the caller's fused DSH signal.
 * @param second - the host teardown signal.
 * @returns a signal that aborts with the first source's reason.
 */
function fuseAbortSignals(first: AbortSignal, second: AbortSignal): AbortSignal {
  if (first === second) return first
  const anyOf = (AbortSignal as unknown as {
    any?: (signals: AbortSignal[]) => AbortSignal
  }).any
  if (typeof anyOf === 'function') return anyOf.call(AbortSignal, [first, second])
  const controller = new AbortController()
  const forward = (source: AbortSignal): void => {
    if (controller.signal.aborted) return
    controller.abort(source.reason)
  }
  if (first.aborted) forward(first)
  else if (second.aborted) forward(second)
  else {
    first.addEventListener('abort', () => { forward(first) }, { once: true })
    second.addEventListener('abort', () => { forward(second) }, { once: true })
  }
  return controller.signal
}

/** The `AgentCancelCause` carried by an aborted DSH tool signal. */
function abortCause(signal: AbortSignal): Record<string, unknown> {
  const reason: unknown = signal.reason
  if (reason !== null && typeof reason === 'object') return reason as Record<string, unknown>
  return { kind: 'user' }
}

/** The `kind` of an `AgentCancelCause`, for the model-facing text and the log. */
function abortCauseKind(cause: Record<string, unknown>): string {
  return typeof cause.kind === 'string' ? cause.kind : 'user'
}

/**
 * Canonical JSON for the cause chain without throwing on a cyclic reason.
 * @param cause - the abort reason recorded by DSH.
 * @returns a JSON-safe rendering for logs and model-facing text.
 */
function causeText(cause: Record<string, unknown>): string {
  try {
    return JSON.stringify(cause) ?? String(cause)
  } catch {
    return String(cause)
  }
}

/**
 * The model-facing and journaled result for a tool call the wrapper had to
 * settle on its own after abort.
 *
 * The result is `isError`, carries the full `AgentCancelCause` in
 * `error.info.reason`, and says explicitly that the command was cut off and may
 * have left partial writes. The WAL keeps those writes (D8/D9): this result
 * marks them, it does not revert them.
 * @param exec - the call being settled.
 * @param key - the D20 idempotency key.
 * @param cause - the abort reason from the tool signal.
 * @returns a terminal tool error result.
 */
function abortedToolResult(exec: { readonly name: string; readonly callId: string },
                           key: string,
                           cause: Record<string, unknown>): ToolExecutionResult {
  const kind = abortCauseKind(cause)
  const text = `Error: the ${exec.name} tool call was cut off before it returned a result (cancel cause: ${kind}, ${causeText(cause)}). `
    + 'The command was cancelled by the harness; any partial writes it already made remain in the workspace and the WAL. '
    + `Idempotency key: ${key}.`
  return {
    isError: true,
    error: {
      message: 'tool call aborted',
      info: {
        name: 'AbortError',
        code: 'ABORTED',
        // `ToolErrorInfo` has a single free-form detail field; the canonical
        // JSON keeps the whole AgentCancelCause chain, not only its kind.
        reason: causeText(cause),
      },
    },
    content: [{ type: 'text', text }],
  }
}

/**
 * Race one tool body against its caller's abort signal.
 *
 * The body gets {@link Config.abortSettleMs} to settle after the abort so a
 * cooperative command keeps its own result (SIGTERM/130, stderr, partial
 * output). After that the wrapper returns `aborted` and the caller writes the
 * terminal cancellation result.
 * @param body - the dispatch promise.
 * @param signal - the fused DSH tool signal.
 * @param graceMs - post-abort settle grace.
 * @returns which side won.
 */
async function settleOrAbort(body: Promise<ToolExecutionResult>,
                             signal: AbortSignal,
                             graceMs: number): Promise<ToolBodyOutcome> {
  if (signal.aborted) return { kind: 'aborted' }
  const wrap = (promise: Promise<ToolExecutionResult>): Promise<ToolBodyOutcome> =>
    promise.then(
      result => ({ kind: 'settled', result }),
      error => ({ kind: 'rejected', error }),
    )
  const aborted = withResolvers<ToolBodyOutcome>()
  const onAbort = (): void => { aborted.resolve({ kind: 'aborted' }) }
  signal.addEventListener('abort', onAbort, { once: true })
  try {
    const first = await Promise.race([wrap(body), aborted.promise])
    if (first.kind !== 'aborted') return first
    if (graceMs <= 0) return first
    let timer: ReturnType<typeof setTimeout> | undefined
    const grace = new Promise<ToolBodyOutcome>(resolve => {
      timer = setTimeout(() => { resolve({ kind: 'aborted' }) }, graceMs)
      timer.unref?.()
    })
    try {
      const second = await Promise.race([wrap(body), grace])
      // A body that rejects after the abort is a cancelled command, not a new
      // tool failure: the caller's turn is already aborting.
      return second.kind === 'rejected' ? { kind: 'aborted' } : second
    } finally {
      if (timer !== undefined) clearTimeout(timer)
    }
  } finally {
    signal.removeEventListener('abort', onAbort)
  }
}

/**
 * Await one recovery re-run only while its cancellation signal is live.
 *
 * DSH's tool registry deliberately waits for a started body to reach
 * quiescence before it reports `ABORTED`. A read-only/idempotent body that is
 * stuck in a native call and does not observe its signal would therefore keep
 * the recovery write-open — and the session writer lease — owned past the
 * route deadline. The re-run class contract makes releasing the writer safe:
 * the call may be executed again, and no result is journaled from the
 * abandoned execution. The body is still observed to its own settlement so a
 * late result or failure is reported instead of becoming an unhandled
 * rejection.
 *
 * @param body - the real `tools.execute` promise.
 * @param signal - the fused route deadline / rerun-timeout signal.
 * @param onLateSettlement - reports a body that settles after cancellation.
 * @returns the body's result when it settles before cancellation.
 */
async function awaitRerunBody<T>(body: Promise<T>, signal: AbortSignal,
                                 onLateSettlement: (outcome: { kind: 'fulfilled' } | { kind: 'rejected'; error: unknown }) => void): Promise<T> {
  const observeLate = (): void => {
    void body.then(
      () => { onLateSettlement({ kind: 'fulfilled' }) },
      (error: unknown) => { onLateSettlement({ kind: 'rejected', error }) },
    ).catch(() => {})
  }
  if (signal.aborted) {
    observeLate()
    throw signal.reason ?? new Error('tool-journal: re-run cancelled before dispatch')
  }
  const aborted = withResolvers<never>()
  const onAbort = (): void => {
    aborted.reject(signal.reason ?? new Error('tool-journal: re-run cancelled'))
  }
  signal.addEventListener('abort', onAbort, { once: true })
  try {
    return await Promise.race([body, aborted.promise])
  } catch (error) {
    if (signal.aborted) observeLate()
    throw error
  } finally {
    signal.removeEventListener('abort', onAbort)
  }
}

/** Hash of the model-facing schema of one tool (name, description, parameters). */
export function schemaHash(tool: Pick<ToolDefinition, 'name' | 'description' | 'parameters'>): string {
  return canonicalHash({ name: tool.name, description: tool.description, parameters: tool.parameters })
}

export class ToolJournal extends Service {
  static inject = ['tools', 'sessions']
  static Config: schema<Config> = schema.object({
    root: schema.string().required(),
    profile: schema.string().required(),
    classes: schema.dict(schema.union(['read-only', 'idempotent', 'non-idempotent'] as const)).default({}),
    rerun: schema.boolean().default(true),
    rerunTimeoutMs: schema.number().default(60_000),
    abortSettleMs: schema.number().default(500),
  }) as schema<Config>

  readonly store: ToolJournalStore
  readonly classify: (name: string) => ToolClass
  private readonly config: Config
  /** Top-level calls between `start` and `done`, per session. */
  private readonly inflight = new Map<string, Set<string>>()
  /** Sessions whose journal gained records since its last compaction. */
  private readonly dirty = new Set<string>()
  /**
   * Host teardown cancellation (G2-FIX-84). The Worker keeps listening to the
   * ordered channel during a drain, so the host can close admission with a
   * `0x50 LIFECYCLE stop` even when the session-level cancel RPC is delayed.
   * The entry dispatches that frame as `pdsh-lifecycle`; this controller fuses
   * into every in-flight tool signal, so the command itself observes the
   * cancellation (D12: it runs in this Worker) and the wrapper settles the
   * call even when the command does not.
   */
  private readonly hostCancellation = new AbortController()

  constructor(ctx: Context, config: Config) {
    super(ctx, 'toolJournal')
    this.config = config
    // G2-FIX-83: retain the 0x30 -> 0x31 hop timestamps and report a slow
    // boundary on the console stream. The wait itself always resolves on the
    // cumulative level-1 ack; the 30 s window is only the fail-loud deadline.
    const syncTimings: JournalSyncTiming[] = []
    const syncGlobals = globalThis as { __PDSH_JOURNAL_SYNC_TIMINGS__?: JournalSyncTiming[] }
    syncGlobals.__PDSH_JOURNAL_SYNC_TIMINGS__ = syncTimings
    this.store = new ToolJournalStore(config.root, config.profile, {
      onSyncTiming: (timing) => {
        syncTimings.push(timing)
        if (syncTimings.length > JOURNAL_SYNC_TIMING_SAMPLES) syncTimings.shift()
        // G2-FIX-119: a slow hop that is mostly this Worker's own event-loop
        // starvation (a CPU-bound in-Worker command) is kept in the sample
        // array above but is not host latency, so it must not pollute the
        // scenario's console_errors.
        if (timing.waitMilliseconds >= SLOW_JOURNAL_SYNC_MILLISECONDS && !timing.workerBusy) {
          console.error(`pdsh-journal-sync: jseq ${String(timing.jseq)} level-1 ack after ${String(timing.waitMilliseconds)} ms (started_at_ms=${String(timing.startedAtMilliseconds)} acked_at_ms=${String(timing.ackedAtMilliseconds)} event_loop_blocked_ms=${String(timing.eventLoopBlockedMilliseconds)} worker_busy=${String(timing.workerBusy)})`)
        }
      },
    })
    this.classify = createClassifier(config.classes)
    ctx.effect(() => () => {
      this.store.close()
      if (syncGlobals.__PDSH_JOURNAL_SYNC_TIMINGS__ === syncTimings) {
        delete syncGlobals.__PDSH_JOURNAL_SYNC_TIMINGS__
      }
    }, 'tool-journal files')
    // The Worker entry publishes its EventTarget as `__PDSH_EVENTS__`; a unit
    // test or a deployment without the entry simply has no host cancellation
    // frame and keeps relying on the DSH `session/cancel` path.
    const events = (globalThis as { __PDSH_EVENTS__?: EventTarget }).__PDSH_EVENTS__
    if (events !== undefined) {
      const onLifecycle = (event: Event): void => {
        const payload = (event as Event & { detail?: unknown }).detail
        if (payload === null || typeof payload !== 'object') return
        if ((payload as { state?: unknown }).state !== 'stop') return
        if (this.hostCancellation.signal.aborted) return
        const admission = (payload as { admission?: unknown }).admission
        const reason = typeof (payload as { reason?: unknown }).reason === 'string'
          ? String((payload as { reason?: unknown }).reason) : 'host'
        this.hostCancellation.abort({
          kind: 'hook',
          reason: { kind: 'drain', admission: admission === 'closed' ? 'closed' : 'open', reason },
        })
      }
      events.addEventListener('pdsh-lifecycle', onLifecycle)
      ctx.effect(() => () => events.removeEventListener('pdsh-lifecycle', onLifecycle),
        'tool-journal host cancellation')
    }

    ctx.on('tools/execute', async (exec, next) => {
      if (exec.agent === undefined || exec.parent !== undefined) return next()
      const session = exec.agent.session
      const sessionId = String(session.id)
      // The recorded `tool/call` must be durable before the journal says "started".
      await ctx.sessions.flush(session)
      if (exec.signal.aborted) return next()
      const key = idempotencyKey(sessionId, exec.callId)
      const tool = ctx.tools.get(exec.name, exec.agent)
      this.track(sessionId, exec.callId, true)
      this.store.append(sessionId, {
        v: 1, t: 'start', key, call_id: exec.callId, tool: exec.name, class: this.classify(exec.name),
        args_sha256: canonicalHash(exec.arguments), schema_sha256: tool === undefined ? null : schemaHash(tool),
        profile: config.profile, at: Date.now(),
      })
      // DSH lets an around-dispatch wrapper replace `exec.signal` for the
      // delegated body (and fuses it back with the caller's); the fused signal
      // carries both the session cancel and the host teardown cancel.
      exec.signal = fuseAbortSignals(exec.signal, this.hostCancellation.signal)
      injectFault('after-start')
      // MCP calls also carry the key by correlation: the Worker's ALS may not
      // survive the SDK transport's own awaits (call-context.ts).
      const releaseMcpKey = registerMcpCall(exec.name, exec.arguments, key)
      let body: Promise<ToolExecutionResult>
      try {
        body = Promise.resolve(toolCallStorage().run({ sessionId, callId: exec.callId, key, spawns: 0 }, next))
      } catch (error) {
        releaseMcpKey()
        throw error
      }
      void body.then(releaseMcpKey, releaseMcpKey)
      const outcome = await settleOrAbort(body, exec.signal, config.abortSettleMs ?? 500)
      if (outcome.kind === 'rejected') throw outcome.error
      // Once the caller signal is aborted the call's outcome is a
      // cancellation, whether the body returned before the grace expired or
      // not. Settle it here with one result shape: the journal end and the
      // session `tool/result` then agree, and an aborted call is never
      // backfilled later from a *success* `executed` record.
      if (exec.signal.aborted) {
        const cause = abortCause(exec.signal)
        const result = abortedToolResult(exec, key, cause)
        // End the call before the agent loop appends its `tool/result`: the
        // host drain must see a terminal D13 step even if the Worker dies
        // immediately after the result is emitted. Marking the call settled
        // first makes the later `tools/result` observer a no-op.
        this.track(sessionId, exec.callId, false)
        // The terminal record must not wait for the same 0x31 ack that the
        // teardown is already racing. The plaintext journal write happens
        // first inside `append`; bound the channel-ack wait so a dead ack
        // never keeps the turn open (the host's own step check fails loud if
        // the record did not reach it).
        const ended = this.store.append(sessionId, {
          v: 1, t: 'done', key, call_id: exec.callId, result: project(result), at: Date.now(),
        }).catch(() => {})
        await new Promise<void>(resolve => {
          const timer = setTimeout(resolve, Math.max(250, config.abortSettleMs ?? 500))
          timer.unref?.()
          void ended.then(() => { clearTimeout(timer); resolve() })
        })
        return result
      }
      if (outcome.kind !== 'settled') {
        throw new Error('tool-journal: an aborted tool outcome arrived without an aborted caller signal')
      }
      const result = outcome.result
      this.store.append(sessionId, { v: 1, t: 'executed', key, call_id: exec.callId, result: project(result), at: Date.now() })
      return result
    })

    ctx.on('tools/result', (exec, result) => {
      if (exec.agent === undefined || exec.parent !== undefined) return
      const sessionId = String(exec.agent.session.id)
      if (!this.inflight.get(sessionId)?.has(exec.callId)) return
      const key = idempotencyKey(sessionId, exec.callId)
      this.store.append(sessionId, { v: 1, t: 'done', key, call_id: exec.callId, result: project(result), at: Date.now() })
      this.track(sessionId, exec.callId, false)
      injectFault('after-done')
    })

    // A new step means the previous step's results were committed; once they are
    // flushed the journal holds nothing the log lacks and can be compacted.
    ctx.on('agent/pre-step', async (payload, next) => {
      const sessionId = String(payload.agent.session.id)
      if (this.dirty.has(sessionId) && (this.inflight.get(sessionId)?.size ?? 0) === 0) {
        await ctx.sessions.flush(payload.agent.session)
        this.store.compact(sessionId)
        this.dirty.delete(sessionId)
      }
      return next()
    })
  }

  private track(sessionId: string, callId: string, started: boolean): void {
    this.dirty.add(sessionId)
    let calls = this.inflight.get(sessionId)
    if (calls === undefined) this.inflight.set(sessionId, calls = new Set())
    if (started) calls.add(callId)
    else calls.delete(callId)
  }

  /**
   * Settle the interrupted calls of a session that is being opened for writing.
   * Appends one `tool/result` per settled call through `handle` and flushes it.
   * @param sessionId - the stored session.
   * @param handle - the write handle the caller will hand to AgentLoop.
   * @param signal - cancellation of the resume.
   * @returns the decisions taken, for diagnostics.
   */
  async reconcile(sessionId: string, handle: SessionHandle, signal?: AbortSignal): Promise<Array<{ callId: string; action: string; detail?: string }>> {
    const { calls } = this.store.entries(sessionId)
    if (calls.size === 0) return []
    const read = await handle.read(0, undefined, signal === undefined ? {} : { signal })
    const events = read.events as unknown as LogEvent[]
    const interrupted = interruptedCalls(events)
    const report: Array<{ callId: string; action: string; detail?: string }> = []
    if (interrupted.length > 0) {
      const last = events.at(-1) as LogEvent
      const decisions = plan({
        calls: interrupted,
        journal: calls,
        profile: this.config.profile,
        classify: this.classify,
        schemaHash: (name) => {
          const tool = this.ctx.tools.get(name)
          return tool === undefined ? undefined : schemaHash(tool)
        },
      })
      let seq = last.seq + 1
      const appended: LogEvent[] = []
      const unknown = (call: InterruptedCall, reason: string): void => {
        const key = idempotencyKey(sessionId, call.callId)
        appended.push(toolResultEvent(call, seq++, last.time, {
          content: [{ type: 'text', text: unknownOutcomeText(call, key, reason) }],
          isError: true,
          error: { name: 'ToolOutcomeUnknownError', code: 'TOOL_OUTCOME_UNKNOWN' },
        }))
        report.push({ callId: call.callId, action: 'unknown', detail: reason })
      }
      for (const decision of decisions) {
        signal?.throwIfAborted()
        switch (decision.kind) {
          case 'skip':
            break
          case 'backfill':
            appended.push(toolResultEvent(decision.call, seq++, last.time, decision.result))
            report.push({ callId: decision.call.callId, action: `backfilled-${decision.source}` })
            break
          case 'rerun': {
            if (!this.config.rerun) { unknown(decision.call, 'resume re-runs are disabled'); break }
            try {
              const result = await this.rerun(sessionId, decision.call, signal)
              appended.push(toolResultEvent(decision.call, seq++, last.time, result))
              report.push({ callId: decision.call.callId, action: 'rerun', detail: decision.toolClass })
            } catch (error) {
              // Cancellation is not an unknown tool outcome: the caller is
              // unwinding and the wrapper must close the writer, not append a
              // result that claims the re-run's outcome is unknown.
              if (signal?.aborted === true) throw error
              unknown(decision.call, `re-run failed: ${error instanceof Error ? error.message : String(error)}`)
            }
            break
          }
          case 'unknown':
            unknown(decision.call, decision.reason)
            break
        }
      }
      if (appended.length > 0) {
        await handle.append(appended as never, signal === undefined ? {} : { signal })
        await handle.flush(signal === undefined ? {} : { signal })
      }
    }

    // A previous write-open can have appended the synthesized `tool/result`
    // and then lost its level-1 `resolved` ack (host deadline, Worker kill).
    // The session log then has no interrupted call, so retry the missing
    // acknowledgement here instead of reporting success while the host still
    // waits for terminal journal evidence.
    const decided = new Set(report.map(entry => entry.callId))
    const reconciled = reconciledCallIds(events)
    if (reconciled.size > 0) {
      const resolvedJseq = new Map<string, bigint>()
      for (const { jseq, record } of this.store.journaled(sessionId)) {
        if (record.t !== 'resolved') continue
        resolvedJseq.set(record.call_id, jseq)
      }
      const confirmation = this.store.confirmed(sessionId)
      const mirrored = this.store.mirrored()
      for (const [callId, entry] of calls) {
        if (decided.has(callId) || !reconciled.has(callId)) continue
        const jseq = resolvedJseq.get(callId)
        if (jseq !== undefined
          && (!mirrored || (confirmation.level >= 1 && confirmation.uptoJseq >= jseq))) {
          continue
        }
        const action = entry.resolved
          ?? (entry.done !== undefined ? 'backfilled-done'
            : entry.executed !== undefined ? 'backfilled-executed'
              : entry.start !== undefined ? 'unknown' : undefined)
        if (action === undefined) continue
        report.push({ callId, action })
      }
    }

    if (report.length === 0) return report
    // Await every `resolved` append. `ToolJournalStore.append` writes the
    // local NDJSON first and then waits for the host's level-1 JOURNAL_ACK;
    // returning before that ack is exactly the host-grace race this closes.
    for (const entry of report) {
      signal?.throwIfAborted()
      await this.store.append(sessionId, {
        v: 1, t: 'resolved', key: idempotencyKey(sessionId, entry.callId), call_id: entry.callId,
        action: entry.action, ...entry.detail === undefined ? {} : { detail: entry.detail }, at: Date.now(),
      }, signal)
    }
    this.dirty.add(sessionId)
    this.ctx.logger('tool-journal').info('session %s: resumed %d interrupted call(s): %s', sessionId, report.length,
      report.map(entry => `${entry.callId}=${entry.action}`).join(', '))
    return report
  }

  /** Run one read-only / idempotent call again under its original idempotency key. */
  private async rerun(sessionId: string, call: InterruptedCall, signal?: AbortSignal): Promise<JournaledResult> {
    const key = idempotencyKey(sessionId, call.callId)
    const timeout = AbortSignal.timeout(this.config.rerunTimeoutMs)
    // Fuse without requiring `AbortSignal.any` in the embedded engine; the
    // same helper is used by the normal tool path for the same reason.
    const runSignal = signal === undefined ? timeout : fuseAbortSignals(signal, timeout)
    const execution = toolCallStorage().run({ sessionId, callId: call.callId, key, spawns: 0 }, () => this.ctx.tools.execute({
      calls: [{ type: 'tool-call', id: ToolCallId(call.callId), name: call.name, arguments: call.arguments }],
      signal: runSignal,
    }))
    const batch = await awaitRerunBody(execution, runSignal, (settled) => {
      const detail = settled.kind === 'fulfilled'
        ? 'fulfilled'
        : `failed: ${settled.error instanceof Error ? settled.error.message : String(settled.error)}`
      this.ctx.logger('tool-journal').warn(
        'session %s: cancelled re-run %s settled after its writer was released (%s)',
        sessionId, call.callId, detail,
      )
    })
    const outcome = batch.results[0]
    if (outcome?.callId !== call.callId) throw new Error('tool-journal: rerun returned no matching outcome')
    const projected = project(outcome.result)
    // The result record is part of the reconcile proof: do not let the
    // caller append `resolved` before this record's level-1 ack.
    await this.store.append(sessionId, { v: 1, t: 'done', key, call_id: call.callId, result: projected, at: Date.now() }, signal)
    return projected
  }
}

export default ToolJournal
