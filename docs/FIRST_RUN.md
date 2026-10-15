# First Run

Zero-to-green on a fresh checkout in three commands:

```bash
brew install elixir terraform just   # python3 ships with macOS / Xcode CLT
bash scripts/bootstrap.sh            # staged [n/8]; green in ~2-5 min
just up                              # substrate on http://localhost:9443
```

## What success looks like

`bootstrap.sh` prints eight `[n/8]` staged steps, each ending with
`ok (Ns)`:

```
[1/8] Prerequisites (elixir/mix/terraform/just/python3)
      ok (0s)
...
[7/8] Boot smoke (substrate up -> GET /metadata/endpoints -> teardown)
      GET /metadata/endpoints -> 200
```

and finishes with:

```
GREEN: bootstrap complete. Start the substrate with: just up
```

Any failure exits nonzero at the failing stage with the exact command
to run printed. Missing prerequisites exit 2 with the exact
`brew install <pkgs>` line.

## The 8 stages

1. **Prerequisites** — `elixir mix terraform just python3` on PATH;
   missing ones exit 2 with `brew install ...`.
2. **`mix deps.get`** — no-op when `deps/` is already satisfied.
3. **`mix compile`** — incremental after the first run.
4. **`scripts/dev_env.sh --check`** — validates
   `SMALT_SB_SHARED_KEY`/`SMALT_SDK_ROOT`/`SMALT_REPO` and running
   `scripts/doctor.py` at the end.
5. **`scripts/gen_dev_cert.sh`** — mints `.smalt/tls/{ca-cert,dev-cert,dev-key}.pem`
   (reuses existing material; idempotent).
6. **`scripts/doctor.py --fix`** — auto-fixes environment findings.
7. **Boot smoke** — starts the substrate (`mix run --no-halt`), polls
   `GET http://127.0.0.1:9443/metadata/endpoints` up to 60s, tears
   the substrate back down.
8. **Proof test** — `mix test test/smalt_test.exs` (the offline unit
   suite proof).

## Environment variables

See `.env.example` for `SMALT_SDK_ROOT`, `SMALT_REPO`,
`SMALT_TLS_CERTFILE`/`SMALT_TLS_KEYFILE`, `SSL_CERT_FILE`, and
`SMALT_SB_SHARED_KEY`. All optional — `scripts/dev_env.sh` derives
deterministic defaults and `scripts/gen_dev_cert.sh` mints the dev
PKI.

## After bootstrap

- `just up` / `just down` — start/stop the substrate (pid in
  `/tmp/smalt.pid`).
- `just doctor` — quick environment re-check.
- `just court` — the full admission court (T1..T4 + bench gate).
- `just receipts` / `just status` — recent receipts and substrate state.
- `just logs` — tail the newest `tmp/*.log`.
