package diag

import (
	"fmt"
	"strings"
)

// Standard Error Codes in the POSH Diagnostic Taxonomy
const (
	CodeRefusedEgress        = "E0101"
	CodeSocketCollision      = "E0102"
	CodeFrameOverflow        = "E0103"
	CodeDeadlineExceeded     = "E0104"
	CodePeercredUnauthorized = "E0105"
	CodeConfigMissing        = "E0201"
	CodeConfigSyntax         = "E0202"
	CodeCompileFailed        = "E0301"
	CodeKubeNodePortUnreachable = "E0401"
	CodePortForwardDied         = "E0402"
	CodePredictiveExhaustion    = "E0501"
)

// RefusedEgress constructs a diagnostic for unauthorized outbound network access.
func RefusedEgress(host, configPath string, line int) *Diagnostic {
	if line <= 0 {
		line = 1
	}
	return New(CodeRefusedEgress, fmt.Sprintf("egress request to host %q refused by default-deny security policy", host)).
		WithSpan(configPath, line, 1, len(host)+2).
		WithHighlight(fmt.Sprintf("host %q is not present on egress_allowlist", host)).
		WithInvariant("Charter Law 2 & POSH-008: Sovereign air-gap egress boundaries require explicit allowlist enrollment.").
		WithWhy(fmt.Sprintf("Membrane received request requiring upstream connection to %q, but egress_allowlist in %s has no matching rule.", host, configPath)).
		WithHelp(fmt.Sprintf("Review %s and append %q to egress_allowlist if sovereign access is intentional.", configPath, host)).
		WithFixCommand(fmt.Sprintf("printf '  - %s\\n' >> %s && posh dev --reload", host, configPath))
}

// SocketCollision constructs a diagnostic when a Unix Domain Socket is already locked.
func SocketCollision(sockPath string, pid int) *Diagnostic {
	why := fmt.Sprintf("A live process (PID %d) is already listening on %s.", pid, sockPath)
	if pid <= 0 {
		why = fmt.Sprintf("A stale or live socket file exists at %s with an active listener.", sockPath)
	}
	return New(CodeSocketCollision, fmt.Sprintf("UDS listener collision at %s", sockPath)).
		WithSpan(sockPath, 1, 1, len(sockPath)).
		WithHighlight("socket is already bound").
		WithInvariant("TPS-POKA-YOKE: Only one membrane listener instance may bind the sovereign UDS path.").
		WithWhy(why).
		WithHelp("Stop the colliding process or run 'posh doctor --fix' to reclaim abandoned endpoints.").
		WithFixCommand(fmt.Sprintf("fuser -k %s || (pkill -f posh && rm -f %s)", sockPath, sockPath))
}

// FrameOverflow constructs a diagnostic when an incoming frame exceeds the safety ceiling.
func FrameOverflow(frameBytes, maxBytes uint32) *Diagnostic {
	return New(CodeFrameOverflow, fmt.Sprintf("frame length %d bytes exceeds protocol safety limit of %d bytes", frameBytes, maxBytes)).
		WithHighlight(fmt.Sprintf("%d > %d bytes (MaxFrameBytes)", frameBytes, maxBytes)).
		WithInvariant("POSH-008 Wire Protocol (v1): Bounded buffers prevent out-of-memory denial of service.").
		WithWhy(fmt.Sprintf("Caller pushed an envelope exceeding 4 MiB (%d bytes), triggering safety rejection at framing gate.", frameBytes)).
		WithHelp("Chunk large payloads into multi-envelope batches or use compressed streaming.").
		WithFixCommand("posh doctor --strict  # verify protocol integrity")
}

// DeadlineExceeded constructs a diagnostic when request execution exceeds its SLA.
func DeadlineExceeded(op, deadlineStr, elapsedStr string) *Diagnostic {
	return New(CodeDeadlineExceeded, fmt.Sprintf("operation %q exceeded client SLA deadline (%s elapsed)", op, elapsedStr)).
		WithHighlight(fmt.Sprintf("exceeded deadline fence %s", deadlineStr)).
		WithInvariant("SPAF Tier 2: Real-time bounded execution prevents queue starvation and upstream thread lockup.").
		WithWhy(fmt.Sprintf("Upstream handler for %q did not return before client-specified wall-clock fence %s.", op, deadlineStr)).
		WithHelp("Optimize downstream ARM/BEAM pipeline latency or supply a higher timeout in client envelope.").
		WithFixCommand(fmt.Sprintf("posh arm  # test loopback round-trip response time"))
}

// PeercredUnauthorized constructs a diagnostic when kernel peer credential check fails.
func PeercredUnauthorized(expectedUID, actualUID uint32) *Diagnostic {
	return New(CodePeercredUnauthorized, fmt.Sprintf("peer credential validation rejected caller UID %d (expected %d)", actualUID, expectedUID)).
		WithHighlight(fmt.Sprintf("UID %d != %d", actualUID, expectedUID)).
		WithInvariant("Kernel-level peer credential authentication enforces sovereign boundary.").
		WithWhy("UDS SO_PEERCRED/getpeereid revealed caller is running under a differing system account.").
		WithHelp("Ensure BEAM and POSH run under the same user UID.").
		WithFixCommand(fmt.Sprintf("id -u  # verify active runtime UID"))
}

// ConfigMissing constructs a diagnostic when posh.yaml is absent.
func ConfigMissing(configPath string) *Diagnostic {
	return New(CodeConfigMissing, fmt.Sprintf("configuration file missing: %s", configPath)).
		WithSpan(configPath, 1, 1, 1).
		WithHighlight("file not found").
		WithInvariant("POSH-008: Fail-closed architecture halts boot immediately when configuration is missing.").
		WithWhy(fmt.Sprintf("The membrane cannot assume default trust boundaries without an explicit %s configuration.", configPath)).
		WithHelp("Bootstrap the configuration using the self-healing setup command.").
		WithFixCommand("posh setup  # auto-generate default configuration and runtime directories")
}

// CompileFailed constructs a diagnostic for Go compiler errors during live watch.
func CompileFailed(file string, line, col int, compilerOutput string) *Diagnostic {
	snippet := compilerOutput
	title := "Go source recompilation failed during live watch cycle"
	lines := strings.Split(compilerOutput, "\n")
	if len(lines) > 0 && strings.TrimSpace(lines[0]) != "" {
		title = strings.TrimSpace(lines[0])
	}
	return New(CodeCompileFailed, title).
		WithSpan(file, line, col, 1).
		WithCustomSnippet(snippet).
		WithHighlight("syntax or type error").
		WithInvariant("Zero-Downtime Live Watch: Broken compilations preserve running worker without interruption.").
		WithWhy("Go toolchain reported compile error; hot-reload held back to protect active connections.").
		WithHelp("Correct the syntax or type issue at the designated file and line, then save to trigger recompile.").
		WithFixCommand(fmt.Sprintf("go vet %s", file))
}

// KubeNodePortUnreachable constructs a diagnostic when Kubernetes NodePort 30943 or port-forward is offline.
func KubeNodePortUnreachable(repoRoot string, port int, why string) *Diagnostic {
	configFile := "k8s/kind-config.yaml"
	if repoRoot != "" {
		configFile = fmt.Sprintf("%s/k8s/kind-config.yaml", strings.TrimSuffix(repoRoot, "/"))
	}
	snippet := "nodes:\n  - role: control-plane\n    extraPortMappings:\n      - containerPort: 30943\n        hostPort: 9443\n"
	if why == "" {
		why = fmt.Sprintf("TCP dial to port %d or loopback ARM endpoint returned ECONNREFUSED; Kind cluster or port-forward process is absent.", port)
	}
	return New(CodeKubeNodePortUnreachable, fmt.Sprintf("Kind/Kubernetes NodePort %d or ARM endpoint unreachable", port)).
		WithSpan(configFile, 26, 9, 20).
		WithCustomSnippet(snippet).
		WithHighlight(fmt.Sprintf("port %d refused connection; port-forward died or Kind node down", port)).
		WithInvariant("SPAF-K8S-30943: Sovereign cluster NodePort 30943 must bridge host 9443 to container plane.").
		WithWhy(why).
		WithHelp("Restart Kind cluster port mapping or run automated reconciliation with 'posh doctor --fix'.").
		WithFixCommand(fmt.Sprintf("posh doctor --fix  # or: kubectl port-forward --address 127.0.0.1 svc/smalt-backend 9443:9443"))
}

// PortForwardDied constructs a diagnostic when a kubectl port-forwarding process died or crashed.
func PortForwardDied(serviceName string, port int, pid int) *Diagnostic {
	why := fmt.Sprintf("Port-forward process for %s (port %d) exited unexpectedly.", serviceName, port)
	if pid > 0 {
		why = fmt.Sprintf("Port-forward process PID %d for %s (port %d) terminated unexpectedly.", pid, serviceName, port)
	}
	return New(CodePortForwardDied, fmt.Sprintf("Kubernetes port-forward process died for %s", serviceName)).
		WithHighlight(fmt.Sprintf("port-forward for port %d is defunct", port)).
		WithInvariant("SPAF-K8S-30943: Continuous loopback forwarder required for sovereign ARM transport.").
		WithWhy(why).
		WithHelp("Respawn the port-forward process using 'posh doctor --fix' or native kubectl.").
		WithFixCommand(fmt.Sprintf("kubectl port-forward --address 127.0.0.1 svc/%s %d:%d", serviceName, port, port))
}

// PredictiveExhaustion constructs a diagnostic when resource growth projects imminent exhaustion.
func PredictiveExhaustion(resource string, rate float64, tteSec float64, ceiling float64) *Diagnostic {
	return New(CodePredictiveExhaustion, fmt.Sprintf("Predictive Resource Exhaustion: %s projected to breach ceiling in %.1fs", resource, tteSec)).
		WithHighlight(fmt.Sprintf("EWMA growth rate %.2f/s projects breach in %.1fs (< 60s horizon)", rate, tteSec)).
		WithInvariant("TPS-JIDOKA-PREDICTIVE: Detect abnormalities and stop the line before hard resource exhaustion.").
		WithWhy(fmt.Sprintf("Derivative EWMA analysis detected rapid allocation of %s at %.2f units/sec towards ceiling %.0f.", resource, rate, ceiling)).
		WithHelp("Inspect process allocation leak, close dangling handles, or tune kernel/system ceilings.").
		WithFixCommand("posh doctor  # inspect resource trends and telemetry")
}

