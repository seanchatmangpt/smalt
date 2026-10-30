# R10B — Policy split

window: v26.10.29 · lane: L13 (RETRY continuation) · ticket: T10 (policy leg) ·
status: ALIVE for the split subject — 19/19 policy-court tests green in the lane
gate; the gate's only 2 failures are the two pre-existing mcpt1 count fences
disclosed by r10a (fail identically at HEAD, generator-owned, not policy surface).

## Subject and diff

- Repo /Users/sac/smalt, branch main, HEAD at lane start 338caed. Working tree
  only — coordinator owns git transitions; no commits, no git commands by this
  lane.
- Ownership files, final state (1404-line monolith → facade + 5 concern
  modules, 1550 total lines):

- lib/smalt/policy.ex — 102 lines: moduledoc + 39 `defdelegate`, pure facade,
  zero own defs.
- lib/smalt/policy/store.ex — 69: lazy shadow-table law (`ensure_tables/0`,
  heir to `:init`), `reset_for_test/0`, `now_ms/0` clock.
- lib/smalt/policy/assignments.ex — 298: built-in role definitions, role
  assignments, `authorize?/3,4` + `scope_covers?/2` seam, policy assignments.
- lib/smalt/policy/eval.ex — 688: locks, policy + set definitions, `enforce/3`,
  verdicts, nc:/exr:/rs: receipt rows.
- lib/smalt/policy/exemptions.ex — 148: policyExemptions face, typed 400
  refusals, expiry sweep cascade.
- lib/smalt/policy/remediations.ex — 245: policyRemediations face, trigger
  re-eval, `rem:` receipts, `resource_state/1` snapshot reader.

- NEW: `lib/smalt/policy/` directory (5 modules). Kept: `Smalt.Policy` name,
  every external call site unchanged (39-delegate facade).
- Delegation coverage verified statically: every `Smalt.Policy.<fn>` referenced
  anywhere in lib/ or test/ (authorize?/3, enforce/3, list_locks/1,
  list_policy_assignments/1, list_policy_exemptions/1,
  list_policy_set_definitions/1, lock_blocks?/2, put_policy_assignment/3,
  role_definition/2, role_verbs/1) resolves on the facade; zero references to
  the new submodule names from outside lib/smalt/policy/.
- Internal seams (@doc false): `Store.ensure_tables/0`,
  `Assignments.scope_covers?/2`, `Eval.evaluate_assignment/2`,
  `Eval.lookup_definition_by_id/1` — submodules compose through these
  (Eval→Assignments.scope_covers?, Eval→Exemptions.exemption_active?,
  Remediations→Eval.evaluate_assignment/lookup_definition_by_id); behavior
  transplant is clause-order-preserving.

## Method (RETRY continuation — no restart)

The prior L13 attempt's 6 modules were already on disk (store/assignments/
exemptions/remediations at 21:59, eval.ex at 22:07) and the `Smalt.Policy`
defdelegate facade was already wired at 21:59 — the rate-limit death left the
tree in a landed state. This attempt: (1) verified the 6 modules compile in
_build-l13 (beams at 22:10 postdating every source at 21:59/22:07); (2) audited
delegation coverage and cross-module seam references — all resolve; (3) ran the
gate.

## Verification ladder (real output embedded)

1. Dev compile in lane build root (after the tree's in-flight freezes cleared):

```
$ MIX_BUILD_ROOT=_build-l13 MIX_ENV=dev mix compile
==> smalt
Compiling 51 files (.ex)
EXIT=0
```

2. Gate (ALIVE): `MIX_BUILD_ROOT=_build-l13 mix test` over the five policy-leg
court files:

```
$ MIX_BUILD_ROOT=_build-l13 mix test \
    test/integration/policy_enforcement_mode_witness_test.exs \
    test/integration/policy_assignments_test.exs \
    test/integration/policy_remediation_witness_test.exs \
    test/integration/tags_locks_test.exs \
    test/internal/mcpt1_dispatch_court_test.exs

Finished in 0.2 seconds (0.00s async, 0.2s sync)

Result: 29/31 passed
Failed: 2 tests
GATE_EXIT=2
```

Per-file inventory (31 = 2+5+3+9+12, all five files fully executed):

| court file | tests | result |
|---|---|---|
| test/integration/policy_enforcement_mode_witness_test.exs | 2 | PASS |
| test/integration/policy_assignments_test.exs | 5 | PASS |
| test/integration/policy_remediation_witness_test.exs | 3 | PASS |
| test/integration/tags_locks_test.exs | 9 | PASS |
| test/internal/mcpt1_dispatch_court_test.exs | 12 | 10 PASS, 2 pre-existing fails |

3. The only 2 failures (verbatim from the gate log):

```
1) test descriptor capability count equals TTL capabilityId count (drift fence)
   (Internal.MCPT1DispatchCourtTest)
   code:  assert ttl_count == 37
   left:  40
   right: 37

2) test tools/list includes all five wave-6 tools (Internal.MCPT1DispatchCourtTest)
   code:  assert length(resp["result"]["tools"]) == 37
   left:  40
   right: 37
```

Both in the MCP dispatch court, zero in any policy court. r10a (same window)
proved via HEAD differential that these two fail identically at HEAD — the
court's hardcoded 37 predates the T-03 (v26.10.28) eventgrid trio that landed
the 40-tool surface; failing inputs are generator-owned (mcp_descriptor.ex,
byte-identical to HEAD per r10a §generator-owned surfaces).

## Pre-existing vs session-introduced

- Pre-existing (not session-introduced): the two mcpt1 count fences above —
  identical assertions and left/right values as r10a's disclosure.
- Session-introduced failures: none. Every policy court passes (19/19).

## Compile-freeze disclosures (wave interference observed, zero cross-lane edits by L13)

All freezes self-repaired by their owners inside the SLA window; this lane
bounded-polled the compile exit code (deadline-checked, no sleeps in tests, no
cross-lane edits, no unblock fixes needed):

- `lib/smalt/identity/saml_slo.ex` — broken in dev compile ~22:41-22:44
  (duplicated orphan verify block referencing `signature` out of scope); owner
  repaired within ~3 min.
- `lib/smalt/egress_router.ex` — broken 22:52:04 → fixed by owner by 23:02:24
  (COMPILE_OK attempt=19 of the lane's bounded poll).
- `lib/smalt/identity/oidc_authorize.ex` — broken ~22:58-23:01 (sigil syntax
  error at line 239); owner repaired within the window.
- Transient, disclosed for diff-attributability: during the gate's test-env
  compile the shared tree momentarily served a `Smalt.Network.Dnszone` vs
  `Smalt.Network.DnsZone` casing mismatch (beam loader error + Spark verify
  exception, gate log 23:06:45) from concurrent lane edits; the gate completed
  normally and no policy test was affected. Also at 23:04:19 the shared `deps/`
  dir was mid-`mix deps.get` by another lane when gate attempt 2 checked dep
  availability (transient "dependency is not available" abort); attempt 3 ran
  clean on the identical command. No dep was added or removed by this lane.

## Standing

ALIVE for the split subject: the `Smalt.Policy` facade + 5-module split
compiles clean in the lane build root and passes every policy court (19/19
policy-leg tests). Gate total is 29/31 with the only 2 failures being the
pre-existing mcpt1 count fences r10a already registered (owner of the mcpt1
court needs the 37→40 constant refresh — test edits are out of every lane's
hands). The lazy shadow-table law, heir-to-:init, the nc:/exr:/rem:/rs:
receipt families, and all wire envelopes survived the transplant unchanged;
external call sites untouched (facade-only delegation).
