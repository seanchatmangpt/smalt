# SYNC-1 — Batch-frame receiver: finish-and-relay (reap audit + completion)

**Standing:** **ALIVE** (compile 0 / court 11/11 / witness 9/9 PASS)
Context: solo

## Subject

- `lib/smalt/sync/{batch,frame,guard,receipt,store}.ex` (own these files),
  `lib/smalt/egress/SyncRoutes.ex`, court
  `test/internal/ath1_batch_frame_receiver_court_test.exs`.
- Build root `MIX_BUILD_ROOT=_build-bk79` (lane lease; delete at integration).
- Toolchain: asdf-pinned (OTP 29 / Elixir 1.20.4-otp-29).

## Reap-law audit (from disk)

No `docs/jira/v26.10.22/receipts/sync1-*.md` existed; no completion
notification arrived. Audited from disk: all five sync modules + SyncRoutes +
the court are landed and complete — no mid-write truncation, no compile
errors, no red tests. Nothing was incomplete; this receipt closes the
register entry.

## What was verified (nothing needed fixing)

- `MIX_BUILD_ROOT=_build-bk79 asdf exec mix compile` — exit 0. Zero errors in
  the sync modules; only pre-existing dep/infra warnings
  (plug/ash_r2rml/ggen_igniter type warnings).
- `MIX_BUILD_ROOT=_build-bk79 asdf exec mix test test/internal/ath1_batch_frame_receiver_court_test.exs`
  — **11 passed** (first run after an initial sandbox-induced mix lock-file
  error, cleared by rerun; the retry ran the real suite). Gates a–e plus
  codec/receipt pure legs: 3-frame admit + receipt round-trip, BAD_CRC32 400
  with prior admits standing (head 1), BAD_MAGIC 400 batch-fatal with Store
  untouched, ANDON 422 zero-mutation via a real law function,
  SEQ_REGRESSION 409 within- and cross-batch, chain-continuation leg.
- Response contract vs the landed client: `200 {"lastSeq":N,"receiptToken":
  "<640 hex>","frames":[{"seq","verdict":"admit"}...]}`; refusals
  `{"refusal":"<code>","serverHeadSeq":N}`. Server `Smalt.Sync.Receipt.mint/1`
  layout is byte-identical to `workspace/lib/engine/receipt.ts`
  `mintReceiptToken`: 320-byte BE — magic 0x534D4C54 / version 1 / leafCount
  u64 / 32-byte sha256-chain root / 272 zero bytes. Chain algebra matches the
  client Accumulator (`merkle.ts`, kind "sha256-chain"): first leaf
  sha256(sha256(f)), then sha256(prev_root <> sha256(f)) — root-match and
  verified:true witnessed below.
- End-to-end witness (BK-63 pattern, harness reused unmodified:
  `tmp/witness/boot.exs` partial-plane runtime — real `Smalt.EgressRouter` +
  real `Smalt.Sync.Store` via Bandit on 127.0.0.1:18443, `:anonymous` auth;
  `node tmp/witness/witness.mjs` against the real workspace engine modules
  via Node TS type-stripping):

```
[PASS] codec.crc32SelfTest :: IEEE check vector 0xCBF43926
[PASS] rt.200-shape :: status=200 lastSeq=3 tokenLen=640 frames=[{"seq":1,"verdict":"admit"},{"seq":2,"verdict":"admit"},{"seq":3,"verdict":"admit"}]
[PASS] rt.parse-320 :: ok=true bytes=320 leafCount=3 version=1 reservedZero=true
[PASS] rt.root-match :: client-recomputed=a1f5a24ec73e3181... server=a1f5a24ec73e3181...
[PASS] rt.verifyReceipt :: verified=true
[PASS] adv.bitflip-refusal :: status=400 body={"refusal":"BAD_CRC32","serverHeadSeq":3}
[PASS] adv.seq-regression :: status=409 body={"refusal":"SEQ_REGRESSION","serverHeadSeq":3}
[PASS] snapback.purge-to-head :: purged=5 newCursor=3 remaining= transitions=["SYNC_REFUSED_BY_SERVER","READY_STANDALONE"]
[PASS] snapback.planSnapback-pure :: purgeSeqIds=8,9 newCursor=3
SUMMARY: 9/9 PASS, 0 FAIL          (node exit 0)
```

## Commands / exits

```
MIX_BUILD_ROOT=_build-bk79 asdf exec mix compile                              exit 0
MIX_BUILD_ROOT=_build-bk79 asdf exec mix test test/internal/ath1_batch_frame_receiver_court_test.exs
                                                                              exit 0, 11 passed
MIX_BUILD_ROOT=_build-bk79 asdf exec mix run --no-start tmp/witness/boot.exs  exit 0 (listener up, BK63_WITNESS_BOOT_OK)
node tmp/witness/witness.mjs                                                  exit 0, 9/9 PASS
```

## Notes

- The two refusals carry `serverHeadSeq: 3` in the witness (client already at
  head 3 from leg 1) — consistent with the snapback purge-to-head leg.
- `boot.exs` carries the documented partial-plane + anonymous-auth
  deviations (BK-63 receipt); the sibling `Smalt.Store.Heir` blocker has
  since landed (`lib/smalt/store/heir.ex` on disk, untracked), so the
  partial-plane posture is belt-and-braces rather than a workaround.
- Teardown: witness listener killed, port 18443 free. `_build-bk79` left for
  the coordinator's lane-clean (integration law).
