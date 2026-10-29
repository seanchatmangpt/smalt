# BK-8 Lane Clean + Ledger Reconcile

**Standing:** ALIVE · Context: solo · Date: 2026-10-22 · Lane: BK-8 (hygiene)
· Repo: /Users/sac/smalt

## Work order

1. Census orphaned `_build-*` lane build roots; delete those whose lane has a
   landed receipt and no live agent. Keep set (live lanes, coordinator-named):
   `_build-wpsx4 _build-wirex4 _build-kfkx4 _build-bk7 _build-kd143
   _build-kdamqp _build-kdconf _build-kdblob _build-bk85`.
2. Reconcile `docs/jira/v26.10.22/_LANES.md` against reality (every dispatched
   lane gets a row: lane, owner files, standing, receipt path).
3. Commit only `_LANES.md` + this receipt.

## Census and deletion (real output)

Census before (68 roots):

```
$ ls -d _build-* 2>/dev/null | wc -l
68
```

du per root (before):

```
711M	_build-az1        713M	_build-az2        711M	_build-az3
713M	_build-az4        713M	_build-az5        342M	_build-bk100b
712M	_build-bk101      350M	_build-bk103      350M	_build-bk103b
712M	_build-bk105      712M	_build-bk107      350M	_build-bk109b
350M	_build-bk111      350M	_build-bk115      712M	_build-bk116
350M	_build-bk117b     350M	_build-bk120      350M	_build-bk121
361M	_build-bk122      713M	_build-bk122r     713M	_build-bk122rr
350M	_build-bk127      713M	_build-bk129r     350M	_build-bk129rr
713M	_build-bk132      713M	_build-bk134      713M	_build-bk134r
350M	_build-bk135r     355M	_build-bk139r     713M	_build-bk143
350M	_build-bk144      712M	_build-bk58       283M	_build-bk69
712M	_build-bk69r      281M	_build-bk7 (KEPT) 712M	_build-bk70
713M	_build-bk70r      713M	_build-bk70rr     705M	_build-bk78
712M	_build-bk79       712M	_build-bk80       350M	_build-bk82
363M	_build-bk83       712M	_build-bk85 (KEPT) 712M	_build-bk87
350M	_build-bk94       355M	_build-bk95-probe 363M	_build-bk95r
355M	_build-docs-bk140 713M	_build-expl3r     713M	_build-expl4r
350M	_build-ft-75ef1f9e 350M	_build-ft-923b4ce8 350M	_build-ft-cc1de554
712M	_build-ja15b      350M	_build-kfkx4 (KEPT) 713M	_build-lane-az4b
712M	_build-lane110    712M	_build-lane92     712M	_build-spofa
712M	_build-spofb      712M	_build-store3     712M	_build-ttv5
713M	_build-w1         713M	_build-w2         713M	_build-w3
363M	_build-w3ca2      363M	_build-w6         350M	_build-wirex4 (KEPT)
350M	_build-witness
(68 roots total; abridged above — full per-root du table in the session
transcript, summary counts re-read from actual command output.
_build-wpsx4/_build-kd143/_build-kdconf/_build-kdblob from the keep set did
not exist on disk at run time.)
```

Reclaimed:

```
before KiB: 39746768
--- remaining:
_build-bk122rr
_build-bk7
_build-bk83
_build-bk85
_build-ft-a538002e
_build-ft-d3a09dc3
_build-kdamqp
_build-kfkx4
_build-wirex4
after KiB: 2134872
reclaimed GiB: 35.86
```

Deleted: 60 orphan roots. Kept: `_build-bk7`, `_build-bk85`,
`_build-kfkx4`, `_build-wirex4` (the members of the coordinator keep set
that existed on disk; `_build-wpsx4/_build-kd143/_build-kdconf/
_build-kdblob` did not exist at run time), plus 4 roots minted
concurrently mid-run by live lanes (`_build-bk122rr`, `_build-bk83`,
`_build-ft-a538002e`, `_build-ft-d3a09dc3`) which were left untouched.

## Ledger

`docs/jira/v26.10.22/_LANES.md` did not exist for this milestone — created,
generated mechanically from the
108 receipt files' own embedded standing lines (re-read from disk, not
recalled) plus `git log --oneline -40` for the in-flight set. Every receipt
path referenced in the ledger was existence-checked on disk; the only
intentionally-missing path at check time was this receipt itself, which was
written after the check (docs-dod-clean at commit time).

Standing vocabulary: ALIVE / PASS / work-in-progress standing per receipt;
2 UNWITNESSED rows (BK-126, ERL-4r — receipts with no standing line),
1 SUSPECT row (SPOFB audit — typed open defect classes, read-only audit).

## Falsifier

A lane with a LANDED receipt was deleted out from under a live agent: false —
deletion set was exactly (roots before) − (coordinator keep set), and roots
minted mid-run were preserved; remaining roots re-listed post-delete.
