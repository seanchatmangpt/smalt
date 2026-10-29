# W30-P — CI Differential Matrix Sketch (smalt vs Azurite)

- **Standing: UNKNOWN** (SKETCH — design artifact for a future lane; nothing landed. No workflow
  file, no git commit. Every untested assumption is marked `[UNTESTED-ASSUMPTION]`.
- **Inputs**: `docs/jira/v26.10.20/receipts/azure-emulators-deep-research.md` (CI
  findings: classic Cosmos emulator preinstalled on `windows-latest` runners;
  Azurite npm-bootable anywhere; Azurite defaults 10000/10001/10002; vNext Cosmos
  gateway on 8080 vs classic 8081; Service Bus emulator excluded — no JS/CI-native
  path, and its static-entity model bounds what interop courts prove).
- **Owner**: W30-P (milestone-doc lane), docs/jira/v26.10.20.
- **Context: solo**

## 1. Goal

A GitHub Actions matrix that boots smalt and Azurite side by side and runs the SAME
differential census assertions against both endpoints, so every Azurite divergence
becomes a KD-register row candidate rather than an ad hoc finding. Fail-closed: any
endpoint that does not come up, or any census cell that cannot be classified
(pass / registered-divergence / loudly-MISSING), fails the job — never a silent skip.

## 2. Proposed matrix (sketch — not landed)

```yaml
# .github/workflows/differential-census.yml  (SKETCH ONLY)
name: differential-census
on:
  workflow_dispatch: {}
  pull_request:
    paths:
      - "lib/smalt/data_plane/**"
      - "gates/**"
      - "scripts/bench/**"

jobs:
  # Job A — storage differential (smalt blob/queue vs Azurite)
  storage-diff:
    strategy:
      matrix:
        os: [ubuntu-latest]        # [UNTESTED-ASSUMPTION] ubuntu suffices; windows
                                   # runner reserved for Job B (preinstalled Cosmos).
        include:
          - os: ubuntu-latest
            smalt_data_port: 8443
            azurite_blob_port: 10000
            azurite_queue_port: 10001
    runs-on: ${{ matrix.os }}
    services:
      azurite:
        image: mcr.microsoft.com/azure-storage/azurite
        ports:
          - 10000:10000   # blob
          - 10001:10001   # queue
        # [UNTESTED-ASSUMPTION] service-container healthcheck support on the image;
        # otherwise poll the port with a bash step (no sleep-loop — bounded poll).
        options: >-
          --health-cmd "nc -z 127.0.0.1 10000"
          --health-interval 5s
          --health-timeout 3s
          --health-retries 12
    steps:
      - uses: actions/checkout@v4        # [UNTESTED-ASSUMPTION] v4 still current pin
      - uses: erlef/setup-beam@v1        # [UNTESTED-ASSUMPTION] pinned Elixir/OTP
                                         # versions not yet chosen
      - run: npm install -g azurite      # fallback boot path if image unavailable
      - run: bash scripts/bootstrap.sh   # [UNTESTED-ASSUMPTION] green on clean CI
                                         # machine (8 idempotent stages, exit 2 = brew)
      - name: Boot smalt (lane-safe)
        run: just substrate-up           # lock-managed; fd closed per lock-inheritance law
      - name: Wait readiness (poll, no sleep)
        run: just substrate-status       # [UNTESTED-ASSUMPTION] exits nonzero until
                                         # listener verified; else poll 9443/8443 sockets
      - name: Differential census
        run: |
          # same corpus, two endpoints, one verdict per cell
          mix run -e 'Smalt.Differential.Census.run(%{
            endpoints: [
              {:smalt,   "https://127.0.0.1:8443"},
              {:azurite, "http://127.0.0.1:10000"}
            ],
            corpus: "test/support/differential_corpus.exs",
            # fail-closed: unclassified cell = exit 1
            on_unclassified: :fail
          })'
        env:
          AZURE_STORAGE_CONNECTION_STRING: "UseDevelopmentStorage=true"
          NODE_EXTRA_CA_CERTS: ".smalt/tls/ca-cert.pem"
          SSL_CERT_FILE: ".smalt/tls/ca-cert.pem"
      - name: Emit receipt
        if: always()
        run: scripts/bench/bench_emit differential-census "${{ matrix.os }}" || exit 1
        # [UNTESTED-ASSUMPTION] bench_emit signature supports an external lane name;
        # bench lane letter law (a*/b*/c*/n*) may require a new letter family.

  # Job B — Cosmos classic differential on the preinstalled windows runner
  cosmos-diff:
    runs-on: windows-latest   # classic emulator is PREINSTALLED here
    steps:
      - uses: actions/checkout@v4
      - name: Import emulator cert
        shell: pwsh
        run: |
          # classic emulator serves its TLS cert at /_explorer/emulator.pem
          # [UNTESTED-ASSUMPTION] preinstalled emulator already listening on 8081;
          # if not, start via `Microsoft.Azure.CosmosDB.Emulator` /.exe /Start
          curl.exe -ksS https://localhost:8081/_explorer/emulator.pem -o emulator.pem
          Import-Certificate -FilePath emulator.pem -CertStoreLocation Cert:\CurrentUser\Root
      - name: Differential census (Cosmos surface)
        run: |
          # [UNTESTED-ASSUMPTION] mix/OTP toolchain installable on windows-latest;
          # if Elixir-on-Windows proves brittle, split: Linux job runs smalt, exposes
          # 8081 via self-hosted runner networking or tunnel — NOT designed yet.
          mix run -e 'Smalt.Differential.Census.run(%{
            endpoints: [
              {:smalt_cosmos, "https://127.0.0.1:8081"},
              {:azurite_none, nil}   # Azurite has no Cosmos surface — cell renders
                                     # N/A-BY-DESIGN, not MISSING (fail-closed parse
                                     # must accept this explicit sentinel)
            ],
            on_unclassified: :fail
          })'
        env:
          SSL_CERT_FILE: ""      # use Windows cert store instead
```

## 3. Differential-census invocation contract (sketch)

- One corpus module (`test/support/differential_corpus.exs`
  `[UNTESTED-ASSUMPTION: module does not exist yet]`), each cell = assertion applied
  identically to every endpoint.
- Verdict per cell: `pass` / `registered-divergence` (KD-nn row exists, receipts cite
  it) / `MISSING` (loud, exit 1) / `N/A-BY-DESIGN` (explicit sentinel, e.g. Azurite
  has no Cosmos surface). Nothing else — a silent skip is the failure mode the
  sdk_coverage.py precedent already refuses.
- Mirror of `scripts/sdk_coverage.py` cell-inventory discipline: inventory derived
  mechanically from `lib/smalt/data_plane/` modules, not hand-listed.

## 4. Fail-closed conditions

1. Any endpoint fails readiness (smalt substrate-down, Azurite container unhealthy) →
   job fails before census runs.
2. Any census cell unclassified (not one of the four verdicts) → exit 1.
3. `bench_emit` failure or missing result jsonl → job fails (receipt always emitted,
   `if: always()`).
4. Azurite API-version drift (x-ms-version > pinned, per deep-research: Azurite
   rejects higher versions without `--skipApiVersionCheck`) → census cell MISSING,
   job fails — pin drift is a signal, not suppressed with `--skipApiVersionCheck`.
   `[UNTESTED-ASSUMPTION: smalt's pinned api-version per storage surface]`
5. Port collision between smalt plan (8443 data plane) and Azurite defaults
   (10000–10002): deep-research open question #1 — no collision in the current plan
   `[UNTESTED-ASSUMPTION]`; the matrix must assert port disjointness at boot, exit 1
   on overlap.
6. Runner-image drift: classic Cosmos emulator presence on `windows-latest` is a
   Microsoft runner-image promise, not a contract — the job must probe 8081 and fail
   loudly (`COSMOS_EMULATOR_ABSENT`) rather than skip.

## 5. Excluded from this sketch (typed)

- Service Bus differential: official emulator is Docker + SQL Server + .NET-only
  management, no JS/CI-native leg; deep-research refuted dynamic entity creation as
  first-class. Out of scope until a lane proves the container pair boots in CI.
- vNext Cosmos (Linux, gateway 8080): variant-dependent port expectations make the
  classic-on-windows leg the cleaner first target; vNext is a follow-up matrix axis.
- Real-Azure third leg: guideline-sanctioned (dual-mode unchanged assertions), but
  requires credentials — deferred; matrix is smalt-vs-Azurite only.

## 6. What would close this sketch

A future lane lands `.github/workflows/differential-census.yml`, runs it once with a
real receipt (exit codes + census totals), mints KD rows for any divergences found,
and flips this receipt's standing from SKETCH. Until then: no workflow file exists —
`git status` confirms nothing landed.
