# PUBLISH_CHECK

Hex publish readiness check for smalt 26.10.14, run 2026-10-14.
Environment: hex 2.5.1, Elixir 1.19.5, OTP 28.3.1.

## Verdict: PUBLISH-READY NO

### Blocking items

1. `mix hex.build` aborts with exit 1. The two path deps
   `ash_graphlaw` and `ggen_igniter` (both `optional: true`) are excluded
   from the package and the build is then failed by hex.
   Exact error:
   `** (Mix) Stopping package build due to errors.`
   `Dependencies excluded from the package (only Hex packages can be dependencies): ash_graphlaw, ggen_igniter`
   `mix hex.publish` will hit the same gate. Fix (mix.exs, coordinator-owned):
   consume published hex versions of ash_graphlaw / ggen_igniter, or drop them
   from the published package's deps list entirely (see gap list below).
2. ~~`docs/CHEAT_SCAN.md` declares "Release blockers: BLOCKER — still present"~~
   **CLEARED (docs-corpus-lens6 cycle 5)**: CHEAT_SCAN.md was re-run by its
   owner — "Release blockers — RESOLVED (second pass)"; the literal
   `smalt-sovereign-azure-secret-key-32b!` has zero hits in the tree
   (`grep -rn` over `*.ex`/`*.exs`, exit 1 = no match). Current code
   (`lib/smalt/arm_gateway/router.ex:72`) uses a `persistent_term` secret,
   generated on first use.
3. `docs/WIRE_PARITY.md` carries named PARTIAL gaps (EH wire tier on 5673 not
   routed to EH semantics; missing SDK smoke coverage for several surfaces).
   Documented honestly under "Coverage boundaries (honest)"; no numeric
   blocker register exists, so there is no zero-blocker gate to satisfy yet.

## 1. `mix hex.build` dry-run transcript

`--dry-run` is not a supported flag (hex 2.5.1 supports only `--output/-o`
and `--unpack`). Equivalent dry run:

```
$ mix hex.build -o /tmp/hex-smalt-check/smalt.tar
Building smalt 26.10.14
  Dependencies:
    bandit ~> 1.6
    plug ~> 1.16
    cors_plug ~> 3.0
    jason ~> 1.4
    joken ~> 2.6
    ash ~> 3.33 (optional)
  ...
  Licenses: Apache-2.0
```

No tarball was produced (build aborted). Exit code 1.

## 2. Packaged file inventory

Because the build aborts, hex prints the file list in the plan but never
produces an artifact to unpack. The printed `Files:` list is the inventory:

- `lib/` (69 files: registry, telemetry, arm_gateway, security, data_plane,
  graphlaw, messaging (amqp + event_hubs), egress_router, tls, application)
- `priv/shacl/smalt-shapes.ttl` — present
- `.formatter.exs`, `mix.exs`, `README.md`, hex default set
- `LICENSE` — present (Apache-2.0)
- `CHANGELOG.md` — present

Checks:

- No `deps/`, `_build/`, `test/`, `test/sdk-smoke/`, `.logs` in the list.
  (`test/sdk-smoke/` exists in the repo with 7 files but is not packaged.)
- Leak grep over the exact packaged set (lib/, priv/, .formatter.exs,
  mix.exs, README.md, CHANGELOG.md, LICENSE) for `athena` and absolute
  checkout paths (the naming-sweep pattern, `scripts/naming_sweep.sh`):
  **zero hits** (grep exit 1, no matches).
- No absolute paths in the packaged set.
- `erl_crash.dump` exists at repo root (CHEAT_SCAN hygiene note) but is not
  packaged. **[HISTORICAL — resolved v26.10.14]** The dump was removed
  2026-10-15 (lane 14); `.gitignore:20-21` already ignores it.

## 3a. ERROR_CODES.md regeneration check (added v26.10.14, lane 14)

Run after the leak scan, before publishing:

```
just gen-error-codes
git diff --exit-code docs/ERROR_CODES.md
```

`just gen-error-codes` regenerates docs/ERROR_CODES.md from the generator's
ANNOTATIONS table + router sources. `git diff --exit-code` must be clean: the
doc is a deterministic projection, so a diff means the committed file is stale
vs the sources — regenerate and commit before publishing.

## 3. Gate documents

See blocking items 2 and 3 above.

## 4. mix.exs gaps (coordinator-owned, reported not edited)

- **Path deps in deps list**: the two path deps fail `hex.build`. Options: (a) publish to hex and pin versions, (b) keep
  as local dev-only via `only: :dev` so hex ignores them, (c) drop from the
  package's deps list.
- **No `files:` list**: packaging uses hex defaults. Defaults already
  exclude test/, deps/, _build/; consider an explicit `files:` list
  (`lib`, `priv`, `LICENSE`, `CHANGELOG.md`, `README.md`, `mix.exs`,
  `.formatter.exs`) to pin the manifest.
- **`links` present** (`GitHub`), `licenses` present (Apache-2.0),
  description present. `source_url` is not set separately but `links.GitHub`
  satisfies hex metadata. Optional adds: `docs/` docs group, `maintainers`.
- Optional hex dep `ash ~> 3.33` is handled correctly as optional by hex.

## 5. Cleanup

`/tmp/hex-smalt-check/` retains the empty `unpacked/` dir only (no tarball
was produced by the aborted build).

---

# PUBLISH_CHECK v2

Run 2026-10-14 (second pass). Environment: hex 2.5.1, Elixir 1.19.5,
OTP 28.3.1. mix.exs changed since v1: new path deps `ash_r2rml` /
`ash_ex4pm` at `only: [:dev, :test]` (optional), new `lib/smalt/{mcp,ocel,
semantic,pplan,...}` trees landed. All runs real; tarball at
`/tmp/hex-smalt-v2/smalt.tar` (205,824 bytes), unpacked to
`/tmp/hex-smalt-v2/unpacked/contents/`.

## Verdict: PUBLISH-READY NO

Two new hard blockers; v1 blocker #1 (path-dep build abort) is RESOLVED.
v1 blockers #2/#3 (stale CHEAT_SCAN.md, WIRE_PARITY PARTIALs) are
unchanged — still open.

## 1. Build transcript (real run)

```
$ mix hex.build -o /tmp/hex-smalt-v2/smalt.tar
Building smalt 26.10.14
  Dependencies:
    bandit ~> 1.6 (app: bandit)
    plug ~> 1.16 (app: plug)
    cors_plug ~> 3.0 (app: cors_plug)
    jason ~> 1.4 (app: jason)
    joken ~> 2.6 (app: joken)
    ash ~> 3.33 (app: ash) (optional)
  ...
Package checksum: 84adfbcffb11ec76fb05b96f9f803a9859a7080aaa8e335864acf088a4a1b970
Saved to /tmp/hex-smalt-v2/smalt.tar
EXIT=0
```

v1 failed here with `Dependencies excluded from the package (only Hex
packages can be dependencies): ash_graphlaw, ggen_igniter`. Exit 0 now.

## 2. Inventory deltas vs v1

- Packaged deps in metadata.config: bandit, plug, cors_plug, jason,
  joken, ash (optional). **Both NEW path deps `ash_r2rml` and
  `ash_ex4pm` are correctly excluded** — the `only: [:dev, :test]`
  pattern held for the new deps and the pre-existing `ash_graphlaw` /
  `ggen_igniter` (`only: :dev`) deps; none appear in `requirements`.
- Packaged lib file count: 99 files under `lib/` (v1: 69) — +30 from the
  mcp/, ocel/ (+revops), semantic/, pplan/, projection/, trust_profile/,
  telemetry/semconv/, dspy/, ash_extension/ trees.
- `docs/` NOT packaged (confirmed absent from contents and from the
  `files` metadata list).
- `test/`, `deps/`, `_build*`, `erl_crash.dump`, `rawssl.beam` all absent.
- LICENSE present (Apache-2.0); README, CHANGELOG, .formatter.exs, mix.exs
  present; `priv/shacl/smalt-shapes.ttl` present.

## 3. Leak scans over the exact packaged tree

<!-- ALLOWLISTED EVIDENCE BLOCK (lane 12 naming-sweep allowlist): the lines
     below quote real past leak-hunt transcripts verbatim; rewriting them
     would falsify the recorded evidence. -->
- `grep -rn '/Users/sac'` over unpacked contents: was **1 HIT** —
  `lib/smalt/mcp/gen/smalt_mcp_surface.ttl:8`, a ggen usage comment.
  **CLEARED (docs-corpus-lens6 cycle 5)**: the comment now uses the
  `caps=<ggen-marketplace checkout>/...` placeholder form; tree-wide
  `grep -n "Users/sac"` over the ttl = no match.
- `athena`: 0 hits. Absolute paths elsewhere: 0 hits.
- Old hardcoded secret literal (`smalt-sovereign-azure-secret-key-32b!`):
  0 hits in the package. Packaged `lib/smalt/arm_gateway/router.ex:124-137`
  uses `:persistent_term` STS secret, generated on first use.

### NEW BLOCKER A — private signing key packaged

`lib/smalt/runtime_contracts/ggen/.ggen/keys/signing.key` ships in the
tarball: 64 hex chars, the checkout's private ed25519 seed. The repo's own
`lib/smalt/runtime_contracts/ggen/.ggen/keys/.gitignore` (also packaged)
says verbatim: "signing.key is this checkout's private ed25519 seed and
must never be committed". Hex packages by file list, not git — the git
ignore does not protect it. `verifying.key`,
`.ggen-v2/receipt.json`, and `.ggen-v2/receipt-log.jsonl` (full ggen
receipt chain, signature hex strings) ship alongside it. Fix: rotate the
key (it is burned once published anywhere) and exclude via explicit
`files:` list in mix.exs (coordinator-owned) or `@hex.docs`-style excludes.

### ~~NEW BLOCKER B — hardcoded-secret gate still formally open~~

**CLEARED (docs-corpus-lens6 cycle 5 re-verify)**: `docs/CHEAT_SCAN.md`
was re-run by its owner; its "Release blockers" section now reads
"RESOLVED (second pass)" and the secret literal has zero tree hits. The
gate document is no longer stale; nothing to re-run.

## 4. Remaining blockers (exact list, re-verified 2026-10-15 lens-6; lens-8 corroboration 2026-10-15)

1. **signing.key in package** (NEW BLOCKER A): rotate + exclude
   `.ggen/keys/` and `.ggen-v2/` from the package via explicit `files:`.
   **RESOLVED-for-packaging 2026-10-15 (v4, below) — tar-grep = 0; key
   ROTATION still pending (coordinator-owned).**
   Re-verified STANDING (keys on disk; `mix.exs files:` ships `lib`
   wholesale). Lens-8 corroboration 2026-10-15: fresh `mix hex.build` rc=0,
   package checksum `71461bd62c62…eec84bba`; the 5 leak paths survive in the
   inner `contents.tar.gz` (`tar -xzf -O contents.tar.gz | tar -tz | grep -cE
   "signing.key|verifying.key|\.ggen|keys/"` = **5**, expected 0). The
   outer tar's top level only shows the hex wrapper (VERSION/CHECKSUM/
   metadata.config/contents.tar.gz) — grep the INNER listing, not the outer.
2. ~~CHEAT_SCAN.md stale BLOCKER~~ **CLEARED** (see Verdict item 2;
   scan re-run, RESOLVED second pass).
3. ~~Absolute-checkout-path comment in `smalt_mcp_surface.ttl:8`~~ **CLEARED**
   (original finding quoted the scan term; redacted as prose, evidence lives
   in the v3 allowlisted evidence block below)
   (`grep -n "Users/sac"` over the ttl -> no match; placeholder form
   landed; also recorded in the v3 section below).
4. WIRE_PARITY.md named PARTIAL gaps (carried from v1; honest, no numeric
   gate yet) — now tokenized `GAP(...)` per the wire-parity convention
   (3 blob, ledger, cosmos).

Verdict stands PUBLISH-READY NO until 1-3 clear; 4 is documentation-honesty,
not a gate.

---

# PUBLISH_CHECK v3

Run 2026-10-15 (third pass). Environment unchanged: hex 2.5.1, Elixir 1.19.5,
OTP 28.3.1. mix.exs gained an explicit `files:` list + `exclude_patterns`
(coordinator fix after B6 found the signing key shipping). Tarball
`/tmp/hex-v3.tar` (checksum `c1375605fc9a17432befb7fec28fde45240961f4d130a7f7e4ae049d02fdfad6`),
pre-fix; rebuild `/tmp/hex-v3b.tar` (checksum
`be5759fa00a6b60b3013d39aa92c59d8a86614f6b907c275a3a78922fa1a09a8`, 215,040
bytes) after the `smalt_mcp_surface.ttl` comment fix below.

## Verdict: PUBLISH-READY NO (one blocker remains)

v2 blocker 1 (signing.key) — **NOT FIXED.** v2 blockers 2-4 — FIXED/OK
(see below).

## 1. v2 blocker re-checks

1. **key-leak — RESOLVED-for-packaging (v4, below; tar-grep 5 → 0; rotation
   still pending, coordinator-owned).** Historical: `mix hex.build` exits 0, but the packaged
   contents still contained all 5 leak-pattern paths:
   - `lib/smalt/runtime_contracts/ggen/.ggen/keys/signing.key` (64-hex
     private ed25519 seed, read from the unpacked tree: first bytes
     `655a399656e7d1f4...`)
   - `.ggen/keys/verifying.key`, `.ggen/keys/.gitignore`
   - `.ggen-v2/receipt.json`, `.ggen-v2/receipt-log.jsonl`
   `tar -tzf | grep -cE "signing.key|verifying.key|\.ggen|keys/"` = **5**
   (expected 0). Root cause: `exclude_patterns:
   ["**/.ggen/**", "**/keys/**", "**/*key*.pem"]` does not match — hex's
   exclude globs are matched against each file's path relative to its
   `files:` entry, and `**` in hex's glob implementation does not traverse
   into dot-directories (`.ggen`, and `keys` under a dot-dir), so none of
   the three patterns ever fire. `**/*key*.pem` additionally can never
   match: the keys have no `.pem` extension. Fix (mix.exs, coordinator):
   either add `lib/smalt/runtime_contracts/ggen` handling via patterns hex
   actually matches (e.g. `exclude_patterns: ["lib/smalt/runtime_contracts/ggen/.ggen/**", ...]` verified against a real `mix hex.build`,
   or simplest and provable: `rm -r` the `.ggen*` dirs from the packaged
   source dir isn't possible for hex, so the robust fix is moving the
   runtime-contract fixtures out of `lib/` (e.g. to
   `test/fixtures/runtime_contracts/` or `priv/`-less `ggen/` dir outside
   the `files:` list) — fixtures are not needed at runtime. Alternatively
   delete the burned `.ggen/keys/` tree from the checkout entirely.
   **The key must be rotated regardless: it shipped in the v2 tarball
   bytes.** Until the paths stop appearing in `tar -tzf`, the gate fails.
2. **mcp ttl comment path — FIXED.** (ALLOWLISTED EVIDENCE BLOCK — quotes the
   real v3 leak-hunt transcript verbatim; not scrubbed.)
   `lib/smalt/mcp/gen/smalt_mcp_surface.ttl:8`
   carried `--query caps=/Users/sac/ggen-marketplace/...` in a ggen usage
   comment. Rewritten to
   `--query caps=<ggen-marketplace checkout>/packs/elixir-mcp-a2a-pack/queries/mcp_capabilities.rq`.
   Rebuild `/tmp/hex-v3b.tar` after the edit: `grep -rl '/Users/sac'` over
   the unpacked contents = **0 hits**; `athena` = **0 hits**.
3. **CHEAT_SCAN stale blocker — FIXED.** `docs/CHEAT_SCAN.md` "Release
   blockers" section updated: the pass-1 "BLOCKER — still present" heading
   now reads "RESOLVED (second pass, see top of this file)" with the
   historical finding preserved, matching the second-pass section that
   already recorded the secret literal gone from the tree (grep exit 1
   re-verified this pass: literal `smalt-sovereign-azure-secret-key-32b!`
   has zero hits in lib/config/test/scripts).
4. **WIRE_PARITY partials (doc-honesty) — OK, reference current.**
   Spot-reverified this pass: `lib/smalt/mcp/router.ex` exists and serves
   `mcp_port` default 9545; `lib/smalt/data_plane/purview_atlas.ex`,
   `data_plane/kql.ex`, `messaging/amqp/delivery_encoder.ex` all exist as
   referenced; registry admitted-types count = 38 matches the doc's "38
   admitted resource types"; filetime dialect references
   (`delivery_encoder.ex` + `runtime_contracts`) present. The doc's
   coverage-boundaries section is honest; no stale PARTIAL text found.

## 2. Inventory verification (both builds)

- All runtime lib dirs INCLUDED: `mcp/`, `ocel/`, `pplan/`, `semantic/`,
  `projection/`, `trust_profile/`, `dspy/`, `ash_extension/` all present
  in the unpacked `lib/smalt/` (v3b listing re-read from disk).
- test/-only content NOT packaged: zero `test/` dirs and zero `*_test.exs`
  files in the unpacked tree; `docs/`, `deps/`, `_build*`, `scripts/`,
  `erl_crash.dump`, `rawssl.beam` all absent.
- `priv/shacl/smalt-shapes.ttl` present in both builds.
- `mix hex.build` exit 0 both runs; metadata deps list unchanged from v2
  (bandit, plug, cors_plug, jason, joken, ash optional; ash_r2rml /
  ash_ex4pm / ash_graphlaw / ggen_igniter correctly absent).

## 3. Remaining blockers (exact list)

1. **signing.key + ggen receipt chain still ship** (v2 blocker 1) —
   **RESOLVED-for-packaging 2026-10-15 (v4, below)**: the `.ggen{,-v2}`
   trees were deleted from `lib/` and the receipt chain relocated to
   `test/fixtures/runtime_contracts/ggen/` (outside `files:`). Tar-grep
   gate now **0** (was 5). `exclude_patterns` remains dead-by-design
   (belt-and-suspenders only; the gate is the physical tree + tar-grep).
   Key ROTATION still pending — coordinator-owned, the seed already
   shipped in the v2 tarball bytes and is burned.
2. WIRE_PARITY doc-honesty gaps (SDK smoke coverage for Sentinel, Purview,
   Ledger, Attestation, Key Vault, Resource Graph) remain documented, not
   gated.

Verdict: **PUBLISH-READY NO** until blocker 1 clears. Recheck command:

```sh
mix hex.build -o /tmp/hex-vN.tar && mkdir -p /tmp/hex-vN-x && \
tar -xf /tmp/hex-vN.tar -C /tmp/hex-vN-x && \
tar -tzf /tmp/hex-vN-x/contents.tar.gz | \
  grep -cE "signing.key|verifying.key|\.ggen|keys/"   # must print 0
```

## 4. Artifacts

- `/tmp/hex-v3.tar` (pre-fix, checksum `c13756...dfad6`)
- `/tmp/hex-v3b.tar` (post ttl-fix, checksum
  `be5759fa00a6b60b3013d39aa92c59d8a86614f6b907c275a3a78922fa1a09a8`,
  215,040 bytes), unpacked at `/tmp/hex-v3b-tree/`


---

# PUBLISH_CHECK v4 (lane 11, 2026-10-15)

Decision (c) hybrid executed (work order V261014-11). File work only — key
rotation deliberately NOT performed (coordinator-owned, post-window).

## Changes

- Deleted `lib/smalt/runtime_contracts/ggen/.ggen/` (signing.key,
  verifying.key, .gitignore) and `lib/smalt/runtime_contracts/ggen/.ggen-v2/`
  via `rm -rf` (coordinator commits the deletion; `git rm` is a git state
  change and was out of lane scope).
- Moved `receipt.json` + `receipt-log.jsonl` to
  `test/fixtures/runtime_contracts/ggen/`; updated the path in
  `test/runtime_contracts_test.exs` (cross-anchor fence).
- `mix.exs` package comment corrected: exclude_patterns documented as
  dead-by-design (per-entry matching, no dot-dir traversal, no `.pem`
  extension); the gate is the physical tree + the tar-grep below, NOT glob
  semantics. `files:` list unchanged.

## Gate (real output, this pass)

```
$ mix test test/runtime_contracts_test.exs
28 tests, 0 failures        (cross-anchor fence green)

$ mix hex.build -o /tmp/hex-lane11/smalt.tar
Package checksum: b3f377cd86287191cf38e0181935a78bd54e1964af8af27c67b62bf67cc363d9

$ tar -xzOf /tmp/hex-lane11/smalt.tar contents.tar.gz | tar -tz | \
    grep -cE "signing.key|verifying.key|\.ggen|keys/"
0                            (was 5; grep exit 1 = zero matches)
```

## Verdict: PUBLISH-READY YES (packaging); rotation pending

Blocker 1 (signing.key/receipt chain in package) is RESOLVED-for-packaging.
One deliberate follow-up remains, not a packaging gate: the burned ed25519
seed must be ROTATED (new seed to `cli/.ggen/keys/` + fixture location,
re-signed receipt chain with byte-identical BLAKE3 pins) — coordinator-owned.
`cli/.ggen/keys/` is an unpackaged dev-only key copy: hex packaging never
includes `cli/` (absent from `files:`).

## Artifacts

- `/tmp/hex-lane11/smalt.tar` (checksum
  `b3f377cd86287191cf38e0181935a78bd54e1964af8af27c67b62bf67cc363d9`)
