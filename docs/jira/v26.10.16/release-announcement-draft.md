# Release Announcement Draft — smalt v26.10.16

DRAFT ONLY — not sent, not minted into any publish surface. Standing lines are
pre-two-green; the wrap is closing. Tag reference: **v26.10.16** (terminal
window; tag prep in [TAG-PREP.md](TAG-PREP.md), no tag executed). Final court
verdict stays a placeholder until a court-x2 run logs
`[COURT-X2] RECEIPT: gate PASSED` (latest completed: run-27, FAILED — see
Court trajectory).

## Headline (from FINAL.md)

> **smalt v26.10.16 — BEAM-native local cloud-edge emulator: ARM-style control
> plane on 9443, TLS twin 9444, data plane 8443, AMQP Service Bus 5672, Event
> Hubs 5673, MCP tool surface 9545. Point SDKs/CLIs at loopback, no cloud needed.
> Standing: PARTIAL_ALIVE (pre-two-green; landing HEAD `7275032`, lineage
> f0d2f47..7275032, 12 commits).**

## Capabilities (honest standing per capability)

- **Affidavit WASM engine — PARTIAL_ALIVE.** Upstream-sealed artifact `44ed468c`
  mounted; CTRT seal path live and classical verify adjudication live
  ([r215](receipts/r215-affidavit-seal-court.md): 113 tests / 0 failures, forge
  rejections typed). PQC is **GAP_TYPED, NOT_CLOSED** — KD-89 OPEN, witness
  PENDING: the mounted engine has no `ML_DSA65` verify op (upstream
  `affidavit-wasm/src/signature.rs:29-55` → `unsupported_algorithm`); the CTRT
  112-byte witness region `[240..352]` is zeroed upstream. `:pqc` trust profile
  returns typed `:PQC_NOT_PROVISIONED`. No faked pass.
- **Substrate — PASS (offline tier).** Native HCL enclave pipeline
  (`parse → plan/apply → destroy`, per-hop sub-100 ms witnessed on the quiet
  run, full-lifecycle apply hop 110 ms under load — both on record), 41 admitted
  resource types (mechanically counted from `@admitted_resource_types` in
  `lib/smalt/registry.ex`), 2435-test offline suite, AMQP/EH wire tier, blob
  WORM / cosmos etag-CAS / ledger-chain / queue-capacity / lock-clamp invariant
  gates (6/7 PASS — `appconfig-etag-cas` red typed as DEF-2 transient boot
  contention under concurrent lane builds, non-vacuity fixtures all correctly
  REFUSE).
- **Trust shim v2 — PASS (host-setup prerequisite, reclassified per WRAP_LEDGER
  "Enclave trust hop").** 4-leg proof in `scripts/trust_shim/`: loopback-only
  SAN gate + leaf-fingerprint pin, hardened-runtime refusal, interposed
  `SecTrustEvaluateWithError`/`SecTrustEvaluate`; use + codesigning constraints
  witnessed in `scripts/trust_shim/README.md`.
- **Console clients — PASS.** Sovereign Console (Next.js 16, air-gapped,
  zero-egress, networking only through `lib/smalt.ts`), `ws-court` **PASS=42
  FAIL=0 SKIP=1** (quiet re-run is the standing datum), smalt-cli two-venv
  pytest tier.
- **Diátaxis docs — PASS.** tutorials/how-to/reference/explanation restructure
  landed; `just docs-dod-check` exit 0 (23/23 paths OK), Diátaxis relative-link
  sweep 0 broken links, naming sweep PASS 0 violations / 46 allowed.
- **KD register — 94 rows (KD-01..KD-94).** Canonical table
  [`../v26.10.14/KNOWN_DIVERGENCES.md`](../v26.10.14/KNOWN_DIVERGENCES.md)
  (`grep -c '^| KD-'` → 94); this window flipped KD-45/46/53/54/68/70/71/76
  CLOSED-SIMULATED and minted KD-77/91/92/93 OPEN with witness receipts
  r200a-r200h. Every divergence is pass / registered-divergence / loudly
  MISSING — no silent skips.

## Court trajectory (one-liner, as-of run-29 launch)

**29 wrap-court invocations launched, 0 two-green receipts.** The
deterministic reds identified across runs 8-20 are **all fixed** (none recurs
in a later run's red set); the remaining reds are one-per-run flake /
contention riders — latest completed gate **run-27** (2026-10-17 00:30-01:14):
run 1 exit 2 on a single red (`Smalt.AffidavitWasmTest:80`,
`test/smalt_affidavit_wasm_test.exs:80`, affidavit flake family, witness
[r216-court-x2-run12-red.md](receipts/r216-court-x2-run12-red.md) typed the
same family at run 12) while run 2 of the same gate was GREEN with 0 test
failures; run-28 run-1 also red on one offline failure, run-29 was IN-FLIGHT
at this edit. **Verdict: `PENDING — no two-green yet; the in-flight run-29 (or
its successor) is the gate; tag cut is gated on it per TAG-PREP.md`.**

## Publish note

`hex.publish` is **typed-blocked (B1/B2)** — court-x2 two-green receipt and
publish-dry witness not yet minted this window; publication defers to the
**next window** per the wrap sequence (re-court → fin sweep → regenerate →
publish-dry → flip standing).
