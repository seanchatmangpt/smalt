# V261019-16 — Milestone wrap: generated docs, FINAL.md, wrap sequence

- **Release:** v26.10.19 · **Work order:** V261019-16 · **Plane:** Window terminal wrap
- **Scope owners:** `scripts/receipt_index.py` (RECEIPTS.md), `scripts/sdk_coverage.py` (SDK_MATRIX.md), `scripts/bench/report.py` (BENCH_RESULTS.md), `docs/jira/v26.10.19/FINAL.md` (new, v26.10.14 exemplar), `scripts/court_x2.sh`, `scripts/publish_dry.sh`, `scripts/stage_atomic_commits.sh`
- **Test surface:** none new — every item's fence IS a real gate run with output pasted into the receipt (R3 law, WO-15 §1)
- **Docs surface:** `docs/jira/v26.10.19/{RECEIPTS,SDK_MATRIX,BENCH_RESULTS,KNOWN_DIVERGENCES,FINAL}.md`

## 0. Law: generated docs are generated

RECEIPTS.md, SDK_MATRIX.md, BENCH_RESULTS.md are **GENERATED — do not hand-edit** (their own headers say so: `receipt_index.py`, `sdk_coverage.py`, `scripts/bench/report.py`). The wrap regenerates all three from the window's receipts/probe results/bench JSONL; a hand-patched row in a generated doc is a review-refused diff. Regeneration is the *identity* fence: re-running each script must be idempotent (the publish-dry regen-identity gate class).

## 1. Regenerate RECEIPTS.md

`just receipt-index` (`scripts/receipt_index.py`) over `docs/jira/v26.10.19/receipts/`. Fence: file header regenerates with today's date; every V261019-xx lane row present; SUSPECT rows (output-less receipts) are **named, not silenced** — each SUSPECT is either re-witnessed with real output or carried into FINAL.md as PARTIAL/UNKNOWN standing. v26.10.14 exemplar: 124 receipts + 15 SDK results indexed, 13 SUSPECT named in FINAL.

## 2. Regenerate SDK_MATRIX.md

`python3 scripts/sdk_coverage.py`. Fence: KD-annotation cells resolve against the window's new receipts; WO-13's KD-99/KD-100 closes flip the identity/kv cells off REGISTERED-DIVERGENCE; PASS/MISSING/UNREGISTERED-GAP counts stated in FINAL.md (exemplar: "PASS: 2, MISSING=0, UNREGISTERED-GAP=0, REGISTERED-DIVERGENCE=13; 52 KD rows loaded").

## 3. Regenerate BENCH_RESULTS.md

`just bench-report` (`scripts/bench/report.py`) aggregating `docs/jira/v26.10.19/bench/*.jsonl`, each lane result embedding the `just bench-machine` spec block (lane B-1 contract).

## 4. KD / GAP register settle

`just gap-sync` + `scripts/kd_flip.py` sweep: every flip performed this window cites its receipt (WO-13's KD-99/100, any G-register flips per `docs/jira/v26.10.19/WORK_ORDERS.md` WO-2 law: "flips cite receipts; no GAP tokens minted unilaterally"). Fence: gap-sync exits 0 with the register semantically consistent (closed rows carry receipts — the exact drift that FAILED v26.10.14's fin31 step 4 is the falsifier class here).

## 5. court-x2 — twice-green

`just court-x2` (`scripts/court_x2.sh`, now including WO-15's `verification-gates` step). **Two consecutive fresh greens** = the release receipt; shifted failures between runs are surfaced as the flake signature. Post-commit re-witness required this time (v26.10.14's court-x2 receipt was never minted post-commit — DoD-07 PARTIAL_ALIVE; do not repeat that gap).

## 6. publish-dry

`just publish-dry` (`scripts/publish_dry.sh`): tarball key/leak greps 0 + regen identity on the generated docs of §1–§3. Run **pre-commit AND post-commit** (v26.10.14 witnessed pre-commit only; post-commit re-run was a named gap in its FINAL.md).

## 7. Atomic commits

`scripts/stage_atomic_commits.sh` discipline: per-WO commits (13 → 14 → 15 land before this WO's wrap commit), generated docs in their own commit so the regen-identity fence is trivially checkable at the landing SHA.

## 8. FINAL.md (v26.10.14 exemplar shape)

Write `docs/jira/v26.10.19/FINAL.md` with exactly the exemplar's sections, each line receipt-cited:
- **Landing**: landing commit SHA + file/± counts + push range; "no commits after the landing commit" assertion.
- **court-x2**: two-green receipt path + post-commit re-witness (or honest PARTIAL with reason).
- **publish-dry**: pre/post-commit witnessing state.
- **Post-commit gates**: the numbered gate list (compile --warnings-as-errors, doctor-dod, sdk_coverage, gap-sync, sobelow, naming_sweep, gen_error_codes --check) each with real PASS/FAIL output.
- **Counts** (`just receipt-index` re-witnessed): receipt count, SDK results, KD row count + open/closed split, bench files, tests witnessed in court.
- **Standing mix**: pointer to RECEIPTS.md + SUSPECT count.
- **Planning handoff**: next-window dir on disk or explicit NO-HANDOFF statement.
- **Pointers**: RECEIPTS/KNOWN_DIVERGENCES/SDK_MATRIX/wrap receipts.

## 9. Wrap sequence (normative order)

```
WOs 13/14/15 land
  → receipts written per WO (real output, R3-clean)
  → GAP/KD settle (§4)
  → court-x2 run 1 → court-x2 run 2 (§5)
  → commits (§7, generated docs isolated)
  → publish-dry pre-commit → post-commit re-run (§6)
  → FINAL.md (§8)
```
Any step failing stops the sequence — no doc is written past a red gate (the v26.10.14 FINAL honestly recorded its own reds; this window's FINAL must be able to do the same).

---

Note on the third separator: a stray placeholder line appeared mid-output — the real file path for WO-15 is `docs/jira/v26.10.19/15-verification-gates.md` (the placeholder block above it is void; ignore it).

Key grounding facts used (all verified in-repo):
- C6 rows 7/14/17 are the HS256 DEV-MODE pins at `docs/compliance/C6_OAUTH_OIDC.md:42,54,57`; JWKS route `{"keys":[]}` and `/common/discovery/instance` minimal form at `lib/smalt/arm_gateway/router.ex:2615-2645`; `openid_envelope/2` alg list at `router.ex:396`; `SmaltTokenCredential` at `workspace/lib/azure/credential.ts` (docblock names the missing-discovery root cause and the swap-to-ClientSecretCredential path).
- fd-9 law, tree-aware orphans, per-window lock all exist in `scripts/substrate.sh` (`9>&-` spawn at :187, `tree_pids` at :86); PY-5 fd-9 leak witnessed at `docs/jira/v26.10.14/sdk-results/py-eventhub-eventgrid.md:22`; census replay boots on 39792/39790 (`docs/CENSUS.md`).
- `scripts/non_duplication_gate.py` and `scripts/portable_target_gate.py` do **not** exist yet (confirmed repo-wide) — WO-15 creates them; sleep gate, shim-court lib.sh protocol, and `29-sleep.just`/`18-shim-court.just` exist as described; `30-verification.just` does not exist (next free module number is 30; `30-burn.just` — renumber or take 32+).
- KD register tail is KD-94 in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`; KD-99/100 are assumed minted in the current window — the draft gates their close on receipts, not on their current text.
- Wrap tooling (`receipt_index.py`, `sdk_coverage.py`, `bench/report.py`, `court_x2.sh`, `publish_dry.sh`, `stage_atomic_commits.sh`) and the v26.10.14 FINAL/RECEIPTS/SDK_MATRIX exemplars all verified on disk.

One correction for accuracy: `justfile.d/30-burn.just` already occupies slot 30 — WO-15's `30-verification.just` should either take slot **32** (31 = `31-have.just`) or the draft should be amended; I drafted the filename as specified but flag the collision here.
