# BK-WP2 — lithography whitepaper citation/figure drift audit — PARTIAL_ALIVE

**Standing**: PARTIAL_ALIVE — all 23 cited artifacts exist at their cited names (no
renames/moves); 18 of 23 anchor cleanly with matching figures and unchanged standings;
5 material drift findings, all typed below. No whitepaper edits made (one-writer rule).

Context: solo
Date: 2026-10-22
Lane: BK-WP2 (read-only audit + this receipt only)

## Method

Extracted every `\art{...}` citation and every figure from
`docs/jira/v26.10.21/whitepaper/lithography.tex` (415 lines, 23 distinct artifacts:
13 receipt .md under `docs/jira/v26.10.21/receipts/`, 10 bench .jsonl under
`tmp/bench/`). For each: (a) existence at cited path, (b) standing line vs paper
characterization, (c) figure re-read from the artifact at use time. Cross-checked
`docs/jira/v26.10.21+22/receipts/` for addenda/supersessions naming the cited receipts.

## Drift table

| # | Paper claim (lithography.tex) | Current disk truth | Recommended action |
|---|---|---|---|
| D1 | Receipt term is O(1): 40 words = 320 B at every n∈{10,10²,10⁴,10⁵}; seal ladder p50 0.024/0.314/64.7/656.1 ms (cites `pb4-merkle-dual.jsonl`, `pb4-merkle-dual-path.md`) | **SUPERSEDED.** PB4-R (v26.10.22 `receipts/pb4r-identity-court.md`, ALIVE) repaired the PB-4 harness replica and re-emitted 16 fresh rows to `tmp/bench/pb4-merkle-dual.jsonl`: `heap_words_receipt: 48` (=384 B) at every n; seal ladder 0.048/0.563/131.6/2399.5 ms. Cause: GAP-6a agent-attribution fields added to the real seal (agent field, prov:Agent triples, wasAssociatedWith/wasAttributedTo/endedAtTime per step). The O(1) claim itself still holds (48 at every n). | cite-update + figure-update: 40→48 words, 320→384 B; re-read seal ladder from the fresh jsonl. The "draft's 352-byte token replaced by measured 320-byte" sentence must become 384 B. |
| D2 | "Journal boot-replay is NOT WIRED … JournalReader has zero non-test callers; no boot-time replay into Smalt.Store, whose restart is documented lossy (store.ex:220)" (threat item, cites ja14) | **SUPERSEDED by TTV-4.** ja14-release-handling.md re-witness (2026-10-21): standing updated to "journal replay wired, boot-fail-closed"; `lib/smalt/store.ex:167` (`boot_replay_for_boot/1`) called from store.ex:575 at init, replay-then-listen, typed boot refusal `{:stop, {:journal_replay_failed, reason}}`; court `test/integration/ttv4_journal_boot_replay_court.exs` on disk. JournalReader now has a non-test caller. store.ex:220 line cite is stale (line moved; content changed). | cite-update: rewrite the threat item as "boot replay WIRED by TTV-4, boot-fail-closed"; drop the store.ex:220 lossy-restart anchor. |
| D3 | "Open defects JA-16 D1–D3" (threat item: atom minting cosmos_sql.ex:766, silent CA load x_arr_cert.ex, silent quota fallback eh_throttle.ex:243) | **CLOSED.** `v26.10.21/receipts/ja-r3-ja16-defect-fixes.md` (standing PASS): all three fixed; D1 fix witnessed in lib (`lib/smalt/cosmos_sql.ex:771` — keyword match is binary comparison against compile-time `@keyword_strings`, `String.to_existing_atom/1` reached only for existing atoms; D1 falsifier re-run flat). | cite-update: retype as "JA-16 D1–D3 fixed (ja-r3, PASS); observability minors may remain" or replace with currently-open defects. |
| D4 | Cross-language parity 2,117.5 (erl) vs 11,426 (powl2) ops/s (cites `pb5-crosslang.jsonl`) | **ARTIFACT DRIFT.** Paper matches its cited receipt (`pb5-crosslang-differential.md` line 153 table: 2,117.5/11,426), but the on-disk `tmp/bench/pb5-crosslang.jsonl` was re-run since and now holds a different run: 1,788.8 vs 8,410.8 ops/s (and an intermediate embedded run shows the erlang side hit 98 errors/200). The paper figure no longer matches the cited jsonl byte-for-byte. | cite-update: either re-anchor to the current jsonl run (1,788.8/8,410.8) or re-run `scripts/bench/pb5_crosslang.sh` cleanly and re-cite. Also note the erlang-runner error exposure (98/200 in one embedded run) before repeating a parity ratio. |
| D5 | "no boot-time replay … persistence is opt-in DetsMirror only" / "restart is documented lossy (store.ex:220)" | **STALE LINE ANCHOR.** The `store.ex:220` exact-line citation no longer points at the lossy comment (boot replay landed near it). Same root cause as D2; listed separately because it is a figure-class anchor (exact file:line) drifting with any lib edit. | cite-update (fold into D2 rewrite). General lesson: file:line anchors decay; cite symbol names, not line numbers. |
| — | All other figures/standings | VERIFIED MATCHING: AMQP 952,381 f/s, 1.05 µs, 254.5 reds; cosmos 0.543/2,251.4 + 0.672/2,130.0; native etag/3 2 µs / 895,335; CAS 5 µs / 383,186; wire-face 0.813 ms; POWL runner 3,222.3 / 0.425 ms / 45,182.7 reds; native settlement 30/74 µs; GL-9 0.25 µs, +47.24–47.49, p99 0.976–1.147 ms; JSON SAX 80 ms / 38,504 B; ceiling 0.9–1.18 µs, 17.65→60.12; SQLD-8 450,450.5 / 64,724.9 rows/s, RSS 100.0/294.2 MB; C-10 11.265/32.671 ms; GLD-7 112 assertions / 47 leaves / HSM 32-B root; SJ-1 5 legs PASS; JA-7 cascade 0–1 ms, +237 KiB/10 cyc; T-47 1,906 ms FAIL disclosed (standing PARTIAL_ALIVE, consistent); GWS-11 caps 16/256/64 MiB, 7/7; GWS-12 3 legs byte-identical, hash 6971c912…; GLD-5FIX 6/6, duckdb 1.4.1, allow_quoted_nulls=false; JA-12 ALIVE; JA-6 PARTIAL PASS (paper's "not minimal" phrasing consistent); JA-14 hot-upgrade UNSUPPORTED unchanged; PB-4-path REFUTED-as-noise (paper describes it honestly as refuted). | none |

## Non-drift hazards (no action this lane)

- The 10 bench .jsonl anchors live in `tmp/bench/` — gitignored scratch. They match
  today, but any `tmp/` cleanup or a re-run silently re-bases the paper's anchors.
  Recommend (future WO, not this lane): canonical jsonl snapshots into
  `docs/jira/v26.10.21/whitepaper/artifacts/` with sha256 in the .tex comments.
- SAS-wildcard/KD-172 host-scoping and the cert e/n swap repairs (v26.10.22) touch
  no figure the whitepaper cites (paper cites no SAS/cert figures) — no drift.

## Verdict

Five typed findings (D1–D5; D5 folds into D2). Paper is otherwise anchor-sound:
every cited receipt exists, every other figure re-reads true from its artifact at
use time. PARTIAL_ALIVE until the operator applies cite-updates D1–D4; the whitepaper
file itself was not modified by this lane.
