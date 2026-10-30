# POSH-005: posh as sidecar (kind lane + erlang-port lane)

## Task
Two packaging modes:
(a) port mode: smalt supervises posh via erlang:open_port({:spawn_executable,
posh_bin}, [:binary, :exit_status]) — ownership in lib/smalt/posh/port.ex with
supervisor child; orphan detection (no listener => restart budget).
(b) sidecar mode: posh container image (distroless/static) added to
k8s/smalt-backend.yaml pod spec; smalt CLI/web reach it over localhost.

## Acceptance
- `just posh-up/posh-status/posh-down` recipes; kind lane boots backend+posh pod;
  in-pod healthz probe witness.
- Port-mode: killing posh under supervision restarts it (witness receipt).

## Falsifier
A pod with posh sidecar that fails healthz must fail pod readiness (not silently
serve ARM without the membrane).

## Landing receipt
LANDED 2026-10-30. Falsifier evidence: socket existed→vanished flips + 2/2 port
tests (P1 receipt 2026-10-30); k8s posh-membrane sidecar stanza in
`k8s/smalt-backend.yaml`. D1/D2 repairs tracked separately.
`receipts/measure/` formal witness pending.
