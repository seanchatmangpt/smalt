# EXPL12-W: ARM wire path KD-15 handshake + typed STS ANDON (EXPL12V-F1 repair)

Standing: ALIVE · Context: solo · 2026-10-22 · Lane EXPL12-W

Subject: `smalt-cli/smalt_cli/wire.py`, `smalt-cli/smalt_cli/commands/monitor.py`,
new court `smalt-cli/tests/test_ty_arm_handshake.py`. Repairs EXPL12V-F1
(`docs/jira/v26.10.22/receipts/expl12v-auth-uniform.md`): arm_put/arm_get
pre-attached `bearer_for_arm()` — no tokenless-first leg, and `bearer_for_arm`
degraded silently to tokenless (`return {}`) on STS failure.

## Fix (wire.py)

- New `wire.arm_request(method, url, *, json_body, params)` — the KD-15
  challenge handshake, same contract as `kv_request`/`cosmos_request`:
  tokenless first touch, on 401 mint via `_sts_token()` and retry once with
  the bearer. `arm_put`/`arm_get` are now one-line wrappers over it.
- `bearer_for_arm()` silent degradation deleted: STS mint failure is now a
  typed ANDON (red stderr, `typer.Exit` code 1), never a tokenless fallback.
- `monitor.py` `metrics` + `endpoints` ported from direct-bearer
  `httpx.get(..., headers=wire.bearer_for_arm())` to `wire.arm_request`
  (same handshake); unused `httpx` import dropped.
- monitor `metrics` api-version fix (BK-MON-1): ALREADY LANDED on disk by the
  EXPL12-D owner (`extra = {"api-version": "2024-02-01"}` present at HEAD
  working tree) — not this lane's edit; nothing to apply.

## Falsifiers — all witnessed

1. **arm_get tokenless-first against :enforce (live, shared substrate 9444
   TLS twin, SSL_CERT_FILE=ca-cert.pem, cold cache)** — leg trace
   (instrumentation wrapper over httpx.Client.request; wire traffic real):

   ```
   ARM_GET status: 404   (resource group lookup, bearer-retried)
   LEGS: GET tokenless | POST STS | GET bearer
   STS mints: ['https://127.0.0.1:9444/oauth2/v2.0/token']
   ```

   The old code traced `GET bearer` only (EXPL12-V table); the challenge leg
   now fires.

2. **STS down -> typed ANDON, never silent tokenless** — court
   `test_sts_refusal_is_typed_andon_never_silent_tokenless`: a REAL local
   http.server face that 401-challenges data requests and 404s the token
   endpoint (no mocks; the enforce STS accepts any creds so it cannot be the
   failure face). `wire.arm_get` -> 401 -> mint fails -> `typer.Exit` code 1
   (ANDON), never a tokenless retry.

3. **CLI face rides the handshake** — `monitor endpoints` cold against
   :enforce exits 0 (challenge -> mint -> 200 when challenged;
   `/metadata/endpoints` itself is the tokenless-open bootstrap face, so that
   one 200s raw — noted, not a defect).

4. **monitor metrics** — lane-private anonymous substrate: existing court
   `test_metrics_live_custom_metric_series` passes on the new arm_request
   path (200, series_count 1, real accumulator rows). Against the shared
   lived-in substrate: `ANDON monitor metrics refused (HTTP 500)` exit 1 —
   the pre-existing BK-MON-2 substrate defect, honestly refused (typed ANDON,
   not silent). Substrate-side, out of this lane's files.

## ty suites (fresh, lane SMALT_CLI_LANE=expl12w, .venv-cli)

```
enforce session:   35 passed, 2 skipped, 114 deselected in 70.64s
anonymous session: 37 passed, 114 deselected in 42.66s
```

Includes the 3 new `tests/test_ty_arm_handshake.py` courts plus the
pre-existing storage/cosmos/kv/servicebus/deployment/monitor/login suites.

## Scope

No Elixir/lib/ edits. Files touched: `wire.py`, `commands/monitor.py`,
`tests/test_ty_arm_handshake.py` (new), this receipt. `bearer_for_arm()` is
still called by `storage._blob_request` — now also loud-on-STS-failure via
the same ANDON path (previously it silently skipped the bearer retry on mint
failure; the resulting 401 already andon'd downstream, the failure point is
just earlier and typed now).
