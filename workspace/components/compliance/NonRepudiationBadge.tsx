'use client';

/**
 * NonRepudiationBadge (lane WS-11): AU-10 status per mission plan —
 * unsigned / signed+hardware-verified / refused. Renders refused honestly:
 * only 'signed-hardware-verified' gets the affirmative treatment; missing or
 * tamper-suspect evidence is never green.
 */

import { assessAu10Status, isGreen } from '../../lib/compliance/au10';
import type {
  Au10Attestation,
  Au10Status,
} from '../../lib/compliance/au10';
import type { LedgerSnapshot } from '../../lib/compliance/ledger-types';

export interface NonRepudiationBadgeProps {
  snapshot: LedgerSnapshot;
  /** Optional verified hardware attestation binding the current tail hash. */
  attestation?: Au10Attestation;
}

const LABELS: Readonly<Record<Au10Status, string>> = {
  unsigned: 'Unsigned',
  'signed-hardware-verified': 'Signed + hardware-verified',
  refused: 'Refused',
};

const DESCRIPTIONS: Readonly<Record<Au10Status, string>> = {
  unsigned:
    'Ledger is intact but entries carry no signature; non-repudiation is not assured.',
  'signed-hardware-verified':
    'Ledger tail signed and verified by a hardware-bound key bound to the current tail hash.',
  refused:
    'No AU-10 claim: ledger empty or hash chain broken. Missing evidence is never compliance.',
};

export function NonRepudiationBadge({ snapshot, attestation }: NonRepudiationBadgeProps) {
  const status = assessAu10Status(snapshot, attestation);
  const green = isGreen(status);

  return (
    <p>
      <span
        role="status"
        aria-label={`AU-10 non-repudiation status: ${LABELS[status]}`}
        data-au10-status={status}
        style={{
          display: 'inline-block',
          padding: '0.15rem 0.6rem',
          border: '1px solid currentColor',
          borderRadius: '999px',
          fontWeight: 600,
          color: green
            ? '#0a5c2e'
            : status === 'refused'
              ? '#8a1f1f'
              : '#7a5b00',
          background: green ? '#d7f0de' : status === 'refused' ? '#f6dcdc' : '#f7eed2',
        }}
      >
        AU-10: {LABELS[status]}
      </span>{' '}
      <span className="visually-hidden" style={{ position: 'absolute', clip: 'rect(0 0 0 0)' }}>
        {DESCRIPTIONS[status]}
      </span>
    </p>
  );
}

export default NonRepudiationBadge;
