# WO v26.10.15 / 24 — SDK corpus mining: differential testing against the SDKs' own deserialization code

- **Repo:** /Users/sac/smalt
- **Insight:** probes test what we thought to ask. The SDKs embed what they
  EXPECT: parsers, model types, error maps, required-envelope shapes. A lane
  that extracts per-surface "what the SDK expects" and diffs it against
  smalt's emitted shapes finds divergences no probe touches.
- **Retro-proved:** KD-02/KD-03 (RFC-1123 dates — the blob list parser would
  have failed to parse), KD-15 (challenge params — `parseWWWAuthenticate`'s
  whitelist rejects smalt's 401), KD-04 (InvalidQueryParameterValue naming —
  the SDK's error-classifier map would miss `InvalidQueryParameter`) — all
  three were probe-found in v26.10.14 AFTER landing; corpus mining catches
  them pre-probe.

## 1. Problem

Every divergence in `KNOWN_DIVERGENCES.md` was found by hand-authored probes
(`test/sdk-smoke/`, `test/sdk-python/`) — the coverage is exactly the
coverage of the probes someone thought to write (KD-37..KD-42 are literally
"no probe cell"). Meanwhile the ground truth of "what Azure SDK clients
tolerate" is already checked into this repo:

- TS: `workspace/node_modules/@azure/*/dist/esm` — e.g.
  `@azure/keyvault-common/dist/esm/parseWWWAuthenticate.js` (the
  WWW-Authenticate param whitelist behind KD-15's ChallengeAuthPolicy
  refusal), serializer/model reflectors in `core-serialization`.
- Python: `smalt-cli/.venv/lib/python3.14/site-packages` — e.g.
  `azure/cosmos/_base.py` QueryFeed closure (`results["Documents"]` +
  `results["_count"]` — KD-07's exact expectation, at line 225-228),
  `azure/eventhub/_pyamqp/_decode.py` (positional NamedTuple frame classes —
  KD-21's 5-field `open` expectation).

## 2. Move

**Corpus extractor per SDK** (both dependency trees are already vendored in
this repo — no network, no installs):

- `scripts/corpus/ts_extract.mjs` — walks
  `workspace/node_modules/@azure/*/dist/esm`, extracts: required response
  fields per deserializer (walk `deserialize...`/`deserializeInto...` calls
  and their `...ErrorMappings`), WWW-Authenticate param whitelists, header
  expectations, RFC-1123 date-parser usage sites.
- `corpus/py/` equivalent walking `smalt-cli/.venv/.../site-packages/azure/`:
  envelope-key closures (`results["Documents"]`-style), NamedTuple frame
  arities, error-map tokens (`error.code` string tables).
- Output: `docs/jira/v26.10.15/sdk-corpus/<sdk>-<surface>.json` — a typed
  per-surface "expectation record": required fields, header names, error
  tokens, date formats, envelope keys.

**Diff report recipe** (this is the deliverable's core, not a one-shot):
`just sdk-corpus-diff` → for each surface: replay smalt's emitted shape for
that surface (from existing probe traffic or a canned fixture) against the
extracted expectation, emit `docs/jira/v26.10.15/sdk-corpus/DIFF_REPORT.md`
rows: `| surface | SDK expects | smalt emits | KD (if known) | NEW? |`.

- "NEW" rows are candidate divergences with NO existing KD row — they go to
  `KNOWN_DIVERGENCES.md` via the existing gap-sync flow (dod-10), not
  unilaterally closed.
- Accepting a probe-authored row requires an actual SDK run to confirm; the
  corpus row only nominates.

## 3. Falsifier

- **F1:** the extractor, run against a surface with a KNOWN divergence
  (KD-15 keyvault challenge params; KD-07 cosmos ReadFeed envelope), fails
  to nominate it — i.e. the corpus diff on `ts-keyvault` auth surface does
  not list the missing `authorization_uri`/`resource`/`scope` params, or the
  py-cosmos diff does not list the missing `Documents`/`_count` envelope.
  If the extractor can't re-find known divergences, it finds nothing real.
- **F2:** the extractor nominates a surface as divergent, a probe confirms
  PASS (SDK actually tolerates smalt's shape) on re-run — the extractor is
  producing false nominations and its rows cannot be trusted.
- **F3:** extractor output changes non-deterministically run-to-run on a
  frozen dependency tree (same node_modules/venv, different JSON) — the
  corpus is not a stable baseline.

## 4. Acceptance

1. F1 witness: extractor re-finds KD-15 and KD-07 from the vendored trees
   alone, no probe traffic — receipt records both nominations.
2. At least one NEW nomination confirmed by a probe run and filed as a KD
   row via gap-sync (proof the lane finds what probes miss, not just replays
   what probes found).
3. `just sdk-corpus-diff` is deterministic on a frozen tree (F3: two runs,
   byte-identical report) and lands `DIFF_REPORT.md` with zero
   unexplained "NEW" rows (each row is confirmed-divergent, confirmed-fine,
   or KD-mapped).
4. Extractors are pinned to the vendored dependency revisions and record
   them (package-lock / dist-info) in the corpus JSON header.

## 5. Files owned

- `scripts/corpus/ts_extract.mjs`, `scripts/corpus/py_extract.py` (new)
- `justfile.d/17-sdk-corpus.just` (new — `sdk-corpus-diff`, `sdk-corpus-refresh`)
- `docs/jira/v26.10.15/sdk-corpus/` (generated expectations + DIFF_REPORT.md)
- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (append NEW nominations via
  gap-sync only)
- Receipt `docs/jira/v26.10.15/receipts/24-sdk-corpus.md`
