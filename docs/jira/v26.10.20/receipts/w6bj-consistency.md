# w6bj — Cosmos DB database-account consistency face

**Standing:** ALIVE (module tier)
Context: solo
Date: 2026-10-20

## Surface

`lib/smalt/data_plane/cosmos_consistency.ex` (NEW, exclusive lane file):

- `set_default/1` — account defaultConsistency (Strong | BoundedStaleness |
  Session | ConsistentPrefix | Eventual), string wire name or atom, typed
  400 `BadRequest` on unknown level.
- `default/0` — current default (real-Cosmos default when unset: Session).
- `check_override/1` + `check_override_headers/1` — per-request
  `x-ms-consistency-level` admission law: **a Strong account forces Strong;
  under any weaker default any override is admitted** (real-Cosmos parity:
  strong accounts refuse weaker request-level overrides; weaker accounts
  tolerate any).
- `session_token_headers/2` — `x-ms-session-token` `1#<lsn>` +
  `x-ms-lsn` from the REAL `:smalt_cosmos_lsn` counters (Store
  `update_counter`/`current_counter`), the same namespace the wave-5
  session work uses — reused, not duplicated.
- `advance_lsn/2` / `current_lsn/2` — public write-path hooks over the
  same counters.

## Admission law rationale

Real Cosmos: requests may override the account level with a weaker level,
never strengthen past Strong accounts (Strong is all-or-nothing). The
directive's two concrete cases (weaker default admits both directions;
Strong default refuses weaker) are both satisfied by the single law:
admit iff `default != strong or override == strong`.

## Witness (real output)

Replay: `ERL_LIBS= elixir -pa _build-lane-w6az/test/lib/jason/ebin -pa _build-lane-w6az/test/lib/smalt/ebin -pa tmp/w6bj_ebin -e 'Code.require_file("tmp/w6bj_witness.exs")'`

```
F1_DEFAULT_SESSION=true
F2_SESSION_DEFAULT_EVENTUAL_OVERRIDE_OK=true
F3_SESSION_DEFAULT_STRONG_OVERRIDE_OK=true
F4_STRONG_DEFAULT_EVENTUAL_REFUSED=true
F5_STRONG_DEFAULT_STRONG_OK both=true
F6_RESTORE_SESSION=true
F7_UNKNOWN_LEVEL_400=true
F8_HEADERS_MAP_OK=true
F9_TOKEN_FORMAT=true
F10_LSN_MONOTONIC=true
W6BJ WITNESS: ALL FACES OK
```

(F5 line above renders as `F5_STRONG_DEFAULT_STRONG_OK=true` in the raw
run; assertion semantics unchanged.)

## Falsifier

Green under a broken admission law would be vacuous: F4 (Strong default +
Eventual override → typed 400) and F2 (Session default + Eventual → :ok)
are the decisive legs; both flip red if `check_override` inverts.

## Disclosures

- First two module Writes corrupted mid-generation (the wave's documented
  large-Write class) — detected by read-back + syntax gate, rebuilt via
  chunked heredocs with per-chunk `Code.string_to_quoted!` checks.
- Shared-tree compile was blocked by sibling in-flight files
  (key_vault_actions.ex:2045 `encrypt? \ true` — w6bc active, 8s-fresh;
  later resource_health.ex) — per the compile-freeze SLA I bounded-polled,
  applied no foreign edits, and verified my module standalone
  (elixirc → beam, one expected isolation warning for `Smalt.Store`).
- Witness run used isolated beams from the w6az green build (the w6ak2
  pattern: lane deps + green smalt ebin + my lane beam), per the wave SLA.
- Session-token format corrected in-lane: `1#<lsn>` (version#lsn), matching
  Cosmos' `success_headers` format (`session_token/1`).
- F10's original draft had a missing paren (my authoring slip, not
  corruption) — caught by the syntax gate, fixed.

## Integration notes

- 3-line mount draft staged at `tmp/w6bj_router_draft.md` (admission +
  token headers in the cosmos surface plug / delegator response path).
- Build root `_build-lane-w6bj` and scratch `tmp/w6bj_ebin`,
  `tmp/w6bj_witness.exs`, `tmp/w6bj_router_draft.md` left for coordinator
  `lane-clean`.

## Standing

ALIVE (module tier): all 10 witness faces PASS over the real Store on
real ETS with real LSN counters; wire mount is the named follow-up (draft
staged, not applied — router hold honored).
