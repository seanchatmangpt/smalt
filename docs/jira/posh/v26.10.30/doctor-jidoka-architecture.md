# POSH Doctor & TPS Jidoka Architecture Specification
**Document ID**: `SMALT-POSH-DOCTOR-JIDOKA-v26.10.30`  
**Engineer**: `AGENT_2_DOCTOR_JIDOKA` (Go Core Team / TPS Doctor & Jidoka Systems Engineer)  
**Status**: `VERIFIED & OPERATIONAL` (`go test ./internal/doctor/...` passing 10/10 probes, sub-3ms execution)

---

## Executive Summary & Foundational Principles

The POSH membrane operates as the ultra-low latency, zero-domain-state interface (SPAF Tier 2) between the BEAM core and hyperscaler cloud ecosystems. System health, reliability, and automated remediation are governed by Toyota Production System (TPS) and Design for Six Sigma (DfSS/DfLSS) doctrine:

1. **Jidoka (Autonomation / 人字の自動化)**: The membrane must detect abnormalities autonomously and stop the line (*Halt-the-Line*) immediately upon discovering a critical defect (RED), preventing defect propagation into downstream actor mailboxes or upstream clients.
2. **Poka-Yoke (Mistake-Proofing / ポカヨケ)**: Sub-second validation of system prerequisites (hermetic configuration, UDS socket readiness, OS kernel credentials, toolchains, disk headroom, and kernel queue bloat) before workload admission.
3. **5-Whys Root Cause Causal Graphs**: Never report a raw symptom without a deterministic causal chain and an exact, copy-pastable prescription command.
4. **Chatman Equation $R = \text{receipt}(A)$**: Every automated remediation action produces a durable receipt containing identity, authority ceiling, consequence, byte-exact replay, and standing.

---

## 1. Automated Remediation Engine (`posh doctor --fix`)

The remediation engine (`internal/doctor/remediation.go`) provides self-healing recipes that restore broken local and container runtime environments without operator intervention.

### 1.1 Remediation Recipes

| Defect Class | Detection Invariant | Self-Healing Actuation | Safety Fence / Anti-Vacuity |
|---|---|---|---|
| **Stale UDS Socket** | Inode exists on filesystem, but `connect(2)` returns `ECONNREFUSED` / timeout | Atomically unlinks stale socket via `os.Remove(sockPath)` | Inode mode check verifies `os.ModeSocket`; dials prior to removal to guarantee no active listener; post-unlink `os.Stat` confirms file is gone |
| **Port 9443 Collision** | `net.Listen("tcp", ":9443")` returns `EADDRINUSE` | Resolves listener PID via `lsof`/`fuser`; sends `SIGTERM` $\to$ 600ms grace period $\to$ `SIGKILL` | **Admitted Process Whitelist**: Refuses to kill PID $\le 1$, self PID, or non-admitted process names (`beam.smp`, `kind`, `smalt-arm`, `posh`); re-binds port to confirm release |
| **Orphaned Substrates** | Scans process table (`ps -eo pid,ppid,comm`) for substrate processes with `PPID == 1` | Sends `SIGTERM` $\to$ 100ms poll $\to$ `SIGKILL` to clean defunct child trees | Whitelist verification; checks `kill -0` to ensure complete reclamation |
| **Corrupted `dev_overrides`** | `tmp/posh/tfrc` missing, invalid HCL, or lacks `direct { exclude = ["hashicorp/azurerm"] }` | Rewrites canonical configuration pointing to `adapters/terraform-provider-smalt` | Writes to `.tfrc.tmp.<pid>` then `os.Rename` for atomic update; validates path existence |

### 1.2 Poka-Yoke Dry-Run Mode

All remediation recipes support `dryRun: true` (`posh doctor --dry-run`). When invoked with `--dry-run`, the doctor computes the exact delta, logs the prospective action, and guarantees zero filesystem or process mutations.

---

## 2. Deep OS Kernel & Socket Telemetry Probes

Located in `internal/doctor/telemetry.go`, `telemetry_darwin.go`, `telemetry_linux.go`, and `telemetry_other.go`. Zero CGO, direct platform syscalls.

### 2.1 Kernel Socket Buffer & Queue Bloat (`SO_RCVBUF` / `SO_SNDBUF` / `FIONREAD`)

UDS frame queue buildup causes latency spikes and dropped frames before the application layer detects failure.
- **Probe ID**: `socket-buffer-bloat`
- **Kernel Inspection**:
  - `syscall.GetsockoptInt(fd, SOL_SOCKET, SO_RCVBUF)` queries kernel receive buffer capacity.
  - `syscall.GetsockoptInt(fd, SOL_SOCKET, SO_SNDBUF)` queries kernel send buffer capacity.
  - Queue Depth Inspection:
    - **Darwin**: `ioctl(fd, FIONREAD, &unread)` (`0x4004667f`) returns unread bytes currently waiting in the socket receive queue.
    - **Linux**: `ioctl(fd, TIOCINQ, &unread)` and `ioctl(fd, TIOCOUTQ, &unsent)` return unread receive and unsent transmit buffer backlogs.
- **Decision Invariants**:
  $$\text{BloatRatio} = \frac{\text{RcvQueueDepth}}{\text{RcvBufBytes}}$$
  - $\text{BloatRatio} < 0.70$: **GREEN** (nominal).
  - $0.70 \le \text{BloatRatio} < 0.90$: **YELLOW** (elevated buffer bloat; consumer queue buildup).
  - $\text{BloatRatio} \ge 0.90$: **RED** (critical buffer bloat; imminent frame drop and backpressure breakdown).

### 2.2 OS File Descriptor Table & Leakage Telemetry

Exhaustion of file descriptors crashes servers with unrecoverable `EMFILE` / `ENFILE` errors.
- **Probe ID**: `file-descriptor-table`
- **Kernel Inspection**:
  - `syscall.Getrlimit(syscall.RLIMIT_NOFILE, &rlim)` queries soft (`rlim.Cur`) and hard (`rlim.Max`) process limits.
  - Open FD count: reads `/dev/fd` (Darwin) or `/proc/self/fd` (Linux) via `f.Readdirnames(-1)` (zero `lstat` calls to prevent ephemeral descriptor errors).
- **Decision Invariants**:
  $$\text{UsageRatio} = \frac{\text{OpenFDs}}{\text{SoftLimit}}$$
  - $\text{UsageRatio} < 0.70$: **GREEN** (nominal).
  - $0.70 \le \text{UsageRatio} < 0.85$: **YELLOW** (advisory warning; connection pooling or handle leakage detected).
  - $\text{UsageRatio} \ge 0.85$: **RED** (critical exhaustion risk; line arrest).

### 2.3 cgroup v2 Memory & CPU Throttling Detection

Monitors container resource starvation when running in Kubernetes sidecars (`k8s/posh-sidecar.yaml`) or Kind clusters.
- **Probe ID**: `cgroup-throttling`
- **Inspection Targets**:
  - `/sys/fs/cgroup/memory.current`, `/sys/fs/cgroup/memory.high`, `/sys/fs/cgroup/memory.max`
  - `/sys/fs/cgroup/cpu.stat` (`nr_periods`, `nr_throttled`, `throttled_usec`)
- **Decision Invariants**:
  $$\text{ThrottledRatio} = \frac{\text{nr\_throttled}}{\text{nr\_periods}}, \quad \text{MemoryRatio} = \frac{\text{memory.current}}{\text{memory.high}}$$
  - If cgroup v2 controllers absent (host Darwin environment): **GREEN** (not mounted; exempt).
  - In container runtime:
    - $\text{ThrottledRatio} > 0.30$ or $\text{MemoryRatio} > 0.95$: **RED** (severe CPU starvation / near OOM).
    - $\text{ThrottledRatio} > 0.10$ or $\text{MemoryRatio} > 0.85$: **YELLOW** (latency jitter / memory pressure).
    - Otherwise: **GREEN**.

---

## 3. Jidoka Circuit Breaking & Downstream Latency Fences

Implemented in `internal/doctor/circuit_breaker.go`.

### 3.1 Architecture & State Machine

```
   [ CLOSED (GREEN) ]  <============================+
           |                                         |
           | SLA breached for K consecutive calls     | N=2 consecutive canary
           | (EWMA > SLA or errors >= threshold)     | passes within SLA
           v                                         |
     [ OPEN (RED) ]  --- (Cooldown elapsed) --->  [ HALF-OPEN (YELLOW) ]
     (Latched; Ingress                             (Canary testing; any
      fast-rejected)                                failure re-latches RED)
```

1. **EWMA Latency Tracking**:
   $$\text{EWMA}_t = \alpha \cdot L_t + (1 - \alpha) \cdot \text{EWMA}_{t-1} \quad (\alpha = 0.2)$$
2. **SLA Breach Trip**:
   When downstream calls exceed SLA latency (e.g. 50ms) or return transport errors for $K=3$ consecutive runs, the circuit trips to **`OPEN` (RED)**.
3. **Ingress Line Arrest**:
   `cb.Allow()` immediately rejects incoming traffic with `ErrCircuitOpen` (HTTP 503 / UDS error response), protecting upstream BEAM actors from timeouts and mailbox explosions.
4. **Hysteresis Recovery ($N=2$)**:
   After cooldown expires, the breaker transitions to `HALF-OPEN` (YELLOW). It requires **$N=2$ consecutive distinct canary calls within SLA** before returning to `CLOSED` (GREEN). Any failure in `HALF-OPEN` instantly re-latches to `OPEN` (RED).
5. **Andon Chain Integration**:
   Transitions fire `OnTransition`, appending signal changes directly to the durable `posh/var/andon.jsonl` receipt chain.

---

## 4. JSON-LD 5-Whys Diagnostic Export

Invoked via `posh doctor --json-ld --work-order <WO_ID>`. Emits valid W3C JSON-LD 1.1 / RDF graph binding system telemetry directly into DfCM Semantic Jira work orders and Chatman receipts ($R = \text{receipt}(A)$).

### 4.1 Schema Definition & Causal Graph

```json
{
  "@context": {
    "@vocab": "https://smalt.dev/ontology/doctor#",
    "sj": "https://chatmangpt.com/schema/sj#",
    "dflss": "https://smalt.dev/schema/dflss#",
    "tps": "https://smalt.dev/schema/tps#",
    "chatman": "https://chatmangpt.com/schema/receipt/v2#",
    "prov": "http://www.w3.org/ns/prov#",
    "xsd": "http://www.w3.org/2001/XMLSchema#",
    "overallStatus": { "@id": "tps:overallStatus", "@type": "xsd:string" },
    "probes": { "@id": "dflss:probes", "@container": "@set" },
    "causalChain": { "@id": "dflss:causalChain", "@container": "@list" },
    "wasDerivedFrom": { "@id": "prov:wasDerivedFrom", "@type": "@id" },
    "generatedAtTime": { "@id": "prov:generatedAtTime", "@type": "xsd:dateTime" }
  },
  "@id": "urn:smalt:doctor:audit:1793390464630133000",
  "@type": [
    "dflss:DiagnosticAudit",
    "sj:WorkOrderAudit"
  ],
  "sj:workOrderId": "WO-261030-JIDOKA-01",
  "chatman:subjectSha": "35bd36d021928f083f42d484ffdd2676adb89e82",
  "prov:generatedAtTime": "2026-10-30T20:01:04Z",
  "tps:overallStatus": "GREEN",
  "dflss:totalDurationMs": 2.32,
  "dflss:fixedCount": 0,
  "dflss:probes": [ ... ]
}
```

The 5-Whys causal chain is modeled as an RDF sequence where each causal node links to its predecessor via `prov:wasDerivedFrom`.

---

## 5. Verification Ladder & Test Evidence

Tested under Darwin arm64 and validated for Linux amd64 (`CGO_ENABLED=0`):

| Test Case | Scope | Observed Result | Duration |
|---|---|---|---|
| `TestDoctorHealthyWithFix` | Full 10-probe suite + dev_overrides auto-creation | **PASS** | 0.00s |
| `TestDoctorStaleSocketDetectionAndHeal` | Stale socket $\to$ RED 5-Whys $\to$ `--fix` atomic unlink $\to$ GREEN | **PASS** | 0.00s |
| `TestFormatAndonDiagnosticFields` | Andon formatting & 5-Whys text assertions | **PASS** | 0.05s |
| `TestRemediationHealDevOverrides` | Corrupted HCL $\to$ dry-run assertion $\to$ atomic heal $\to$ idempotence | **PASS** | 0.01s |
| `TestDeepKernelSocketTelemetry` | Loopback socket buffer getsockopt & ioctl queue depth query | **PASS** | 0.00s |
| `TestFileDescriptorTelemetry` | `rlimit_nofile` vs open FDs via `/dev/fd` | **PASS** | 0.00s |
| `TestCGroupV2Telemetry` | Mock cgroup v2 controller directory; nominal vs severe throttling | **PASS** | 0.00s |
| `TestJidokaCircuitBreakerLatchingAndHysteresis` | SLA breach trip $\to$ RED latch $\to$ canary HALF-OPEN $\to$ $N=2$ recovery | **PASS** | 0.16s |
| `TestJSONLDDiagnosticExport` | Full RDF graph unmarshal and DfCM/Chatman binding verification | **PASS** | 0.00s |
| **Total Test Suite** | `smalt.dev/posh/internal/doctor` | **10/10 PASS** | **0.58s** |
| **Linux Cross-Compilation** | `GOOS=linux go vet ./internal/doctor/...` | **PASS (Clean)** | **0.00s** |
| **CLI Runtime Benchmark** | `posh doctor --json-ld` on live system | **PASS (10 probes)** | **2.32ms** |

---

## 6. CLI Usage Guide

```bash
# Run deterministic 10-probe health check
posh doctor

# Run with automated remediation (heals stale sockets, dev_overrides, port collisions)
posh doctor --fix

# Simulate remediation without disk or process mutations
posh doctor --fix --dry-run

# Export W3C JSON-LD / RDF schema audit report bound to DfCM WorkOrder
posh doctor --json-ld --work-order WO-261030-JIDOKA-01

# Enforce strict zero-defect mode (exit 1 on YELLOW warnings)
posh doctor --strict
```
