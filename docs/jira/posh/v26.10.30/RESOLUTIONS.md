# RESOLUTIONS — posh window v26.10.30

Seam agreements from this wave. `_LANES.md` was not minted for this window; the
partitions below are the wave's lane ownership record.

## File ownership

- `posh/` Go core, `adapters/terraform-provider-smalt/` Go sources: owned by the
  Go lanes (POSH-001 / POSH-004). Docs lanes touch nothing under these paths.
- `lib/` Elixir membrane + client (`lib/posh/`): Go-lane/Go-adjacent ownership;
  docs lanes read-only.
- Coordinator-owned (never lane-touched): `lib/smalt/arm_gateway/router.ex` plug
  changes, supervisor wiring (`lib/smalt/application.ex` and plane supervisors),
  and all git transitions (commits, merges).

## Byte contract (pinned)

- Turnstile token wire format:
  `op UTF-8 bytes || u64BE(timestamp_ns) || payload_body`, pinned by digest `0c39d201…`.
  Any mutation of framing or endianness is a wire break, not a refactor.

## Receipt discipline

- Migration ledger + ERRC-delete draft: `receipts/migration/` (lane R6); the
  delete itself is a coordinator-owned transition — the draft stays
  `applied: false` in-lane.

## Final seam decisions (2026-10-30, appended at wrap, lane F13)

- **Turnstile byte contract (pinned)**: `op UTF-8 bytes || u64BE(timestamp_ns) ||
  payload`, digest-pinned `0c39d201…` (implemented in
  `lib/smalt/posh/turnstile.ex`). Framing/endianness mutations are wire breaks,
  not refactors. Supersedes the shorter pin above; same vector.
- **Plug mount point**: the posh membrane plug mounts in
  `lib/smalt/arm_gateway/router.ex` ABOVE the Bearer authentication plug —
  turnstile verification precedes bearer auth. Coordinator-owned edit; lanes
  did not touch `router.ex`.
- **ggen copy-out disabled pending KD-POSH-5**: posh surfaces are excluded from
  ggen copy-out until KD-POSH-5 (copy-in) closes. No generated posh projection
  is admitted without that KD row closing.
- **Coordinator-owned transitions executed 2026-10-30**: `router.ex` plug mount
  (above Bearer); supervisor wiring (`lib/smalt/application.ex` + plane
  supervisors, posh membrane under its own supervisor
  `lib/smalt/posh/supervisor.ex`); root-spike ERRC-delete (Elixir spike archived
  at `tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`,
  sha256 `f0fe321b…` verified, then deleted via Trash — Go port stays).
- **Ownership correction**: the Elixir membrane lives at `lib/smalt/posh/`
  (not `lib/posh/` as first written above). `lib/smalt/posh/` is the canonical
  path in the ownership table.
- **Final lane partition**: see `_LANES.md` (minted at wrap, lane F13) — it is
  the wave's exercised-ownership record.
