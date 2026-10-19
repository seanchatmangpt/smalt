# Affidavit Evidentiary Design

Explanation register for the ten evidentiary mechanisms of the
`affidavit_wasm` integration. **This document states design intent: each
row names a technical mechanism and the legal posture it is INTENDED to
support. It does not assert that any legal effect has been obtained,
would be obtained, or is obtainable.** Citations (FRCP 37(e), SOX 1514A,
ABA 3.4(a), FRE 902) are the design's own normative references, not
legal advice or a claim of compliance.

## Standing

**PARTIAL_ALIVE.** The smalt-side integrations (CTRT seal on PUT/DELETE,
OCEL `affidavit.seal` emitters, tariff bytes via `Smalt.FinOps.Calculator`,
KD-89 closure path) are live in this tree. The affidavit-side mechanisms
were validated separately (reconciled validator verdicts, 2026-10-16);
per-row status below reflects those verdicts. The four validation Explore
lane transcripts were not retrievable at write time, so rows without a
reconciled verdict are marked VALIDATION-PENDING.

Status vocabulary: **WITNESSED** (validator-confirmed by executed court
or direct read), **WITNESSED-GAP** (mechanism live but a named sub-
surface is absent/zeroed), **DESIGN-INTENT** (not implemented on the
affidavit side), **VALIDATION-PENDING** (no transcript available).

## Mechanism 1 — Content seal (CTRT token)

- **Corporate move (defense posture):** produce sealed, self-describing
  records of admissibility decisions so the enterprise can demonstrate
  deliberate, systematic evidence handling rather than improvised
  retention.
- **Mechanism:** canonical state-delta JSON admitted through the WASM
  engine export `affi_admit_and_seal/1`; the engine returns a sealed
  352-byte CTRT token binding the decision.
- **Code anchor:** `lib/smalt/affidavit/wasm_engine.ex:219+` (CTRT
  layout gate), `lib/smalt/affidavit/seal.ex:30-33` (`admit_and_seal/2`).
- **Cited authority:** FRCP 37(e) (curable spoliation posture via
  systematic preservation).
- **smalt integration point:** seal sideband on every successful ARM
  resource PUT and RG-delete cascade.
- **Status:** WITNESSED (engine court; smalt mount live).

## Mechanism 2 — Tamper-evident delta binding (blake3)

- **Corporate move:** make post-hoc alteration of a sealed record
  detectable, supporting an affirmative spoliation defense narrative.
- **Mechanism:** CTRT binds `blake3(delta)` at offset [70..102] and a
  nullifier `blake3(delta_hash)` at [176..208]; the host re-derives the
  blake3 leg when `b3sum` is installed and reports the leg as
  `pqc_receipt: unverified_blake3_host` otherwise.
- **Code anchor:** `lib/smalt/affidavit/wasm_engine.ex:219+`
  (layout gate and host re-derivation, :221-228).
- **Cited authority:** FRCP 37(e); FRE 901(b)(1) (distinctive
  characteristics) as the design's reference for identification.
- **smalt integration point:** layout gate runs on every
  `call_admit_and_seal/4` result the router sideband accepts.
- **Status:** WITNESSED. (Note: the live nullifier formula on the
  affidavit side is keyed-blake3 over the CTRT wire with an HMAC-sealed
  snapshot; the commitment/seq/sig derivation in the engine docs is dead
  code on that side.)

## Mechanism 3 — Deontic modality byte

- **Corporate move:** distinguish records the enterprise treats as
  mandatory-accept from those under a commercial hold, so hold classes
  survive personnel changes.
- **Mechanism:** a 1-byte deontic modality at CTRT offset [175]
  (modality 1 accept / 2 restricted, selected by the tariff threshold
  `@affidavit_high_tariff_cents`).
- **Code anchor:** `lib/smalt/affidavit/wasm_engine.ex:219+` (modality
  slot in the layout gate);
  selection in `lib/smalt/arm_gateway/router.ex` (`affidavit_seal/2`,
  :2226).
- **Cited authority:** SOX 1514A as the design's reference for
  episodic hold-imposition posture.
- **smalt integration point:** modality computed per-record at seal
  time from the tariff sideband.
- **Status:** WITNESSED-GAP. The byte is written and selected live, but
  the intended UnremittedCommercialHold state machine does NOT exist on
  the affidavit side; nearest artifacts are the
  `DEONTIC_PRESERVATION_HOLD 0x03` constant (`wire_ctrt.rs:48-55`,
  never written by any path) and the $50M tier semantics, which exist in
  doc comments only. Witnesses-verifier refusal strings that do exist:
  `EVIDENTIARY_CHAIN_GAP_DETECTED (FRCP-37E)` (`verifier.rs:239`,
  obligated-gated string, not a typed enum) and
  `UNLAWFUL_RECORD_EXPUNCTION (ABA-3.4A)`.

## Mechanism 4 — Tariff-bound materiality

- **Corporate move:** grade records by quantified consequence so any
  future defensibility argument can cite the enterprise's own materiality
  ladder rather than ad-hoc judgement.
- **Mechanism:** tariff cents are computed from the stored record via
  `Smalt.FinOps.Calculator.avoided_tariff_cents/3` and carried INTO the
  seal: 8-byte LE u64 at CTRT offset [167..175], round-trip asserted
  byte-exact.
- **Code anchor:** `lib/smalt/fin_ops/calculator.ex:90`
  (`avoided_tariff_cents/3`); write at `affidavit-wasm/src/ffi.rs:175`.
- **Cited authority:** SOX 1514A (materiality gradation) as the
  design's reference.
- **smalt integration point:** tariff bytes flow from the FinOps
  calculator through the router sideband into the WASM seal path smalt
  actually mounts.
- **Status:** WITNESSED in the WASM seal path (falsified otherwise: the
  "wasm has no tariff write" validator claim was refuted by direct read
  of `ffi.rs:175` plus W16's executed Rust court). Honest upstream gap:
  the affidavit-side native `handlers.rs` emit path zeroes the tariff
  bytes; smalt is not on that path.

## Mechanism 5 — Fail-closed typed refusal

- **Corporate move:** ensure the system never emits a plausible-looking
  witness under degraded conditions — an absent witness is named, not
  faked.
- **Mechanism:** degraded inputs return typed errors
  (`:payload_too_large` over 16 MiB, `{:error, _}` on garbage delta); a
  subsequent well-formed call still succeeds (no crash-loop); engine
  load failure is a verbatim BLOCKED flunk, never a skip.
- **Code anchor:** `lib/smalt/affidavit/wasm_engine.ex` (typed-error
  contract :214-219; fail-closed engine-unavailable path :141);
  real-run tier in
  `test/smalt_affidavit_wasm_test.exs` (3 tests, no mocks, no skips).
- **Cited authority:** FRCP 37(e) is reference for the design position
  that an honest absence is defensible while a fabricated witness is
  not.
- **smalt integration point:** the same typed-error contract governs
  the router sideband's `witness_absent/1` fallback.
- **Status:** WITNESSED.

## Mechanism 6 — Fail-safe sideband (wire parity preserved)

- **Corporate move:** keep the operational plane (customer traffic)
  orthogonal to the evidentiary plane, so no evidence mechanism can be
  blamed for availability or storage drift.
- **Mechanism:** the seal is a best-effort SIDEBAND: a dead engine, a
  refused seal, or an unavailable tariff calculator never changes the
  HTTP outcome; witnesses land in the ETS table
  `:smalt_affidavit_witnesses` plus logs, never in wire records.
- **Code anchor:** `lib/smalt/arm_gateway/router.ex:2191-2195` (wire-up
  law comment + witness table).
- **Cited authority:** FRE 902(13)-(14) posture reference: records
  certified by a process that demonstrably does not perturb them.
- **smalt integration point:** every ARM PUT/DELETE in
  `lib/smalt/arm_gateway/router.ex` (:685, :790).
- **Status:** WITNESSED (smalt-side; lane 611 SHIM-COURT comments).

## Mechanism 7 — OCEL event ledger linkage

- **Corporate move:** convert seals into process-minable event objects
  so retention decisions are auditable as a process, not a pile.
- **Mechanism:** each seal emits an `affidavit.seal` OCEL event via the
  registered event vocabulary.
- **Code anchor:** `lib/smalt/ocel/event_registry.ex:23`
  (`"affidavit.seal"`); emitter receipt
  `docs/jira/v26.10.16/receipts/lane606-affidavit-seal-event.md`
  (3 tests, 0 failures, ALIVE).
- **Cited authority:** SOX 302/404 audit-trail posture as the design's
  reference.
- **smalt integration point:** emitter fires inside the router seal
  sideband, adjacent to the ETS witness write.
- **Status:** WITNESSED-GAP. The emitter is live in smalt and a generic
  `receipt_to_ocel` bridge is WITNESSED on the affidavit side
  (`mining.rs:207`); the four NAMED object-type bindings (committer,
  PR, reviewer, state-mutation) intended for the linkage are ABSENT.

## Mechanism 8 — Post-quantum witness (ML-DSA-65)

- **Corporate move:** seal decisions with signatures expected to remain
  hard to forge across long retention horizons (harvest-now-decrypt-later
  posture).
- **Mechanism:** the trust-profile envelope signs over the RS256
  substrate with the engine's CTRT seal; the CTRT witness region
  [240..352] is RESERVED for the ML-DSA witness (on the pre-rebuild
  artifact `44ed468c` it was ZEROED upstream — no ML-DSA bytes were
  embedded), with the `:PQC_NOT_PROVISIONED` typed refusal
  retained as fail-closed fallback. **Update 2026-10-17 (KD-89
  closed):** upstream engine `a8c3c2b` ships dedicated
  `pqc_verify`/`pqc_assemble` ops with real ML-DSA-65 adjudication;
  smalt's mounted artifact is re-pinned to sha256 `b3cf38ba…` and the
  engine-adjudicated ML-DSA-65 forge court (KAT accepted via
  `pqc_verify`, tamper refused `ml_dsa65_rejected`) is witnessed in
  `docs/jira/v26.10.16/receipts/kd89-ml-dsa-closure.md`.
- **Code anchor:** `lib/smalt/trust_profile/trust_profile.ex:224,264`
  (envelope + witness block); refusal at
  `lib/smalt/trust_profile/trust_profile.ex:62,78`.
- **Cited authority:** FRE 902 (self-authenticating records posture)
  as the design's reference.
- **smalt integration point:** KD-89 closure path — wasm artifact
  shipped (`priv/wasm/affidavit_wasm.wasm` + checksum), doctor OK, and
  forge-rejection court are the named close condition; the register row
  remains OPEN pending the D-lane ladder witness; flip is
  registrar-owned (`scripts/kd_flip.py --apply`).
- **Status (updated 2026-10-17):** RESOLVED for the engine-verify surface.
  Historical: on the pre-rebuild artifact `44ed468c`, the wasm engine smalt
  mounted supported only classical verify ops (`verify_signature`:
  ES256/ES256K/Ed25519; `ML_DSA65` returned `unsupported_algorithm`), and
  the seal-path witness region [240..352] was zeroed — the typed
  `unsupported_algorithm` refusal for `verify_signature alg=ML_DSA65`
  persists upstream-by-design; PQC is routed through the dedicated
  `pqc_verify`/`pqc_assemble` ops (upstream `src/pqc.rs`). Engine state
  now: upstream `a8c3c2b` ships both ops with real ML-DSA-65
  adjudication; smalt's mounted artifact re-pinned `b3cf38ba…`;
  engine-adjudicated ML-DSA-65 forge court witnessed (KAT accepted,
  tamper refused `ml_dsa65_rejected`), KD-89 CLOSED-WITH-RECEIPT
  (`docs/jira/v26.10.16/receipts/kd89-ml-dsa-closure.md`). Residual
  (unchanged): the FRE 902 certificate verb is canned text, not a
  computed certificate.

## Mechanism 9 — Chain-gap detection and expunction refusal

- **Corporate move:** detect evidentiary chain breaks and refuse record
  expunction under hold, converting two litigation-risk scenarios into
  named, logged machine refusals.
- **Mechanism:** verifier-side refusals keyed to the design's own
  authority tokens: `EVIDENTIARY_CHAIN_GAP_DETECTED (FRCP-37E)` and
  `UNLAWFUL_RECORD_EXPUNCTION (ABA-3.4A)`.
- **Code anchor:** `affidavit-wasm/src/verifier.rs:239` (chain-gap
  string, obligated-gated). smalt-side: PENDING — no smalt surface
  consumes these refusals yet.
- **Cited authority:** FRCP 37(e); ABA Model Rule 3.4(a) as the
  design's references.
- **smalt integration point:** intended to surface through the
  witness-absent sideband as typed reasons; not wired.
- **Status:** WITNESSED (strings exist and are obligated-gated on the
  affidavit side) / smalt linkage VALIDATION-PENDING.

## Mechanism 10 — Safe-harbor materiality cards

- **Corporate move:** carry the design's own authority anchors inside
  the sealed token so a reader of the CTRT alone can see which posture
  a record claims.
- **Mechanism:** 16-byte anchor labels in the CTRT wire format
  (`SOX_1514A`, etc.).
- **Code anchor:** the WASM seal path DOES write a statutory anchor:
  `affidavit-wasm/src/ffi.rs:174` writes `b"GAIN_5050\0..."` at CTRT
  [151..167] (WITNESSED by direct read + W16's executed Rust court);
  constant labels also live at `affidavit-wasm/src/wire_ctrt.rs:40-43`.
  smalt-side: PENDING — no smalt code reads or validates the anchor
  region.
- **Cited authority:** SOX 1514A (label names the posture; it asserts
  nothing more, by design); GAIN 5050 as written in the seal path.
- **smalt integration point:** intended as a display/validation field
  in the trust-profile payload map; not implemented.
- **Status:** WITNESSED for the anchor bytes in the WASM seal path;
  WITNESSED-GAP for card semantics — the full safe-harbor/FinOps card
  machinery (rules, computation, enforcement) is ABSENT on the
  affidavit side. Design intent only.

## Reconciled zero/absent set (single source)

As of the 2026-10-16 reconciled validator verdicts, the absent/zeroed
surface is confined to exactly these six items; everything else in this
register is WITNESSED in the WASM seal path smalt mounts:

1. Witness region [240..352] — zeroed (Mechanism 8).
2. Native `handlers.rs` emit path — zeroes tariff + anchor bytes
   (upstream gap; smalt is not on this path, Mechanism 4).
3. OCEL four-object bindings (committer/PR/reviewer/state-mutation) —
   absent (Mechanism 7).
4. UnremittedCommercialHold state machine — absent (Mechanism 3).
5. Safe-harbor/FinOps card machinery — absent (Mechanism 10).
6. FRE 502 / crime-fraud machinery — absent (design intent, no row
   above; listed here so the boundary is explicit).

## Reading this document

- Rows marked DESIGN-INTENT or WITNESSED-GAP describe direction, not
  capability. No row is a compliance claim.
- The GAP-token discipline applies at the KD layer only: KD-89 is the
  single named open gap here, closed receipt-gated via
  `scripts/kd_flip.py --apply`. This document mints no new GAP tokens.
- Validation lane transcripts for the four concurrent validation
  Explore lanes were polled twice and not found at write time
  (2026-10-16); affected rows carry VALIDATION-PENDING and will be
  refreshed by a follow-up lane when transcripts land.

See Also: `docs/jira/v26.10.16/WRAP_LEDGER.md` (KD-89 section),
`docs/jira/v26.10.16/receipts/lane606-affidavit-seal-event.md`,
`lib/smalt/affidavit/wasm_engine.ex`, `lib/smalt/fin_ops/calculator.ex`.
