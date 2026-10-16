/**
 * Generated 150k-entity-scale fixture for the Sovereign Hierarchy Navigator.
 *
 * Hierarchy: Constellation -> Orbital Squadron -> Space Vehicle -> Sensor
 * Payload. Only the top two levels are materialized eagerly; vehicles and
 * payloads are synthesized lazily on expand (deterministic, seeded PRNG) so
 * the fixture exposes Constellation-scale shape without allocating 150k
 * objects up front. Nothing here is hand-listed — all counts and labels are
 * derived from a string-hash-seeded mulberry32 stream.
 */

import type { NavNode } from './tree-model';

/** Deterministic PRNG (mulberry32) seeded from a string hash. */
function rng(seed: string): () => number {
  let h = 2166136261 >>> 0;
  for (let i = 0; i < seed.length; i++) {
    h ^= seed.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  let a = h >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const CONSTELLATION_NAMES = [
  'Aegis', 'Borealis', 'Cygnus', 'Daedalus', 'Erebus', 'Fornax',
  'Gorgon', 'Hyperion', 'Iris', 'Kronos', 'Lyra', 'Meridian',
] as const;

const SQUADRON_DESIGNS = ['Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo', 'Foxtrot'] as const;
const VEHICLE_BUSES = ['SV-', 'BUS-', 'ORBIT-'] as const;
const PAYLOAD_SENSORS = ['SAR', 'EO/IR', 'SIGINT', 'RF', 'LIDAR', 'MSI'] as const;

/** Number of constellations (top level). */
export const CONSTELLATION_COUNT = 12;
/** Declared aggregate entity count the fixture models (lazy shape). */
export const DECLARED_ENTITY_SCALE = 150_000;

function pad(n: number, width: number): string {
  return String(n).padStart(width, '0');
}

/** Lazily synthesize the payload children of a space vehicle. */
function makePayloads(vehicleIndex: number, squadronId: string): () => readonly NavNode[] {
  return () => {
    const rand = rng(`${squadronId}:payloads`);
    const count = 24 + Math.floor(rand() * 120); // 24..143 payloads per vehicle
    const out: NavNode[] = new Array(count);
    for (let i = 0; i < count; i++) {
      const sensor = PAYLOAD_SENSORS[Math.floor(rand() * PAYLOAD_SENSORS.length)];
      out[i] = {
        id: `${squadronId}/pl-${pad(vehicleIndex, 3)}-${pad(i, 4)}`,
        label: `${sensor} PAYLOAD ${pad(i + 1, 4)}`,
        kind: 'payload',
      };
    }
    return out;
  };
}

/** Lazily synthesize the vehicle children of an orbital squadron. */
function makeVehicles(squadronId: string): () => readonly NavNode[] {
  return () => {
    const rand = rng(`${squadronId}:vehicles`);
    const count = 16 + Math.floor(rand() * 48); // 16..63 vehicles per squadron
    const out: NavNode[] = new Array(count);
    for (let i = 0; i < count; i++) {
      const bus = VEHICLE_BUSES[Math.floor(rand() * VEHICLE_BUSES.length)];
      const id = `${squadronId}/sv-${pad(i, 3)}`;
      out[i] = {
        id,
        label: `${bus}${pad(i + 1, 3)}`,
        kind: 'vehicle',
        lazyLoad: makePayloads(i, id),
      };
    }
    return out;
  };
}

/** Lazily synthesize the squadron children of a constellation. */
function makeSquadrons(constellationId: string): () => readonly NavNode[] {
  return () => {
    const rand = rng(`${constellationId}:squadrons`);
    const count = 3 + Math.floor(rand() * 4); // 3..6 squadrons per constellation
    const out: NavNode[] = new Array(count);
    for (let i = 0; i < count; i++) {
      const design = SQUADRON_DESIGNS[i % SQUADRON_DESIGNS.length];
      const id = `${constellationId}/sq-${pad(i, 2)}`;
      const vRand = rng(`${id}:vcount`);
      const vCount = 16 + Math.floor(vRand() * 48);
      out[i] = {
        id,
        label: `${design} ORBITAL SQUADRON ${pad(i + 1, 2)}`,
        kind: 'squadron',
        declaredChildCount: vCount,
        lazyLoad: makeVehicles(id),
      };
    }
    return out;
  };
}

/**
 * The fixture root: eagerly-built constellations with declared vehicle
 * aggregates; squadrons, vehicles, and payloads materialize lazily on
 * expand. Deterministic across processes and reloads.
 */
export function makeFixtureRoot(): readonly NavNode[] {
  const out: NavNode[] = new Array(CONSTELLATION_COUNT);
  for (let c = 0; c < CONSTELLATION_COUNT; c++) {
    const name = CONSTELLATION_NAMES[c];
    const id = `con-${pad(c, 2)}`;
    const rand = rng(`${id}:meta`);
    const sqCount = 3 + Math.floor(rand() * 4);
    const vRand = rng(`${id}:vtotal`);
    let vTotal = 0;
    for (let s = 0; s < sqCount; s++) {
      vTotal += 16 + Math.floor(vRand() * 48);
    }
    out[c] = {
      id,
      label: `${name.toUpperCase()} CONSTELLATION`,
      kind: 'constellation',
      declaredChildCount: vTotal,
      lazyLoad: makeSquadrons(id),
    };
  }
  return out;
}

/** Shared singleton used by demo pages; pure and deterministic. */
export const FIXTURE_ROOT: readonly NavNode[] = makeFixtureRoot();
