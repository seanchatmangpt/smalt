# docimpl-9 — D10 group A mechanical crosslink rewrite

Standing: PASS
Context: solo(docs-audit D10 group A crosslink grep census; no mix test invocation)
Lane: docs-audit D10 group A (mechanical)
Date: 2026-10-18

## Scope

Batch-rewrite stale flat `docs/<NAME>.md` backticked cites to their
post-v26.10.16-restructure locations, only where the target exists on disk.

## Edits landed

- `docs/archive/NAMING_SWEEP.md` — 7 cites rewritten:
  `docs/CHEAT_SCAN.md[:n]` → `docs/archive/CHEAT_SCAN.md`,
  `docs/PUBLISH_CHECK.md[:n]` → `docs/archive/PUBLISH_CHECK.md`
  (self-quotes `docs/NAMING_SWEEP.md` left verbatim — historical ledger rows).
- `docs/archive/CHEAT_SCAN.md` — 3 cites rewritten (PUBLISH_CHECK + self path).
- `docs/archive/PUBLISH_CHECK.md` — 3 cites rewritten (CHEAT_SCAN paths).
- `CHANGELOG.md:438` — `docs/CHEAT_SCAN.md` → `docs/archive/CHEAT_SCAN.md`.
  Line 436 "moved from `docs/ARCHITECTURE.md`" kept verbatim (historical
  statement, not a live pointer).
- `docs/PACK_INTEGRATION/clap-noun-verb.md` — 2 cites rewritten:
  `docs/command-reference.md` → `cli/docs/command-reference.md` (target
  verified to exist — the ggen-generated doc lands under `cli/docs/`, so
  these were relocatable, not dangling).
- `docs/jira/v26.10.17/CORPUS_DERIVATION_DESIGN.md:80` — `docs/CORPUS_ENVELOPES.md`
  never landed (no rewrite-drafts corpus-projection file exists); left in
  place with an inline `<!-- [stale-path] ... -->` marker comment naming the
  design doc as the referent.

## Deliberately NOT rewritten (would falsify the record)

- Closed-window WOs/receipts/_LANES in `docs/jira/v26.10.14`–`v26.10.17`
  (frozen milestone records of what was owned/edited at the time): 14
  residual flat cites, all in v26.10.14.
- Historical statements: CHANGELOG.md:436, docs/explanation/architecture.md:8,
  docs/how-to/dev-loop.md:6 ("moved from `docs/<OLD>`"),
  docs/reference/ports-and-planes.md:6 ("There is no `docs/REGISTRY.md`" —
  true and already points at the live registry).

## Validation (real output)

Spot-check of 10 rewritten/named targets:

```
$ for p in docs/archive/CHEAT_SCAN.md docs/archive/PUBLISH_CHECK.md \
      docs/archive/NAMING_SWEEP.md docs/archive/RELEASE_NOTES_v26.10.14.md \
      cli/docs/command-reference.md docs/explanation/architecture.md \
      docs/how-to/dev-loop.md scripts/bench/REGISTRY.md NOTICE.md \
      docs/jira/v26.10.17/CORPUS_DERIVATION_DESIGN.md; do \
    [ -f "$p" ] && echo "EXISTS $p" || echo "MISSING $p"; done
EXISTS docs/archive/CHEAT_SCAN.md
EXISTS docs/archive/PUBLISH_CHECK.md
EXISTS docs/archive/NAMING_SWEEP.md
EXISTS docs/archive/RELEASE_NOTES_v26.10.14.md
EXISTS cli/docs/command-reference.md
EXISTS docs/explanation/architecture.md
EXISTS docs/how-to/dev-loop.md
EXISTS scripts/bench/REGISTRY.md
EXISTS NOTICE.md
EXISTS docs/jira/v26.10.17/CORPUS_DERIVATION_DESIGN.md
```

Residual live flat cites outside frozen windows and archive/:

```
$ grep -rn '`docs/\(CHEAT_SCAN\|PUBLISH_CHECK\|NAMING_SWEEP\|command-reference\)\.md`' \
    --include='*.md' . | grep -v '_build\|/deps/\|node_modules\|\.venv\|docs/archive/\|cli/docs\|moved from\|archive/' | wc -l
       14
```

(All 14 are v26.10.14 frozen-window records — intentionally left.)

## Count note

Audit estimated ~55 group-A hits; the live-pointer subset rewritable without
falsifying frozen history is 16 rewrites + 1 stale-path marker. The remainder
of the ~55 are (a) closed-window v26.10.14/15/16 WO/receipt records and (b)
historical "moved from" prose — both categories are records, not pointers.
