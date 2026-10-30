# INDEX — v26.10.31 Unification-Dialect Migration Gap Reports (M1–M17)

Canonical home: `docs/jira/posh/v26.10.31/gaps/` (files keep the `posh/` prefix path;
the v26.10.31 window cross-references it). Statuses verified by reading each file
2026-10-30.

> **M14 digest correction (prominent).** The dispatching task specified the turnstile
> receipt digest as over `(delta ∥ node_id ∥ timestamp_ns ∥ state_root)`. That is
> wrong per the on-disk law: the actual cross-language contract is
> **`BLAKE3(op_utf8 || u64BE(ts_ns) || payload_body)`** — three inputs
> (`settlement.ex:58-68`, `receipt_turnstile.ex:22-23`, `verify.go`). The delta is the
> *body*; `node_id` and `state_root` are event-log *entry fields*, not digest inputs.
> Any charter text carrying the four-input formula is a false citation; use the
> three-input formula (see `gaps/14-turnstile-neutrality.md`, Violations §1).

Reports 01–17 all verified present in the canonical directory; no stray copies were
found in the courtroom repo (`/Users/sac/cai/courtroom-platform-az/posh/` holds only
`var/dx-events.jsonl`; its `docs/` holds only `nextjs-harness/v26.10.30` material).
Also present in the canonical dir, outside this index's 01–17 scope:
`69-dod-execution-harness.md`.

## Rows

| Report | Milestone | Status (read 2026-10-30) | Verdict summary | Blocking |
|---|---|---|---|---|
| [01-sts-migration.md](../../posh/v26.10.31/gaps/01-sts-migration.md) | M1 | Report verified; verdict stated | STS wire face is **Azure-dialect, not sovereign** (dialect #0, identity) — with one sovereign residue; wire stays byte-identical in smalt | — |
| [02-payload-laws-census.md](../../posh/v26.10.31/gaps/02-payload-laws-census.md) | M2 | ALIVE (all home citations re-read from disk) | 13 wire laws censused; neutral-core set (L2/L5/L7/L8/L10/L11/L13) → P1; Azure-vocabulary set (L1/L3/L4/L6/L8b/L9/L12 + L11 GUID table) → P2 dialect mapping; nothing blocks P3 | **BLOCKING** (P1 core-ttl input) |
| [03-provider-mapping-inventory.md](../../posh/v26.10.31/gaps/03-provider-mapping-inventory.md) | M3 | PARTIAL (provider tree read in full; posh overlap surface-census only, no integration test) | Every azurerm-specific coercion → posh azurerm-dialect package; neutral machinery (retry, ApiError, token cache, singleflight, timeout, diag, import assertion) stays in provider core; seed of posh's first dialect package beyond Terraform | — |
| [04-diagnostic-vocabulary.md](../../posh/v26.10.31/gaps/04-diagnostic-vocabulary.md) | M4 | PARTIAL (taxonomy/envelope designed from ALIVE-cited reads; no re-shaping diffs landed) | Typed refusal classes the neutral core owns; ARM envelope (`send_arm_error/5`) is the projection target; `AdmissionRefused` fence envelope already typed; `UNSUPPORTED(tls-variant-absent)` is doc-comment today, needs a wire type | — |
| [05-fence-disposition.md](../../posh/v26.10.31/gaps/05-fence-disposition.md) | M5 | Verified with refinement | Egress fence is already posh-side; migration is single-homing **per language runtime**, not a move; each language's fence stands at a different standing | — |
| [06-wasm-disposition.md](../../posh/v26.10.31/gaps/06-wasm-disposition.md) | M6 | PARTIAL_ALIVE (engines read in full; `go test ./internal/wasm/ ./internal/receipt/` exit 0) | **KILL** `posh/internal/wasm/` with named design inheritance: admission authority lives in BEAM; `Smalt.Affidavit.WasmEngine` is the one admitted engine; `posh/internal/receipt/` pure-Go BLAKE3 kernel KEEP (byte-identity inheritance clause) | — |
| [07-tui-watcher-seams.md](../../posh/v26.10.31/gaps/07-tui-watcher-seams.md) | M7 | PARTIAL_ALIVE (spec + exact diffs landed) | Closes GM1 (TUI invents telemetry; `DirectMetricsSource` seeds invented `cachedAndon = "GREEN"`) and GM5 (watcher reload-storm risk on regen-check paths) via TelemetrySource/ScriptStatusSource contracts; report-only scripts are the lawful transport; L42 fragment paths UNVERIFIED | — |
| [08-k8s-coupling.md](../../posh/v26.10.31/gaps/08-k8s-coupling.md) | M8 | PARTIAL (all cells dispositioned from on-disk evidence) | Charter names client-go as the allowed Go k8s surface; posh imports zero of it (0 hits in go.mod); only k8s logic in posh is exec-based kube_healer; smalt kind estate ALIVE but backend CrashLoopBackOff at last probe (cluster face PARTIAL) | — |
| [09-credential-model.md](../../posh/v26.10.31/gaps/09-credential-model.md) | M9 | PARTIAL (census ALIVE; model spec drafted; no code changed) | Neutral `CredentialRequest` core vocabulary (principal/shared-secret/audience/Scope/SecretRef/opaque PrincipalId); Azure shape reclassified as dialect #1 mapping; current Entra-mock credential set is dialect data, not the model | **BLOCKING** (core credential model gates dialect extraction) |
| [10-spike-residuals.md](../../posh/v26.10.31/gaps/10-spike-residuals.md) | M10 | Report verified; archive hash byte-matches ledger | 11 session-introduced `lib/` fixes dispositioned per-fix (re-home / graduate to NEUTRAL-CORE wire law / die with spike); Elixir spike archive is the sole reference (sha256 `f0fe321b…`), in-tree spike root confirmed hard-deleted | — |
| [11-harness-coupling.md](../../posh/v26.10.31/gaps/11-harness-coupling.md) | M11 | ALIVE (all 24 harness files / 3,022 lines classified from full reads) | Suites split per-file into DIALECT-CONFORMANCE vs neutral; category (c) NEEDS-ABSTRACTION is empty today (no abstraction layer exists); note: the decision record is not in the courtroom repo — the ruling is taken from the dispatch | — |
| [12-compat-pin-split.md](../../posh/v26.10.31/gaps/12-compat-pin-split.md) | M12 | PARTIAL (split plan complete, 33 rows + 2 proposed dialectBehavior rows; nothing executed) | Rows split CORE (substrate-owned, → `compat-pin-core.ttl`) vs DIALECT (azurerm-wire pins → dialect pin path); gate split + court plan (flip + loud-skip probes, COMPAT-PIN-SKIP exit 3) specified; substrate currently ALIVE via unsplit pin | — |
| [13-admission-split.md](../../posh/v26.10.31/gaps/13-admission-split.md) | M13 | Read-mostly design lane (no lib/ changes) | Three conflated concerns split: capability existence (neutral) vs wire strings (dialect data) vs api-versions (dialect versioning) — out of one ontology/`registry.ex` into a two-layer admission: core classes above, dialect mappings below | **BLOCKING** (P1 entry consumes M13 phase-1 core ttl; admission-corpus court is its close condition) |
| [14-turnstile-neutrality.md](../../posh/v26.10.31/gaps/14-turnstile-neutrality.md) | M14 | PARTIAL (law verified neutral from real reads; dialect participation specified, not executed; TF-apply turnstile enforcement UNVERIFIED — gaps/26 residue) | Turnstile receipt law is provider-neutral; see the header correction above: digest is **3-input** `BLAKE3(op ‖ ts_ns ‖ body)`, not the 4-input dispatch premise. Residual Azure coupling in the fence route predicate (`/subscriptions/*`) registered, not a violation | — |
| [15-doc-migration-plan.md](../../posh/v26.10.31/gaps/15-doc-migration-plan.md) | M15 | Plan lane (rows carry close conditions; no prose executed) | Normative corpus censused into Tier A (gains NEUTRAL-CORE section), Tier B (becomes DIALECT-SCOPED), Tier C (unchanged); wave-2 doc edits owned per-row | — |
| [16-migration-sequencing.md](../../posh/v26.10.31/gaps/16-migration-sequencing.md) | M16 | Lane file ALIVE; P0–P3 UNVERIFIED (guard written, not run); P4 UNSUPPORTED (no admitted work order); Byte-Identity Guard ALIVE as spec only | Sequences the whole migration under the BYTE-IDENTITY GUARD (harness gates + TF 0-drift plan + cleanroom at every phase); P1 entry consumes M13 core ttl; phase failing the guard is BLOCKED, not failed | **BLOCKING** (master sequence; explicitly marked BLOCKING in-file) |
| [17-what-must-not-migrate.md](../../posh/v26.10.31/gaps/17-what-must-not-migrate.md) | M17 | PARTIAL (enumeration/tripwires from receipts; tripwires PLANNED, no gate wired) | Normative forbidden list: GraphLaw admission + ontology ttl (F1), turnstile/settlement/event-log (F2), pinned BLAKE3 kernel exception (F2b) — moving any is a charter violation; tripwires are the follow-up | — |

## Blocking set summary

- **M2** — wire-law census feeds P1 (core ttl lands above the registry).
- **M9** — neutral credential model gates Azure-dialect extraction.
- **M13** — two-layer admission split; phase-1 core ttl is the P1 entry input.
- **M16** — master sequence; its Byte-Identity Guard gates every phase.
