# Receipt: w6ax — App Config feature flags (TimeWindow + Targeting filters)

- **Date**: 2026-10-20
- **Lane**: w6ax (wave-6)
- **Standing**: PARTIAL_ALIVE (witness ALIVE on a real green tree; full-tree `--warnings-as-errors` deferred — sibling in-flight `key_vault_actions.ex:1904` mid-edit, not w6ax's surface)
- **Context**: solo

## Landed

- `lib/smalt/data_plane/appconfig_features.ex` (NEW): Azure App Config feature-flag convention —
  flags are kv rows at `.appconfig.featureflag/{name}` (content type
  `application/vnd.microsoft.appconfig.ff+json`), JSON-validated on write and read.
- `put_flag/4` (typed 400 `InvalidFeatureFlag`/`InvalidFeatureFlagName`; rides the lawful write
  path `Smalt.AppConfigRevisions.write/4` so flag writes land in revision history),
  `get_flag/2`, `list_flags/1` (flag rows only, name merged), `delete_flag/2`.
- `evaluate/3` — Microsoft.FeatureManagement semantics: missing → `:undefined`, disabled → `false`,
  no filters → `true`, filters AND-composed; unknown filter / evaluation error → `false` (conservative).
- `TimeWindowFilter` (RFC3339 From/To; one-bound subsets honored) and `TargetingFilter`
  (Users exact → Groups percentage override → DefaultRolloutPercentage fallback; deterministic
  rollout = `rem(MD5(name || 0xFF || user_id)[0:4] as uint32, 100) < pct` — MD5 chosen for
  cross-run/node stability, documented in @doc).
- No new ETS (projection of the kv plane); no router edits (module face; wire exposure is a
  3-line post-integration route arm, staged as follow-up).

## Witness (real output — isolated-beam path on the w6j2 green tree)

Replay:
`elixir -pa _build-lane-w6j2/test/lib/smalt/ebin -pa _build-coord/test/lib/jason/ebin -pa tmp/w6ax_ebin -e 'Code.require_file("tmp/w6ax_witness.exs")'`

```
F1_ON=true
F2_OFF=true
F3_UNDEFINED=true
F4_WINDOW_OPEN=true
F5_WINDOW_CLOSED=true
F6_0PCT=true
F7_100PCT=true
F8_DETERMINISTIC=true
F8B_STABLE50=true
F9_AND_FALSE=true
F10_MALFORMED_400=true
F11_LIST_BODY_400=true
F12_LIST=true
F13_DELETE=true
F14_REVISIONS=true
W6AX WITNESS: ALL FACES OK
```

## Defects caught during witnessing (both fixed before receipting)

1. `rollout_hit?/3` — `:erlang.list_to_integer(256)` charlist path raised ArgumentError on every
   targeting evaluation (F7 red, then crash); replaced with `:binary.part + :binary.decode_unsigned`.
2. Witness-side: F6 originally passed the group a fixed 100% while varying only the default —
   the group override masked the 0% default; group pct now varies with the leg.

## Falsifier

F6/F7 (0%/100% boundary exactness), F8/F8B (determinism across 50 evaluations), F4/F5
(window bounds honored), F9 (AND-composition can veto), F10/F11 (typed 400 faces) are the
non-vacuity legs — green under a broken targeting hash or bounds-ignoring window would fail them.
