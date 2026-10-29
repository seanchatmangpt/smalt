# Receipt — WPS-EXP4: EXPL-4 Web PubSub wirefront repairs

**Standing**: ALIVE
**Context**: solo
**Date**: 2026-10-22
**Lane**: WPS-EXP4 (repo `/Users/sac/smalt`, canonical checkout, build root `_build-wpsx4`)

## Scope

EXPL-4 findings F1 / F6 / F5 against `lib/smalt/webpubsub/` (lane-owned files).

## F1 — token verify fail-closed (`lib/smalt/webpubsub/token.ex`)

`verify/2` now fails closed on absent claims: aud/exp/nbf/sub are all
essential (joken 2.7 skips validation for absent claims, so presence is
enforced by the `@essential_claims` guard after `verify_and_validate/3`),
and the `sub` claim validator refuses the empty-string principal. No-aud /
no-exp / no-nbf / no-sub / empty-sub tokens verify `:error`; the aud claim
is bound to the hub (`/webpubsub/hubs/<hub>`), so a hub-A token is refused
on hub B.

## F6 — dispatch fallthrough (`lib/smalt/webpubsub/socket.ex`)

`dispatch/3` has a catch-all clause: a known type with a missing required
key (`sendToGroup` without `group`, `event` without `event`, ...) answers
the protocol error frame (`ack success=false` with `error.name
"InvalidMessage"` when ackId'd, `{"type":"error"}` otherwise) instead of a
FunctionClauseError kill. **leaveGroup asymmetry note (per dispatch)**: the
real service gates leaveGroup under the same `webpubsub.joinLeaveGroup`
role as joinGroup; the face previously allowed un-permissioned leaves. The
landed repair permission-checks leaveGroup symmetric to joinGroup (Forbidden
ack on missing role) — this closes the asymmetry rather than registering it.

## F5 — unauthenticated server faces (`lib/smalt/webpubsub/router.ex`)

Chose the **register** branch: the open server faces (generateToken /
negotiate / groups-send, plus the default all-groups wildcard role mint)
are registered as **KD-169** in `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md`
(deliberate loopback-open posture, air-gap law; close condition = a
server-credential gate with witness receipt). No router edit; no new KD row
minted (KD-169 already covers F5 — minting a second row would double-book
the surface). Router keeps its existing `# KD-COVERS: KD-166` tag; the
row's own text notes a gate landing in router.ex would carry
`# KD-COVERS: KD-169`.

## Court

`test/internal/wps_exp4_court_test.exs` — 10 tests, real compiled modules,
real Joken HS256, real Socket dispatch (no mocks, no sleeps).

```
$ MIX_BUILD_ROOT=_build-wpsx4 bash scripts/fast_test.sh test/internal/wps_exp4_court_test.exs
Current time: 1792666429

.........
Finished in 0.06 seconds (0.00s async, 0.06s sync)

Result: 10 passed
[03:53:49] wall: 3s (build root: _build-ft-923b4ce8)
```

Regression court on the sibling AZ-5 wire face (real RFC6455 client over
real TCP through Bandit):

```
$ MIX_BUILD_ROOT=_build-wpsx4 bash scripts/fast_test.sh test/internal/webpubsub_test.exs
.......
Finished in 1.9 seconds (0.00s async, 1.9s sync)

Result: 7 passed
[03:56:51] wall: 154s (build root: _build-ft-a538002e)
```

## Falsifier coverage

* no-aud token → `:error` (F1 falsifier)
* no-exp token → `:error` (never-expires face closed)
* no-nbf / no-sub → `:error`
* empty sub → `:error`
* hub-A token on hub B → `:error`, same token on hub A verifies
* mint/verify roundtrip unchanged
* sendToGroup missing `group` → InvalidMessage error frame, no raise
* event missing `event` → InvalidMessage error frame
* invalid frame then valid permitted join — socket stays alive, registry
  sees the join (real `Smalt.WebPubSub.join/3` + cleanup `leave/3`)
* leaveGroup without permission → Forbidden ack (join/leave symmetry)

## Notes

* F1/F6 repairs were already present in the working tree (landed via the
  v26.10.21/22 tick checkpoints, commits 5f1ddc85/6e3e77eb lineage); this
  lane verified them against the falsifiers, closed the remaining gap
  (dedicated court file), and receipts the standing.
* No git state commands run by this lane; coordinator owns transitions.
