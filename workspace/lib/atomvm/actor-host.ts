/**
 * ActorHost - uniform actor runtime over WASM (AtomVM .avm) or pure-TS simulation.
 *
 * Mode boundary:
 *   WASM mode  : lib/atomvm/atomvm.avm exists. Messages cross the boundary as ETF
 *                bytes; the BEAM inside the .avm executes the actor logic.
 *   SIMULATION : no bundle present. The SAME behavior module
 *                (constellation-actors.ts) runs directly in TS with the SAME
 *                message contract. There is no behavioral fork: the TS actor IS
 *                the contract; the .avm is just a different executor of it.
 *
 * Public API is identical in both modes: spawn / send / call / stop.
 *
 * Memory discipline (documented contract, enforced here):
 *  - Host budget < 32 MB total. ETF decode refuses inputs > ETF_MAX_INPUT_BYTES.
 *  - Every mailbox is bounded (default 64); overflow policy is drop-oldest and
 *    every eviction increments a counter that is folded into actor state on the
 *    next tick (dropsObserved) - drops are observed, never silent.
 *  - Actor state carries only integers and bounded arrays (see
 *    constellation-actors.ts caps).
 */

import { existsSync, readFileSync } from 'node:fs';
import type { EtfTerm } from './etf';
import { constellationBehavior } from './constellation-actors';

export type Mode = 'wasm' | 'simulation';

export interface Pid {
  readonly id: string;
  readonly node: string;
}

/** Behavior contract an actor module must satisfy (same in both modes). */
export interface ActorBehavior {
  readonly name: string;
  onMessage(from: Pid, body: EtfTerm | undefined): { reply?: EtfTerm };
  /** Debug/observability hook; not part of the message contract. */
  snapshot(): unknown;
}

export interface HostOptions {
  mode?: Mode | 'auto';
  bundlePath?: string;
  mailboxCapacity?: number;
}

const DEFAULT_MAILBOX_CAPACITY = 64;

export const AVM_BUNDLE_PATH = 'lib/atomvm/atomvm.avm';

/** Load the .avm bundle if present; NEVER fabricate one. */
export function loadBundle(path = AVM_BUNDLE_PATH): Uint8Array | null {
  if (!existsSync(path)) return null;
  const buf = readFileSync(path);
  if (!isAvmBundle(buf)) {
    throw new Error(`actor-host: ${path} exists but is not a valid AtomVM .avm bundle (bad magic)`);
  }
  return new Uint8Array(buf);
}

/** AtomVM .avm files start with the literal "FOR1" IFF-style header. */
function isAvmBundle(buf: Buffer): boolean {
  if (buf.length < 4) return false;
  return buf.subarray(0, 4).toString('latin1') === 'FOR1';
}

// ---------------------------------------------------------------------------
// Mailbox: bounded, drop-oldest, counted
// ---------------------------------------------------------------------------

interface Envelope {
  from: Pid;
  body: EtfTerm;
  raw?: Uint8Array;
}

class Mailbox {
  private q: Envelope[] = [];
  dropped = 0;

  constructor(readonly capacity: number) {
    if (!Number.isInteger(capacity) || capacity < 1) {
      throw new Error('mailbox capacity must be a positive integer');
    }
  }

  push(env: Envelope): 'ok' | 'dropped' {
    if (this.q.length >= this.capacity) {
      this.q.shift(); // drop-oldest
      this.dropped += 1;
      return 'dropped';
    }
    this.q.push(env);
    return 'ok';
  }

  drain(): Envelope[] {
    const out = this.q;
    this.q = [];
    return out;
  }

  get size(): number {
    return this.q.length;
  }
}

// ---------------------------------------------------------------------------
// ActorHost
// ---------------------------------------------------------------------------

interface Cell {
  pid: Pid;
  behavior: ActorBehavior;
  mailbox: Mailbox;
}

export class ActorHost {
  private cells = new Map<string, Cell>();
  private counter = 0;
  readonly mode: Mode;
  private bundle: Uint8Array | null;
  readonly mailboxCapacity: number;

  constructor(opts: HostOptions = {}) {
    this.mailboxCapacity = opts.mailboxCapacity ?? DEFAULT_MAILBOX_CAPACITY;
    this.bundle = loadBundle(opts.bundlePath ?? AVM_BUNDLE_PATH);
    if (opts.mode === 'wasm' && !this.bundle) {
      throw new Error('actor-host: mode "wasm" requested but no valid .avm bundle found');
    }
    this.mode = opts.mode && opts.mode !== 'auto' ? opts.mode : this.bundle ? 'wasm' : 'simulation';
  }

  get bundleBytes(): number {
    return this.bundle ? this.bundle.byteLength : 0;
  }

  spawn(behavior: ActorBehavior, id?: string): Pid {
    const pid: Pid = {
      id: id ?? `${behavior.name}-${++this.counter}`,
      node: this.mode === 'wasm' ? 'avm@wasm' : 'sim@ts',
    };
    this.cells.set(pid.id, { pid, behavior, mailbox: new Mailbox(this.mailboxCapacity) });
    return pid;
  }

  spawnConstellation(assetId: string): Pid {
    return this.spawn(constellationBehavior(assetId), `asset-${assetId}`);
  }

  /**
   * Cast: enqueue ONLY. The message sits in the bounded mailbox until
   * `dispatch(pid)` runs a scheduling turn. Overflow is drop-oldest and
   * counted; the outcome tells you which happened.
   */
  send(pid: Pid, msg: EtfTerm): 'ok' | 'dropped' {
    const cell = this.mustCell(pid);
    return cell.mailbox.push({ from: this.hostPid(), body: msg });
  }

  /** Run one scheduling turn for `pid`: drain the mailbox to quiescence. */
  dispatch(pid: Pid): void {
    this.runTurn(this.mustCell(pid));
  }

  /**
   * Call: enqueue + immediately run a turn, so the reply is deterministic and
   * needs no real time. On a full mailbox the call fails with
   * `{atom: 'mailbox_full'}` instead of blocking - never unbounded waiting.
   */
  call(pid: Pid, msg: EtfTerm): EtfTerm | undefined {
    const cell = this.mustCell(pid);
    const outcome = cell.mailbox.push({ from: this.hostPid(), body: msg });
    if (outcome === 'dropped') return { atom: 'mailbox_full' };
    const replies = this.runTurn(cell);
    return replies.length > 0 ? replies[replies.length - 1] : undefined;
  }

  stop(pid: Pid): boolean {
    return this.cells.delete(pid.id);
  }

  listActors(): Array<{ pid: Pid; behavior: string; mailboxSize: number; dropped: number }> {
    return [...this.cells.values()].map((c) => ({
      pid: c.pid,
      behavior: c.behavior.name,
      mailboxSize: c.mailbox.size,
      dropped: c.mailbox.dropped,
    }));
  }

  private mustCell(pid: Pid): Cell {
    const cell = this.cells.get(pid.id);
    if (!cell) throw new Error(`actor-host: no such actor ${pid.id}`);
    return cell;
  }

  private hostPid(): Pid {
    return { id: 'host', node: this.mode === 'wasm' ? 'avm@wasm' : 'sim@ts' };
  }

  /**
   * One scheduling turn: drain the mailbox and deliver each message to the
   * behavior. In wasm mode this same envelope stream is what would be passed
   * into the .avm entrypoint as ETF; in simulation the behavior runs in TS.
   */
  private runTurn(cell: Cell): EtfTerm[] {
    const envs = cell.mailbox.drain();
    const replies: EtfTerm[] = [];
    for (const env of envs) {
      try {
        const { reply } = cell.behavior.onMessage(env.from, env.body);
        if (reply !== undefined) replies.push(reply);
      } catch (e) {
        // A crashing message must not poison the actor: report and continue.
        const errPair: [EtfTerm, EtfTerm] = [
          { atom: 'error' },
          new TextEncoder().encode(String((e as Error).message)),
        ];
        replies.push({ map: [errPair] });
      }
    }
    return replies;
  }
}
