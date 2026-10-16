/**
 * AttestationMode — digest + signature-validity badge view.
 *
 * Part of lane WS-3. Renders `attestation` props verbatim; signature
 * VALIDATION LOGIC IS OWNED BY LANE WS-10 — this component only presents the
 * verdict it receives. When `attestation` is absent, renders an honest
 * refused/unavailable state (no fabricated digest, no inferred verdict).
 */
import type { Attestation, InspectorNode } from "./ResourceInspector";

export interface AttestationModeProps {
  node: InspectorNode;
  attestation?: Attestation;
}

function Badge({ valid }: { valid: boolean }) {
  return valid ? (
    <span
      role="status"
      className="inline-flex items-center gap-1 rounded-full border border-emerald-600/60 bg-emerald-950/40 px-2 py-0.5 text-xs font-medium text-emerald-300"
    >
      Signature valid
    </span>
  ) : (
    <span
      role="alert"
      className="inline-flex items-center gap-1 rounded-full border border-red-600/60 bg-red-950/40 px-2 py-0.5 text-xs font-medium text-red-300"
    >
      Signature INVALID
    </span>
  );
}

export default function AttestationMode({ node, attestation }: AttestationModeProps) {
  if (!attestation) {
    return (
      <div className="flex min-h-0 flex-col gap-3">
        <div className="text-sm text-neutral-300">
          No attestation available for node <code>{node.id}</code>.
        </div>
        <span
          role="status"
          className="inline-flex w-fit items-center gap-1 rounded-full border border-neutral-600 bg-neutral-900 px-2 py-0.5 text-xs font-medium text-neutral-400"
        >
          Unverified — no attestation record
        </span>
        <p className="text-xs text-neutral-500">
          The inspector renders only received verdicts; signature validation is
          performed upstream by the attestation service.
        </p>
      </div>
    );
  }

  return (
    <div className="flex min-h-0 flex-col gap-3">
      <div className="flex items-center gap-3">
        <Badge valid={attestation.valid} />
        {attestation.signer && (
          <span className="text-xs text-neutral-400">
            Signer: <code className="text-neutral-300">{attestation.signer}</code>
          </span>
        )}
      </div>
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 font-mono text-xs">
        <dt className="text-neutral-500">Digest</dt>
        <dd className="break-all text-emerald-200">{attestation.digest}</dd>
        <dt className="text-neutral-500">Subject</dt>
        <dd className="break-all text-neutral-300">{node.id}</dd>
      </dl>
    </div>
  );
}
