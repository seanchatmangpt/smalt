# run smalt on Windows (per-user, no admin)

How to get the substrate cloned, compiled, and answering on its documented
ports on a Windows box with **no administrator rights**, then stand up the
real-Azure emulators next to it for side-by-side comparison.

Everything below was executed and receipted 2026-10-27/28 on Windows 10
(10.0.26300 x64), cmd.exe, fresh machine profile: no Docker, no WSL, no
MSVC, no winget, chocolatey present but unusable (its `C:\ProgramData`
lock is admin-only). Result: substrate green on 9443/9444/8443/5672/5673/9545,
offline suite 125/132 (the 7 fails are the standing flake/port classes,
not setup defects — see the receipt row at the bottom).

Diátaxis home: `docs/how-to/how-to-run-on-windows.md`.

## 0. Why this path (constraints)

| Constraint | Consequence |
|---|---|
| No admin | No Program Files writes, no choco installs, no `wsl --install`. Everything installs per-user (scoop, npm, per-user MSI). |
| No MSVC linker (`link.exe`) | `ggen_igniter`'s Rust NIF cannot compile → the **dev** env is unreachable. Use `MIX_ENV=test` (ggen is `only: :dev`, `mix.exs:133`). |
| No Docker/WSL | Service Bus and Event Hubs emulators (Docker-only images) cannot run. Azurite (npm) and the Cosmos emulator (per-user MSI) cover the rest. |
| `gh` without git on PATH | `gh repo clone` refuses until git is on PATH (`%LOCALAPPDATA%\Programs\Git\cmd` or scoop's git shim). |
| cmd.exe `set VAR=value ` | A trailing space before `&&` leaks into the value (`_build/test /lib` mkdir failure). Always `set "VAR=value"`. |

## 1. Clone (gh CLI + the sibling path deps)

`mix.exs` declares three **path** dependencies that are NOT on Hex —
`../ash_graphlaw` (`mix.exs:103`), `../ash_r2rml` (`mix.exs:108`),
`../ggen_igniter` (`mix.exs:133`). They are optional, but without them
`mix compile` fails with "the dependency is not available". Clone all four
into the same parent directory:

```bat
set "PATH=%USERPROFILE%\scoop\shims;%USERPROFILE%\scoop\apps\git\current\bin;%PATH%"
cd <parent-dir>
gh repo clone seanchatmangpt/smalt
gh repo clone seanchatmangpt/ash_graphlaw
gh repo clone seanchatmangpt/ash_r2rml
gh repo clone seanchatmangpt/ggen_igniter
```

`ash_graphlaw` and `ash_r2rml` compile on Windows with warnings only;
`ggen_igniter` compiles a Rust NIF and will fail at link — that is expected
and harmless in the test env (it is never fetched there).

## 2. Per-user toolchain (scoop)

Chocolatey needs admin; scoop does not. Install once per user:

```powershell
Invoke-RestMethod get.scoop.sh | Invoke-Expression   # -ExecutionPolicy Bypass if needed
```

```bat
scoop install git erlang elixir python terraform just
```

Receipted versions on the reference run: Erlang/OTP 29.1.2, Elixir 1.20.4
(compiled with OTP 27 — runs fine on OTP 29), Python 3.15.2, Terraform
1.17.0, just 1.59.0.

Two PATH quirks to know:

- **elixir/mix have no scoop shims** — scoop adds
  `~\scoop\apps\elixir\current\bin` to the *user* PATH at install, but a
  shell opened before that (or a non-login context) won't see it. Prefix
  commands with
  `set "PATH=%USERPROFILE%\scoop\shims;%USERPROFILE%\scoop\apps\elixir\current\bin;%PATH%"`.
- git for gh: see step 1.

## 3. Fetch deps and compile (test env)

```bat
cd <parent-dir>\smalt
set "PATH=%USERPROFILE%\scoop\shims;%USERPROFILE%\scoop\apps\elixir\current\bin;%PATH%"
set "MIX_ENV=test"
mix deps.get
mix compile
```

Notes from the receipted run:

- `mix deps.get` once died on `File.RenameError` renaming
  `deps/.phoenix.hex-staging` (Windows AV/indexer holds the dir briefly).
  A plain retry succeeded. If it recurs, close Explorer windows on `deps\`
  and retry — no clean needed.
- Hex prints a wall of CVE advisories (ash/bandit/jose/plug_crypto) —
  informational, does not block.
- First `mix compile` takes a few minutes (yamerl/rebar3 path). "Generated
  smalt app" is success; the type warnings are upstream noise.

Do NOT run `mix compile` without `MIX_ENV=test` on a box without MSVC —
the dev env pulls `ggen_igniter` and dies at `link.exe` (exit 101 from
rustc).

## 4. Run the offline suite (optional sanity gate)

```bat
set "MIX_ENV=test"
mix test
```

The README names `test/smalt_test.exs` as the bootstrap proof test; that
path is stale post-reset — the residual offline tier lives in
`test/internal/` (see `docs/how-to/dev-loop.md`). Plain `mix test` runs it.

## 5. Boot the substrate on the documented ports

The test config binds **random ephemeral ports** by default
(`config/test.exs:45`). To get the documented surface
(9443/9444/8443/5672/5673/9545 — `docs/reference/ports-and-planes.md`),
pin them with the `SMALT_TEST_*_PORT` overrides the test config already
honors (`config/test.exs:20-36`):

```bat
set "MIX_ENV=test"
set "SMALT_TEST_ARM_PORT=9443"
set "SMALT_TEST_ARM_TLS_PORT=9444"
set "SMALT_TEST_EGRESS_PORT=8443"
set "SMALT_TEST_AMQP_PORT=5672"
set "SMALT_TEST_EVENT_HUBS_PORT=5673"
set "SMALT_TEST_MCP_PORT=9545"
mix run --no-halt
```

Boot is ~10s. Readiness lines (from the substrate's own log):

```
[info] Running Smalt.EgressRouter with Bandit 1.13.1 at 127.0.0.1:8443 (http)
[info] Running Smalt.ArmGateway.Router with Bandit 1.13.1 at 127.0.0.1:9443 (http)
[info] Running Smalt.Application.TlsTwinDispatch with Bandit 1.13.1 at 127.0.0.1:9444 (https)
[info] [amqp] sb listener bound on port 5672
[info] [amqp] eh listener bound on port 5673
[info] Running Smalt.Mcp.Router with Bandit 1.13.1 at 127.0.0.1:9545 (http)
```

Probe (both must answer):

```bat
curl -s http://127.0.0.1:9443/metadata/endpoints
curl -s -o nul -w "%{http_code}\n" http://127.0.0.1:9545/
```

`/metadata/endpoints` returns the full ARM-style endpoint manifest
(`name: smalt-sovereign`, login/resourceManager on 9443, the
`*.smalt.local` suffix map); the MCP root answers 200. In `MIX_ENV=test`
the auth mode is `:anonymous` — no Bearer needed for probing.

Note `scripts/bootstrap.sh` (the README's blessed entry) is bash-stage
based and its port-bound stages assume 9443/9545 free plus a full dev env;
on a no-admin Windows box the manual steps above are the working
equivalent. `just doctor` works if you want the preflight separately.

## 6. The Azure emulators (comparison stack)

What "real Azure" surface can run on the same no-admin box, next to smalt:

| Emulator | Covers | Install | Status on the reference box |
|---|---|---|---|
| Azurite | Blob/Queue/Table | `npm install azurite` per-user | runs (ports 10000/10001/10002) |
| Azure Cosmos DB Emulator | Cosmos SQL | per-user MSI (`aka.ms/cosmosdb-emulator`) | installed; must be started from Start Menu once (see below) |
| Azure Service Bus emulator | AMQP SB | Docker image only | **blocked** (no Docker/WSL) |
| Azure Event Hubs emulator | EH | Docker image only | **blocked** (no Docker/WSL) |

### Azurite

```bat
mkdir %USERPROFILE%\dev\tools\azurite && cd %USERPROFILE%\dev\tools\azurite
npm init -y
npm install azurite
npx azurite --skipApiVersionCheck --blobPort 10000 --queuePort 10001 --tablePort 10002 --blobHost 127.0.0.1 --queueHost 127.0.0.1 --tableHost 127.0.0.1
```

Probe: `curl -s -o nul -w "%{http_code}" http://127.0.0.1:10000/` → 400
(no route) means listening. Use the well-known dev account:

- account `devstoreaccount1`
- key `Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==`
- endpoints `http://127.0.0.1:10000/devstoreaccount1` (blob) etc.

### Cosmos DB Emulator

The 425 MB MSI installs **per-user** to
`%LOCALAPPDATA%\Programs\Azure Cosmos DB Emulator\` even with the quiet
flags `msiexec /i CosmosDB.Emulator.msi /qn /norestart` from a non-elevated
shell (receipted: msiexec exit 0, registry InstallLocation under
`%LOCALAPPDATA%`, event log "Configuration completed successfully").

It serves on `https://127.0.0.1:8081` (self-signed cert) with the fixed
master key `C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==`.

Quirk receipted on the reference box: launching
`Microsoft.Azure.Cosmos.Emulator.exe /NoUI` from a service-context shell
starts nothing visible (no process survives, port 8081 never binds). Start
it once from the **Start Menu → "Azure Cosmos DB Emulator"** in the user
session; thereafter it listens on 8081 and
`https://127.0.0.1:8081/_explorer/index.html` is the data explorer.

### Service Bus / Event Hubs emulators — the honest blocker

Both ship only as Linux container images
(`mcr.microsoft.com/azure-messaging/servicebus-emulator`,
`mcr.microsoft.com/azure-event-hubs/emulator`). No Docker and no WSL
(`wsl --status` → "not installed", and installing it needs admin) means
these two cannot run here. To unblock: one elevated `wsl --install`, then
Docker Desktop (or rootless podman) — no other smalt-side change needed.

## 7. Running the comparison

All planes are loopback-only; point two copies of the same SDK/CLI config
at the two stacks and diff behavior:

| Surface | smalt | real emulator |
|---|---|---|
| ARM control plane | `http://127.0.0.1:9443` (anonymous in test env) | no emulator (ARM has none — compare via SDK responses) |
| Blob data plane | `https://127.0.0.1:8443` (`:blob_account_key`) | Azurite `http://127.0.0.1:10000/devstoreaccount1` |
| Cosmos | `https://127.0.0.1:8443` (`:cosmos_master_key`) | emulator `https://127.0.0.1:8081` |
| Service Bus AMQP | `amqp://127.0.0.1:5672` | SB emulator (blocked here) |
| Event Hubs | `amqp://127.0.0.1:5673` | EH emulator (blocked here) |

Wire-parity expectations are the KD register's territory
(`docs/reference/kd-register.md`,
`docs/jira/v26.10.16/KNOWN_DIVERGENCES.md`); the README's Standing block
says the courts are currently red for the heaviest gates — divergences you
find in a diff are data for that register, not surprises.

## Receipts (reference run)

| step | result |
|---|---|
| clone ×4 via gh | clean (2382 + 753 + 1625 + … files) |
| scoop toolchain | erlang 29.1.2 / elixir 1.20.4 / python 3.15.2 / terraform 1.17.0 / just 1.59.0 |
| `mix deps.get` | 1 transient rename error, retry green |
| `mix compile` (dev) | FAIL — ggen_igniter rustc 101, `link.exe` missing (expected, no MSVC) |
| `mix compile` (test) | green, "Generated smalt app" |
| `mix test` (offline) | **125/132**; fails: 1 deletedkeys TLS-twin purge, 2 cluster join (distribution), 1 ARM consumer-group bridge, 3 sb-arm rules — standing flake/port classes, not setup |
| boot with pinned ports | all 6 listeners on documented ports |
| `/metadata/endpoints` 9443 | 200, full manifest |
| MCP 9545 | 200 |
| Azurite | listening 10000/10001/10002 |
| Cosmos emulator MSI | installed per-user; headless autostart from service shell failed, Start Menu launch is the working path |
| SB / EH emulators | blocked: Docker-only images, no Docker/WSL |
