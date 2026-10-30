# POSH Doctor v26.10.30: Predictive Resource Exhaustion & Cluster Resilience Architecture

**Document ID**: `SMALT-POSH-DOCTOR-v26.10.30`  
**Engineer**: `AGENT_2_DOCTOR_V26` (TPS Doctor, Predictive Telemetry & Cluster Resilience Engineer)  
**Date**: `2026-10-30`  
**Status**: `VERIFIED & OPERATIONAL` (23/23 tests passing with `-race`, sub-7ms full diagnostic run)  
**Components**:
- `posh/internal/doctor/predictive.go` & `predictive_test.go`
- `posh/internal/doctor/kube_healer.go` & `kube_healer_test.go`
- `posh/internal/doctor/doctor.go` (Probe 11 & Probe 12 integration)
- `posh/internal/diag/catalog.go` (Elm/Rust diagnostic codes `E0401`, `E0402`, `E0501`)

---

## 1. Executive Summary & Mission Scope

The POSH membrane operates as the ultra-low latency, zero-domain-state interface (SPAF Tier 2) between the BEAM core and hyperscaler cloud ecosystems. Under Toyota Production System (TPS) and Design for Six Sigma (DfSS/DfLSS) doctrine, passive diagnostic checks are insufficient:
1. **Jidoka (Autonomation / 人字の自動化)** requires early detection of resource abnormalities before fatal kernel crashes occur (e.g. `EMFILE` descriptor leaks or socket buffer overflow).
2. **Poka-Yoke (Mistake-Proofing / ポカヨケ)** demands that offline Kubernetes port mappings or dead port-forwards self-heal automatically, or render actionable, compiler-grade Elm/Rust diagnostic spans pointing to exact configuration files.

In release v26.10.30, the POSH Doctor suite is expanded from 10 to 12 deterministic health probes, introducing:
- **Probe 11 (`predictive-exhaustion`)**: An Exponentially Weighted Moving Average (EWMA) derivative trend engine that projects Time-To-Exhaustion (TTE) for open file descriptors and socket buffer queues, raising early Jidoka [YELLOW] warnings before hard `RLIMIT_NOFILE` or buffer ceilings are breached.
- **Probe 12 (`kube-nodeport-healer`)**: An automated cluster reachability and self-healing engine verifying Kind/Kubernetes NodePort 30943 and loopback ARM endpoints (port 9443), performing non-destructive reconciliation or emitting Elm/Rust compiler-style diagnostic blocks.

---

## 2. Predictive Resource Exhaustion & Trend Engine (`predictive.go`)

### 2.1 Mathematical Calculus: EWMA Derivatives

Let $S = \{(t_0, y_0), (t_1, y_1), \dots, (t_n, y_n)\}$ be a chronological sequence of resource observations (where $y_i$ represents open file descriptors or socket buffer queue depth in bytes).

For any consecutive pair of observations $(t_{i-1}, y_{i-1})$ and $(t_i, y_i)$ with time delta $\Delta t_i = t_i - t_{i-1} > 0$:
$$\dot{y}_i = \frac{y_i - y_{i-1}}{\Delta t_i} \quad [\text{units / second}]$$

To filter high-frequency sampling jitter while preserving rapid sensitivity to continuous leaks, the engine computes the Exponentially Weighted Moving Average (EWMA) of the derivative:
$$\mu_i = \alpha \cdot \dot{y}_i + (1 - \alpha) \cdot \mu_{i-1}$$
where $\alpha \in (0, 1]$ defaults to `0.35`.

### 2.2 Time-To-Exhaustion (TTE) Forecasting

Given current resource level $y_{\text{latest}}$ and safety ceiling $C$ (such as `RLIMIT_NOFILE` soft limit or kernel receive buffer capacity $RcvBufBytes$):
$$\text{Headroom } H = C - y_{\text{latest}}$$

If $\mu > 0$ (resource consumption is increasing):
$$\tau_{\text{exhaust}} = \frac{H}{\mu} \quad [\text{seconds}]$$

### 2.3 Jidoka Threshold Fences

| Condition | Status | Action / Telemetry |
|---|---|---|
| $y_{\text{latest}} \ge C$ | **`RED`** | **Critical Line Stop**: Resource ceiling already breached. |
| $\mu > 0$ and $\tau_{\text{exhaust}} \le 15.0\text{s}$ | **`RED`** | **Critical Line Stop**: Hard exhaustion imminent within critical buffer ($< 15\text{s}$). |
| $\mu > 0$ and $15.0\text{s} < \tau_{\text{exhaust}} \le 60.0\text{s}$ | **`YELLOW`** | **Early Jidoka Warning**: Unsustainable growth rate projects exhaustion within 60s; emits Elm/Rust diagnostic `E0501`. |
| $\mu \le 0$ or $\tau_{\text{exhaust}} > 60.0\text{s}$ | **`GREEN`** | **Nominal**: Resource trajectory flat, decreasing, or headroom safe. `time_to_exhaustion_sec = -1`. |

### 2.4 Monitored Resource Surfaces

1. **Open File Descriptors (`open_file_descriptors`)**:
   - Source: `InspectFileDescriptors()` via `/dev/fd` (Darwin) or `/proc/self/fd` (Linux).
   - Ceiling: `syscall.RLIMIT_NOFILE` soft limit (`rlim.Cur`).
   - Remediation: Detects unclosed HTTP/UDS connections, prompts `ulimit -n 65536`.
2. **Socket Buffer Backlog (`socket_buffer_queue_depth`)**:
   - Source: `InspectSocketBuffers()` via `getsockopt(SOL_SOCKET, SO_RCVBUF)` and `ioctl(FIONREAD / TIOCINQ)`.
   - Ceiling: Kernel receive buffer capacity (`RcvBufBytes`).
   - Remediation: Flags consumer stall, requests membrane restart or BEAM flow control.

---

## 3. Automated Cluster Port-Forwarding & NodePort Healer (`kube_healer.go`)

### 3.1 Topology & Target Endpoints

In the Smalt Sovereign Cloud Architecture, Kind clusters map host loopback ports to container NodePorts:
- **NodePort 30943**: Canonical backend ARM plain-HTTP control plane (`k8s/kind-config.yaml:26:9`).
- **Host Port 9443**: Loopback endpoint mapped directly to NodePort 30943 or serviced via `kubectl port-forward`.

### 3.2 Detection & Self-Healing State Machine

```
               [ Check 127.0.0.1:30943 & 127.0.0.1:9443 ]
                                   |
         +-------------------------+-------------------------+
         | Reachable                                         | Unreachable
         v                                                   v
   [ Status: GREEN ]                               [ Check Cluster Procs ]
 (Cluster transport healthy)                    (kind, kubectl, beam.smp)
                                                             |
                                  +--------------------------+--------------------------+
                                  | All Offline (Pre-Boot)                              | Procs Active (Broken Forwarder)
                                  v                                                     v
                           [ Status: GREEN ]                                     [ Fix Requested? ]
                        (Idle / clean pre-boot)                                         |
                                                         +------------------------------+------------------------------+
                                                         | Fix=true                                                    | Fix=false / DryRun
                                                         v                                                             v
                                              [ Non-Destructive Reconcile ]                               [ Emit Elm/Rust Diagnostic ]
                                              (spawn kubectl port-forward)                               (Diagnostic E0401 / E0402)
                                                         |                                                             |
                                           +-------------+-------------+                                               v
                                           | Reconnect OK              | Failed                               [ Status: YELLOW / RED ]
                                           v                           v
                                   [ Status: GREEN ]           [ Status: YELLOW ]
                                     (Fixed: true)
```

### 3.3 Elm/Rust Compiler-Style Diagnostic Example

When NodePort 30943 or loopback port 9443 is unreachable without `--fix`, the probe renders a full Elm/Rust diagnostic block:

```text
error[E0401]: Kind/Kubernetes NodePort 30943 or ARM endpoint unreachable
  --> k8s/kind-config.yaml:26:9
   │
26 │       - containerPort: 30943
   │         ^^^^^^^^^^^^^^^^^^^^ port 30943 refused connection; port-forward died or Kind node down
   │
   = invariant: SPAF-K8S-30943: Sovereign cluster NodePort 30943 must bridge host 9443 to container plane.
   = 5-whys: Local Kind/Kubernetes port 30943 and loopback ARM endpoint http://127.0.0.1:9443/metadata/endpoints?api-version=2020-01-01 are unreachable; port-forwarding process died or cluster nodeport mapping is inactive.
   = help: Restart Kind cluster port mapping or run automated reconciliation with 'posh doctor --fix'.
   = remediation: posh doctor --fix  # or: kubectl port-forward --address 127.0.0.1 svc/smalt-backend 9443:9443
```

---

## 4. Complete Doctor Probe Roster (v26.10.30)

| # | Probe ID | Invariant | Description |
|---|---|---|---|
| 1 | `config-poka-yoke` | `POSH-008 Hermetic Config` | Validates `posh.yaml` schema, socket path, and egress allowlists. |
| 2 | `uds-socket` | `POSH-001 UDS Listener Readiness` | Detects and atomically unlinks stale Unix Domain Sockets on disk. |
| 3 | `kernel-peercred` | `POSH-PEERCRED Kernel Creds` | Direct `getsockopt` for `LOCAL_PEERCRED` / `SO_PEERCRED` caller UID. |
| 4 | `arm-gateway` | `SPAF-ARM-9443 Control Plane` | Probes HTTP reachability of Smalt ARM metadata endpoint on port 9443. |
| 5 | `dev-overrides` | `TF-DEV-OVERRIDES Local Provider` | Heals transient `tmp/posh/tfrc` local provider overrides for Terraform. |
| 6 | `disk-headroom` | `TPS-HEIJUNKA Disk Headroom` | `statfs(2)` check guaranteeing $\ge 1.00\text{ GiB}$ free space floor. |
| 7 | `toolchain` | `TPS-TOOLCHAIN Alignment` | Confirms required toolchain binaries (`go`, `terraform`) on `PATH`. |
| 8 | `socket-buffer-bloat` | `POSH-008 Bounded Kernel Socket Buffers` | Deep kernel `SO_RCVBUF`/`FIONREAD` queue depth & bloat inspection. |
| 9 | `file-descriptor-table`| `TPS-POKA-YOKE FD Leakage Prevention` | Inode table inspection vs `RLIMIT_NOFILE` soft limits. |
| 10 | `cgroup-throttling` | `TPS-HEIJUNKA CGroup v2 Resource Headroom`| Parses `/sys/fs/cgroup` for CPU quota throttling and memory limits. |
| 11 | `predictive-exhaustion`| `TPS-JIDOKA-PREDICTIVE Resource Exhaustion Forecast` | **[NEW]** EWMA rate-of-change trend engine projecting TTE $<60\text{s}$. |
| 12 | `kube-nodeport-healer` | `SPAF-K8S-30943 NodePort & Port-Forward Resilience`| **[NEW]** Automated Kind NodePort 30943 healer with Elm/Rust syntax. |

---

## 5. Verification & Performance Receipts

### 5.1 Test Execution Receipt (`go test -race ./internal/doctor/...`)

```text
=== RUN   TestDoctorHealthyWithFix
--- PASS: TestDoctorHealthyWithFix (0.01s)
=== RUN   TestDoctorStaleSocketDetectionAndHeal
--- PASS: TestDoctorStaleSocketDetectionAndHeal (0.01s)
=== RUN   TestFormatAndonDiagnosticFields
--- PASS: TestFormatAndonDiagnosticFields (0.13s)
=== RUN   TestRemediationHealDevOverrides
--- PASS: TestRemediationHealDevOverrides (0.00s)
=== RUN   TestDeepKernelSocketTelemetry
--- PASS: TestDeepKernelSocketTelemetry (0.00s)
=== RUN   TestFileDescriptorTelemetry
--- PASS: TestFileDescriptorTelemetry (0.00s)
=== RUN   TestCGroupV2Telemetry
--- PASS: TestCGroupV2Telemetry (0.00s)
=== RUN   TestJidokaCircuitBreakerLatchingAndHysteresis
--- PASS: TestJidokaCircuitBreakerLatchingAndHysteresis (0.16s)
=== RUN   TestJSONLDDiagnosticExport
--- PASS: TestJSONLDDiagnosticExport (0.01s)
=== RUN   TestDoctorPredictiveAndKubeHealerIntegration
--- PASS: TestDoctorPredictiveAndKubeHealerIntegration (0.01s)
=== RUN   TestKubeHealerHealthyNodePort
--- PASS: TestKubeHealerHealthyNodePort (0.00s)
=== RUN   TestKubeHealerPrebootClean
--- PASS: TestKubeHealerPrebootClean (0.00s)
=== RUN   TestKubeHealerEmitsElmRustDiagnosticWhenUnreachable
--- PASS: TestKubeHealerEmitsElmRustDiagnosticWhenUnreachable (0.00s)
=== RUN   TestKubeHealerDryRunReconciliation
--- PASS: TestKubeHealerDryRunReconciliation (0.00s)
=== RUN   TestKubeHealerActiveReconciliation
--- PASS: TestKubeHealerActiveReconciliation (0.10s)
=== RUN   TestKubeHealerSpawnerFailureFallsBackToDiagnostic
--- PASS: TestKubeHealerSpawnerFailureFallsBackToDiagnostic (0.00s)
=== RUN   TestCalculateEWMADerivativeLinearSequence
--- PASS: TestCalculateEWMADerivativeLinearSequence (0.00s)
=== RUN   TestCalculateEWMADerivativeStepChange
--- PASS: TestCalculateEWMADerivativeStepChange (0.00s)
=== RUN   TestPredictiveFDExhaustionYellowWarning
--- PASS: TestPredictiveFDExhaustionYellowWarning (0.00s)
=== RUN   TestPredictiveSocketBufferCriticalRed
--- PASS: TestPredictiveSocketBufferCriticalRed (0.00s)
=== RUN   TestPredictiveFlatOrDecreasingGreen
--- PASS: TestPredictiveFlatOrDecreasingGreen (0.00s)
=== RUN   TestPredictiveEngineWindowPruning
--- PASS: TestPredictiveEngineWindowPruning (0.00s)
=== RUN   TestPredictiveEngineConcurrentRace
--- PASS: TestPredictiveEngineConcurrentRace (0.05s)
PASS
ok  	smalt.dev/posh/internal/doctor	1.753s
```

### 5.2 Microbenchmark Receipts

```text
goos: darwin
goarch: arm64
pkg: smalt.dev/posh/internal/doctor
cpu: Apple M3 Max
BenchmarkCalculateEWMADerivative-16     	 1449222	       826.0 ns/op	    2168 B/op	       4 allocs/op
BenchmarkPredictiveEngineEvaluate-16    	  767154	      1557 ns/op	    2930 B/op	      14 allocs/op
PASS
ok  	smalt.dev/posh/internal/doctor	4.136s
```

### 5.3 Live CLI Execution Receipt (`posh doctor`)

```text
$ posh doctor
========================================================================
  SMALT POSH — Deterministic DX Factory / System Doctor (TPS Andon)
========================================================================
  [GREEN ] config-poka-yoke   (  0.23ms)  valid config posh.yaml (socket=run/posh.sock, allowlist=0)
  [GREEN ] uds-socket         (  0.01ms)  socket path clean (pre-boot)
  [GREEN ] kernel-peercred    (  0.32ms)  kernel UDS peercred verified (uid=501, goos=darwin)
  [GREEN ] arm-gateway        (  2.59ms)  Smalt ARM Gateway reachable (http://127.0.0.1:9443/metadata/endpoints?api-version=2020-01-01 -> HTTP 200)
  [GREEN ] dev-overrides      (  0.28ms)  transient dev_overrides active at tmp/posh/tfrc
  [GREEN ] disk-headroom      (  0.02ms)  109.40 GiB available (>= 1.00 GiB floor)
  [GREEN ] toolchain          (  0.05ms)  go and terraform present on PATH (2/2)
  [GREEN ] socket-buffer-bloat (  0.30ms)  rcvbuf=8192 bytes, sndbuf=8192 bytes, queue_depth=0 (bloat=0.00%)
  [GREEN ] file-descriptor-table (  0.08ms)  7/184320 FDs in use (0.0% of soft limit)
  [GREEN ] cgroup-throttling  (  0.01ms)  cgroup v2 not mounted (host/darwin platform)
  [GREEN ] predictive-exhaustion (  0.06ms)  resource consumption rates nominal (growth trajectory stable)
  [GREEN ] kube-nodeport-healer (  1.93ms)  cluster transport healthy: ARM endpoint http://127.0.0.1:9443/metadata/endpoints?api-version=2020-01-01 alive
------------------------------------------------------------------------
  ANDON STATUS: [GREEN] | Probes: 12 | Fixed: 0 | Total: 6.15ms
========================================================================
```

---

## 6. Architectural Standing

1. **Jidoka (Autonomous Error Stop)**: Predictive trend derivatives halt defect accumulation before OS `EMFILE` or network packet drops trigger cascading downstream failures.
2. **Poka-Yoke Self-Healing**: Automated port-forward remediation recovers cluster endpoints without developer toil; dry-run mode ensures transparent inspection.
3. **Rust/Elm Visual Ergonomics**: Diagnostics produce human-centered compiler carets and copy-paste shell commands directly in terminal output.
4. **Sub-10ms Total Latency**: All 12 probes execute concurrently or sequentially in $\sim 6.15\text{ms}$, satisfying the sub-second CLI diagnostic budget.
