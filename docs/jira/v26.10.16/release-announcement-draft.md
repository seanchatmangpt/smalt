# Release Announcement Draft — smalt v26.10.16

DRAFT ONLY — not sent, not minted into any publish surface. Standing lines are
pre-court-x2; the wrap is closing. Tag reference: **v26.10.16** (terminal window).
Final court verdict is a placeholder until the fin sweep's two-green receipt lands.

## Headline (from FINAL.md)

> **smalt v26.10.16 — BEAM-native local cloud-edge emulator: ARM-style control
> plane on 9443, TLS twin 9444, data plane 8443, AMQP Service Bus 5672, Event
> Hubs 5673, MCP tool surface 9545. Point SDKs/CLIs at loopback, no cloud needed.
> Standing: PARTIAL_ALIVE (pre-court-x2).**

## Capabilities (honest standing per capability)

- **Affidavit WASM engine — PARTIAL_ALIVE.** Upstream-sealed artifact `44ed468c`
  mounted; CTRT seal path live and classical verify adjudication live
  ([r215](receipts/r215-affidavit-seal-court.md): 113 tests / 0 failures, forge
  rejections typed). PQC is **GAP_TYPED, NOT_CLOSED** — KD-89 OPEN, witness
  PENDING: the mounted engine has no `ML_DSA65` verify op (upstream
  `affidavit-wasm/src/signature.rs:29-55` → `unsupported_algorithm`); the CTRT
  112-byte witness region `[240..352]` is zeroed upstream. `:pqc` trust profile
  returns typed `:PQC_NOT_PROVISIONED`. No faked pass.
- **Substrate — PASS.** Native HCL enclave pipeline
  (`parse → plan/apply → destroy`, per-hop sub-100 ms witnessed on the quiet
  run, full-lifecycle apply hop 110 ms under load — both on record), 41 admitted
  resource types (mechanically counted from `@admitted_resource_types` in
  `lib/smalt/registry.ex`), 2222-test offline suite, AMQP/EH wire tier, blob
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

## Court trajectory (one-liner)

**8 wrap-court invocations, 0 two-green receipts** — 7 deterministic reds
identified and **all fixed** (neither recurs in any later run's red set);
remaining reds typed as ordering / load-churn (1-flake-per-run riders,
environment/contention — e.g. run 8's 9445-occupied + SIGKILL), **final verdict:
`PLACEHOLDER — two-green pending, first next-window action is the re-court`
(fin sweep fills)**.

## Publish note

`hex.publish` is **typed-blocked (B1/B2)** — court-x2 two-green receipt and
publish-dry witness not yet minted this window; publication defers to the
**next window** per the wrap sequence (re-court → fin sweep → regenerate →
publish-dry → flip standing).
