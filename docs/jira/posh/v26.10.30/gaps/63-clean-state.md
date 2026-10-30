# 63 Clean-State Audit (DoD lane 10/16)

Status: ALIVE — one real clean→build→test cycle executed + bare-clone dry-audit complete (2026-10-30).

Audit surface: the four clean mechanisms over the posh window; durability-law
verification by execution, plus a dry-audit of the fresh-clone path.

## 1. Clean-surface tabulation (what each deletes vs preserves)

| Surface | Deletes | Preserves |
| --- | --- | --- |
| `just posh-clean` (justfile.d/58-posh.just:649) | `tmp/posh/` (court logs, tfrc, gate receipts), `posh/bin/` (bin/posh, bin/poshvet), `adapters/terraform-provider-smalt/terraform-provider-azurerm` (provider plugin binary) | `posh/var/` (andon + dx-events durable receipt chain — untouched), `posh/default.pgo`, `posh/run` recreated on `make run`, coverage.out lives in posh/ root (only removed by make clean) |
| `posh: make clean` (posh/Makefile) | `posh/bin/posh`, `posh/coverage.out`, `posh/run/` (UDS socket dir) | `posh/var/` — explicit comment in the Makefile: "durable state, deliberately outside posh-clean's rm -rf tmp/posh as well"; also preserves `bin/poshvet` (only `bin/posh` is rm'd), `default.pgo`, `tmp/posh/` |
| Adapters `make clean` (adapters/terraform-provider-smalt/Makefile) | the provider plugin binary `terraform-provider-azurerm` in the adapter dir only | `bin/` of posh, `tmp/posh/`, posh/var, everything else — smallest surface of the four |
| `just lane-clean` (justfile.d/06-lane-cleanup.just) | repo-root `_build*` dirs EXCEPT canonical `_build`, skipping any dir live-referenced (lsof +D, beam/elixir cwd, `ps eww` MIX_BUILD_ROOT env) — with `lane-clean-dry` for the du -sh census | canonical `_build`, all source, `posh/var`, `tmp/posh` (not a `_build*` dir), lane receipts/docs |

Durability law: `posh/var/andon.jsonl` is preserved by all four surfaces; the
posh Makefile clean carries the law as an in-file comment; `posh-clean` gets
there by omission (`tmp/posh` is swept, `posh/var` never appears in any rm).

## 2. Witness cycle (executed, posh/)

1. Pre-clean snapshot: `sha256 var/andon.jsonl var/dx-events.jsonl > /tmp/posh-var-before.sha`; `var/andon.jsonl` = 17 lines, mtime 13:49.
2. `make clean` — removed `bin/posh`, `coverage.out`, `run/`; `var/` intact. (My trailing `ls run` exited 1 on the now-absent dir — probe artifact, not a clean failure.)
3. `make build` — exit 0, PGO:ON (`-pgo=default.pgo`), version stamp `f0e0a125-dirty`, `bin/posh` rebuilt.
4. `go test ./...` — exit 0, all packages ok (27 ok, 1 no-test-files).
5. Durability check: `sha256 -c /tmp/posh-var-before.sha` — andon.jsonl byte-identical (b03b9e69…543110), 17 lines; dx-events identical (87808e7b…ab01f6).
6. Restoration: none required — clean destroyed only regenerable artifacts and the build regenerated them; `var/` was never touched.

ALIVE: real gate + real output above; standing ALIVE for the posh make-clean surface.

## 3. Bare-clone dry-audit (NOT executed — substrate held mid-court by lane 38)

Fresh-clone question set, answered from disk, with bootstrap-stage mapping
(recipe: `just posh-bootstrap`, lane 56 = gaps/56-bootstrap-landing.md):

| Question | Finding | Bootstrap stage |
| --- | --- | --- |
| protobuf regen seeding before escript build? | **Non-gap for the current surface.** No `.pb.go` in posh/ (grep empty); the Go provider consumes the protobuf layer via Go module deps (`adapters/terraform-provider-smalt/go.mod` pins hashicorp plugin protocol deps) — vendored, no regen step exists or is needed. The escript build (justfile.d/57-tf-provider.just `mix escript.build`) targets the Elixir spike provider that was archived and deleted 2026-10-30 (RESOLUTIONS.md: spike archived at tmp/spike tar sha256 f0fe321b…, then deleted). The "protobuf" hits in lane 38's court logs are the `protocol_ex` hex package, a different thing. | none — do not add a stage |
| TLS dev certs mint on boot? | **No minting step exists in the posh surface.** `posh.yaml` has no TLS keys; `k8s/posh-sidecar.yaml` is plain HTTP; gap 03 already registers kind ingress as plain-HTTP (HIGH). Not needed for clone-to-green; kind TLS parity is GAP03's close condition, not bootstrap's. | none |
| kind images absent on fresh clone? | **Covered.** S3 (`just kind-up kind-images kind-deploy` with `SMALT_KIND_BACKEND_IMG=smalt:local` pinned) + S4 (crictl image check) handle it; the disk preflight (20 GB kind-node floor) is the known remaining blocker class (gap 25: witnessed FAIL 0/8 on disk 15864MB < 20000MB). | S3/S4 (exists) |
| posh.yaml present? | **Yes** — git-tracked (`git ls-files` confirms), regenerable-free config, present on any clone. | S1/doctor |

### Bootstrap-stage additions (gap list)

1. **G63-1 (Medium):** `posh/bootstrap` S1/doctor does not preflight PGO seed: `default.pgo` IS git-tracked, so fresh clones get it — but if it is ever moved out of git (perf hygiene), `make build` silently degrades to `PGO:OFF` (Makefile auto-detects and prints `PGO:OFF`). Add a doctor WARN (not FAIL) when `PGO:OFF` is chosen on a build declared PGO:ON-intended, so PGO degradation is loud. No stage needed today — loud-skip only.
2. **G63-2 (Medium):** `lane-clean` vs `posh-clean` overlap: `lane-clean` sweeps `_build*` only; `posh-clean` sweeps `tmp/posh` — a fresh-clone rehearsal (`git clean -fdx`-class wipe) is not a single command anywhere: it needs posh-clean + lane-clean + `rm -rf posh/run` (make clean covers) — document `just posh-clean` as the posh-window wipe primitive in the runbook (gap 12) and add a `posh-clean-all` (posh-clean + lane-clean-dry → lane-clean) composite only if a second use appears (ERRC: do not generate until demanded).
3. G63-3 (Low): `posh/var/` is untracked-and-not-ignored: a `git clean -fdx` clone-rehearsal WOULD destroy the durable andon chain (make clean and posh-clean preserve it; `git clean -fdx` does not). Add `posh/var/` to .gitignore (ignore, not delete) so clean-rehearsals via git clean stay inside the durability law — one-line diff, coordinator-owned (`.gitignore` was not in this lane's files).

## 4. Standing

- Executed witness: ALIVE (§2, real commands + exits above).
- Dry-audit: complete; 0 of the 4 posed bare-clone risks is a live gap in the current surface (protobuf: non-gap; TLS: non-gap, GAP03-owned; kind images: covered by S3/S4; posh.yaml: tracked).
- Open items: G63-1/2/3 above; durability law holds across all four surfaces.
