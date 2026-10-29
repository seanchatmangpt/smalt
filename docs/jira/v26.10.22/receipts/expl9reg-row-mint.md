# EXPL9-REG — KD-175 mint (egress read_body naked-500 divergence) + KD-174 mis-mint retoken

**Standing:** ALIVE
Context: solo
Date: 2026-10-22
Lane: EXPL9-REG (owns ONE KD register row addition + this receipt; plus the
egress_router.ex token re-tokens disclosed below)

## Disposition decision (option (a) — mint, not untag)

The five EXPL-9 fences in `lib/smalt/egress_router.ex` carried
`# KD-COVERS: KD-174`. KD-174's row scope is the **Kafka legacy
message-set surface** (`lib/smalt/messaging/kafka/wire.ex` version_matrix,
magic-2 produce) — it cannot cover the egress read_body class. Mis-mint
typed: the KD-COVERS token names a divergence row it does not cover.

Chose option (a) over option (b) (plain repair, untag): the witnessed
defect is a real Azure wire divergence, not only a typed-error-contract
gap — real Azure answers **413 RequestBodyTooLarge** with a Storage
`<Error>` envelope + `x-ms-request-id`; smalt's pre-repair behavior was a
NAKED adapter 500 (empty body, no envelope, no request id; EXPL-9 witness
P3). That matches the register's divergence bar (KD-135/KD-143 precedent:
wire-observable Azure contract violation → row). The F2b crash-path fence
is repair-class typed-error-contract work, co-tagged on the row via the
shim token; the divergence proper is the oversized-body naked 500. Noted
in the row.

## Edits

1. `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical table): minted
   row **KD-175** after KD-174 — status OPEN (registered), shim token
   `# KD-COVERS: KD-175` (egress_router.ex:45/:841/:994/:1126/:3957),
   evidence = court receipt `expl9r1-egress-guards.md`, disposition =
   owner EXPL9-R1/R2, flip via `scripts/kd_flip.py --apply`.
2. `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` (pointer): minted KD-175
   bullet after the KD-174 bullet; bumped the pointer line
   "Mint from KD-175 (highest minted id is KD-174)" →
   "Mint from KD-176 (highest minted id is KD-175)".
3. `lib/smalt/egress_router.ex`: re-tokened the five mis-minted
   `# KD-COVERS: KD-174` tokens → `# KD-COVERS: KD-175`. COMMENT-ONLY
   (no code change); disclosed under the compile-freeze/disclosure law
   since EXPL9-R1/R2 lanes own the file this window.

## Verification (embedded evidence)

```
$ grep -c "KD-COVERS: KD-174" lib/smalt/egress_router.ex   # before
5
$ grep -c "KD-COVERS: KD-175" lib/smalt/egress_router.ex   # after
5
$ grep -c "KD-COVERS: KD-174" lib/smalt/egress_router.ex   # after
0
$ grep -c "^| KD-175 |" docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
1
$ grep -n "Mint from KD-176" docs/jira/v26.10.22/KNOWN_DIVERGENCES.md
4:Mint from KD-176 (highest minted id is
```

kd_flip read-only (real output, EXIT=0; the register row is freshly minted
OPEN, so KD-175 shows as flip-refused pending an unambiguous witness):

```
$ python3 scripts/kd_flip.py 2>&1 | tail -6; echo "EXIT=$?"
WITNESS-AMBIGUOUS: 2 — flip refused, disambiguate with --witness KD-ID=PATH:
  KD-174: 5 post-shim receipts carry close evidence for KD-174 — pass --witness KD-174=<path> to disambiguate: /Users/sac/smalt/docs/jira/v26.10.22/receipts/bkwrap2-regen.md; /Users/sac/smalt/docs/jira/v26.10.22/receipts/expl9r1-egress-guards.md; /Users/sac/smalt/docs/jira/v26.10.22/receipts/expl9r2-arm-guards.md; /Users/sac/smalt/docs/jira/v26.10.22/receipts/expl9reg-row-mint.md; /Users/sac/smalt/docs/jira/v26.10.22/receipts/kdfixf-register-prose.md
  KD-175: 2 post-shim receipts carry close evidence for KD-175 — pass --witness KD-175=<path> to disambiguate: /Users/sac/smalt/docs/jira/v26.10.22/receipts/bkwrap2-regen.md; /Users/sac/smalt/docs/jira/v26.10.22/receipts/expl9reg-row-mint.md
EXIT=0
```

Read-only observation for the owner lane: the KD-175 flip will need
`--witness KD-175=docs/jira/v26.10.22/receipts/expl9r1-egress-guards.md`
(the court receipt is the witness; this receipt and bkwrap2-regen.md are
mention-only candidates kd_flip correctly refuses to auto-pick).

## Falsifier

If KD-174's row were retyped to cover egress (rejected: it names
`lib/smalt/messaging/kafka/wire.ex` and magic-2 produce, zero overlap with
`lib/smalt/egress_router.ex` read_body), or if the court receipt
`expl9r1-egress-guards.md` did not witness 413 RequestBodyTooLarge with
x-ms-request-id on real HTTP, this mint would be vacuous.

## Standing

ALIVE: registers carry KD-175 in both files, pointer bumped, tokens
re-pointed, receipt-gated flip path named.

## Landing note

The coordinator's checkpoint commit 70405ff6 ("landed ... EXPL9-REG ...
owners hold their files") folded the KD-175 register edits into HEAD
before this lane's solo commit; verified via `git show HEAD:...` grep
(KD-175 row present, pointer bumped). This commit therefore carries only
the receipt. The `lib/smalt/egress_router.ex` re-token (comment-only,
5 sites KD-174→KD-175) remains in the working tree and rides the
EXPL9-R1/R2 lanes' commits — the file holds their in-flight code this
window; verified on disk: 0×`KD-COVERS: KD-174`, 5×`KD-COVERS: KD-175`
(comment-only, no code semantics touched).
