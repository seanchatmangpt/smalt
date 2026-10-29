# Receipt: BK-DIGEST — digest-algorithm pin census (BK-MCPSHA lesson class)

- **Date**: 2026-10-22
- **Lane**: BK-DIGEST
- **Standing**: ALIVE
- **Context**: solo
- **Subject**: BK-MCPSHA lesson
  (`docs/jira/v26.10.22/receipts/bkmcpsha-sha-fix.md`): bare `shasum`
  defaults to SHA-1; a verification block comparing it against a sha256
  claim false-fails. Class: digest comparisons must name their algorithm.

## Census (scripts/ test/ verification/ workspace/scripts/)

Sweep: `grep -rn 'shasum( |$)'` minus `shasum -a`, plus `md5` /
`openssl dgst` minus explicit-algorithm forms, over `scripts/`, `test/`,
`verification/`, `workspace/scripts/` (node_modules excluded). Full
matched-site list:

| Site | Form | Context | Classification |
|---|---|---|---|
| `scripts/fast_test.sh:46` | bare `shasum \| cut -c1-8` | `HASH=$(printf '%s' "$FILE" \| shasum \| cut -c1-8)` — derives the per-file private build-root dirname `_build-ft-<hash>` | **non-comparison — leave.** The digest is a path→dirname naming function; it is never compared against a hash literal or claim. Pinning `-a 256` would orphan every existing `_build-ft-*` root (behavior change), out of scope. |
| `scripts/tf_enclave_loop.sh:208-209` | `openssl md5` | cert modulus vs key modulus match check (`[ "$c" = "$k" ]`) inside `snap_pair_ok` | **non-fixable-class — leave.** Both sides are computed live with the SAME named algorithm (`openssl md5`); no literal/claim cross-algorithm comparison, which is exactly the BK-MCPSHA failure shape. MD5-as-pairing-equality is sound here. |
| `scripts/bench/c11_tf_loop.sh:207-208` | `openssl md5` | same pattern as tf_enclave_loop (mirrors `tf_plan_check.sh`) | same as above — leave. |
| `scripts/witness_all.py:70` | string `"shasum"` | READONLY_PREFIXES allowlist entry (command-name list, not a digest computation) | non-comparison — leave. |
| `scripts/shim_court/lib.sh:54` | `shasum -a 256` | `shim_court_sha()` used for BASELINE/RESTORE byte-exact checks | already correctly pinned — no action. |
| `test/integration/blob_kd_fixes_test.exs`, `blob_k1_rows_witness_test.exs`, `kd130_container_exists_test.exs` | `:crypto.hash(:md5, …)` / Content-MD5 headers | Azure Blob **Content-MD5 wire semantics** (algorithm named explicitly, protocol-mandated) | correct by spec — leave. |

`verification/` (excluding node_modules) and `workspace/scripts/`: zero
digest-computation sites at all.

## Verdict

**Zero comparison-context bare-digest sites.** No script pins to change;
the BK-MCPSHA defect shape (algorithm-A output compared against
algorithm-B claim) does not currently occur in the tree — the one bare
`shasum` in a script (`fast_test.sh`) feeds a dirname, never a comparison,
and every real comparison site (`shim_court/lib.sh`, `openssl md5`
pairing checks, Elixir `:crypto.hash(:md5, …)` wire tests) already names
its algorithm on both sides.

## Re-run proof (no behavior change — nothing touched)

No scripts were edited (zero fix sites), so there is no before/after exit
pair to reproduce. Spot check that the classified sites still run:

```
$ bash -n scripts/fast_test.sh && bash -n scripts/tf_enclave_loop.sh && bash -n scripts/bench/c11_tf_loop.sh
(exit 0 — syntax clean, unmodified)

$ grep -n 'shasum' scripts/fast_test.sh
  HASH=$(printf '%s' "$FILE" | shasum | cut -c1-8)
$ grep -n 'shim_court_sha' scripts/shim_court/lib.sh
shim_court_sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
```

## KD register check

`grep -i 'shasum\|sha-1\|digest' docs/jira/v26.10.22/KNOWN_DIVERGENCES.md`
→ zero matches. **No pinion-class KD row exists** for the
bare-digest-algorithm class. Per lane scope (note, don't mint): recorded
here as a **repair-class** observation — digest comparisons must name the
algorithm; bare `shasum` is SHA-1. Candidate KD row for the registrar if
the class recurs; not minted unilaterally per GAP/KD convention.
