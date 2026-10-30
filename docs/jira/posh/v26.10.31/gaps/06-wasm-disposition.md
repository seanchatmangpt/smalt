# Gap 06 — internal/wasm engine disposition (MIGRATE vs KILL)

Status: **ALIVE** (KILL executed 2026-10-30 at /Users/sac/smalt/posh: `posh/internal/wasm/` deleted; `go mod tidy` dropped `github.com/tetratelabs/wazero v1.12.0`; `go build ./...` exit 0, `go vet ./...` exit 0, `go test -count=1 ./...` exit 0 for all 36 non-in-flight packages — failures confined to other lanes' live-work: `internal/diag` (red test in untracked in-flight work), `internal/dialect/azure` TestWireCourt and `internal/telemetry/otlp` (live-substrate port/entity preconditions). Zero `internal/wasm` or wazero references remain (grep = 0 hits); `internal/receipt/` BLAKE3 kernel untouched (KEEP); inheritance clauses recorded in "What survives the deletion" below.

## Decision: KILL (B), with named design inheritance

Killing `posh/internal/wasm/` outranks migrating it. Reasons, each receipted:

1. **Admission authority lives in BEAM, not posh.** The v26.10.31 operator
decision (`00-unification-dialect-decision.md`, law 4) is explicit: "any posh
component owning state or admission stops being a shim." The Go engine
compiles arbitrary bytes by name (`engine.go:123-143` — no sha256 pin, no
import allowlist beyond stock WASI, no ABI handshake), so migrating it as the
court-execution substrate means first building BEAM-parity admission (pin +
WASI allowlist + af_abi handshake) inside a tier that must not own admission.
2. **One artifact, one engine (anti O(N²) drift).** `Smalt.Affidavit.WasmEngine`
(`lib/smalt/affidavit/wasm_engine.ex`) is wired, supervised, fail-closed
(`{:error, :engine_unavailable}`), sha256-sidecar-pinned, allowlist+handshake
admitted, and is the only engine consuming the pinned artifact. A Go port is
a second implementation of the same affidavit calculus — exactly the
N-implementations-drift class. GM6's KEEP verdict predates the v31 decision
and is superseded by it.
3. **Dead code today, ERRC delete outranks generate.** Zero non-test
consumers (fresh `grep -rn "internal/wasm" --include="*.go"` over posh/
returns only the package itself), confirmed by GM2 (gaps/72 §2) and not
changed since. Keeping it until "needed" is a future audit liability; the
git history is the reversible option.

## What survives the deletion (named inheritance)

- **`internal/receipt/` (pure-Go zero-alloc BLAKE3 kernel) — KEEP, untouched.**
It is not part of the killed package, has its own AllocsPerRun-tested kernel,
and matches the Elixir lane byte-for-byte (`R = BLAKE3(op || ts_ns || body)`).
It is the receipt kernel the Phase-4 Rust kernel must reproduce, and it does
not depend on internal/wasm (dependency is one-directional: engine → receipt).
- **Host-fn ABI design — carry into the Phase-4 no_std Rust kernel.** The
pattern worth keeping is not the runtime but the ABI posture: host functions
return machine-typed outcomes into a caller-provided out-pointer
(`posh_turnstile_receipt(op_ptr, op_len, ts, payload_ptr, payload_len,
out_receipt_ptr) -> u32`), with the host as sole crypto authority. The
Phase-4 kernel inherits this ABI shape (and the guest-malloc/packed
`out_ptr<<32|out_len` packing already shared with `af_call`).
- **Tests/courts carry-over.** GM4 (gaps/74 §Chicago) is correct —
`engine_test.go` is exemplary-Chicago: real wazero collaborators, asserts on
final state (payload bytes, `[32]byte` receipt equality), a real
memory-bound adversarial case (2-page module vs 1-page limit), plus a real
benchmark. Three artifacts port forward to the Phase-4 kernel's court:
  1. the hand-crafted `tinyPluginBinary` fixture pattern (real wasm bytes,
     no generated fixtures);
  2. the memory-bound adversarial compile-rejection case (real artifact,
     real refusal);
  3. receipt-equality assertion against an independently computed digest.
  In the BEAM engine's courts these already exist in stronger form
  (shim-court over a real restore, invariant gate re-deriving blake3
  host-side), so nothing is lost on the BEAM side.

## Migration/deletion plan (KILL)

1. Delete `/Users/sac/smalt/posh/internal/wasm/` (engine.go + engine_test.go,
223+106 lines).
2. Drop `github.com/tetratelabs/wazero v1.12.0` from `posh/go.mod`
(`go mod tidy`) — verify `go build ./...` and full `go test ./...` exit 0.
3. Do NOT touch `internal/receipt/` (KEEP; add a `# KD-COVERS`-style header
note pointing here if the register requires it).
4. Amend GM6 (gaps/76 §2 "KEEP (it IS the court host)") with one line:
"Superseded by v26.10.31/gaps/06: KILL per operator law 4 — admission
authority never lives in posh; BEAM `Affidavit.WasmEngine` remains the sole
court-execution substrate."
5. Record the inherited ABI design (out-pointer host-fn returning u32, host
sole crypto authority, packed ptr|len) in the Phase-4 kernel spec so the
next implementation buys, not re-invents, it.

Close condition (falsifier): the deletion PR runs `go build ./...` and
`go test ./...` fresh (exit 0) with zero references to internal/wasm or
wazero remaining, and the affidavit artifact continues to seal through the
BEAM engine only (`priv/wasm/affidavit.sha256` pin unchanged).

## Sources

- `/Users/sac/smalt/posh/internal/wasm/engine.go` (223 L, read in full)
- `/Users/sac/smalt/posh/internal/wasm/engine_test.go` (106 L, read in full)
- `/Users/sac/smalt/lib/smalt/affidavit/wasm_engine.ex` (660 L, read in full)
- GM2 `/Users/sac/smalt/docs/jira/posh/v26.10.30/gaps/72-gemini-spf-audit.md` §2
- GM6 `/Users/sac/smalt/docs/jira/posh/v26.10.30/gaps/76-gemini-reconciliation.md` §2 (KEEP, superseded)
- GM4 `/Users/sac/smalt/docs/jira/posh/v26.10.30/gaps/74-gemini-test-vacuity.md` (Chicago finding)
- v26.10.31 operator decision `00-unification-dialect-decision.md` law 4
