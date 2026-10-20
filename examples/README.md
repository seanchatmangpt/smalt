# examples

Runnable examples for the smalt local cloud-edge emulator. Each example
boots (or reuses) a real substrate, exercises a real wire surface, and
cleans up after itself. No mocks: every example hits live listeners on
loopback.

## Prerequisites

- smalt repo built at least once (`mix compile` has run, or run
  `bash scripts/bootstrap.sh` once).
- Free loopback ports 9443/9444/8443/5672/5673/9545, or point the
  examples at your own running substrate via `SMALT_ARM` /
  `SMALT_EGRESS` / `SMALT_MCP` env overrides.

## Examples

### quickstart.sh — tour all planes over real HTTP

```bash
bash examples/quickstart.sh
```

Boots a lane-private substrate (block `c50`, anonymous auth),
then walks each plane over the wire:

1. control plane (9443): `GET /metadata/endpoints`, STS token mint,
   `GET /subscriptions`, resource-group create/list/get/delete,
2. data plane (8443): Cosmos DB create/list, blob container create,
   blob put/get round-trip, queue create/send/receive,
3. identity plane: KeyVault key create/get (via the egress router).
   The integration plane (AMQP) is out of scope here — it needs an
   AMQP 1.0 client, see `docs/tutorials/planes-profiles.md`.

Exits 0 on full success, nonzero (with the failing step printed) on
the first wire failure. Teardown happens via `trap`.

### python_client.py — stdlib-only Python client

```bash
python3 examples/python_client.py
```

Same walk as the quickstart, in ~150 lines of pure stdlib
(`urllib.request`): STS token mint → ARM resource-group CRUD → blob
round-trip. Run it against an already-running substrate
(`SMALT_ARM`/`SMALT_EGRESS` env overrides honored); it never boots
the substrate itself.

## Booting your own substrate first

```bash
scripts/substrate-ctl up --block c50 --auth anonymous
# ... run examples with SMALT_ARM=http://127.0.0.1:9443 ...
scripts/substrate-ctl down --block c50 --mode owner
```

`substrate-ctl` is reuse-else-boot: if a substrate for the block is
already up it reuses it and leaves teardown to the owner. Anonymous
auth keeps examples dependency-free; pass `--auth enforce` and
`SSL_CERT_FILE=.smalt/tls/ca-cert.pem` for the bearer-token court
shape used by `verification/py/run.sh`.
