# POSH-007: migration ledger — Elixir provider spike -> posh

> Status: REMOVED — archived at `tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`
> (sha256 `f0fe321b6db94a4ab686a6226bef72412518cccc3ffacd78c3e01a0ddab6a16d`,
> 11957 entries), root tree deleted 2026-10-30. Per-file ledger at
> `receipts/migration/terraform-provider-smalt-ledger.md` (31 Go-port rows + 67
> root-spike rows); ERRC-delete receipt
> `receipts/migration/posh007-errc-delete-receipt.json` (APPLIED).
> Disk finding: `adapters/terraform-provider-smalt/` holds the Go provider, not an
> Elixir spike — the Go source is the ported authority (see ledger preamble).

## Task
Track disposition of the 2026-10-30 Elixir-provider lanes
(terraform-provider-smalt/): per file — port to Go / discard / keep-as-reference.
Protocol facts worth carrying: handshake line `1|6|tcp|<addr>|grpc`, magic cookie
check, TF_PLUGIN_MAGIC_COOKIE env contract, DynamicValue msgpack unknown-sentinel
(ext code 0), GetProviderSchema/GetMetadata surface, grpc health + GRPCStdio +
GRPCController services required by go-plugin.

## Acceptance
Every terraform-provider-smalt file has a ledger row (ported | discarded + reason)
before posh provider merges; terraform-provider-smalt is then archived or removed
by explicit ERRC-delete receipt (never silently kept).

## Falsifier
posh provider merging while terraform-provider-smalt still compiles in-tree with
no ledger row = FAIL.
