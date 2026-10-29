# GL-10 Skeptic Court — Law-Governance Wave (GL-1..8) Adversarial Audit

- **Date**: 2026-10-21
- **Lane**: GL-10 (skeptic, OTP-29)
- **Subject**: `lib/smalt/powl2/{executor,law_compiler,andon,andon_wire}.ex` at on-disk state 2026-10-21 15:22 UTC-7
- **Context**: solo
**Standing**: SUSPECT — two KILL-class defects proven (F1 seam unreachable/unguarded bypass, F2 exclusion evasion); 4 advisory findings; otherwise fail-closed

## Method

Adversarial audit per the task contract: bypass attempts against the GL-1
guard seam over real ETS/DETS (no mocks), representation fuzzing of the
exclusion invariant, digest collision attempts, formatter-hostile fail-closed
probes. The wave's files landed mid-audit (3 mid-write states observed);
courts were re-targeted to each on-disk state and the final run pins the
state at 15:22.

## Command output

```
$ PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-gl10 mix test test/integration/graphlaw_skeptic_court.exs
.................
Finished in 0.4 seconds (0.00s async, 0.4s sync)

Result: 27 passed
```

Court: `/Users/sac/smalt/test/integration/graphlaw_skeptic_court.exs` (27 tests).

## Per-claim verdicts

### Claim 1 — can a violating transition mutate ETS through any path?

**KILLED (F1, structural bypass).** The guard seam's model-level surfaces are
unreachable or silently dropped:

- `AST.Transition` declares only `[:id, :label, op: :tau]` and
  `AST.PartialOrder` `[:children, order]` (reticle.ex:33-39) — there is NO
  `law_guard`/`repair`/`law_module`/`repair_edges` struct field, while the
  executor reads them via `Map.get` and `struct/2` silently drops unknown
  keys. A caller setting `law_guard` through the documented construction path
  gets an **unguarded, mutating** transition. Court: F1 test — op mutates a
  real ETS counter 0→1 with zero refusals, `:ok` completion.
- `Reticle.admit/1` returns `:ok` for models with no guard at all (F1b) —
  admission never requires a guard, so the seam is optional-by-construction
  and the law layer is dead code on the typed path.
- Overlay maps (`%{__struct__: AST.Transition, ...}` with extra keys) DO
  reach the seam — meaning the enforcement path only works for maps that
  Gate-1's struct-typed API never produces. The seam is inverted: typing
  drops the law; dropping the typing restores it.

Everything else in C1 held fail-closed (real ETS counts stayed 0 in all
cases): guard refusal skips the op; raise/exit/throw in a guard → typed
`:guard_raised` refusal; garbage verdict → `:bad_guard_verdict`; LawCompiler
`{:violation, _, _}` vocabulary now rides through typed; malformed guard
tuple → `{:bad_op, _}` failure; malformed law_guard (non-fun) → typed
`:guard_raised`; invalid law_module → untyped function_clause exit before any
op (finding F4a); invalid law_module on the overlay path kills the frontier
Task with no orchestration verdict at all; ChoiceGraph routing cannot bypass
a guarded target node; repair edge never re-runs the violating op (violation
table 0, repair table 1).

### Claim 2 — exclusion invariant across term representations

**KILLED (F2, evasion).** `notEquals` compares with Elixir `==` and no
representation normalization (`law_compiler.ex` `check/2` `not_equals`
clause):

- `%{"actor" => "alice", "approver" => :alice}` → `:ok` — self-approval
  **evades** the exclusion (atom vs binary spells the same principal).
- Different struct types carrying the same id (`%Principal{id: "p1"}` vs
  `%PrincipalAlt{id: "p1"}`) → `:ok` — evasion across struct types.
- Safe direction: `7` vs `7.0` → violation (== crosses int/float), so the
  equality is representation-sensitive in BOTH directions: over-strict for
  int/float, over-permissive for atom/binary/struct.

Fix direction: normalize both sides through `to_string/1` (or a typed
principal identity) before comparing; document the class used.

### Claim 3 — do two different violations ever produce identical digests?

**HELD (no digest collision), one advisory (F3).** sha256(term_to_binary) is
injective at the term level: representation-distinct contexts (`1`, `1.0`,
`"1"`, `:alice` vs `"alice"`) mint 4 distinct digests. Distinct rules over
the same context share the context digest by design and are separated by
`andon:refusalId` + `andon:failedConstraint`. Advisory F3: `refusalId`
commits `{session, rule_id, context_digest}` and omits `ts` — two distinct
refusal EVENTS (same rule/context/session, different wall clock) collapse to
one id. Bodies still differ (prov:atTime) but within the same wall-clock
second the truncation makes the full JSON-LD byte-identical, so an audit
consumer keying on refusalId (+body) cannot distinguish two refusals in one
second. Add ts (or a refusal nonce) to the id.

### Claim 4 — is the ANDON path fail-closed when the formatter crashes?

**HELD.** The executor's refusal path never calls the GL-3 formatter
(record_andon mints its own receipt map), so a crashing formatter cannot
flip a refusal: proven by formatting a refusal while a hostile input raises
FunctionClauseError in the formatter — the run still refuses typed
(`{:powl2_andon, :t9, "r", "d"}`), op unmutated. The wire face fails closed
typed: unknown/partial shapes → `{:error, :unwirable_shape}`; the HTTP and
AMQP faces agree on the refusal facts (rule_id, digest, diagnostic) modulo
live-minted ts.

Advisory findings (F4 family):

- **F4a**: invalid law_module (`%{}` on the overlay path) kills the frontier
  Task with an untyped `{:function_clause, _}` exit and NO orchestration
  verdict reaches the caller — fail-closed by crash, untyped by channel.
- **F4b IRI injection**: hostile session/rule ids ride URN positions
  unescaped — `<urn:smalt:andon:s"pace:rule"x:...>` — illegal N-Triples and
  malformed URNs; the same raw pair rides the JSON-LD refusalId.
- **F4c repair masks refusal**: with a repair edge, a run containing a
  violated law returns `:ok` / `{:orchestration_completed, ...}`; the
  violation is only visible in `receipt.steps` and the DETS andon row. The
  law held (op never ran), but the top-level status reads :completed —
  audit consumers reading only the status bit see a clean run.

## Cross-lane events (disclosed)

- law_compiler.ex landed mid-write twice; GL-9's disclosed compile-freeze
  unblock (token-unwrap `local_name` clause, marked in source) closed the
  untyped-crash seam defect this court had pinned earlier — the current
  state compiles the canonical TTL typed (pinned by court).
- Two shared-tree compile freezes by other lanes (file_share.ex guard
  macros, wasm/worker.ex catch_exit) were waited out under the 10-min SLA;
  both owners fixed them. No unblock fixes applied by this lane.

## Files

- Court: `/Users/sac/smalt/test/integration/graphlaw_skeptic_court.exs`
- Subjects: `/Users/sac/smalt/lib/smalt/powl2/{executor,law_compiler,andon,andon_wire}.ex`
- Build root: `_build-gl10` (lane lease; reclaim at integration)
