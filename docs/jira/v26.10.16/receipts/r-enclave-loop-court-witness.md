# r-enclave-loop-court-witness

Standing: **PASS** (non-vacuous; all three enclave-loop families flip; restore
byte-exact on each).

- Court: `scripts/shim_court/enclave_loop_court.sh` (exit 0)
- Subjects (three families):
  - `scripts/bench/enclave_loop.exs` sha256 `222e4d640c6d9844f93c5026040d2757294d087dd9563490e3be4d152030cbae`
  - `workspace/scripts/enclave-loop.mjs` sha256 `a7daabb1810909bc1a686aca6a964f250150854f53a16dfd3d12b4bd5a56a5a1`
  - `scripts/tf_enclave_loop.sh` sha256 `422ce48af6754e20f4d48d71d44f3c9e93f4ada0c5d62983d273a50ccdc5ab99`
- Witness date: 2026-10-17, lane I20, individual court run
  (`timeout 480 bash scripts/shim_court/enclave_loop_court.sh`).
- Closes the FINAL.md "enclave_loop session-witnessed only, witness receipt
  PENDING" gap (D5 re-scope).

## Embedded output

```
[self-check] sha256 restore-detection verified
== enclave-loop family: scripts/bench/enclave_loop.exs ==
[SHIM] baseline sha256(scripts/bench/enclave_loop.exs) = 222e4d640c6d9844f93c5026040d2757294d087dd9563490e3be4d152030cbae
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to scripts/bench/enclave_loop.exs (SHIM-COURT marker present)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] enclave_loop_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
== enclave-loop family: workspace/scripts/enclave-loop.mjs ==
[SHIM] baseline sha256(workspace/scripts/enclave-loop.mjs) = a7daabb1810909bc1a686aca6a964f250150854f53a16dfd3d12b4bd5a56a5a1
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to workspace/scripts/enclave-loop.mjs (SHIM-COURT marker present)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] enclave_loop_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
== enclave-loop family: scripts/tf_enclave_loop.sh ==
[SHIM] baseline sha256(scripts/tf_enclave_loop.sh) = 422ce48af6754e20f4d48d71d44f3c9e93f4ada0c5d62983d273a50ccdc5ab99
[SHIM] shim applied to scripts/tf_enclave_loop.sh (SHIM-COURT marker present)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] enclave_loop_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
[enclave-loop] all three families: skip loudness proven load-bearing
```
(exit 0)

Falsifier: each family's AFTER leg flips against its shim; a court that could
not flip would exit 1. Skip loudness itself is proven load-bearing in the
final leg.
