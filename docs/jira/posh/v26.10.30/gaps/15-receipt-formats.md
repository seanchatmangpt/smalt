# Gap lane 15 — receipt format fragmentation (smalt ecosystem)

Status: **PARTIAL_ALIVE** — every schema/writer/reader below was read from
disk this session (file paths + grep receipts cited inline); the posh andon
chain and court receipts were checked for cross-references by real grep.

## Format matrix

| | posh andon.jsonl | smalt OCEL NDJSON | court markdown | ggen receipt-log.jsonl |
|---|---|---|---|---|
| Writer | `posh/cmd/andon/main.go` (stdin gate results) → `internal/andon/receipt.go` `Appender.Append` | `Smalt.Telemetry.OcelNdjson.append/3` via emitters `court_ocel.ex`, `enclave_ocel.ex`, `affidavit_ocel.ex` | hand-written by lanes/humans into `docs/jira/**/receipts/*.md` | ggen-engine sync Stage 5 (`crates/ggen-engine/src/sync.rs:280`, `RECEIPT_LOG_REL_PATH`) |
| Location | `posh/var/andon.jsonl` (durable, NOT swept by `make clean`/`just posh-clean`; legacy `tmp/posh/andon.jsonl` honored via `-receipts`) | `tmp/ocel/events.ndjson` + `tmp/ocel bad_events.ndjson` (gitignored `/tmp/`) | `docs/jira/<milestone>/receipts/*.md` (git-TRACKED) | `.ggen-v2/receipt-log.jsonl` (git-TRACKED in smalt — verified `git ls-files`); smalt log 19 lines, ggen's own 211 lines |
| Schema | flat JSONL, 15 fields: `ts, subject_sha256, gate, prev_signal, signal, outcome, exit, sla_ms, hysteresis_count, composite, arrested, skip_reason, reason` | OCEL 2.0: one complete 4-key doc per line (`ocel:eventTypes/objectTypes/events/objects`); fail-closed assembly + object-reference closure + PROV-O `eo:Agent`/`prov:wasAssociatedWith` chain | free markdown: window/date/tier, standing header, "Claim witnessed" prose + one embedded JSON verdict block | `ggen-receipt/v2`: hash chain (`payload_hash_hex`, `prev_chain_hash_hex`, `chain_hash_hex`, `signature_hex`, `chain_rule: praxis-chain/v2-fold`) + `v2.admission` (per-evidence Admitted decisions), `equivalence` (8-class blake3 map vs previous receipt), `standing_ceiling`, `andon` label, `promotion_eligible` |
| Retention | durable on disk, gitignored-by-convention (dir absent until first run) | disposable (gitignored `tmp/`) — one `rm -rf tmp` from vanishing | permanent (committed) | permanent (committed) |
| Consumers (grep receipts) | `internal/andon/machine.go:38` — `LastGate` reads prior signal from the chain, never memory; `hysteresis` over DISTINCT `subject_sha256`s | `lib/smalt/ocel/revops/powl_bridge.ex:51,232`, `revops.ex:63`, `fitness_verdict.ex`, `ocel_trace.ex`, `lib/smalt/ocel.ex:6` | humans, lanes, WRAP_LEDGER.md (grep: WRAP_LEDGER cites `ev-court-run-8837` event ids) | `sync.rs:985 read_receipt_log_generation` (generation counter), `sync.rs:571` reflexive law (`ggenr:Sync` facts into the graph), chain replay tests (`receipt_chain_own_history_replay.rs`) |

## Authoritativeness (which format owns which claim)

- **andon.jsonl** is authoritative for *gate signal state*
  (GREEN/YELLOW/RED + hysteresis + latch), and — uniquely — the only format
  carrying a **subject SHA** (`subject_sha256`).
- **ggen receipt-log** is authoritative for *sync admission and equivalence*
  (what changed vs the previous sync, per 8 equivalence classes, chain-signed).
- **OCEL NDJSON** is authoritative for *process history* (court.run/
  enclave/affidavit events; POWL model + fitness verdicts are derived from it).
- **court markdown** is authoritative for *human-argued claims* (browser OIDC
  PKCE pass, refusals witnessed) — the only format with narrative evidence,
  and the only one a skeptic lane can actually read without a parser. It is
  also the least machine-checkable (free markdown, no schema).

## Cross-referencing: none

Greps over `docs/jira/v26.10.30/receipts/` found **zero** references to
`tmp/ocel`, `andon`, or any 40-hex SHA. Verified:

- andon receipts carry `subject_sha256` but no OCEL event ids and no ggen
  chain hash.
- ggen receipts carry an `andon: "Green"` label — the *name* of the andon
  format, not a hash of any andon chain head.
- court receipts cite OCEL event ids only historically (WRAP_LEDGER
  v26.10.16), not in the current window's receipts.

Chaining exists **within** each format only: ggen `prev_chain_hash_hex`,
andon `prev_signal` chain, OCEL object-reference closure. No join key
spans formats.

## Unprovable-if-vanished claims

- **andon.jsonl vanished**: hysteresis demotion and RED-latch state become
  unprovable; next run reads no prior signal → vacuous GREEN (the exact
  vacuous-pass class the chain exists to prevent).
- **OCEL NDJSON vanished**: court.run process mining and POWL fitness
  verdicts unprovable — and this one is *already one `rm -rf tmp` away from
  vanished* (gitignored), so process-history claims have shelf life of one
  cleanup.
- **ggen receipt-log vanished**: generation counter resets; every next sync
  re-records equivalence `Divergent` against nothing; chain replay
  (`receipt_chain_own_history_replay.rs`) impossible. Mitigated: it is
  committed.
- **court markdown vanished**: all human-argued witness claims (e.g. r-p03
  browser OIDC) lose their evidence trail; the embedded JSON verdicts are
  the only record of refusals.

## Close conditions

1. **Subject git SHA as mandatory join key**: every format gains the
   subject commit SHA (andon already has `subject_sha256`; OCEL events gain
   a `subject` object; ggen receipts gain repo+SHA in `v2`; court receipts
   gain a `subject: <sha>` header line). Until then, "was THIS commit's
   court green?" requires reading four heterogeneous stores by timestamp.
2. **One index**: `docs/jira/<ms>/receipts/INDEX.jsonl` mapping
   `subject_sha → {court_md_path, andon_line (ts+gate), ocel_event_ids,
   ggen_chain_hash}` — one file, one grep to join all four. Ggen's
   reflexive law already proves the pattern: read prior receipts as graph
   facts; do the same across formats.
3. **OCEL sink durability**: move the NDJSON sink out of gitignored `tmp/`
   (e.g. `var/ocel/`) or commit a compressed periodic snapshot, else
   process-history claims expire at cleanup time.

## Receipt

- Read: `~/smalt/posh/internal/andon/receipt.go` (full),
  `cmd/andon/main.go`, `internal/andon/helpers.go:11`, `machine.go`;
  `~/smalt/lib/smalt/telemetry/ocel_ndjson.ex` (full);
  `~/smalt/docs/jira/v26.10.30/receipts/r-p03-browser-oidc.md`;
  `~/ggen/crates/ggen-engine/src/sync.rs:280,571-640,985,2111`;
  `~/smalt/.ggen-v2/receipt-log.jsonl` tail record (full key dump);
  `~/smalt/tmp/ocel/events.ndjson` head line.
- Greps: cross-format refs in court receipts (0 hits ×3 patterns);
  `git check-ignore` (tmp/ocel ignored, .ggen-v2 tracked);
  consumer greps per format (cited in matrix).
- Not witnessed: an actual `posh/var/andon.jsonl` on disk (the chain has
  never run in this checkout — posh/var absent). Andon format status is
  therefore code-ALIVE / data-UNVERIFIED.
