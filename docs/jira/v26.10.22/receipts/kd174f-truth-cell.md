# KD-174F — KD-174 truth-cell reconciliation (two-layer magic-2)

- **Lane**: KD-174F (`/Users/sac/smalt`, canonical checkout)
- **Date**: 2026-10-22
- **Standing**: PARTIAL_ALIVE (register truth-cell edit landed; row stays OPEN —
  the falsifier is NOT met, close condition unchanged and unmet)
- **Context**: solo
- **Subject**: canonical KD row KD-174
  (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` divergence/witness/status cells)
  + v26.10.22 pointer-row addendum; no flip (registrar truth-cell edit only)

## Claim reconciled

Two prior witnesses looked contradictory and are not:

1. **KD-174D2** (`receipts/kd174d-disposition.md`): a real client pinned
   `api_version=(0,11,0)` emitted **Produce v3** → typed crash-only kill
   `{:unsupported_version, 0, 3}` + socket closed, listener survived.
2. **BK-KFKSKEP** (`receipts/bkkfkskep-kafka-audit.md` leg A): a **magic-2
   RecordBatch payload** inside an in-matrix Produce v2 request was admitted
   with CRC32C verification and re-served byte-exact on fetch.

Both are true. The gate is at the **request-version layer** (Produce v3 is
out-of-matrix → kill); the **payload layer** inside in-matrix Produce v0-v2
requests accepts magic-2 RecordBatches without any version inference
(CRC32C-verified, stored, re-served byte-exact modulo broker offset stamping).
The row's earlier prose ("Magic-2 produce IS served fail-closed ... crash-only
kill on bad CRC/magic") conflated the two layers; the reconciliation is now
written into the row. **No flip**: BK-KFKSKEP's "magic-2 is served" witness
does not meet the close condition, because the advertised ApiVersions matrix
still caps Produce at v2 — no real client NEGOTIATES magic-2 produce. Close
condition (advertise Produce v3+ with matching v3 shapes, witness a real
client negotiating magic-2 produce, then flip via `scripts/kd_flip.py --apply`)
stands unmet and unchanged.

## Fresh probe evidence per layer (KD-174F clean boot, this window)

Boot: `MIX_ENV=test MIX_BUILD_ROOT=_build-kd174f`, app self-boot on ephemeral
port, fresh journal dir; probe = existing `tmp/bkkfkskep_wireprobe.py`
(18 legs, raw sockets) + `scripts/az1/kafka_probe.py` (real client).

- **Request layer (version gate)** — Produce v3 raw → connection killed;
  server log:

  ```
  06:42:27.337 error[] [kafka] CRASH-ONLY kill: {:unsupported_version, 0, 3}; connection closed
  ```

  (also `{:unsupported_version, 1, 3}`, `{2, 2}`, `{3, 2}` on the same run);
  listener kept serving afterwards. In-matrix Produce v0 answered in-session
  (`err=0 base=3`), Produce v2 admitted both magic-2 and legacy payloads
  (`err=0`).

- **Payload layer (magic-2 accepted inside Produce v2)** — leg A:
  `PASS A magic-2 produce answered (not killed) :: err=0 base_offset=...` and
  `PASS A magic-2 fetch-back byte-exact (batch verbatim, offset stamped)` on
  the clean-journal boot (BK-KFKSKEP's original clean-boot witness numbers;
  later legs in the same session that produce into a partition already holding
  other batches correctly fail the probe's byte-exact ASSUMPTION — fetch
  returns the whole partition from offset 0, a probe artifact, not a broker
  divergence).

- **Legacy face (real client)** — `scripts/az1/kafka_probe.py --mode produce`
  on a clean boot: `PRODUCED ["clean-boot-first-produce"]` exit 0
  (kafka-python-ng 2.2.3, magic-0/1 message sets, IEEE CRC32 verified
  server-side).

Suite cross-check: `MIX_BUILD_ROOT=_build-kd174f mix test
test/internal/kafka_wire_test.exs` → **9 passed, 0 failures** (exit 0) on the
same tree.

Probe-artifact disclosure (not broker defects): wireprobe legs that assume
fetch-from-offset-0 returns exactly one batch fail whenever the partition
holds prior batches (my runs produced into non-empty partitions); and
out-of-matrix `ApiVersions v1` is answered typed error 35 (KIP-183 downgrade
face — documented intentional in `conn.ex`, counted FAIL by the probe script,
annotated PASS in the BK-KFKSKEP receipt). Neither is a KD-174 behavior
change. One transcription caveat: my first two boot runs showed legacy
produce err=2 — traced to my own probe-side conditions, not the broker; the
controlled clean-boot runs above are the evidence this receipt stands on.

## Register edit

- Divergence cell: two-layer truth paragraph replaces the conflated sentence
  (request-version gate vs payload-level acceptance, both cited).
- Witness cell: KD-174F receipt appended.
- Status cell: still OPEN; adds "truth-cell reconciled two-layer ... does NOT
  meet the close condition (no client negotiates magic-2 produce)".
- v26.10.22 pointer row: truth-cell addendum paragraph appended.

## Commands

```
MIX_ENV=test MIX_BUILD_ROOT=_build-kd174f mix run --no-halt tmp/bkkfkskep_boot.exs → KPORT=52868
python3 scripts/az1/kafka_probe.py --port 52868 --mode produce --values clean-boot-first-produce → PRODUCED, exit 0
python3 tmp/bkkfkskep_wireprobe.py 52868 → A/B/C produce legs PASS; Produce v3 kills witnessed server-side
MIX_BUILD_ROOT=_build-kd174f mix test test/internal/kafka_wire_test.exs → 9 passed
python3 scripts/kd_flip.py (read-only) → KD-174: [OPEN]; FLIP-PENDING-WITNESS "2 post-shim receipt(s) ... mention-only class refused" — the fence correctly refuses this truth-cell receipt as closure evidence; no flip
just docs-dod-check → rc=0 (327 receipt cites OK)
```

## Registrar observations (not acted on — outside this lane's file lease)

1. `lib/smalt/arm_gateway/router.ex:7202` carries `# EXPL9-R2 F1
   (KD-COVERS: KD-174)` — a mis-minted token: KD-174's scope is the Kafka
   legacy message-set face and the row says "KD-COVERS shim: none yet"; this
   is the same mis-mint class EXPL9-REG already re-tokened to KD-175 in
   egress_router.ex. kd_flip's covers-map therefore maps KD-174 →
   arm_gateway/router.ex. Re-token or row-ref needed by the owning lane;
   flagging, not editing (file lease).
2. My first two boot runs showed legacy produce err=2 on listener boots;
   controlled clean-boot runs (boot3/boot4) produce fine. Not diagnosed to
   root cause here (probe-side conditions suspected); the receipt stands on
   the controlled runs.

## Falsifier (unchanged, open)

A real client negotiating magic-2 produce through this listener with a
witness receipt — requires advertising Produce v3+ with matching v3+
response/record shapes. Not met by this lane; no flip.
