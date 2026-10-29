# w6bf — Storage SAS constraint parity (sip + spr)

**Standing:** ALIVE (module tier; full-tree strict gate deferred on sibling churn — see typed deferral)
Context: solo
Date: 2026-10-20

## Surface

- `lib/smalt/auth/sas.ex` (additive, exclusive lane surface):
  - `verify/2` with `:peer_ip` opt — synthetic-peer seam: on the real wire
    callers omit it and `conn.remote_ip` (populated by Plug from `:peer_data`)
    is the origin; the egress path passes no opt, behavior unchanged.
  - `check_signed_ip/2` now refuses out-of-range with a TYPED
    `{:error, :ip_mismatch}` (was folded into :bad_signature).
  - NEW `check_protocol/2`: enforces the signed protocol constraint `spr`
    AFTER signature verification — previously spr was signed but NEVER
    checked (real parity gap). spr tokens are comma-separated subsets of
    {"https","http"}; scheme :https admitted by "https", :http requires
    explicit "http"; malformed element → fail-closed `:malformed`.
  - **Defect fixed**: `mint/3` defaulted `spr` to `"https"` while the
    verifier signs `""` when spr is absent — every token minted without an
    explicit spr failed verification. Default now `""`, mint/verify agree.
  - @doc/@spec updated.

- `lib/smalt/egress_router.ex` `blob_route_guarded/2` (additive mapping):
  - `:ip_mismatch` → 403 `AuthorizationSourceIPMismatch`
  - `:protocol_mismatch` → 403 `AuthorizationProtocolMismatch`
  - (both with x-ms-error-code header + JSON error envelope, matching the
  landed AuthorizationFailure mapping shape)

## Witness (real output, EXIT=0)

Replay:
`elixir -pa _build-coord/dev/lib/plug/ebin -pa _build-coord/dev/lib/plug_crypto/ebin -pa tmp/w6bf_ebin -e 'Code.require_file("tmp/w6bf_witness.exs")'`
(requires `Application.put_env(:smalt, :blob_account_key, ...)` — script sets it)

```
F1_SIP_SINGLE_ADMIT=true
F2_SIP_OUT_OF_RANGE_REFUSE=true
F3_SIP_CIDR_ADMIT=true
F4_SPR_HTTPS_OVER_HTTP_REFUSE=true
F5_SPR_HTTPS_OVER_HTTPS_ADMIT=true
F6_SPR_BOTH_ADMIT_BOTH=true
F7_NO_CONSTRAINT_ADMITS=true
F8_SPR_MALFORMED=true
F9_PEER_IP_SEAM=true
WITNESS_RC=0
```

## Defects found + fixed in-lane

1. **mint/verify spr-default disagreement (real defect)**: mint signed
   "https" by default; verifier signed "" — all no-spr tokens failed.
   Fixed in sas.ex:114.
2. (debug-artifact) Two corrupted witness-authoring attempts (the wave's
   Write-corruption class, in my own generation) — caught by read-back,
   rebuilt via chunked heredoc + `Code.string_to_quoted!` gate.

## Typed deferral

Full-tree `mix compile` in this window aborts on
`lib/smalt/data_plane/cosmos_query_metrics.ex` — a sibling lane's in-flight
file that landed broken mid-window (not session-introduced; my surface
compiled green in the same root earlier this window, and the witness ran
green on isolated beams from the same module sources). Strict-gate flip to
full-tree ALIVE rides the quiesced-tree integration window.

## Falsifier

Green under a broken spr check or a sip out-of-range admit would be
vacuous: F2/F4 are the decisive refusals (same token, only peer/scheme
changed), F8 is the malformed-token fail-closed leg.

See Also: KNOWN_DIVERGENCES.md (no new KD rows minted — both faces are
real-Azure parity, not divergences)
