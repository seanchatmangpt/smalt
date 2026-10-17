# r238 — Bench registry drift rulings (receipt-form only; REGISTRY.md untouched)

Standing: PASS
Lane: milestone-doc (architectural item #7, coordinator ruling carried receipt-form).
Lease discipline: `scripts/bench/REGISTRY.md` is lane I17's lease — NOT edited here.
This receipt records three rulings for I17 (or the next registry owner) to carry
into REGISTRY.md under its own lease.

## Ruling 1 — b42 dataplane-saturation: RETIRE-UNLESS-REGISTERED

Ruling: b42's ports are UNAUDITED (no port block registered in REGISTRY.md).
Carry to v26.10.18 with a register-or-retire close condition: either a v26.10.18
lane registers a b42 port block, or the b42 lane and its result file are retired
as a historical artifact (same rule as b10/b11).

Evidence (read on disk 2026-10-17):

- `scripts/bench/REGISTRY.md` lines 74-76 (current text, verbatim):
  > - b42 dataplane saturation lane (`docs/jira/v26.10.16/bench/b42-dataplane-saturation.jsonl`)
  >   — ports UNAUDITED: no port block registered for it in this file; register or
  >   retire before its next run.
- Result file exists on disk (`ls` exit 0):
  ```
  $ ls docs/jira/v26.10.16/bench/b42-dataplane-saturation.jsonl
  docs/jira/v26.10.16/bench/b42-dataplane-saturation.jsonl
  ```

## Ruling 2 — e1 meta rows embedding global substrate ports: LEGAL, not VOID

Ruling: the VOID law in `scripts/bench/enclave_loop.exs` (lines 48-50) is written
for the harness's own DEFAULTS (the c-law c9 block 39290..39295). e1's wrapper
`scripts/tf_enclave_loop.sh` exports its own `SMALT_TEST_*` envs (lines 305-307),
so the e1 rows are LEGAL. However, future enclave rows must export private ports
per the c-law; global-substrate embedding in new rows is VOID going forward.

Evidence (read on disk 2026-10-17):

- `scripts/bench/enclave_loop.exs:48` (verbatim):
  > # embed the global substrate ports (9443/8443/5672/5673) are VOID — a
  > # default-less boot must land in the lane block, never the shared substrate.
- Harness defaults are the c-law block, never global:
  ```
  $ sed -n '51,53p' scripts/bench/enclave_loop.exs
  # c-law defaults (REGISTRY.md): lane c9 -> 39290..39295 (mcp port 39295 is
  # the spare; this harness uses arm/egress/amqp/ehub/arm_tls only).
  ```
- Wrapper exports private envs (`scripts/tf_enclave_loop.sh:305-307`):
  Verbatim (`sed -n '305,307p'`):
  > export SMALT_TEST_ARM_PORT=$ARM_PORT SMALT_TEST_EGRESS_PORT=$EGRESS_PORT
  > export SMALT_TEST_AMQP_PORT=$AMQP_PORT SMALT_TEST_EVENT_HUBS_PORT=$EHUB_PORT
  > export SMALT_TEST_MCP_PORT=$MCP_PORT SMALT_TEST_ARM_TLS_PORT=$ATLS_PORT
- Observed meta rows in `docs/jira/v26.10.16/bench/e1-enclave-loop.jsonl`
  (205 lines total): lines 1 and 9 are the only two meta rows embedding global
  ports (line 1: `"ports":{"arm":"9443","egress":"8443","event_hubs":"5673","amqp":"5672"}`;
  line 9 adds `"tls":"9444"`). Every later meta row (lines 17, 26, 34, 42, 51, 60,
  69, 78, 87, 95, 103, 111, 119, 127, 135, 143, 150, 157, 164, 172, 180, 188, 197)
  embeds the private e-law block: `"ports":{"tls":"39371","arm":"39370","egress":"39372","event_hubs":"39374","amqp":"39373"}`.
  The two global-port rows are the witnessed run-1/2 wrong-tree defect called out
  in the wrapper comment (`scripts/tf_enclave_loop.sh:301-305`):
  > # ...or they fall back to the GLOBAL substrate (9443/8443) and validate the
  > # wrong tree (witnessed: run 1/2 mjs minted from 127.0.0.1:9443 while the lane
  > # substrate held 39370).

Note for the next registry owner: the two global-port rows (lines 1, 9) are the
defect witness, not a standing lane practice — the export fix landed after run 2
and every subsequent run emitted the private 39370 block.

## Ruling 3 — a/n-family register-or-retire stands

Ruling: the a/n-family register-or-retire rule stands as written. Only a9
(39490, legacy pre-lib.sh block) and n5 (39555, boots its own `next start`)
are registered; all other a1-a9 / n1-n8 result files are historical artifacts
unless their lanes register blocks.

Evidence (read on disk 2026-10-17):

- `scripts/bench/REGISTRY.md` line 82-84 (verbatim):
  > - a-family / n-family (a1-a9, n1-n8 in `docs/jira/v26.10.14/bench/`):
  >   register-or-retire — no port blocks for these lanes are registered in this
  >   file beyond a9 39490 (a-family) and n5 39555 (n-family). Any re-activated
  >   a/n lane must register its block here or be retired; result files without an
  >   active registered lane are historical artifacts (same rule as b10/b11).
- Registered blocks confirmed present: line 56 `lifecycle_harness 39640..39650, a9 39490.`
  and line 66 `- **n5** boots its own `next start` on 39555 (b-band 39010..39125 reserved).`
- a/n result files confirmed in `docs/jira/v26.10.14/bench/` (a1-change-feed.jsonl,
  a2-cas-contention-sdk.jsonl, a2-cas-contention.jsonl, a3-cross-partition.jsonl,
  a4-crypto.jsonl, a6-port-exhaustion.jsonl, a7-hns-rename.jsonl, a8-lro-storm.jsonl,
  a9-auth-flood-rss.jsonl, a9-auth-flood.jsonl, …).

## Receipt metadata

- Date: 2026-10-17
- Author: milestone-doc lane (architectural item #7), coordinator-directed ruling
- Files touched by this lane: only this receipt.
- Files deliberately NOT touched: `scripts/bench/REGISTRY.md` (lane I17 lease),
  `scripts/bench/enclave_loop.exs` (uncommitted, other lane's in-flight file).
