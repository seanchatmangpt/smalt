# JA-2: Let-It-Crash Audit — silent-violation sweep

Repo: `/Users/sac/smalt` · Branch: `main` · Date: 2026-10-21 · Context: solo · READ-ONLY agent; parent persisted.

## Prior ARMFIX closures re-checked: 3/3 INTACT

## New silent-violation sites (ranked)

- **V1 — `lib/smalt/planes.ex:63-66`**: `String.to_atom` atomize of plane names is fail-open — malformed `SMALT_PLANES` input mints arbitrary atoms at boot instead of refusing. Fix class: validate against the known plane set first, raise on unknown (boot refuses via `{:invalid_plane, name}` downstream but only AFTER the atom exists).
- **V2 — `lib/smalt/egress_router.ex:880-884`**: `safe_subrouter_call` rescues and falls through with a benign default instead of re-raising or returning a typed refusal — a crashed subrouter path looks like a normal miss on the wire.
- **V3 — `lib/smalt/arm_gateway/router.ex:3291` + `lib/smalt/affidavit/seal.ex:113`**: two `engine_unavailable` catch-alls swallow without `Logger.error`/telemetry — the fail-closed envelope is correct but the operator-visible signal is silent.
- **V4 — `lib/smalt/security/ledger_writer.ex:166`**: a `rescue` around signing swallows the error silently (no log, no telemetry) — ledger entries can be dropped invisibly.

## Standing

**Standing:** PASS — all 4 findings fixed by JA-R1 (`ja-r1-silent-violation-fixes.md`; see Re-witness below), prior ARMFIX closures intact.

## Re-witness (BK-28, 2026-10-21)

All four findings re-derived on the CURRENT tree; each fix is tagged in-code `JA-R1 (Vn)` and
receipted by the JA-R1 lane in `ja-r1-silent-violation-fixes.md` (19/19 targeted
tests; landed commit `4cb91e1`). Adjacent lanes: `ja-r2-apim-atom-bridge-fixes.md`,
`ja-r3-ja16-defect-fixes.md`.

```
$ grep -n 'JA-R1 (V' lib/smalt/planes.ex lib/smalt/egress_router.ex lib/smalt/arm_gateway/router.ex lib/smalt/security/ledger_writer.ex
lib/smalt/planes.ex:64:  # JA-R1 (V1): validate against the known plane set BEFORE any atomize —
lib/smalt/egress_router.ex:947:  # JA-R1 (V2): the ONLY expected failure class here is an unmatched route
lib/smalt/arm_gateway/router.ex:3401:  # JA-R1 (V3): fail-closed envelope unchanged; the crash is no longer
lib/smalt/security/ledger_writer.ex:169:  # JA-R1 (V4): the typed {:ledger_sign_refused, ledger} refusal is
```

- **V1 FIXED — planes.ex:64-71**: `validate_name` matches against `@known_strings` FIRST, then
  `String.to_existing_atom/1`; unknown raises `Smalt.Planes.InvalidPlane` (`raise(InvalidPlane,
  plane: name)` at planes.ex:71). No atom minting from `SMALT_PLANES` input.
- **V2 FIXED — egress_router.ex:951-963**: `safe_subrouter_call` rescues ONLY `FunctionClauseError`
  (unmatched route = benign fallthrough, now `Logger.warning`-visible); every other exception class
  propagates untouched. No silent benign default on crashes.
- **V3 FIXED — router.ex:3401-3415 + seal.ex:121-133**: both `engine_unavailable` catch-alls now
  `Logger.error` (`arm_gateway affidavit seal: engine crash/exit -> :engine_unavailable`; seal.ex
  adds crash/exit/throw triple with `Logger.error`). Operator signal no longer silent.
- **V4 FIXED — ledger_writer.ex:166-180**: the sign `rescue` keeps the typed
  `{:ledger_sign_refused, ledger}` refusal + counter compensation, and adds `Logger.error("ledger_writer:
  sign failed for #{ledger} ...")` — no longer an invisible drop.
