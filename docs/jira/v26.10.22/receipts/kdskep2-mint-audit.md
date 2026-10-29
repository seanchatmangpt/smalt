# Receipt: KD-SKEP2 — read-only skeptic audit of the five v26.10.22 KD mints (KD-174..179 family)

- **Lane**: KD-SKEP2 (read-only skeptic audit; only this receipt written)
- **Date**: 2026-10-22
- **Standing**: **ALIVE**
- **Context**: solo
- **Subject**: KD-175, KD-176, KD-177, KD-178, KD-179 rows (canonical
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` + v26.10.22 window pointer) and
  their evidence receipts

## Verdict

**ALIVE — all five mints are sound.** Every evidence receipt exists on disk,
carries a standing line supporting its row's status, and its surface
description matches the code. Cross-mint consistency holds; the adversarial
probes found no fabricated witness.

## Per-mint audit table

| Mint | Row status | Evidence receipt on disk | Standing | Surface verified vs code | Close condition concrete? |
|---|---|---|---|---|---|
| KD-175 (egress oversized-body naked 500) | CLOSED-WITH-EVIDENCE | `expl9r1-egress-guards.md` | ALIVE | 3 KD-175 tokens in `lib/smalt/egress_router.ex` (:42 crash fence, :837 put_range guard, :1127 service-properties guard); kd_flip covers-map maps KD-175 → egress_router.ex + arm_gateway/router.ex | Yes — 413 RequestBodyTooLarge envelope w/ x-ms-request-id, witnessed 5/5 real HTTP (9MB Put Range → 413 XML, 9MB Put Properties → 413, small-body baselines typed), flip already applied, receipt postdates shim |
| KD-176 (MAA nonce-ETS unbounded) | CLOSED-WITH-EVIDENCE | `bkmaap6-nonce-bounds.md` | ALIVE | `lib/smalt/attestation/maa.ex`: `@nonce_max_key_bytes 256`, `nonce_max_entries` (65 536), `sweep_expired_nonces/1` compute-on-write, owner-ref'd rows — all present | Yes and met — bounded intake/TTL sweep/entry cap with 5/5×20 court; real-ETS legs verified in `test/internal/bkmaap6_nonce_bounds_court_test.exs` (220-row build + real future-timestamp `select_delete` sweep, no sleeps) |
| KD-177 (env-gated hardware trust CLASS) | OPEN — TYPED ENVIRONMENT-GATED | `kd177-envclass.md` | PARTIAL_ALIVE (registration census, supports OPEN class row) | Members' UNSUPPORTED legs confirmed at cited receipt lines (az2:48-53/106, az4:104-107); census honesty note verified — no dkls/kldrm receipts exist, class grounded on az2/az4 only, as disclosed | Yes — per-member close conditions remain row-authoritative; class DO-NOT-FLIP per KD-168 hold precedent; kd_flip currently refuses KD-168 cross-id evidence (`FLIP-ELIGIBLE: 0`, hold mechanically active) |
| KD-178 (Web PubSub broker-wipe silent) | OPEN (registered) | `bkwpss2-recovery.md` | ALIVE | `lib/smalt/webpubsub/service.ex:61` `init(:ok) -> %{groups: %{}, events: :queue.new()}` — in-memory only, exactly as the row states | Yes — socket-lifetime link to broker death (monitor from socket/upgrade path) with witness receipt; BK-WPSS2's 5/5 real supervised-kill witness matches the row's claims (wipe of groups+witness buffer, `{:ok, 0}` publish, first-try rejoin) |
| KD-179 (inet_aton shorthand loopback) | OPEN — TYPED ACCEPTED-BECAUSE-GENUINELY-LOOPBACK | `bkampv-parse-verify.md` (+ `bkampf1-loopback-parse.md` provenance) | ALIVE | `lib/smalt/messaging/amqp/sas_verifier.ex:221-233` — `loopback_host?/1` → `loopback_ipv4?/1` via `:inet.parse_address/1`, exactly where the row says; no shim (registration-only, `lib/` unchanged — covers-map has no KD-179 entry) | Yes — strict dotted-quad shape guard conditional on a downstream divergence being witnessed; all four shorthand accepts (`0177.0.0.1`, `0x7f.0.0.1`, `127.1`, `2130706433`) witnessed OK(200) in bkampv Leg 3, `[::ffff:127.0.0.1]` refused fail-closed, evil-host falsifiers still 401 |

## Cross-mint consistency

1. **No surface double-claim.** KD-175 (egress blob/ARM egress faces) vs
   KD-174 (Kafka legacy message-set) are disjoint and the row says so
   explicitly (mis-mint disclosure). KD-176 and KD-168 share the FILE
   `maa.ex` but different surfaces (nonce ETS bounds vs TEE-quote
   validation); KD-176's row discloses this and correctly declines a
   KD-COVERS token. KD-178 vs KD-169 both touch Web PubSub but distinct
   faces (broker supervision vs unauthenticated API faces). No collision.
2. **DO-NOT-FLIP holds coherent.** kd_flip read-only (run this audit):
   `FLIP-ELIGIBLE: 0`, `FLIP-PENDING-WITNESS: 1 — KD-168 registrar hold
   (cross-id evidence matches are refused)`. The KD-177 class DO-NOT-FLIP
   rides the same hold and is mechanically enforced, not just prose.
3. **KD-174F truth cell matches BK-KFKV's dual-stamp witness.** Canonical
   row text and `bkkfkv-replay-verify.md` BK-KFKV-1 agree precisely: broker
   stamps base offset into BOTH the served wrapper offset field AND the
   batch's inner baseOffset (bytes 0..7, CRC-neutral); no-op at base 0,
   which is why earlier byte-compare witnesses on empty partitions missed
   it. The KD-174 row correctly stays OPEN (no client negotiates magic-2
   produce; close condition unmet).
4. **Pointer coherence.** Window pointer "Mint from KD-181 (highest minted
   id is KD-180)" matches disk: canonical highest row is KD-180
   (CLOSED-WITH-EVIDENCE, Kafka recordsCount, shim token at
   `records.ex:100`), no KD-181 row exists; window carries rows
   KD-169..KD-180.

## Adversarial probes (typed findings)

- **KD-SKEP2-1 (OBSERVATION, no action)**: `kdp6-row.md`'s embedded gate
  snapshot shows `FLIP-ELIGIBLE: 1 (KD-168)` at its mint time; today
  kd_flip reports `FLIP-ELIGIBLE: 0` with KD-168 under an explicit
  registrar hold refusing cross-id evidence. This is a strengthening of
  the hold since that mint (time-of-mint snapshot drift), not a defect —
  the current state is the safer one.
- **KD-SKEP2-2 (RESOLVED-CLOSED)**: KD-174F's registrar observation 1
  flagged `lib/smalt/arm_gateway/router.ex:7202` as carrying a mis-minted
  `# KD-COVERS: KD-174` token. Verified on disk this audit: the site now
  carries `KD-COVERS: KD-175` (EXPL9-R2 F1 ATOM alias face) and the
  covers-map has NO KD-174 entry — the KD-174 row's "KD-COVERS shim: none
  yet" now matches the mechanical truth. Observation closed by this
  receipt.
- **KD-SKEP2-3 (OBSERVATION, no action)**: the `expl9r1-egress-guards.md`
  body retains EXPL9-R1's historical "KD-COVERS: KD-174 fences in place"
  KD-note prose (the receipt body is declared unmodified with a KD-175
  disposition appended disclosing the re-token). Internally disclosed;
  historical body, no repair owed.
- **KD-SKEP2-4 (COSMETIC, no action)**: window-doc mint rows are landed in
  lane-completion order, not id order (KD-179, KD-180, then KD-169..178,
  176, 177). No semantic effect; the canonical table remains ground truth.

## Gates (read-only, this tree, this session)

```
$ python3 scripts/kd_flip.py
KD-COVERS covers-map: 121 KD ids from 145 files
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1 (KD-168 registrar hold — cross-id evidence refused)
exit=0

$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 737 receipt cites across 6 registers + 2 pattern docs
+ 5 milestone docs (406 cites, 6 typed-gap skips) -> OK
exit=0
```

## Footer

Read-only lane: only this receipt written; no register, lib/, test/, or
pointer edits. No git state commands run. Worktree state audited is the
shared checkout as-found (both registers dirty from concurrent lanes;
audit is of on-disk content).
