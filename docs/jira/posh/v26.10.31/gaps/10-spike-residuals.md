# GAP-10: Elixir Spike Residuals — Disposition of the 11 lib/ Fixes (v26.10.31)

Lane 10 of 17, unification-dialect migration (read-mostly). Reads:
`00-unification-dialect-decision.md`, `receipts/provider-court-20261030.md` (F2's
disclosure), `migration-ledger.md` (POSH-007), v26.10.30 gaps/13
(two-provider-limbo). Scope: for each of the 11 session-introduced `lib/` fixes
the F2 provider court required, decide and verify — does the GO provider re-home
it, does it graduate to a NEUTRAL-CORE wire law, or does it die with the spike?

> **Lane-4 landing-site note (2026-10-30, lane g04)**: the W1–W4 landing site now
> EXISTS — lane 4 absorbed the law register into
> `gaps/04-diagnostic-vocabulary.md` §"W1–W4 law register" (with the residual
> close-condition table), closing the six LANDING-SITE OPEN rows (1, 4-law, 5, 6,
> 7, 8-law, 9-law) as a side effect. The per-row verdicts table below predates
> that landing; read LANDING-SITE OPEN as CLOSED-LANDED-AT-LANE-4.

## (1) The archive stays the reference — confirmed on disk this session

- Tarball present: `tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`
  (78,080,628 bytes), sha256
  `f0fe321b6db94a4ab686a6226bef72412518cccc3ffacd78c3e01a0ddab6a16d` — byte-for-byte
  the hash the migration ledger cites. The archive is the one reference; nothing
  resurrects it.
- In-tree spike root `~/smalt/terraform-provider-smalt/` is **absent** (`ls` exit 1).
  This is v26.10.30 gaps/13 close condition 4(a) — hard-delete over tombstone —
  now witnessed as **executed**: the tombstone stub documented in gaps/13 is gone,
  and the POSH-007 receipt falsifier check (`test ! -d terraform-provider-smalt`)
  passes again. **POSH-007 falsifier still holds**: the spike cannot compile
  in-tree (no tree), the adapters Go tree is fully rowed (31/31), and the ledger's
  open deletion condition (b) — machine-gated schema-level parity — keeps the
  adapters tree in place unchanged.
- The F2 receipt's replay (extract → build_install.sh → provider_court.sh) remains
  re-runnable **from the archive only**; per the receipt, a fresh extraction also
  needs the mTLS wrapper/tfrc/proxy files from the F2 receipt's tree — a documented
  replay caveat, not a resurrection path.

## (2) Fix-by-fix disposition (11 fixes)

Verification base: the Go provider is terraform-plugin-framework v1.19.0
(`adapters/terraform-provider-smalt/go.mod`); `go build ./...` re-run this session,
exit 0. The framework owns DynamicValue/msgpack encode-decode, the diagnostics
envelope, schema serialization, and plan/apply ctx threading, so most fixes are
Go-side **by construction** — the ledger's `ported-to-go` rows already assert
this; the per-fix dispositions below make that explicit against the F2 receipt
disclosure.

| # | fix (F2 receipt numbering) | disposition | evidence |
|---|---|---|---|
| 1 | msgpack unknown sentinel: ext0 long-form `C7 05 00 "value"` → fixext1 `D4 00 00` | NEUTRAL-CORE wire law (W1) | protocol-6/go-cty law, dialect-independent. Go: framework-internal by construction. Byte-shim in the TLS proxy was built and REJECTED — length rewrite corrupts HTTP/2 DATA framing. |
| 2 | apply ctx never carried `config` (create/update read nil → "Missing required argument") | DIES WITH SPIKE | Elixir handler plumbing; framework threads ctx by construction — no such seam exists in `internal/provider/*.go`. |
| 3 | refresh tuple mismatch (`read/1` returns `{:ok, state, private}`, handler matched `{:ok, state}`) | DIES WITH SPIKE | Elixir tuple-shape contract; framework defines the Read response contract. |
| 4 | list-privates carried as response diagnostics (`to_diag/1`) | mechanism dies; law re-homed (W3) | Elixir tuple→diagnostics conversion dies; surviving law: state-adjacent payloads ride the diagnostics field, never a private channel. |
| 5 | `attr_type_atom/1` flattened every non-list proto attr type to `:string` | NEUTRAL-CORE wire law (W2) | schema types must round-trip the cty JSON type exactly — no flattening. Go: framework schema serialization by construction. |
| 6 | container types double-wrapped under `:type` | NEUTRAL-CORE wire law (W2) | second witnessed failure shape of the same round-trip law. |
| 7 | null DynamicValues on the destroy face decoded to nil (previously raised) | NEUTRAL-CORE wire law (W4a) | protocol-6/go-cty law: null/empty msgpack DynamicValue decodes to nil state, never raises. Go: framework-internal. |
| 8 | `Msgpax.pack!(nil)` iolist in a proto `:bytes` field (destroy plan encode fail) | NEUTRAL-CORE wire law (W4b) | proto bytes fields take a single binary, never an iolist. Go: framework-internal. |
| 9 | `resp/2` catch-all: ARM errors `{:arm_error, status, body}` raised FunctionClauseError → opaque gRPC "Internal Server Error" | mechanism dies; law re-homed (W3) | the clause-set mechanism is spike-internal; the law is the diagnostics-only error channel (W3) — ARM errors must surface as TF diagnostics, never as opaque wire errors. |
| 10 | to_state nil-dropping law: state must carry every schema attribute (7 resource/schema files) | RE-HOMED IN GO | framework state contract; delete → `resp.State.RemoveResource(ctx)` witnessed at `internal/provider/resource_container_app.go:741`, `resource_container_app_environment.go:313`, `resource_key_vault.go:289`. |
| 11 | delete returns null new state (not `%{}`/`removed_state`) | RE-HOMED IN GO | same framework contract as 10; `RemoveResource` greps above; `go build ./...` exit 0 this session. |

## Law register (NEUTRAL-CORE wire laws) — what the core docs must own

- **W1 (fix 1) — unknown sentinel encoding**: unknown encodes as msgpack fixext1
  `D4 00 00` (ext type 0, one-byte payload `<<0>>`), never the long-form ext
  header `C7 05 00 "value"`. TF rejects the wrong form with
  `["id"]: unsupported extension type 0x00 with len 5`. The fix lives in the
  provider's encoder, never a mid-wire shim (see the byte-shim REJECTED witness).
- **W2 (fixes 5+6) — schema type round-trip**: attr types round-trip the cty JSON
  type exactly (bool/number/map/list preserved; no flattening to string, no
  double-wrap under `:type`). Both failure shapes witnessed in the spike.
- **W3 (fixes 4+9, law-only) — diagnostics-only error channel**: state-adjacent
  payloads and errors ride the proto diagnostics field; private/tuple channels
  are not wire-proven. Pairs with lane 4's envelope (class/dialect/fix/receipt).
- **W4 (fixes 7+8) — null DynamicValue laws**: (a) a null/empty msgpack
  DynamicValue on the destroy face decodes to nil state, never raises; (b) proto
  bytes fields take a single binary.
- W1–W4 are protocol-6/go-cty law — dialect-independent by construction; they
  bind any future dialect face that speaks TF protocol 6. The mechanisms (Elixir
  clause sets, tuple normalization, `IO.iodata_to_binary/1` in `null_dv`,
  `to_diag/1`) die with the spike; only the laws migrate.

## Re-homed (Go-side, verified this session)

- Fixes 10+11: framework state contract, `RemoveResource` greps + build exit 0
  (above).
- Fixes 1, 5, 6, 7, 8: satisfied by construction (framework-owned
  encode/decode/schema) AND graduate to law register W1/W2/W4 — the Go provider
  meets them without carrying them; the laws bind the core wire docs, not the Go
  tree.
- Fixes 2, 3, 9 (mechanism) + 4 (mechanism) die with the spike; archived in the
  tarball, referenced from the F2 receipt only.

## Cross-references

- `receipts/provider-court-20261030.md` — the 11-fix disclosure (source of this
  table); byte-shim REJECTED witness; replay caveats.
- `migration-ledger.md` (POSH-007) — `ported-to-go` rows for every spike `lib/`
  file; this file's per-fix table is the fix-level refinement of the ledger's
  file-level rows.
- v26.10.30 `gaps/13-two-provider-limbo.md` — close condition 4(a) (hard-delete)
  witnessed executed this session; POSH-007 falsifier holds again.
- Lane 4 (`gaps/04-diagnostic-vocabulary.md`) — W1–W4 are an input to lane 4's
  neutral-core envelope docs.
- Lane 17 (`gaps/17-what-must-not-migrate.md`) — the spike mechanisms that die
  (2, 3, 9, 4-mechanism) belong on lane 17's must-not-migrate list.
- Lane 16 (`gaps/16-migration-sequencing.md`) — W1–W4 are phase-independent
  (protocol-6 wire law, not dialect law); the P0 freeze pins the Go provider
  binary, so W1's encoding rides the byte-identity guard as a frozen witness, not
  re-derived per phase.

## Status line

- Archive reference: **ALIVE** — tarball on disk, sha256 matches the ledger
  citation; byte-identity resting on the ledger's recorded 3-sample round-trip.
- POSH-007 falsifier: **ALIVE** — spike absent in-tree; 98/98 ledger rows; open
  deletion condition (b) (machine-gated schema-level parity) unchanged, nearest
  gate POSH-009 coverage gate with green receipt cited in the ledger.
- Disposition table: **PARTIAL** — built from the F2 receipt disclosure + real
  greps and a `go build ./...` re-run this session (exit 0). No archive extraction
  was run this session (read-mostly lane); fix-level Go behavior is by-construction
  evidence (framework contract + greps), not per-fix executed wire witnesses.
- Lane 10 file itself: **ALIVE** — written this session, exit 0 from Write.
- Overall lane 10: **PARTIAL** — archive/falsifier legs ALIVE; the open close
  condition is the W1–W4 hand-off into lane 4's neutral-core wire docs.
- Independent re-verification (annex above): **PARTIAL** — archive hash, spike
  absence, mechanism-die rows (2, 3, 4-mechanism, 9-mechanism), and re-homed rows
  (10, 11) all VERIFIED by fresh commands; the six NEUTRAL-CORE graduates
  (1, 4-law, 5, 6, 7, 8-law, 9-law → W1–W4) have **no landing site** in lane 4's
  neutral-core docs — status stays PARTIAL, not ALIVE, until lane 4 carries W1–W4.

## Verification annex (independent re-verification, 2026-10-30)

All rows re-verified this session by fresh commands from repo root `/Users/sac/smalt`.

- Archive hash: `shasum -a 256 tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`
  → `f0fe321b6db94a4ab686a6226bef72412518cccc3ffacd78c3e01a0ddab6a16d` — matches the
  ledger citation. Tarball size 78,080,628 bytes, unchanged.
- In-tree spike root: `test -d terraform-provider-smalt` → absent. POSH-007
  falsifier (`test ! -d terraform-provider-smalt`) holds.
- `go build ./...` in `adapters/terraform-provider-smalt/` → exit 0; go.mod pins
  terraform-plugin-framework v1.19.0.
- Spike-mechanism residual grep over `lib/` + `test/` (`.ex`/`.exs`,
  `attr_type_atom|to_diag|Msgpax`): **zero matches** (grep exit 1).

Per-row verdicts:

| # | disposition class | verdict | evidence (this session) |
|---|---|---|---|
| 1 | NEUTRAL-CORE graduate (W1) | **LANDING-SITE OPEN** | Law is defined and dialect-independent, but W1 does not yet appear in any neutral-core doc — lane 4 (`gaps/04-diagnostic-vocabulary.md`) carries no W1–W4 register; grep for `W[1-4]` over `docs/jira/posh/v26.10.31/` hits only this file and `00-unification-dialect-decision.md` (and the decision-doc hits are unrelated W3C/NIST refs). No test/court covers the law text. |
| 2 | die-with-spike | **VERIFIED** | mechanism grep zero matches in `lib/`+`test/`; nothing resurrects the handler plumbing. |
| 3 | die-with-spike | **VERIFIED** | same zero-match grep. |
| 4 | mechanism dies; law re-homed (W3) | **LANDING-SITE OPEN** | mechanism dead (grep), but the surviving law (state-adjacent payloads ride diagnostics) has no neutral-core landing site. |
| 5 | NEUTRAL-CORE graduate (W2) | **LANDING-SITE OPEN** | as row 1. |
| 6 | NEUTRAL-CORE graduate (W2) | **LANDING-SITE OPEN** | as row 1. |
| 7 | NEUTRAL-CORE graduate (W4a) | **LANDING-SITE OPEN** | Go-side by-construction holds (`go build` exit 0); law site open as row 1. |
| 8 | NEUTRAL-CORE graduate (W4b) | **LANDING-SITE OPEN** | as row 1. |
| 9 | mechanism dies; law re-homed (W3) | **LANDING-SITE OPEN** | as row 4. |
| 10 | RE-HOMED IN GO | **VERIFIED** | `RemoveResource` grep: 13 sites incl. `resource_container_app.go:741`, `resource_container_app_environment.go:313`, `resource_key_vault.go:289` — exactly the three the disposition cites; plus 10 more in remaining_v1/key_vault_secret/resource_group_tf. |
| 11 | RE-HOMED IN GO | **VERIFIED** | same grep + `go build ./...` exit 0. |

Open-row file:line for the six open law-site rows: the law register lives only at
`docs/jira/posh/v26.10.31/gaps/10-spike-residuals.md:54-73` (this file's "Law
register" section); the named landing site `docs/jira/posh/v26.10.31/gaps/04-diagnostic-vocabulary.md`
contains zero `W1`–`W4` references (grep verified). Closing the landing site is a
docs-only edit (no `lib/` work) and remains with lane 4's owner.

## Close conditions

1. Lane 4 accepts W1–W4 into the neutral-core wire docs — the law register above
   is the input; the laws are protocol-6/go-cty law and bind any dialect face
   speaking TF protocol 6.
2. Machine-gated schema-level parity (migration ledger deletion condition (b)) —
   pre-existing open item, not lane 10's to close; named here for the register.
3. Archive reference caveat: any future extraction must copy the mTLS
   wrapper/tfrc/proxy files from the F2 receipt's tree (per the receipt's replay
   note); never commit a resurrection into the smalt tree.
