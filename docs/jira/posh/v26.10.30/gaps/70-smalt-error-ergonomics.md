# GAP-70: SMALT-side typed-failure ergonomics audit

Complement to GAP-57 (courtroom-platform-az half,
docs/jira/posh/v26.10.30/gaps/57-error-ergonomics.md). Lane, 2026-10-30.
Scope: every typed failure string on the smalt side of the posh surface:
`justfile.d/57+58+59`, the posh gate scripts, `posh/internal` Go error
strings, and `adapters/terraform-provider-smalt` diagnostics.

ALIVE claim: table compiled from real greps/reads of the working tree this
session; the 4 disclosed message edits are on disk and witnessed below.

## Failures runbook

### Family A — justfile.d/57-tf-provider.just ([TF-*])

| # | Message (emitted verbatim) | Where | Cause | Fix in-message? | Status |
|---|---|---|---|---|---|
| 1 | `[TF-PREREQ-FAIL] tool not on PATH: $t — install: brew install $t` | 57:36 | missing tool | yes (brew cmd) | PASS |
| 2 | `[TF-ARCHIVED] {{SMALT_TF_DIR}}/mix.exs absent — Elixir spike tree archived to tmp/...tar.gz; active implementation: adapters/terraform-provider-smalt (GA court: just posh-court, 58-posh.just)` | 57:46 | archived spike tree invoked | yes (names active impl + court) | PASS (model row) |
| 3 | `[TF-BUILD-FAIL] mix escript.build exited nonzero in {{SMALT_TF_DIR}}` | 57:51 | escript build failed | WAS no → FIXED: now `— fix the escript source in {{SMALT_TF_DIR}}, never the built artifact` | CLOSED (disclosed edit) |
| 4 | `[TF-INSTALL-FAIL] $s missing in {{SMALT_TF_DIR}} — land it first` | 57:66 | install script absent | yes ("land it first") | PASS |
| 5 | `[TF-INSTALL-FAIL] $s exited nonzero` | 57:67 | install script failed | no (script's own stderr precedes) | GAP-minor |
| 6 | `[TF-COURT-FAIL] healthz never answered within 60s — witness: just kind-status` | 57:96 | backend never came up | yes (witness cmd) | PASS |
| 7 | `[TF-COURT-FAIL] scripts/provider_court.sh missing ... — land it first` | 57:100 | court script absent | yes | PASS |
| 8 | `[TF-COURT-FAIL] provider_court.sh exited nonzero` | 57:102 | court failed | no (court's own output precedes) | GAP-minor |

### Family B — justfile.d/58-posh.just ([POSH-*])

| # | Message | Where | Cause | Fix in-message? | Status |
|---|---|---|---|---|---|
| 9 | `[POSH-PREREQ-FAIL] tool not on PATH: $t — install: brew install $t` | 58:72 | missing tool | yes | PASS |
| 10 | `[POSH-GENERATE-FAIL] ggen not on PATH — install per ggen-marketplace README` | 58:92 | ggen missing | yes | PASS |
| 11 | `[POSH-GENERATE-FAIL] invariant gate over {{SMALT_POSH_PACK}} failed (exit $?)` | 58:105 | graph invariant violation | partial (gate's own typed rows precede; exit 1=violation / 2=infra documented at 58:408) | PASS |
| 12 | `[POSH-GENERATE-FAIL] ggen sync run exited nonzero over {{SMALT_POSH_PACK}}` | 58:110 | ggen sync failed | no (ggen stderr precedes) | GAP-minor |
| 13 | `[POSH-GENERATE-FAIL] could not parse ggen sync JSON` | 58:114 | sync output drift | no | GAP (close: name the sync log path or rerun cmd) |
| 14 | `[POSH-GENERATE-FAIL] ggen sync rendered 0 rows (written+skipped empty) - KD-POSH-5 regression` | 58:116 | zero-row render | yes (KD id named) | PASS |
| 15 | `[POSH-GENERATE-FAIL] copy-out of pipeline modules failed` / `of generated Go adapters failed` | 58:126,129 | cp failed | no | GAP-minor (close: name src→dst pair) |
| 16 | `[POSH-GENERATE-FAIL] mix compile failed over rendered pipeline modules - fix the template, not the output` | 58:137 | rendered code won't compile | yes (model phrasing) | PASS |
| 17 | `[POSH-VET-FAIL] golangci-lint exited nonzero in $d` | 58:161 | lint findings | partial (dir named; findings precede) | PASS-minor |
| 18 | `[POSH-ALLOC-TEST-FAIL]/[POSH-BUILD-FAIL] ... — land POSH-001/POSH-004 first` | 58:171-189 | substrate missing | yes | PASS |
| 19 | `[POSH-FENCE-TEST-FAIL] posh/internal/{egress,config} missing — land POSH-001 first` | 58:201 | fence packages missing | yes | PASS |
| 20 | `[POSH-FENCE-TEST-FAIL] go test -race exited nonzero over egress+config fence packages` | 58:204 | fence test failed | partial (test output precedes) | PASS-minor |
| 21 | `[POSH-INSTALL-FAIL] $bin not built — run: just posh-build` | 58:214 | binary not built | yes (exact cmd) | PASS (model row) |
| 22 | `[POSH-SMALT-WIRE-FAIL] STS bearer mint at $arm/...` / `STS returned empty access_token` / `GET resourcegroups` / `GET containerApps` / `resourcegroups empty — wire did not materialize` | 58:254-265 | wire probe failed | partial: probe names the step; empties name consequence | PASS-minor |
| 23 | `[POSH-SMALT-WIRE-FAIL] X-Smalt-Receipt-Turnstile header absent ... — turnstile stamp missing; fail-closed` | 58:274 | stamp missing | yes (names header + policy) | PASS |
| 24 | `[POSH-SMALT-WIRE-FAIL] unreceipted mutating delta NOT refused (got $fence_code, want 400) — turnstile fence not enforced; fail-closed` | 58:280 | fence vacuous | yes (got/want + consequence) | PASS |
| 25 | `[POSH-SMALT-WIRE-FAIL] fence 400 body is not a typed AdmissionRefused envelope; fail-closed` | 58:282 | envelope drift | yes | PASS |
| 26 | `[POSH-COURT-PRE] FAIL kind ladder exited $rc — witness: just kind-status` / `metadata anchor never answered 200 within 60s — witness: just kind-status` | 58:359,376 | kind plane down | yes (witness cmd) | PASS |
| 27 | `[POSH-COURT] result: $pass/9 PASS, $skip SKIP, $fail FAIL` + per-stage `stage N "FAIL ... exited $rc (…)"` lines | 58:301,408-519 | stage failed | partial (stage number + rc; per-stage sub-script output precedes) | PASS-minor |

### Family C — justfile.d/59-posh-ops.just ([POSH-OPS-*])

| # | Message | Where | Cause | Fix in-message? | Status |
|---|---|---|---|---|---|
| 28 | `[POSH-OPS-UP-FAIL] build failed` | 59:51 | posh build failed | no (make output precedes) | GAP-minor (close: `— log follows above from make -C posh build`) |
| 29 | `[POSH-OPS-UP-FAIL] lock $LOCK held >3s by another posh-up` | 59:69 | concurrent posh-up | yes (names holder) | PASS |
| 30 | `[POSH-OPS-UP-FAIL] old pid $OLD_PID ignored SIGTERM within 5s — refusing to double-spawn` | 59:89 | stale membrane | yes (names pid + policy) | PASS |
| 31 | `[POSH-OPS-UP-FAIL] posh exited during boot — log: $STATE/posh.log` | 59:109 | boot crash | yes (log path) | PASS |
| 32 | `[POSH-OPS-UP-FAIL] socket $SOCK did not appear within 10s — log: $STATE/posh.log` | 59:115 | listener never bound | yes | PASS |
| 33 | `[POSH-OPS-DOWN-FAIL] pid $PID survived SIGKILL within 2s (stuck in uninterruptible wait?)` | 59:159 | unkillable pid | yes (names hypothesis) | PASS |

### Family D — gate scripts

| # | Message | Where | Cause | Fix in-message? | Status |
|---|---|---|---|---|---|
| 34 | `[SLA-REFUSE] gate '$gate' has no registered SLA clock — runner refuses (exit 2)` | scripts/posh_sla.sh:41 | unregistered gate | yes (names contract) | PASS |
| 35 | `[SLA-REFUSE] gate '$gate': neither timeout nor gtimeout on PATH — a clock that cannot be set is an SLA-less gate (exit 2)` | posh_sla.sh:46 | no timeout binary | yes (names defect) | PASS |
| 36 | `[SLA-RED] $gate exceeded ${sla}s — killed, RED (timeout counts as fail)` | posh_sla.sh:61 | SLA breach | yes (policy stated) | PASS |
| 37 | `[INVARIANT-GATE-SKIP] <pack file> missing — pack not landed; loud skip` | scripts/posh_invariant_gate.py:17 | pack absent | yes | PASS |
| 38 | `[INVARIANT-GATE-FAIL] cannot parse graph: {e}` | posh_invariant_gate.py:25 | unparseable turtle | WAS no → FIXED: now `— re-render with: just posh-generate` | CLOSED (disclosed edit) |
| 39 | `[INVARIANT-GATE-FAIL] no queries/invariant_*.rq found — vacuous gate` | posh_invariant_gate.py:30 | zero queries | yes | PASS |
| 40 | `[COMPAT-PIN-SKIP] source missing: {p}` / `@api_versions map not found/empty` / `no APIVersion constants found under {PROVIDER}` / `pin row unparseable: {what} in {path}` | scripts/compat_pin_check.py:54-165 | structural drift | yes (paths named) | PASS |
| 41 | `[COMPAT-PIN-FAIL] {f_}` — bare file list | compat_pin_check.py:226 | law violated in file | no (file only, no law named) | GAP (close: emit the CHECKED_LAWS key + expected vs derived) |
| 42 | `[POSH-COVERAGE-FAIL] Missing {server_test}` / `Resource {r} not registered in provider inventory test` / `... not accounted for in KNOWN_DIVERGENCES.md` | scripts/posh_coverage.py:48-80 | coverage cell missing | yes (names exact file/cell + ledger) | PASS |
| 43 | `[POSH-MERGE-FAIL] unknown arg $1` | scripts/posh_merge_allowlist.sh:20 | bad invocation | WAS no → FIXED: now carries usage line | CLOSED (disclosed edit) |
| 44 | `[POSH-MERGE-FAIL] --fragment and --config required` | posh_merge_allowlist.sh:23 | missing args | partial (arg names = usage) | PASS-minor |
| 45 | `[POSH-MERGE-FAIL] fragment entry '$h' still contains / : @ or space — REPLACE normalization leaked (graph defect, fail loud)` | posh_merge_allowlist.sh:36 | normalization leak | yes (cause class) | PASS |
| 46 | `[POSH-MERGE-FAIL] operator posh.yaml egress_allowlist entry '$h' is NOT in the graph-projected set — widening (graph is the ceiling; narrow only)` | posh_merge_allowlist.sh:68 | allowlist widening | yes (names the law) | PASS (model row) |
| 47 | `MISMATCH: resource pin $pin_r != registrations $reg_r` (+ datasource, KD-prose variants) | scripts/posh_surface_crosscheck.sh:25-33 | count divergence | partial (both counts named, no tag, no doc pointer) | GAP-minor |
| 48 | `CROSSCHECK FAIL` (bare final line) | posh_surface_crosscheck.sh:44 | ≥1 mismatch above | WAS no → FIXED: now `— mismatch rows above name the divergent count; fix the pin/KD prose, never posh_coverage.py output` | CLOSED (disclosed edit) |
| 49 | `[DOD-FAIL] no requirements matched (section={s})` | scripts/dod_check.py:75 | wrong --section | partial (section named, no valid-sections list) | GAP-minor |
| 50 | `[DOD-FAIL] {n} alive-row FAIL(s) — honest baseline recorded` | dod_check.py:96 | alive rows failing | yes (policy stated) | PASS |

### Family E — scripts/doctor.py + doctor_dod.py

| # | Message | Where | Cause | Fix in-message? | Status |
|---|---|---|---|---|---|
| 51 | `DiagnosticFailure(id, msg, hint-cmd, fix=callable)` — every failure carries a prescription hint and optional --fix callable | scripts/doctor.py:164-525 | per-check | yes (third arg is a copy-pastable cmd, e.g. `bash scripts/gen_dev_cert.sh`, `chmod 600 ...`) | PASS (model row — best in estate) |
| 52 | `dev-certs-missing: cert minter not found at {CERT_SCRIPT}` | doctor.py:207 | script absent | partial (inspect cmd given) | PASS |
| 53 | `FAIL  {msg}` (plain, doctor_dod.py:105) | scripts/doctor_dod.py:105 | DoD row failed | partial (msg from row itself) | PASS-minor (court-internal) |

### Family F — posh Go internal

| # | Message | Where | Cause | Fix in-message? | Status |
|---|---|---|---|---|---|
| 54 | `MembraneError{Code: TRANSPORT\|UPSTREAM\|DEADLINE\|REFUSED_EGRESS, Op, Message}` — string form `op: code: msg: cause` | posh/internal/api/errors.go:56-127 | wire/transport faults | protocol codes, not prose; codes documented in errors.go doc comment | PASS (typed, machine-readable) |
| 55 | `REFUSED(egress-imds): link-local/IMDS/unspecified address %s forbidden` | posh/internal/egress/egress.go:139 | IMDS probe | yes (policy named) | PASS |
| 56 | `REFUSED(egress-allowlist): host %q not in posh.yaml allowlist` / `redirect to unadmitted host %q` | egress.go:153,176 | unadmitted host | yes (fix implied: add to posh.yaml allowlist) | PASS |
| 57 | doctor findings with `PrescriptionCmd` (e.g. `posh doctor --fix  # check for hung processes or restart membrane with 'just posh-restart'`, `ulimit -n 4096  # or inspect lsof -p $(pgrep posh)`, `kubectl edit deployment posh-sidecar  # increase cpu.limits...`) | posh/internal/doctor/{doctor,telemetry}.go | per-diagnostic | yes — every finding ships a copy-pastable fix command | PASS (model row) |

### Family G — adapters/terraform-provider-smalt

| # | Message | Where | Cause | Fix in-message? | Status |
|---|---|---|---|---|---|
| 58 | `UNSUPPORTED(attr roundtrip/wire face): <resource> <attr>` warns + `refuseFabricatedValue` typed diag naming `TFPOSH_ALLOW_FABRICATED_IDS=1` escape hatch | resource_remaining_v1.go:479-1582, resource_container_app_environment.go:512 | computed attr cannot roundtrip from smalt ARM face | yes (env-var escape in adjacent diag detail; README:92 documents) | PASS |
| 59 | 400 `MissingApiVersionParameter` / `InvalidApiVersionParameter` — "The api-version 'X' is invalid. The latest supported api-version for '<type>' is 'Y'." | lib/smalt/arm_gateway/providers/container_apps_router.ex:421-431 (+ resource_providers.ex:809, activity_log.ex:188, egress_router.ex:2212) | wrong api-version | yes (latest supported named = the fix) | PASS (ARM-parity) |
| 60 | GAP22-3 import diags: `Import ID "X" is not a valid <type> ID: expected the ARM segment "M" in the ID path. Wrong-resource IDs are refused rather than silently adopted (GAP22-3).` (+ forbid-segment variant; + bare-name-without-subscription variant naming the exact full id shape to import) | adapters/.../import_state.go:29,45; resource_resource_group_tf.go:231-243 | wrong-resource import id | yes (expected segment + law named) | PASS (model row) |

## Disclosed message edits (4, message-string-only, no logic touched)

1. `justfile.d/57-tf-provider.just:51` — [TF-BUILD-FAIL] now names the fix
   (fix the escript source, never the artifact).
2. `scripts/posh_invariant_gate.py:25` — cannot-parse FAIL now names
   `just posh-generate` as the re-render cmd.
3. `scripts/posh_merge_allowlist.sh:20` — unknown-arg FAIL now carries the
   usage line.
4. `scripts/posh_surface_crosscheck.sh:44` — CROSSCHECK FAIL now points at
   the mismatch rows above and forbids fixing the coverage output.

Non-vacuity: `bash scripts/posh_merge_allowlist.sh --bogus x` → exit 1 with
the new usage line; `python3 scripts/posh_invariant_gate.py` → clean run
over the real pack graph; `bash scripts/posh_surface_crosscheck.sh` →
CROSSCHECK OK; root `just --justfile Justfile --list` parses exit 0 with the
57 edit in place. (Loading 57 standalone fails on a pre-existing
`_check_kind_tools` dependency-resolution quirk — defined in 52-kind.just,
resolves under the root import; not session-introduced.)

## Gap count

Honest: **~61 messages inventoried, 8 gap rows open** (5, 8, 12, 13, 15,
41, 47, 49 — rows 28/44/50/53 graded PASS-minor where surrounding output
carries the reason), 4 closed this session. All open rows are one-line
message edits; nothing needs new machinery. Family-level: the posh Go side
is the strongest surface (every doctor finding ships a PrescriptionCmd);
the justfile GENERATE/INSTALL bare-exit lines are the weakest.

Worst offenders remaining:

1. Row 41 compat_pin_check bare file-list FAIL — gate names the file, not
   the violated law.
2. Row 13 could-not-parse-sync-JSON — infra failure with no rerun cmd.
3. Row 49 DOD-FAIL section mismatch — no valid-sections list.
4. Row 47 surface-crosscheck MISMATCH lines lack a [XCHECK-*] tag (only
   the final line carries remediation now).
5. Rows 15/5/8/12 bare `exited nonzero` wrappers — subordinate output
   precedes, but the wrapper itself carries zero bits.

## Cross-reference

- Courtroom-platform-az half: gaps/57-error-ergonomics.md (same repo,
  23 rows, 3 disclosed edits). That estate's model row is
  guard_local_apply REFUSE heredoc; this estate's model rows are doctor.py
  DiagnosticFailure (hint+fix per row), posh doctor PrescriptionCmd, and
  the GAP22-3 import diags.
