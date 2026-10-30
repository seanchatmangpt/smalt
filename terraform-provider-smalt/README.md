# terraform-provider-smalt (Elixir spike — ARCHIVED)

Status: ARCHIVED/SUPERSEDED. This directory was the Elixir Terraform provider
spike; per POSH-007 and `docs/jira/posh/v26.10.30/receipts/migration/terraform-provider-smalt-ledger.md`,
the tree was archived to
`tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`
(archive verified, tree deleted 2026-10-30). The active implementation is the
Go provider at `adapters/terraform-provider-smalt`.

## Elixir court (for the archived spike)

If working from the archive tarball:

```sh
tar -xf tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz -C tmp/posh/archive/
cd tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030
mix deps.get
mix test
```

The Go provider's court is separate: `just posh-court` (see
`justfile.d/58-posh.just`).
