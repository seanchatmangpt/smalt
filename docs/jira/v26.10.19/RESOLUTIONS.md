# v26.10.19 — Shared Seams & Resolutions

Cross-lane agreements for the work orders in `docs/jira/v26.10.19/WORK_ORDERS.md`. When two orders touch the same surface, the seam is recorded here so neither duplicates or clobbers the other.

## S1 — test/ deletion seam (single deletion lane owns the commit)

- **Owner:** the single deletion lane — one lane owns the `test/` deletion commit exclusively.
- **Consumers:** every lane whose close condition reads a green `mix test` run (WO-3's `test/data_plane/ test/arm/ test/wire/ test/azsim/` regression set, WO-2's 18 test bodies, WO-6's engine + wire tests).
- **Rule:** only the deletion lane commits test/ removals; no other lane deletes or moves test bodies, even ones it owns. The deletion lane's run result is the **parity gate input** — the parity gate consumes the deletion lane's commit (deletions land together with a green run), never a per-lane partial deletion. A lane that needs a test body changed files the change to the deletion lane rather than editing in place.

## S2 — verification/ts+py keyspace prefixes (run-scoped names)

- **Owner:** the lane introducing the verification artifacts (WO-5's `scripts/isolation_court.py --runtime-only` rerun artifacts; any `.ts`/`.py` verification files the window adds).
- **Consumers:** every other lane that reads verification outputs from disk (WO-1's burn validation, WO-4's `scripts/validate_burn.py`, WO-5's quiet-window falsifier counts).
- **Rule:** all verification keyspaces — TypeScript and Python — use **run-scoped names** (prefixes carrying the run/window identity, never bare shared names). No two lanes write to the same unprefixed path; a consumer reads only the prefixed name it was handed. Colliding unprefixed names are a defect regardless of which lane landed first.

## S3 — port-law v-family 39700+10N (boot library owns the formula)

- **Owner:** the boot library owns the port formula exclusively (`39700 + 10N`, v-family allocation).
- **Consumers:** WO-1 (ring boot under the flock image-build lease — every ring node boots from the library's allocation), WO-3 (`MIX_BUILD_ROOT=_build-ft-az20 just azsim-sdk` probe runs), WO-4/WO-5 soak and isolation runs.
- **Rule:** no lane hardcodes a port number or invents its own offset scheme. All ports come from the boot library's v-family formula. A lane needing more ports than its slice takes the next `N`, never a neighbor's.

## S4 — identity credential seam (`CREDENTIAL_FACTORY`, RS256 flip)

- **Owner:** the lane that lands the `CREDENTIAL_FACTORY` seam and the RS256 flip.
- **Consumers:** WO-2 (G2 X-ARR-ClientCert mTLS gateway termination + spoof injector — the spoof test needs the factory to mint a bad cert the gateway must refuse), WO-3 (ARM plane-mount verification runs authenticate through the seam), WO-6 (queue storage wire tests).
- **Rule:** no lane constructs credentials ad hoc. All identity material is minted through `CREDENTIAL_FACTORY`; the RS256 flip is a single-lane change at the seam, and consumers must not pin to the pre-flip algorithm. After the flip, consumers re-run their gate rather than asserting the old signature shape.

## S5 — gate corpus stability (gates land after residual tier, before court rewiring)

- **Owner:** the gate-corpus lane, landing in a fixed order: **residual tier first, then the gate corpus, then court rewiring**.
- **Consumers:** WO-5 (`scripts/isolation_court.py --runtime-only` quiet-window rerun — its falsifier counts must be read against a frozen corpus), WO-1/WO-4 (`validate_burn.py` standing derivation), WO-2 (G-register flip receipts).
- **Rule:** the gate corpus is frozen (no additions, removals, or threshold edits) while any residual-tier work is in flight; gates land only after the residual tier settles and only before court rewiring begins. Once gates land, the court rewiring lane treats them as read-only inputs. No lane mutates a gate to make its own WO green.

## S6 — generated-doc authority (scripts own outputs)

- **Owner:** the owning script owns its generated output (e.g. `scripts/validate_burn.py` owns burn standing receipts, `scripts/isolation_court.py` owns isolation counts, the ring owns its burn receipt).
- **Consumers:** every lane citing a generated number in a doc or register flip (WO-2 register flips, WO-1 close condition, WO-4 ALIVE standing, WO-5 falsifier counts).
- **Rule:** generated docs/receipts are never hand-edited. If the number looks wrong, fix the script and regenerate. Docs cite the output at landing time (carry-over of the v26.10.14 S8 seed-detection discipline: recompute at landing, do not copy values out of the work orders).

## S7 — substrate lock namespace (`/tmp/smalt-verify-vN.lock`)

- **Owner:** the lane running substrate/verify boot (WO-1's flock image-build lease + boot-stage verification, following the `scripts/substrate.sh` discipline).
- **Consumers:** WO-3 (build-root `azsim-sdk` runs), WO-4 (cgroup soak harness), WO-5 (quiet-window isolation court) — anything that must not run concurrently with a substrate verify.
- **Rule:** all verify-window locks live under the **`/tmp/smalt-verify-vN.lock`** namespace, versioned by `vN` for the window. No lane creates a lock outside the namespace (no ad-hoc `/tmp/my-lane.lock`), and no lane deletes or reuses another `vN`'s lock. A lane that must exclude concurrent substrate work takes the lock under the namespace; a lane that finds it held waits or reschedules, never forces.
