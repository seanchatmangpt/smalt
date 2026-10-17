# CHEAT_SCAN.md

## Re-scan 2026-10-14 (second pass)

Scanner rebuilt from the `anti-llm-cheat-lsp` repo (release; binary
`target/release/anti-llm-cheat-lsp`). Scan dir: `/tmp/smalt-cheat-scan-1792022444`
(fresh copy of `~/smalt`; `deps/`, `_build/`, `_build-lane11/`, `tmp/`
physically removed this pass, plus the same
`--ignore-dirs target node_modules deps _build .git`). Consequence: this pass
sees 78 observations / 43 diagnostics vs the first pass's 2038/793 — the first
pass counted ~750 vendored-deps noise diagnostics that this copy excludes by
construction, so the comparable in-repo surface is directly comparable.

### Blockers remaining: **0 (NO)**

- Release-blocker secret `smalt-sovereign-azure-secret-key-32b!` is **GONE
  from `lib/`**. Direct grep of the whole tree: the literal now exists only
  inside this report (docs/CHEAT_SCAN.md:44,47 — quoted text). `lib/`,
  `config/`, `test/`, `scripts/` all clean (grep exit 1).
- Fix confirmed in place: `lib/smalt/arm_gateway/router.ex:69-108` — STS
  signing secret now read from `Application.get_env(:smalt, :sts_signing_secret)`
  (>=32 bytes enforced), fail-fast in prod if unset, `:persistent_term` cache
  mirroring `Smalt.Security.ReceiptSigner`. `config/config.exs:9` has the
  injectable `receipt_signing_key: nil` pattern; `:sts_signing_secret` follows
  the same shape.
- Scanner cross-check: **0 diagnostics point anywhere under `lib/`** in the
  full 43-line output.

### Diagnostics delta (43 total this pass, all non-`lib/`)

| code | location | verdict | note |
|---|---|---|---|
| CLAIM-004 | `.github/workflows/ci.yml:52,70` | FALSE POSITIVE — shell `for...done` | unchanged from pass 1 |
| CLAIM-004 | `docs/CHEAT_SCAN.md:69-74` | NOISE — this report quoting pass-1 findings (self-referential) | new surface |
| CLAIM-004 | `erl_crash.dump:183006,223259` | NOISE — crash-dump cruft; still present, still should be deleted | repo-owner |
| CLAIM-004 | `scripts/doctor.py:4` | FALSE POSITIVE — exit-code legend docstring | unchanged |
| CLAIM-004 | `scripts/release.sh:24,44,63,67` | FALSE POSITIVE — shell `for...done` / log helper | new file |
| CLAIM-004 | `scripts/release.txt:48` | NOISE — honest boundary prose "Not done here: CI workflow (lane 19 owns)" | new file |
| CLAIM-004 | `scripts/tf_smoke.sh:35,93,106` | FALSE POSITIVE — shell `done` | pass-1 rows (35,91), lines shifted |
| CLAIM-005 | `test/sdk-smoke/amqp.test.cjs:4,52` | FALSE POSITIVE — rhea receiver API `complete()` | unchanged |
| CLAIM-005 | `test/sdk-smoke/census.test.cjs:194,257` | FALSE POSITIVE — `completeMessage` / `abandonCompleteCase` are Azure Service Bus SDK method/case names (wire parity) | NEW file since pass 1 |
| CLAIM-004 | `test/security/security_hardening_test.exs:198` | FALSE POSITIVE — `{:done, i}` atom in concurrency test | unchanged |
| VERSION-004/005 | `test/smalt_arm_gateway_test.exs:206,215,238,320,509` | FALSE POSITIVE — IPv4 octets in ARM address prefixes (`10.0.0.0/16` etc.) | pass-1 rows, lines shifted +1-2 |
| VERSION-004/005 | `test/smalt_graphlaw_validator_test.exs:165,171,172` | FALSE POSITIVE — GraphLaw version-literal fixtures | unchanged |
| TEST-001 | `test/smalt_services_test.exs:339,340` | FALSE POSITIVE — Blob-listing XML wire parity (`<EnumerationResults`, `<Name>exhibit_a.pdf</Name>`) | new lines (pass 1: 207,208) |
| TEST-001 | `test/wire/egress_wire_test.exs:54,106` | FALSE POSITIVE — etag header containment / WORM message = API contract | unchanged |

### Verdict counts (this pass)

| verdict | count |
|---|---|
| TRUE-POSITIVE (smalt code defect) | **0** |
| FALSE POSITIVE — wire-parity / protocol literals / shell syntax | 24 |
| NOISE (report self-quotes, crash dump, boundary prose) | 5 |
| (diagnostics in `lib/`) | 0 |

New code landed since pass 1 (`lib/smalt/messaging/`, `data_plane/`,
`security/`, `test/sdk-smoke/census.test.cjs`, `scripts/release.sh`) produced
**zero true-positives**; every diagnostic on the new surfaces is an SDK-method
or shell-syntax false positive of the same classes already triaged in pass 1.

---

## First scan 2026-10-14

Anti-LLM-cheat scan of smalt, 2026-10-14. Scanner:
`anti-llm-cheat-lsp` (release build of the `anti-llm-cheat-lsp` repo).

Run shape: `scan --dir <copy> --ignore-dirs target node_modules deps _build .git`
(binary exposes `scan` as a raw pre-clap path; plain-text output only — no
`--json`/`--format` flag is accepted on the `scan` subcommand). Scanned a
`/tmp` copy because the scanner writes `ocel/` artifacts into the scan dir;
the canonical checkout (`~/smalt`) was not modified by the scan. Note: the walker honors
`.gitignore`, which is why `erl_crash.dump`-class cruft still surfaced (it is
listed there — scanner honoring gitignore would have dropped it).

## Receipt

- Observations: 2038
- Diagnostics emitted: 793
  - CLAIM-004 (overclaim word): 573
  - VERSION-004/005 (CalVer heuristics): 69 + 44
  - METRIC-001/002/003: 9 + 4 + 52
  - VERSION-001: 22
  - STRANGE-009/010/011: 1 + 5 + 1
  - HOLLOW-008/009: 4 + 1
  - TEST-001: 4
  - CLAIM-005: 2
  - STANDING-001: 2
- Diagnostics inside `lib/` (smalt source of truth): **0**
- Diagnostics on smalt-owned files (non-deps): 31

## Triage counts

| verdict | count |
|---|---|
| TRUE-POSITIVE (defect in smalt code) | 1 |
| FALSE POSITIVE — wire-parity / protocol literals | 15 |
| NOISE (lockfiles, deps, crash dump, shell syntax, API method names) | 777 |

## Release blockers

**RESOLVED (second pass, see top of this file).** The hardcoded STS signing
secret formerly in `lib/smalt/arm_gateway/router.ex:39` is gone from the tree
(literal now exists only inside this report as quoted text). Historical
finding:

```elixir
signer = Joken.Signer.create("HS256", "smalt-sovereign-azure-secret-key-32b!")
```

Cross-check result: the literal `smalt-sovereign-azure-secret-key-32b!`
exists at exactly one location — `router.ex:39`. The companion literal
`smalt-maa-attestation-signing-key-32b!` is **not present anywhere** in the
tree (moved or never landed). Lanes 8/12 moved the *receipt* signing key to
config (`lib/smalt/security/receipt_signer.ex:6,123` reads
`Application.get_env(:smalt, :receipt_signing_key)`; `config/config.exs` has
the `kv_master_secret: nil` injectable pattern), but the **router STS secret
was NOT moved**. This token signs Contributor/Owner-role access tokens for
the control plane on port 9443 — must block release.

Fix (owner: router/STS lane): read
`Application.get_env(:smalt, :sts_signing_secret)` (fail-fast if nil in
non-test), add `sts_signing_secret: nil` (test-only value in
`config/test.exs`) to `config/config.exs`, matching the existing
`receipt_signing_key` pattern.

## Triage table

| code | location | verdict | fix-owner-lane |
|---|---|---|---|
| — (manual grep) | `lib/smalt/arm_gateway/router.ex:39` | **TRUE-POSITIVE — hardcoded secret, RELEASE BLOCKER** | router/STS lane |
| CLAIM-005 | `test/sdk-smoke/amqp.test.cjs:4,52` | FALSE POSITIVE — `msgs[0].complete()` is the rhea AMQP receiver API; line 4 is an honest-expect-set comment | n/a |
| CLAIM-004 | `.github/workflows/ci.yml:52,70`, `Justfile:43`, `scripts/tf_smoke.sh:35,91` | FALSE POSITIVE — shell `for ... done` / `fi` syntax, not prose | n/a |
| CLAIM-004 | `scripts/doctor.py:4` | FALSE POSITIVE — docstring "0 all checks pass" is an exit-code legend | n/a |
| CLAIM-004 | `test/security/security_hardening_test.exs:198` | FALSE POSITIVE — `{:done, i}` message atom in Task.async concurrency test | n/a |
| TEST-001 | `test/smalt_services_test.exs:207,208` | FALSE POSITIVE — `String.contains?` on required Blob-listing XML (`<EnumerationResults`) = wire-parity assertion | n/a |
| TEST-001 | `test/wire/egress_wire_test.exs:54,106` | FALSE POSITIVE — etag header containment + WORM message = wire-parity / API-contract assertion | n/a |
| VERSION-004/005 | `test/smalt_arm_gateway_test.exs:203,212,235,317,507` | FALSE POSITIVE — `10.0.0`-shaped strings are **IPv4 octets** in address prefixes (`10.0.0.0/16`, `10.0.1.0/24`), not versions | n/a |
| VERSION-004/005 | `test/smalt_graphlaw_validator_test.exs:165,171,172` | FALSE POSITIVE — GraphLaw version-literal fixtures under test | n/a |
| STANDING-001 | `deps/reactor/...`, `deps/spark/...` | NOISE — vendored deps, not smalt code | n/a |
| HOLLOW/STRANGE/METRIC/CLAIM bulk | `deps/wasmex/native/...`, deps docs, `mix.lock` | NOISE — vendored third-party sources (573 CLAIM-004 hits nearly all in deps docs) | n/a |
| — | `erl_crash.dump` | NOISE — crash-dump cruft; repo hygiene: delete it (2 spurious hits) | repo-owner |

## Wire-parity whitelist (for future scans)

Required protocol literals, never flags: `Microsoft.*` provider segments,
`azure-compliant-cvm`, `management.azure.com`, `login.microsoftonline.com`,
`<EnumerationResults`, ARM error codes (`MissingApiVersionParameter`,
`InvalidApiVersionParameter`), rhea `receiver.complete()`. None of the 793
diagnostics flagged these — no scanner-side whitelist patch required this run.

---

## Re-scan 2026-10-15 (third pass, v3)

Scanner: same binary, the `anti-llm-cheat-lsp` release binary
(present, no rebuild needed; release build dated Oct 14). Scan dir:
`/tmp/smalt-cheat-scan-v3` (fresh rsync of `~/smalt`, excluding
`target node_modules deps _build _build-* .git` by construction; additionally
removed from the COPY only: all `.venv` python environments under `test/`
(py-court + s6/s8/s10 e2e suites, ~1470 vendored site-packages hits),
`tmp/`, `erl_crash.dump`, `rawssl.beam`). Run shape unchanged:
`scan --dir <copy> --ignore-dirs target node_modules deps _build .git _build-lane`.

### Headline

- Observations: 816, Diagnostics: 320 (after .venv/tmp stripping).
- Diagnostics under `lib/` (smalt source of truth): **0** — grep-verified on
  the full output. The new I-family integration modules (`ash_extension`,
  `ocel/`, `pplan`, `semantic`, `projection`, `trust_profile`, `mcp`, `dspy`,
  `runtime_contracts`, `semconv`), `auth/bearer`, `skr`, and the stress suite
  produced **zero scanner diagnostics**.
- Release blockers: **0 (NO)**. Direct grep of the canonical tree:
  `smalt-sovereign-azure-secret-key-32b!` and
  `smalt-maa-attestation-signing-key-32b` exist only as quoted text in two
  docs (`docs/CHEAT_SCAN.md`, `docs/PUBLISH_CHECK.md:21,160` — both asserting
  the literal's absence). No code/config/test/script hit.
- Old blocker fix confirmed still in place (STS signing secret via
  `Application.get_env(:smalt, :sts_signing_secret)`).

### Delta vs v2 (2026-10-14 second pass)

New surfaces scanned for the first time: `cli/` (generated Rust `smaltctl`
binary), `test/e2e/*` shell+node suites, `test/redteam/*`, `test/py-court/`,
`scripts/stress/*`, plus the new lib modules above (clean). 320 diagnostics
break down as: 113 CLAIM-004, 104 VERSION-004/005, 27 CLAIM-005, 10 TEST-001,
9 AUTH-002, 7 METRIC-003, 6 STRANGE-012, 5 ORACLE-004, 4 MUT-001, 3
VERSION-001, 3 STRANGE-009, 3 STANDING-001, 1 each RECEIPT-003, STRANGE-008/
010, HOLLOW-001/002. New diagnostic classes vs v2, all triaged:

| class | location | verdict | note |
|---|---|---|---|
| ORACLE-004 | `cli/src/custom_handlers.rs:15,20,25,104,201` | FALSE POSITIVE | `std::env::var` with safe defaults (`SMALT_ARM_URL` etc.) — standard CLI config, not a hidden oracle channel |
| MUT-001 | `cli/src/generated_boundaries.rs:8,40,42,47` | FALSE POSITIVE | file writes are the CLI's function (boundary-file receipts); scanner assumed an LSP read-only authority path — surface confusion, this is a CLI binary not an LSP server |
| STRANGE-012 | `byok.test.mjs:250`, `pipeline.test.mjs:28`, `oauth_neg.test.mjs:114`, `worm.test.cjs:48`, `state.test.mjs:441`, `ts-reality.test.mjs:110` | FALSE POSITIVE | `createHash("sha256")` is test-side custody-key/ledger-hash wire parity with the substrate's sha256 chain — matching the wire is the point; not a migration candidate |
| HOLLOW-001/002 | `cli/src/generated_cli.rs:294,295` | NOISE | `todo!`/`unimplemented!` strings appear inside a test (`no_consumer_handler_seam_survives_generation`) asserting their ABSENCE — self-referential |
| STRANGE-008 | `cli/src/main.rs:9` | FALSE POSITIVE | actually `eprintln!` on the error/exit path of a CLI binary — legitimate |
| RECEIPT-003 | `.ggen_igniter/receipts/2026-10-14.jsonl:1` | NOISE | machine-written ggen receipt (`completed_at: null` — a run in flight); tooling artifact, not smalt code |
| AUTH-002 | `cli/Cargo.toml:19`, `test/strata_compat_test.exs:12,312,316,320`, `docs/PACK_INTEGRATION/*` | FALSE POSITIVE | "CLAP" here is the strata STX1/CLAP/1.0 wire protocol (docs explicitly pin it NOT-APPLICABLE) and the `clap-noun-verb` dep name — not a fake abstraction |
| STANDING-001 | `docs/PUBLISH_CHECK.md:6,109,197` | FALSE POSITIVE | scope is stated in surrounding prose of the publish checklist |

Known classes recurred on new files with the same verdicts as v2: CLAIM-004
shell `done` (`e2e/*/run.sh`, `scripts/stress/*`, `bootstrap.sh`,
`fast_test.sh`, `dev_watch.sh`), `{:done, i}` atoms
(`security_hardening_test.exs:198,223`), JS local `const done`
(`eventhubs.test.cjs:163-193`); CLAIM-005 Azure SDK method names
(`completeMessage`, `abandonCompleteCase`, rhea `complete()`); VERSION-004/005
IPv4 octets (`smalt_arm_gateway_test.exs`, `lro_test.exs:259` = `10.9.0.0/16`,
`gate_cost*`, AZURITE_COMPARE 12.34.0 = an SDK version literal) and version
fixtures; TEST-001 wire-parity assertions (`azure-asyncoperation` header
containment in `compliance/c1_arm.exs`, semconv model-YAML containment,
egress XML); CLAIM-004 in `docs/` = this report + honest boundary prose
(self-referential).

### Verdict counts (this pass)

| verdict | count |
|---|---|
| TRUE-POSITIVE (smalt code defect) | **0** |
| FALSE POSITIVE — wire-parity / SDK names / shell syntax / CLI idioms | 30 |
| NOISE (report self-quotes, test-asserts-absence strings, ggen artifact) | 7 |
| (diagnostics in `lib/`) | 0 |

### Blockers remaining: **0 (NO)**

The tree grew substantially since v2 (cli/, e2e/redteam/py-court/stress
suites, ~15 new lib modules) and every diagnostic on the new surfaces is a
false positive or noise of already-triaged classes. The v1 hardcoded-secret
blocker remains fixed; no new true-positive surfaced in v3.
