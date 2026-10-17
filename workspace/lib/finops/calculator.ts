/**
 * Avoided-spend calculator (Agent 14, finops lane).
 *
 * Pure functions over a run manifest — no substrate, no I/O.
 * Tariffs: published Azure retail, approximate (hardcoded 80/20 constants).
 */

import { createHash } from 'node:crypto';

export type ResourceTypes =
  | 'resource_group'
  | 'storage_account'
  | 'key_vault'
  | 'cosmos_serverless'
  | 'eventhub_standard'
  | 'servicebus_standard';

export interface RunManifest {
  resources: Array<{ type: ResourceTypes; count: number }>;
  cycles: number;
  durations_ms: number;
}

export interface PqcReceipt {
  algorithm: 'SHA-256';
  digest: string;
  pqc_status: 'PQC_NOT_PROVISIONED';
}

export interface AvoidedSpendResult {
  totalUsd: number;
  perCycleUsd: number;
  avoidedHours: number;
  receipt: PqcReceipt;
}

export class FinopsError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.name = 'FinopsError';
    this.code = code;
  }
}

/**
 * Retail tariff table — published Azure retail, approximate.
 * Per resource unit:
 *   usdPerHour: hourly-metered component (monthly fees prorated at 730 h/mo)
 *   usdPerUnit: once-per-cycle unit charge (GB, secret-version, ingress event, op)
 */
export const RETAIL_TARIFFS: Record<
  ResourceTypes,
  { usdPerHour: number; usdPerUnit: number; note: string }
> = {
  resource_group: {
    usdPerHour: 0,
    usdPerUnit: 0,
    note: 'Azure RG is free — management-plane construct only',
  },
  storage_account: {
    usdPerHour: 0.02 / 730,
    usdPerUnit: 0.05,
    note: '$0.02/mo account fee (prorated /730) + $0.05/GB (1 GB per unit)',
  },
  key_vault: {
    usdPerHour: 0,
    usdPerUnit: 0.03,
    note: '$0.03 per secret-version (standard tier)',
  },
  cosmos_serverless: {
    usdPerHour: 0.25 / 730,
    usdPerUnit: 0.25,
    note: '$0.25 per M RU-s (negligible at 1 unit) + $0.25/GB (1 GB per unit)',
  },
  eventhub_standard: {
    usdPerHour: 0.03,
    usdPerUnit: 0,
    note: '$0.03/hour standard tier; ingress events under included quota',
  },
  servicebus_standard: {
    usdPerHour: 0.05,
    usdPerUnit: 0,
    note: '$0.05/hour per messaging unit; ops under included base quota',
  },
};

function canonicalJson(value: unknown): string {
  return JSON.stringify(value, (_key, v) => {
    if (v !== null && typeof v === 'object' && !Array.isArray(v)) {
      return Object.keys(v)
        .sort()
        .reduce<Record<string, unknown>>((acc, k) => {
          acc[k] = v[k];
          return acc;
        }, {});
    }
    return v;
  });
}

/**
 * Compute avoided spend over a run manifest.
 * Per cycle: Σ over resources of count × (usdPerHour × avoidedHours + usdPerUnit).
 */
export function computeAvoidedSpend(manifest: RunManifest): AvoidedSpendResult {
  if (typeof manifest.cycles !== 'number' || manifest.cycles < 0) {
    throw new FinopsError(
      'INVALID_CYCLES',
      `cycles must be a non-negative number, got ${manifest.cycles}`,
    );
  }
  if (typeof manifest.durations_ms !== 'number' || manifest.durations_ms < 0) {
    throw new FinopsError(
      'INVALID_DURATIONS_MS',
      `durations_ms must be a non-negative number, got ${manifest.durations_ms}`,
    );
  }
  for (const r of manifest.resources) {
    if (!(r.type in RETAIL_TARIFFS)) {
      throw new FinopsError(
        'UNKNOWN_RESOURCE_TYPE',
        `unknown resource type: ${String(r.type)}`,
      );
    }
  }

  const avoidedHours = manifest.durations_ms / 3_600_000;
  let perCycleUsd = 0;
  for (const r of manifest.resources) {
    const t = RETAIL_TARIFFS[r.type];
    perCycleUsd += r.count * (t.usdPerHour * avoidedHours + t.usdPerUnit);
  }
  const totalUsd = perCycleUsd * manifest.cycles;

  const digest = createHash('sha256')
    .update(canonicalJson(manifest))
    .digest('hex');

  return {
    totalUsd,
    perCycleUsd,
    avoidedHours,
    receipt: {
      algorithm: 'SHA-256',
      digest,
      pqc_status: 'PQC_NOT_PROVISIONED',
    },
  };
}
