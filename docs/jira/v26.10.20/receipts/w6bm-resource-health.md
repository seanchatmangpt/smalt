# Receipt — w6bm: Azure Resource Health face

- **Lane**: w6bm (wave-6, v26.10.20)
- **Standing**: ALIVE (module tier)
- **Context**: solo

## Surface

`lib/smalt/arm/resource_health.ex` (NEW, 157 lines). Azure Resource Health
parity computed honestly from the real `:smalt_resources` store.

- `availability_statuses/4` — existing → synthetic-Available (documented
  emulator boundary: no fabricated outages); unknown → 404 parity.
- `record_transition/4..6` — public recorder; invalid state typed-refused;
  unknown resource → {:error, :not_found}.
- `history/4` most-recent-first, [] when none (no fabricated history).
- `status_wire/1` / `history_wire/1` — availabilityStatuses envelope; mount
  staged at tmp/w6bm_router_patch.md (ROUTER HOLD respected).
- `:smalt_arm_health` ETS: :heir 3-tuple owner init, keyword-form opts.

## Verification (real)

Witness: tmp/w6bm_witness.exs over the REAL Store via isolated beams
(/tmp/w6bm_ebin2 = Store + StoreTables + ResourceHealth; deps jason/telemetry
from _build-lane-w6bm/test/lib). Authoritative log: tmp/w6bm_witness_run.log
(exit 0). Witness output (verbatim from the log):

```
A_AVAILABLE=true
A_SUMMARY_SYNTH=true
A_OCCURRED_PRESENT=true
B_SUFFIX_TOLERATED=true
C_UNKNOWN_404=true
D_TRANSITION_OK=true
E_CURRENT_IS_DEGRADED=true
F_INVALID_STATE_REFUSED=true
G_UNKNOWN_TRANSITION_404=true
H_HIST_COUNT=1
I_WIRE_STATE=true
J_WIRE_ID_SUFFIX=true
K_FRESH_AVAILABLE=true
K2_FRESH_HISTORY_EMPTY=true
W6BM WITNESS: ALL FACES OK
```

## Defect fixed in-lane (witness-caught)

`record_transition` on an unknown resource returned bare `:error`; parity is
404. Leg G flipped false→true post-fix — the non-vacuity proof. Else-clause
landed, recompiled, re-witnessed (log above is the post-fix run).

## Compile

Strict `MIX_BUILD_ROOT=_build-lane-w6bm MIX_ENV=test mix compile --warnings-as-errors`
→ exit 0 tree-wide (my file contributes zero diagnostics).

## Falsifier

Green under a broken not-found parity (leg G) or a fabricated Degraded state
(legs A/K: reasonType must be EmulatorSynthetic for untouched resources)
would be vacuous. Replay command in the log capture above; module chunks were
syntax-gated per chunk.
