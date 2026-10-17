// ocel.ts — server-side OCEL read surface over the landed tmp/ocel/events.ndjson sink.
//
// Each line is an OCEL 2.0 fragment: { "ocel:eventTypes", "ocel:events",
// "ocel:objectTypes", "ocel:objects" }. This module reads server-side only,
// guarded to the repo tmp dir, groups events, and exposes counts, paginated
// events, and per-object traces for the console process-mining page.

import fs from "node:fs";
import path from "node:path";

// Sink root is the repo tmp/ocel dir; test harness may point it at a fixture
// dir via SMALT_OCEL_DIR (same guard semantics, different root).
export const OCEL_ROOT = path.resolve(
  process.env.SMALT_OCEL_DIR || path.join(process.cwd(), "tmp", "ocel"),
);
export const OCEL_EVENTS_PATH = path.join(OCEL_ROOT, "events.ndjson");
export const OCEL_POWL_PATH = path.join(OCEL_ROOT, "powl_model.json");

const TMP_ROOT = OCEL_ROOT;

export interface OcelEvent {
  id: string;
  type: string;
  time: string;
  attributes: Record<string, unknown>;
  relationships: { objectId: string; qualifier: string }[];
}

interface OcelFragment {
  "ocel:eventTypes"?: { name: string }[];
  "ocel:events"?: OcelEvent[];
  "ocel:objectTypes"?: { name: string }[];
  "ocel:objects"?: { id: string; type: string; attributes?: Record<string, unknown> }[];
}

export interface OcelSummary {
  available: boolean;
  reason?: string;
  eventsPath: string;
  eventTypes: { name: string; count: number }[];
  objectTypes: { name: string; count: number }[];
  totalEvents: number;
  totalObjects: number;
  recentEvents: OcelEvent[];
  perObjectTraces: {
    objectId: string;
    objectType: string;
    trace: { id: string; type: string; time: string }[];
  }[];
  powlModel?: unknown;
}

/** Path guard: only files directly under the repo tmp/ocel dir are readable. */
export function guardOcelPath(p: string): string {
  const resolved = path.resolve(p);
  if (resolved !== TMP_ROOT && !resolved.startsWith(TMP_ROOT + path.sep)) {
    throw new Error("OCEL_READ_REFUSED: outside tmp/ocel");
  }
  return resolved;
}

function readFragments(p: string): OcelFragment[] {
  const guarded = guardOcelPath(p);
  if (!fs.existsSync(guarded)) return [];
  const out: OcelFragment[] = [];
  const lines = fs.readFileSync(guarded, "utf8").split("\n");
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line) as OcelFragment);
    } catch {
      // tolerate a torn trailing line in an actively-appended sink
    }
  }
  return out;
}

/** Full summary. Missing/empty sink => available:false with a reason, never a throw. */
export function readOcelSummary(
  eventsPath: string = OCEL_EVENTS_PATH,
  powlPath: string = OCEL_POWL_PATH,
): OcelSummary {
  const fragments = readFragments(eventsPath);
  const events: OcelEvent[] = [];
  const objects = new Map<string, { id: string; type: string }>();
  const eventTypes = new Set<string>();
  const objectTypes = new Set<string>();
  for (const f of fragments) {
    for (const et of f["ocel:eventTypes"] ?? []) eventTypes.add(et.name);
    for (const ot of f["ocel:objectTypes"] ?? []) objectTypes.add(ot.name);
    for (const ev of f["ocel:events"] ?? []) events.push(ev);
    for (const o of f["ocel:objects"] ?? []) objects.set(o.id, { id: o.id, type: o.type });
  }

  if (events.length === 0) {
    return {
      available: false,
      reason: "no OCEL events in " + eventsPath,
      eventsPath,
      eventTypes: [],
      objectTypes: [],
      totalEvents: 0,
      totalObjects: 0,
      recentEvents: [],
      perObjectTraces: [],
    };
  }

  // Deterministic recency order: descending time, id as tiebreak.
  events.sort((a, b) => (a.time === b.time ? a.id.localeCompare(b.id) : a.time < b.time ? 1 : -1));

  const eventTypeCounts = new Map<string, number>();
  for (const ev of events) {
    eventTypeCounts.set(ev.type, (eventTypeCounts.get(ev.type) ?? 0) + 1);
  }

  const objectTypeCounts = new Map<string, number>();
  for (const o of objects.values()) {
    objectTypeCounts.set(o.type, (objectTypeCounts.get(o.type) ?? 0) + 1);
  }

  // Per-object traces: event sequences grouped by related objectId.
  const traces = new Map<string, { id: string; type: string; time: string }[]>();
  for (const ev of events) {
    for (const rel of ev.relationships ?? []) {
      let t = traces.get(rel.objectId);
      if (!t) traces.set(rel.objectId, (t = []));
      t.push({ id: ev.id, type: ev.type, time: ev.time });
    }
  }

  const recentEvents = events.slice(0, 20);
  const perObjectTraces = [...traces.entries()]
    .map(([objectId, trace]) => ({
      objectId,
      objectType: objects.get(objectId)?.type ?? "unknown",
      trace,
    }))
    .sort((a, b) => b.trace.length - a.trace.length)
    .slice(0, 20);

  let powlModel: unknown;
  try {
    const guarded = guardOcelPath(powlPath);
    if (fs.existsSync(guarded)) powlModel = JSON.parse(fs.readFileSync(guarded, "utf8"));
  } catch {
    // powl model is optional garnish
  }

  return {
    available: true,
    eventsPath,
    eventTypes: [...eventTypeCounts.entries()]
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count),
    objectTypes: [...objectTypeCounts.entries()]
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count),
    totalEvents: events.length,
    totalObjects: objects.size,
    recentEvents,
    perObjectTraces,
    ...(powlModel !== undefined ? { powlModel } : {}),
  };
}
