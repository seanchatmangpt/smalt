# BK-2b — ML-KEM Go-client leg residual close-out

Context: solo

Date: 2026-10-22 · Lane: bk2b · Repo: /Users/sac/smalt
**Standing:** **ALIVE — committed probe replays from source-only state with
exit 0; no binaries tracked; IMPL-14 residual pointer updated.**

## Replay (committed state, real output)

`cd scripts/mlkem_go_probe && bash run_probe.sh` (PATH asdf shims first;
driver pins `GOTOOLCHAIN=go1.24.0`) — **exit 0**:

```
=== BK-2 ML-KEM-768 cross-implementation probe (workdir /tmp/mlkem-bk2.DFfeCr) ===
OTP=29 (crypto 5.10)  GO=go1.24.0 darwin/arm64
--- Leg A: Go keygen -> OTP encapsulate -> Go decapsulate ---
WROTE /tmp/mlkem-bk2.DFfeCr/go_ek.bin 1184 bytes
WROTE /tmp/mlkem-bk2.DFfeCr/go_seed.bin 64 bytes
OTP-ENCAP ct=1088 ss=32 -> /tmp/mlkem-bk2.DFfeCr/ct_otp.bin, /tmp/mlkem-bk2.DFfeCr/ss_otp.bin
WROTE /tmp/mlkem-bk2.DFfeCr/ss_go.bin 32 bytes
LEG-A(Go->Elixir) ss_match=true bytes=32
--- Leg B: OTP keygen -> Go encapsulate -> OTP decapsulate ---
OTP-KEYGEN ek=1184 dk=2400 -> otp_ek.bin, otp_dk.bin
WROTE /tmp/mlkem-bk2.DFfeCr/go_ct.bin 1088 bytes
WROTE /tmp/mlkem-bk2.DFfeCr/go_ss.bin 32 bytes
LEG-B(Elixir->Go) ss_match=true bytes=32
--- Corrupt-ct legs (byte 0 flipped), both sides ---
corrupt fixture: ct_bad.bin written (byte 0 flipped)
GO-CORRUPT-CT ss_differs_from_valid=true ss_len=32 (no crash)
OTP-CORRUPT-CT implicit_rejection ss_differs_from_valid=true ss_len=32
=== PROBE COMPLETE: all interop legs PASS ===
```

## Source-only law

`git ls-files scripts/mlkem_go_probe/` → `go.mod`, `main.go`,
`mlkem_otp_leg.erl`, `run_probe.sh` — source only. The `golegprobe` binary
present on disk is untracked scratch (rebuild via `run_probe.sh`).

## IMPL-14 residual sweep

The residual pointer lives in
`../v26.10.21/receipts/imp14-mlkem-flip.md` (the v26.10.22 receipts dir has
no imp14 file; RECEIPTS.md references it by that path). Annotated its
Falsifier status section: the **raw-KEM interop gap** ("proven only against
itself plus a TLS-handshake-shape Go leg") is closed by
`bk2-mlkem-go-leg.md` + this close-out; the **Go mlkem-only TLS pin**
(`CurvePreferences` client-side validation) remains UNSUPPORTED as typed —
it is a Go toolchain-level restriction, not covered by the raw-KEM probe.
No overclaim: the probe closes the raw-KEM residual only.

## VALIDATION.md sweep

`docs/jira/v26.10.22/VALIDATION.md` has no ML-KEM/IMPL-14/TLS cell (grep:
only the unrelated NFR-SEC-001/002 PENDING row). No board edit warranted;
nothing updated.

## Commands (replay)

```
export PATH="$HOME/.asdf/shims:$PATH"
cd scripts/mlkem_go_probe && bash run_probe.sh   # exit 0, output embedded above
git ls-files scripts/mlkem_go_probe/             # source-only, no binaries
```
