# BK-CENS4 — census registration wave 4

- **Date**: 2026-10-22
- **Lane**: BK-CENS4, repo /Users/sac/smalt (canonical checkout), MIX_BUILD_ROOT=_build-bkcens4
- **Standing**: **ALIVE** — census 6/6 green on the sealed population; all 6 court files verified (receipt on disk), registered, and run green individually.
- **Context**: solo

Resolves the 4 census-drift blockers BK-SEAL3 typed on unregistered in-flight
files (plus 2 more that landed mid-window, swept per the BK-CENS2 method).

## Per-file ledger (all receipts on disk at registration time)

| file | owner lane | receipt | tier | exemptions | run |
|---|---|---|---|---|---|
| expl10r_court_test.exs | EXPL10-R | expl10r-high-repairs.md | :internal | none (no tokens) | 10 passed |
| expl11r_court_test.exs | EXPL11-R | expl11r-repairs.md | :internal | none (no tokens) | 4 passed |
| bkmaap6_nonce_bounds_court_test.exs | BK-MAAP6 | bkmaap6-nonce-bounds.md | :internal | [:status_literal] | 5 passed |
| expl11r3_court_test.exs | EXPL11-R3 | expl11r3-planes-meta.md | :internal | none (registered by owner lane in the same map) | 7 passed |
| bkseqb_seq_base_court_test.exs | BK-SEQB | bkseqb-seq-base.md | :internal | none (no tokens) | 3 passed |
| bkegs1_fence_court_test.exs | BK-EGS1 | bkegs1-fallback-fence.md | :wire | [:client_token] | 6 passed |

(Expl11r3's registration row landed from the owner lane while this lane was
polling; verified content, not re-registered. Census maps are shared seams —
the file is one seam, edits disclosed here.)

## Bounded-wait timeline (bounded polls on receipts dir, no fixed sleeps in tests)

- expl10r receipt on disk at session open (05:43).
- expl11r-repairs.md landed ~05:52.
- bkmaap6-nonce-bounds.md landed ~05:55.
- expl11r3 receipt did NOT land inside the first ~25 min of bounded polls;
  the row was about to be typed PENDING-WITH-OWNER per lane law. It landed at
  ~06:20 (expl11r3-planes-meta.md) and was registered; per-file run 7/7.
- Mid-wait, 2 more in-flight files hit the fence (bkseqb, bkegs1); both
  owners' receipts landed inside a 5-minute bounded poll; both registered.

## Embedded census output (verbatim)

```
MIX_BUILD_ROOT=_build-bkcens4 mix test test/internal/internal_tier_census_test.exs
Result: 6 passed
```

Per-file runs (verbatim tails):

```
expl10r_court_test.exs                 Result: 10 passed
expl11r_court_test.exs                 Result: 4 passed
bkmaap6_nonce_bounds_court_test.exs    Result: 5 passed
expl11r3_court_test.exs                Result: 7 passed
bkseqb_seq_base_court_test.exs         Result: 3 passed
bkegs1_fence_court_test.exs            Result: 6 passed
```

## Self-scan disclosures

- Two comment lines this lane added naming the raw Erlang HTTP client token
  tripped the census's honest self-scan; reworded in place (BK-CENS2 pattern:
  census comment text must not contain the literal tokens the scans match).
- The census file is a shared seam: BK-CENS4 rows (bkmaap6, bkseqb, bkegs1,
  bkegs1 exemption + EgressRouter/FenceCourtTest allowlist entries) plus the
  owner lane's own expl11r3 row coexist in the one file. `Smalt.EgressRouter`
  appears twice in the observables literal (MapSet dedups; harmless).

## Verdict

Population fence sealed at this snapshot: every file in `test/internal/` is
registered with tier + typed exemptions; census 6/6. The BK-SEAL3 census
blockers are all cleared; a quiesced rerun can now advance the seal claim.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-bkcens4 mix test test/internal/internal_tier_census_test.exs   # 6 passed
for f in expl10r_court_test.exs expl11r_court_test.exs \
         bkmaap6_nonce_bounds_court_test.exs expl11r3_court_test.exs \
         bkseqb_seq_base_court_test.exs bkegs1_fence_court_test.exs; do
  MIX_BUILD_ROOT=_build-bkcens4 mix test test/internal/$f
done
```
