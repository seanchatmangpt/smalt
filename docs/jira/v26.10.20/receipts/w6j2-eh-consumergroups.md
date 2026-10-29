# W6J2 — Event Hubs Consumer Groups Close-Out (w6j witness executed)

**Standing:** ALIVE (module tier, real Plug dispatch over real Store+engine)
Context: pair (close-out of lane w6j; single-lane execution)
Date: 2026-10-20

## What this lane did

Lane w6j landed `lib/smalt/arm/eh_consumergroups.ex` (224 lines: consumer-group
CRUD + `$default` immutability + engine registration) and staged
`tmp/w6j_witness.exs` but never executed it (rolling compile churn, then the
disk wall). This lane executed it, fixed two witness-side defects (no lib/
changes), and minted this receipt.

## Witness execution

Replay command (this session, exit 0, full-tree compile GREEN on fresh root
`_build-lane-w6j2` — the w6R split compiles):

```
MIX_ENV=test MIX_BUILD_ROOT=_build-lane-w6j2 mix run --no-start tmp/w6j_witness.exs
```

Real output (complete result lines, single authoritative run, exit 0;
full transcript `tmp/w6j2_witness.out`):

```
NS_PUT_OK=true
HUB_PUT_201=true
PUT_201=true
META_ECHO=true
ENGINE_EXISTS=true
REPUT_200=true
CREATED_TS_PRESERVED=true
CONFLICT_409=true
CONFLICT_CODE=true
DEFAULT_PUT_400=true
DEFAULT_PUT_CODE=true
GET_404=true
GET_404_CODE=true
DEFAULT_DEL_400=true
DEFAULT_DEL_CODE=true
LIST_200=true
LIST_HAS_DEFAULT_ONCE=true
DELETE_200=true
ENGINE_GONE=true
GET_AFTER_404=true
DELETE_MISS_404=true
W6J WITNESS DONE
```

## Verdict per leg (21/21 PASS, 0 FAIL)

| Leg | Verdict | Evidence line (all `=true`) |
|---|---|---|
| namespace PUT face | PASS | NS_PUT_OK |
| hub PUT | PASS | HUB_PUT_201 |
| CG create | PASS | PUT_201 |
| metadata echo | PASS | META_ECHO |
| engine registration | PASS | ENGINE_EXISTS |
| idempotent re-PUT | PASS | REPUT_200 |
| created-time preserve | PASS | CREATED_TS_PRESERVED |
| duplicate PUT | PASS | CONFLICT_409 + ConsumerGroupConflict |
| PUT $default | PASS | DEFAULT_PUT_400 + ConsumerGroupNotCreatable |
| GET unknown | PASS | GET_404 + ConsumerGroupNotFound |
| DELETE $default | PASS | DEFAULT_DEL_400 + ConsumerGroupNotDeletable |
| LIST carries $default once | PASS | LIST_200 + LIST_HAS_DEFAULT_ONCE |
| DELETE cg → engine gone | PASS | DELETE_200 + ENGINE_GONE |
| GET after delete | PASS | GET_AFTER_404 |
| DELETE unknown | PASS | DELETE_MISS_404 |

## Witness-side fixes (no lib/ changes)

1. `Smalt.Store.init/0` → `init([])` (arity drift since the script was staged).
2. NS-PUT leg premise updated to the post-KD-111 sync face (the run with the
   raw-status probe confirmed the face answers in the 200/201 family; the
   final script asserts `NS_PUT_OK`).

## Falsifier

Green under a broken consumer-group engine (e.g. `$default` deletable, dup
admitted, engine not torn down on DELETE) would be vacuous. The ENGINE_GONE /
CONFLICT / $default-immutability legs are the load-bearing non-vacuity legs.

## Notes

- Full-tree `mix compile` was GREEN on this fresh root — first observed
  green since the w6R split landed; delegator warnings in the log are
  pre-existing unused-variable warnings in KvRoutes (not errors).
- No git operations. Scratch: tmp/w6j2_witness.{out,err}.
