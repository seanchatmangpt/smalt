# RECEIPT_CONTEXT_LAW — batch-context witness law (milestone-doc lane, item #2)

Window: v26.10.17. Repo: the smalt checkout root. Standing: LAW (binding from this
window forward).

## 1. The law

Every witness receipt in this repo MUST state its run CONTEXT — the shape of
the `mix test` invocation the receipt's output came from:

```
Context: solo|pair(A,B)|slice(...)|full
```

- `solo` — one test file (or one `file:line`), single `mix test` invocation.
- `pair(A,B)` — exactly two files, one invocation.
- `slice(...)` — an explicit, enumerated subset of files, one invocation;
  the file list (or a glob plus count) goes inside the parens.
- `full` — the whole suite (`just court-x2` tier, `mix test` with no file
  arguments).

A "green" claim is valid ONLY for the context named. **Per-file greens do
NOT certify suite-context behavior.** Contexts are not transitive in either
direction: a full-suite red does not by itself refute a solo green, and a
solo green never certifies the slice/full context.

## 2. Evidence (why the law exists)

- `receipts/i3-witness-sweep.md` §4 (2026-10-17): 8 test files, each green
  solo, run as ONE `mix test` invocation produced **321 tests, 71 failures** —
  all 401/`MissingBearerToken`-class cross-file shared-state artifacts (e.g.
  `Kd79BlobApiVersionWireTest` setup: "parent SA creation failed: 401").
  Every file in the batch was green in its own invocation; the batch context
  was red for the same code. Only the named context distinguishes the two
  claims.
- `receipts/r236-court-run1-red-75.md` (2026-10-17): court run-1 full tier,
  2655 tests / 75 failures, with the same modules (C4Blob, C2Keyvault, C1Arm)
  failing in the full context that show partial or solo-context greens
  elsewhere. Converse check: context labels cut both ways — a full-context
  red must be attributed to the full context, not read as refuting every
  solo green of the same file.

## 3. Receipt template line

Add exactly one line to the header block of every witness receipt:

```
Context: solo
```

or, e.g.:

```
Context: pair(test/amqp/connection_test.exs, test/amqp/event_hubs_test.exs)
Context: slice(16 modified test files, listed §4)
Context: full (just court-x2, offline tier, Excluding tags: [:amqp_wire])
```

A receipt with no `Context:` line is malformed for witness purposes;
`receipt_index.py` SUSPECT flagging (output-less receipts) is unchanged and
orthogonal — a receipt can embed real output and still be context-less, and
context-less witness claims are not admissible as gates.

## 4. Migration rule for future windows

- **New receipts** (v26.10.17 onward): `Context:` line mandatory at
  receipt creation. Authors of WO receipts add it in the header next to the
  command line.
- **Existing receipts**: no retroactive rewrite of closed-window receipts.
  Open/gate-bearing receipts in the active window gain the line on their
  next touch (rerun, flip, or correction); the line names the context the
  EXISTING embedded output was produced under, never an assumed one.
- **Gate readers** (kd_flip, court wrap, GAP flips): when citing a receipt
  as a witness, quote its context. A flip whose witness receipt lacks a
  `Context:` line or cites a green outside the needed context is not
  admitted.
- **Enforcement path** (next window): adoption in the receipt template plus
  a spot-audit of each wave's receipts (see NEXT_WINDOW.md §6 carry-forward);
  mechanical enforcement via `receipt_index.py` may follow once the template
  is stable, but is not required by this law.
