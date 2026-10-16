'use client';

/**
 * ReceiptLedger (lane WS-11): read-only rendering of the WS-4 hash-chained
 * session ledger for the NIST AU-10 compliance surface.
 *
 * Read-only by construction: no event handlers, no state, no callbacks, no
 * mutation affordance of any kind — the component structurally lacks the
 * ability to write to the ledger.
 */

import type { LedgerSnapshot } from '../../lib/compliance/ledger-types';

export interface ReceiptLedgerProps {
  snapshot: LedgerSnapshot;
}

function fmtTime(ts: number): string {
  return new Date(ts).toISOString();
}

export function ReceiptLedger({ snapshot }: ReceiptLedgerProps) {
  const { entries, tailHash, length, intact } = snapshot;

  return (
    <section aria-labelledby="receipt-ledger-heading" data-intact={String(intact)}>
      <h2 id="receipt-ledger-heading">Receipt Ledger</h2>
      <p id="receipt-ledger-status">
        {length} {length === 1 ? 'entry' : 'entries'}; chain{' '}
        {intact ? 'intact' : 'BROKEN — evidence tamper-suspect'}.
      </p>

      <table aria-describedby="receipt-ledger-status">
        <caption>
          Hash-chained session ledger (read-only). Each row&apos;s prevHash must
          equal the previous row&apos;s hash; GENESIS anchors row 0.
        </caption>
        <thead>
          <tr>
            <th scope="col">#</th>
            <th scope="col">When</th>
            <th scope="col">Kind</th>
            <th scope="col">Verb</th>
            <th scope="col">URL</th>
            <th scope="col">Prev hash</th>
            <th scope="col">Hash</th>
          </tr>
        </thead>
        <tbody>
          {entries.map((e) => (
            <tr key={e.seq}>
              <th scope="row">{e.seq}</th>
              <td>{fmtTime(e.ts)}</td>
              <td>{e.kind}</td>
              <td>{e.verb}</td>
              <td>
                <code>{e.url}</code>
              </td>
              <td>
                <code>{e.prevHash}</code>
              </td>
              <td>
                <code>{e.hash}</code>
              </td>
            </tr>
          ))}
          {length === 0 && (
            <tr>
              <td colSpan={7}>No ledger entries.</td>
            </tr>
          )}
        </tbody>
      </table>
    </section>
  );
}

export default ReceiptLedger;
