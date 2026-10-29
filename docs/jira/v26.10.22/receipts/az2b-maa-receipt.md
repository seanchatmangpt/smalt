# AZ-2b — MAA Attestation Face: Finish-and-Relay Receipt

**Standing**: ALIVE
**Context**: solo
**Date**: 2026-10-22
**Lane**: bk120 (finish-and-relay, AZ-2 redirected mid-flight; lane gone; no prior receipt)

## Subject

* `lib/smalt/attestation/maa.ex` (21,300 bytes, mtime 2026-10-21 23:52, coordinator snapshot)
* `test/internal/az2_maa_attestation_court_test.exs` (8,730 bytes, mtime 2026-10-21 23:53)
* Wiring: `lib/smalt/egress/AttestRoutes.ex` — `post "/attest/:type"` dispatches
  `report`-bearing bodies to `Smalt.Attestation.Maa.attest/3`
  (`Smalt.Egress.AttestRoutes` is mounted from `lib/smalt/egress_router.ex:1003`).

## Found vs Finished

**Found (already in-tree, complete)** — audited from disk, nothing minted:

* attest/:type route face, MAA REST shape `POST /attest/:type?api-version=2022-08-01`,
  loopback quote framing `SMQ1 | measurement(32) | len(u32 BE) | runtime JSON`.
* MAA policy grammar evaluator: `authorizationrules` (fail-closed: no rules ⇒ refusal)
  + `issuancerules` with literal and claim-reference conditions/actions.
* RS256 JWT via real `Smalt.Security.ReceiptSigner` (sign + verify via
  `Maa.verify_attestation/1`).
* CTRT binding (real 352-byte BK-85 seal from the real wasm engine;
  `ctrt_sha256` + probe-region digest committed into the JWS).
* VC 2.0 binding through real `Smalt.Receipt.VcExport.verify_vc/1`.
* SKR witness leg: valid measurement JWT → real `Smalt.DataPlane.SKR.release/2`
  admits (200, `attested_measurement` echoed); tampered/foreign measurement →
  typed 403 `UnauthorizedAttestation` without touching SKR.
* Nonce replay registry (ETS `:smalt_maa_nonces`) → typed `nonceReplay`.
* Typed refusals carry chain-complete BK-111 PROV-O andon leaves, fail-closed
  (`Andon.verify_ntriples` asserted inside `refuse/3`).

**Finished**: nothing — the snapshot was complete. No missing pieces; no edits
made to `maa.ex` or the court. The only gap was the absent receipt itself.

## Court runs (real output, ×2 green)

```
$ MIX_BUILD_ROOT=_build-bk120 mix test test/internal/az2_maa_attestation_court_test.exs
Running ExUnit with seed: 109695, max_cases: 32
.......
Finished in 0.1 seconds (0.00s async, 0.1s sync)
Result: 7 passed            # exit 0

# run 2, fresh seed
.......
Finished in 0.2 seconds (0.00s async, 0.1s sync)
Result: 7 passed            # exit 0
```

7/7 legs: api-version pin, valid-measurement JWS+CTRT binding, VC binding
(valid + tampered), tampered-measurement 400 + andon chain, nonce replay,
policy grammar (gate + issuance + fail-closed + unsupported TEE), SKR witness
(valid 200 / tampered 403). Chicago: real signer, real wasm-sealed CTRT, real
VC verify, real SKR release; bounded polls, zero sleeps.

## Honesty row (typed)

Real SEV-SNP/TDX hardware quote production = UNSUPPORTED on this machine (no
SNP/TDX firmware); the protocol face (quote validation, MAA-grammar policy,
binding, RS256 token, SKR release) is real and court-verified. Documented in
the module moduledoc; carried, not hidden.

## Replay

```bash
cd /Users/sac/smalt
PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-bk120 \
  mix test test/internal/az2_maa_attestation_court_test.exs
```

Not committed (per lane contract). Build root `_build-bk120` left in place for
the coordinator's `lane-clean`.
