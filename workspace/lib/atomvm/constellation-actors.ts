/**
 * ConstellationNode actors - per-asset state machines for the constellation sim.
 *
 * Laws honored here:
 *  - Deterministic: state is event-sourced from message inputs only (no wall clock,
 *    no randomness, no floats).
 *  - Fixed-point integer arithmetic ONLY: quantities are integers in milli-units
 *    (mK, mAh, meters). No float ever enters state or transitions.
 *  - Bounded memory: per-actor event log capped; retired events counted.
 */

import { atom, isAtom, isList, isTuple, type EtfTerm } from './etf';

/** Fixed-point scale: real quantities carried as integer milli-units (1e-3). */
export const MILLI = 1000;

export function mulFixed(a: number, b: number): number {
  const p = a * b;
  return Math.floor((p + 500) / MILLI);
}

export function divFixed(a: number, b: number): number {
  if (b === 0) throw new Error('divFixed: divide by zero');
  const negative = a < 0 !== b < 0;
  const q = Math.floor((Math.abs(a) * MILLI) / Math.abs(b));
  return negative ? -q : q;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

export interface EphemerisPoint {
  /** Sim time, ms. */
  t_ms: number;
  x_m: number;
  y_m: number;
  z_m: number;
}

export interface ConstellationState {
  assetId: string;
  /** Sim time, ms; advances only via `tick`. */
  t_ms: number;
  /** Temperature, milli-kelvin. */
  thermal_budget_mK: number;
  /** Battery charge, milli-amp-hours. */
  battery_reserve_mAh: number;
  /** Ephemeris table sorted by t_ms, capped at EPHEMERIS_CAP (bounded). */
  ephemeris: EphemerisPoint[];
  /** Bounded event log; state = fold(events, init). */
  events: ConstellationEvent[];
  /** Number of events retired from the log head (conservation counter). */
  eventsRetired: number;
  /** Host-mailbox drops folded into state on tick. */
  dropsObserved: number;
}

export const EPHEMERIS_CAP = 256;
export const EVENT_LOG_CAP = 256;

export type ConstellationEvent =
  | { type: 'INIT'; assetId: string; temperature_mK: number; battery_mAh: number }
  | { type: 'TICK'; t_ms: number; dTemp_mK: number; dCharge_mAh: number }
  | { type: 'EPHEMERIS_SET'; count: number }
  | { type: 'DROPS'; n: number };

export type ConstellationMsg =
  | { kind: 'tick'; t_ms: number }
  | { kind: 'set_ephemeris'; points: EphemerisPoint[] }
  | { kind: 'set_power'; battery_mAh: number }
  | { kind: 'query' };

export interface MsgResult {
  state: ConstellationState;
  events: ConstellationEvent[];
  reply?: EtfTerm;
}

// ---------------------------------------------------------------------------
// Pure transitions (state = fold(events, init); every change emits an event)
// ---------------------------------------------------------------------------

export function initConstellation(assetId: string, temperature_mK: number, battery_mAh: number): ConstellationState {
  return {
    assetId,
    t_ms: 0,
    thermal_budget_mK: temperature_mK,
    battery_reserve_mAh: battery_mAh,
    ephemeris: [],
    events: [{ type: 'INIT', assetId, temperature_mK, battery_mAh }],
    eventsRetired: 0,
    dropsObserved: 0,
  };
}

const AMBIENT_mK = 288000; // 288 K in milli-kelvin
const TAU_MS = 600000; // thermal time constant, ms
const DRAIN_mAh_PER_S = 2;

export function appendEvent(events: ConstellationEvent[], ev: ConstellationEvent): { events: ConstellationEvent[]; retired: number } {
  const next = events.concat([ev]);
  if (next.length <= EVENT_LOG_CAP) return { events: next, retired: 0 };
  return { events: next.slice(next.length - EVENT_LOG_CAP), retired: next.length - EVENT_LOG_CAP };
}

export function applyTick(s: ConstellationState, t_ms: number): MsgResult {
  if (t_ms < s.t_ms) {
    return { state: s, events: [], reply: atom('monotonic_violation') };
  }
  const dt = t_ms - s.t_ms;
  const gap = s.thermal_budget_mK - AMBIENT_mK;
  // first-order lag toward ambient, integer math only
  const dTemp = -Math.floor((gap * dt) / TAU_MS);
  const dCharge = -Math.floor((dt / 1000) * DRAIN_mAh_PER_S);
  const ev: ConstellationEvent = { type: 'TICK', t_ms, dTemp_mK: dTemp, dCharge_mAh: dCharge };
  const r = appendEvent(s.events, ev);
  const st: ConstellationState = {
    ...s,
    t_ms,
    thermal_budget_mK: s.thermal_budget_mK + dTemp,
    battery_reserve_mAh: s.battery_reserve_mAh + dCharge,
    events: r.events,
    eventsRetired: s.eventsRetired + r.retired,
  };
  return { state: st, events: [ev], reply: atom('ok') };
}

export function applySetEphemeris(s: ConstellationState, points: EphemerisPoint[]): MsgResult {
  const sorted = points.slice().sort((a, b) => a.t_ms - b.t_ms);
  const kept = sorted.slice(Math.max(0, sorted.length - EPHEMERIS_CAP));
  const ev: ConstellationEvent = { type: 'EPHEMERIS_SET', count: sorted.length };
  const r = appendEvent(s.events, ev);
  const st: ConstellationState = {
    ...s,
    ephemeris: kept,
    events: r.events,
    eventsRetired: s.eventsRetired + r.retired,
  };
  return { state: st, events: [ev], reply: atom('ok') };
}

export function applySetPower(s: ConstellationState, battery_mAh: number): MsgResult {
  const ev: ConstellationEvent = { type: 'TICK', t_ms: s.t_ms, dTemp_mK: 0, dCharge_mAh: battery_mAh - s.battery_reserve_mAh };
  const r = appendEvent(s.events, ev);
  const st: ConstellationState = {
    ...s,
    battery_reserve_mAh: battery_mAh,
    events: r.events,
    eventsRetired: s.eventsRetired + r.retired,
  };
  return { state: st, events: [ev], reply: atom('ok') };
}

export function applyDrops(s: ConstellationState, n: number): ConstellationState {
  return { ...s, dropsObserved: s.dropsObserved + n };
}

// ---------------------------------------------------------------------------
// Wire contract: ConstellationMsg <-> ETF tuples
//   {tick, T} | {set_ephemeris, [{T,X,Y,Z},...]} | {set_power, C} | {query}
// ---------------------------------------------------------------------------

function int(t: EtfTerm): number {
  if (typeof t === 'number') return t;
  if (typeof t === 'bigint') {
    if (t < BigInt(Number.MIN_SAFE_INTEGER) || t > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new Error('int: bignum out of safe range');
    }
    return Number(t);
  }
  throw new Error('int: expected integer term');
}

export function msgToEtf(m: ConstellationMsg): EtfTerm {
  if (m.kind === 'tick') {
    return { elements: [atom('tick'), m.t_ms] };
  }
  if (m.kind === 'set_ephemeris') {
    const pts: EtfTerm[] = m.points.map((p) => ({ elements: [p.t_ms, p.x_m, p.y_m, p.z_m] }));
    return { elements: [atom('set_ephemeris'), { list: pts }] };
  }
  if (m.kind === 'set_power') {
    return { elements: [atom('set_power'), m.battery_mAh] };
  }
  return { elements: [atom('query')] };
}

export function msgFromEtf(t: EtfTerm): ConstellationMsg {
  if (!isTuple(t) || t.elements.length < 1 || !isAtom(t.elements[0])) {
    throw new Error('msgFromEtf: expected tuple with atom tag');
  }
  const tag = t.elements[0].atom;
  if (tag === 'tick' && t.elements.length === 2) {
    return { kind: 'tick', t_ms: int(t.elements[1]) };
  }
  if (tag === 'set_ephemeris' && t.elements.length === 2 && isList(t.elements[1])) {
    const points = t.elements[1].list.map((e) => {
      if (!isTuple(e) || e.elements.length !== 4) throw new Error('msgFromEtf: bad ephemeris point');
      return { t_ms: int(e.elements[0]), x_m: int(e.elements[1]), y_m: int(e.elements[2]), z_m: int(e.elements[3]) };
    });
    return { kind: 'set_ephemeris', points };
  }
  if (tag === 'set_power' && t.elements.length === 2) {
    return { kind: 'set_power', battery_mAh: int(t.elements[1]) };
  }
  if (tag === 'query' && t.elements.length === 1) {
    return { kind: 'query' };
  }
  throw new Error(`msgFromEtf: unknown message ${tag}`);
}

// ---------------------------------------------------------------------------
// ActorBehavior plumbing (consumed by actor-host.ts; identical in both modes)
// ---------------------------------------------------------------------------

import type { ActorBehavior, Pid } from './actor-host';

export function constellationBehavior(assetId: string): ActorBehavior {
  let state = initConstellation(assetId, 288500, 120000); // 288.5 K, 120 Ah
  return {
    name: 'constellation_node',
    onMessage(_from: Pid, body: EtfTerm | undefined) {
      if (body === undefined) return {};
      const msg = msgFromEtf(body);
      let res: MsgResult;
      if (msg.kind === 'tick') res = applyTick(state, msg.t_ms);
      else if (msg.kind === 'set_ephemeris') res = applySetEphemeris(state, msg.points);
      else if (msg.kind === 'set_power') res = applySetPower(state, msg.battery_mAh);
      else res = queryReply(state);
      state = res.state;
      return { reply: res.reply };
    },
    snapshot() {
      return state;
    },
  };
}

function queryReply(s: ConstellationState): MsgResult {
  const st: ConstellationState = { ...s };
  const toBin = (sv: string) => new TextEncoder().encode(sv);
  const snap: EtfTerm = {
    map: [
      [atom('asset'), toBin(st.assetId)],
      [atom('t_ms'), st.t_ms],
      [atom('thermal_mK'), st.thermal_budget_mK],
      [atom('battery_mAh'), st.battery_reserve_mAh],
      [atom('events'), st.events.length],
      [atom('events_retired'), st.eventsRetired],
      [atom('drops'), st.dropsObserved],
    ],
  };
  return { state: st, events: [], reply: snap };
}
