# BK-SECPEND — NFR-SEC-001/002 PENDING-row closure (COURT-ATOM-CLAMP / COURT-CERT-OBS)

**Standing**: PARTIAL_ALIVE — COURT-ATOM-CLAMP cell flips to **PASS via composition**; COURT-CERT-OBS flips to **PARTIAL_ALIVE** (observable witnessed, standalone court still absent). `Context: solo`

Lane: BK-SECPEND, 2026-10-22, solo. Closes the last-but-one PENDING row in
`docs/jira/v26.10.22/VALIDATION.md` §3 (the row BK-2b recorded). Method per
PRD §4: no named consolidated court exists for either NFR, so the constituent
courts were **re-run fresh this lane** (MIX_BUILD_ROOT=_build-bksec,
asdf-shims PATH) and the cells typed as the composition's real standing —
no court file was minted, no standing smoothed.

## Constituent courts re-run (all real mix test runs, exit 0)

### NFR-SEC-001 (Δatoms ≡ 0 @100k hostile) — COURT-ATOM-CLAMP composition

| Leg | Court file | Result |
|---|---|---|
| ja5 fail-fast court, gate 3 atom-smuggling battery | `test/integration/ja5_fail_fast_court.exs` | **4 passed, exit 0** |
| VM zero-growth atom fences (<64 atoms over census windows) | `test/internal/vm_zero_growth_test.exs` | batch: **12 passed, exit 0** |
| SPOFB EH atom court | `test/internal/spofb_eh_atom_court_test.exs` | (in batch) |
| KD-51 SB-over-HTTPS atom + TLS listener | `test/integration/kd51_sb_atom_https_test.exs` | (in batch) |

```bash
$ MIX_BUILD_ROOT=_build-bksec mix test test/integration/ja5_fail_fast_court.exs
Finished in 15.2 seconds (0.00s async, 15.2s sync)
Result: 4 passed
(exit 0)

$ MIX_BUILD_ROOT=_build-bksec mix test test/internal/vm_zero_growth_test.exs \
    test/internal/spofb_eh_atom_court_test.exs \
    test/integration/kd51_sb_atom_https_test.exs
Finished in 0.6 seconds (0.00s async, 0.6s sync)
Result: 12 passed
(exit 0)
```

Composition standing: **PASS** — the Δatoms≡0 fence is witnessed fresh on the
real VM (ja5 gate 3 atom-smuggling battery over the real Bandit wire face +
zero-growth fences asserting `:erlang.system_info(:atom_count)` deltas < 64
over hostile input). Residue (honest): PRD §5's named standalone
`COURT-ATOM-CLAMP` script does not exist; the cell stands via constituent
receipts only. Falsifier for the residue: a standalone exit-0 script named
`COURT-ATOM-CLAMP` remains absent from `scripts/` and `justfile.d/` (verified
by grep this lane: zero hits for `ATOM-CLAMP` in justfile.d/ and scripts/).

### NFR-SEC-002 (cert fail-closed observable) — COURT-CERT-OBS composition

Observable under test: `Logger.error` on all 4 failure branches of
`lib/smalt/auth/x_arr_cert.ex` `ca_certs/0`/`decode_ca_file/1` (lines 140,
149, 171, 184 — re-read on disk this lane; JA-R3 D2 fix). Evidence:

| Leg | Evidence | Result |
|---|---|---|
| JA-R3 D2 code witness (4 × Logger.error) | `../v26.10.21/receipts/ja-r3-ja16-defect-fixes.md` (Standing: PASS) + source on disk | 4 sites present |
| Cert pending/LRO court | `test/internal/certificates_pending_test.exs` | batch: **20 passed, exit 0** |
| KD-104 cert witness (TLS integration) | `test/integration/certificates_kd104_witness_test.exs` | (in batch) |
| TLS blob dispatch (TLS listener config + bearer over TLS) | `test/integration/tls_blob_dispatch_test.exs` | (in batch) |
| WPS token fail-closed court (F1 no-aud/no-exp verify :error) | `test/internal/wps_exp4_court_test.exs` | (in batch); standing ALIVE: `receipts/wps-exp4-repairs.md` |
| MHSM release policy court | `test/internal/az4_mhsm_release_policy_court_test.exs` | (in batch) |

```bash
$ MIX_BUILD_ROOT=_build-bksec mix test test/internal/wps_exp4_court_test.exs \
    test/internal/az4_mhsm_release_policy_court_test.exs \
    test/internal/certificates_pending_test.exs \
    test/integration/certificates_kd104_witness_test.exs \
    test/integration/tls_blob_dispatch_test.exs
Finished in 1.1 seconds (0.00s async, 1.1s sync)
Result: 20 passed
(exit 0)
```

Composition standing: **PARTIAL_ALIVE** — the cert fail-closed *observable*
is witnessed (JA-R3 D2 fix on disk with 4 Logger.error branches; surrounding
cert/TLS/token/MHSM fail-closed surface green 20/20), but no dedicated
exit-0 court asserts the Logger.error observability itself. Falsifier +
owner: the PRD §5 named-court WO (standalone COURT-CERT-OBS script) remains
open — a grep for `CERT-OBS|cert_obs` over `scripts/` and `justfile.d/`
returns zero hits this lane (zero hits, verified).

## Residue

One WO unchanged: mint standalone exit-0 scripts COURT-ATOM-CLAMP and
COURT-CERT-OBS (PRD §5 (a)). Until then, the VALIDATION.md cells carry the
composition standings above, not a single-court PASS.
