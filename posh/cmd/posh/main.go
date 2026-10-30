// Command posh is the POSH Go adapter membrane (SPAF Tier 2): a stateless
// protocol-translation listener between the BEAM core and hyperscaler
// ecosystems. Protocol translation only — zero domain state (charter law 2).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"

	tea "github.com/charmbracelet/bubbletea"
	"smalt.dev/posh/internal/andon"
	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/armclient"
	"smalt.dev/posh/internal/adapter"
	"smalt.dev/posh/internal/bootstrap"
	"smalt.dev/posh/internal/completion"
	"smalt.dev/posh/internal/config"
	"smalt.dev/posh/internal/dev"
	"smalt.dev/posh/internal/diag"
	"smalt.dev/posh/internal/doctor"
	"smalt.dev/posh/internal/logging"
	"smalt.dev/posh/internal/metrics"
	"smalt.dev/posh/internal/mock"
	"smalt.dev/posh/internal/replay"
	"smalt.dev/posh/internal/server"
	"smalt.dev/posh/internal/telemetry/diffpprof"
	"smalt.dev/posh/internal/tui"
)

// ops is the admitted op registry. Echo is the first admitted op; later
// tickets add ops behind the egress allowlist.
var ops = map[string]server.Handler{
	"echo": echoOp,
}

// version is stamped at build time via -ldflags "-X main.version=..." (see
// Makefile GO_LDFLAGS). Empty when built with plain `go build` — versionString
// falls back to the toolchain-embedded VCS revision, so it is safe when absent.
var version string

// versionString renders the stamped version, falling back to VCS build info
// embedded by the go toolchain (>= 1.18, when built from a git checkout).
func versionString() string {
	if version != "" {
		return version
	}
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, s := range bi.Settings {
			if s.Key == "vcs.revision" {
				rev := s.Value
				if len(rev) > 12 {
					rev = rev[:12]
				}
				if bi.Main.Version != "" && bi.Main.Version != "(devel)" {
					return bi.Main.Version + " (" + rev + ")"
				}
				return "dev (" + rev + ")"
			}
		}
	}
	return "dev"
}

// startPprofIfDebug binds a net/http/pprof mux on a localhost-only address
// when POSH_DEBUG=1. Dev-only: never default-on, never bound off-loopback.
func startPprofIfDebug(addr string) error {
	if os.Getenv("POSH_DEBUG") != "1" {
		return nil
	}
	// net/http/pprof registers handlers on http.DefaultServeMux at import
	// time. Rebind them onto a private mux here so the pprof surface can
	// never leak into any serving path of the membrane.
	pub := http.DefaultServeMux
	http.DefaultServeMux = http.NewServeMux()
	mux := http.NewServeMux()
	mux.Handle("/debug/pprof/", pub)
	fmt.Fprintf(os.Stderr, "posh: DEV-ONLY pprof on http://%s/debug/pprof/ (POSH_DEBUG=1)\n", addr)
	return http.ListenAndServe(addr, mux)
}

// metricsAddr resolves the POSH_METRICS_ADDR gate. Unset or empty disables
// metrics entirely (never default-on). The value "1" selects the loopback
// default 127.0.0.1:9091; any other non-empty value is used as the
// host:port bind address verbatim.
func metricsAddr() string {
	v := os.Getenv("POSH_METRICS_ADDR")
	switch {
	case v == "":
		return ""
	case v == "1":
		return "127.0.0.1:9091"
	default:
		return v
	}
}

// startMetricsIfConfigured serves the Prometheus-text /metrics endpoint on a
// private mux when POSH_METRICS_ADDR is set — same discipline as the pprof
// debug mux: never default-on, loopback by default, private mux so the
// surface can never leak into any serving path, and a failed bind only logs
// to stderr (never takes the membrane down).
func startMetricsIfConfigured(reg *metrics.Registry) error {
	addr := metricsAddr()
	if addr == "" || reg == nil {
		return nil
	}
	mux := http.NewServeMux()
	mux.Handle("/metrics", reg)
	fmt.Fprintf(os.Stderr, "posh: metrics on http://%s/metrics (POSH_METRICS_ADDR=%s)\n", addr, os.Getenv("POSH_METRICS_ADDR"))
	return http.ListenAndServe(addr, mux)
}

// andOnTransitionHook wires the andon signal-transition counter into the
// metrics registry: posh_andon_transitions_total{gate, from, to}. Holds
// are receipted transitions too, so they are counted (from == to).
func andOnTransitionHook(reg *metrics.Registry) {
	andon.OnTransition = func(gate string, from, to andon.State) {
		reg.Inc("posh_andon_transitions_total", map[string]string{
			"gate": gate,
			"from": from.String(),
			"to":   to.String(),
		})
	}
}

func runDoctor(args []string) int {
	fs := flag.NewFlagSet("posh doctor", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	defaultCfg := "posh.yaml"
	if _, err := os.Stat(defaultCfg); os.IsNotExist(err) {
		if _, err2 := os.Stat("posh/posh.yaml"); err2 == nil {
			defaultCfg = "posh/posh.yaml"
		}
	}
	cfgPath := fs.String("config", defaultCfg, "path to posh.yaml")
	repoRoot := fs.String("repo-root", ".", "path to repository root")
	fix := fs.Bool("fix", false, "auto-heal stale sockets, port 9443 collisions, and transient dev_overrides")
	dryRunFix := fs.Bool("dry-run", false, "simulate auto-remediation without actuating changes")
	asJSON := fs.Bool("json", false, "emit machine-readable JSON report")
	asJSONLD := fs.Bool("json-ld", false, "emit machine-readable JSON-LD / RDF schema diagnostic audit report")
	workOrderID := fs.String("work-order", "", "bind diagnostic report to DfCM WorkOrder ID")
	strict := fs.Bool("strict", false, "treat YELLOW advisory warnings as non-zero exit")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "posh doctor: unknown positional argument(s): %s (expected flags only: --config, --fix, --dry-run, --json, --json-ld, --work-order)\n",
			strings.Join(fs.Args(), " "))
		return 2
	}

	rep := doctor.Run(context.Background(), doctor.Options{
		ConfigPath:  *cfgPath,
		RepoRoot:    *repoRoot,
		Fix:         *fix,
		DryRunFix:   *dryRunFix,
		WorkOrderID: *workOrderID,
	})
	if *asJSONLD {
		b, err := doctor.FormatJSONLD(rep, *workOrderID, "")
		if err != nil {
			fmt.Fprintf(os.Stderr, "posh doctor: json-ld marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(b))
	} else if *asJSON {
		b, err := doctor.FormatJSON(rep)
		if err != nil {
			fmt.Fprintf(os.Stderr, "posh doctor: json marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(b))
	} else {
		fmt.Print(doctor.FormatAndon(rep))
	}
	if rep.HasRed() || (*strict && rep.OverallStatus != doctor.StatusGreen) {
		return 1
	}
	return 0
}

func runDev(args []string) int {
	fs := flag.NewFlagSet("posh dev", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	cfgPath := fs.String("config", "posh.yaml", "path to posh.yaml")
	withTUI := fs.Bool("tui", false, "attach interactive TUI dashboard to reload loop")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	cfg, err := config.Load(*cfgPath)
	sockPath := "run/posh.sock"
	if err == nil && cfg.Socket != "" {
		sockPath = cfg.Socket
	}

	sup, err := dev.NewSupervisor(dev.SupervisorOptions{
		ConfigPath: *cfgPath,
		SocketPath: sockPath,
	})
	if err != nil {
		d := diag.SocketCollision(sockPath, 0)
		fmt.Fprintln(os.Stderr, d.Render(diag.ColorConfig{ForceColor: true}))
		return 3
	}

	if *withTUI {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		go func() {
			_ = sup.Run(ctx)
		}()
		docOpt := doctor.Options{ConfigPath: *cfgPath}
		reg := metrics.New()
		source := tui.NewDirectMetricsSource(reg, docOpt)
		model := tui.NewDashboard(source, func(rctx context.Context) error {
			return sup.Reload(rctx)
		})
		p := tea.NewProgram(model, tea.WithAltScreen())
		if _, err := p.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "posh tui: %v\n", err)
			return 1
		}
		return 0
	}

	if err := sup.Run(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "posh dev: %v\n", err)
		return 1
	}
	return 0
}

func runTUI(args []string) int {
	fs := flag.NewFlagSet("posh tui", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	cfgPath := fs.String("config", "posh.yaml", "path to posh.yaml")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	docOpt := doctor.Options{ConfigPath: *cfgPath}
	reg := metrics.New()
	source := tui.NewCompositeSource(
		tui.NewDirectMetricsSource(reg, docOpt),
		tui.NewScriptStatusSource("scripts/posh_status.sh", "scripts/dx_report.py"))
	model := tui.NewDashboard(source, nil)
	p := tea.NewProgram(model, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "posh tui: %v\n", err)
		return 1
	}
	return 0
}

func runSetup(args []string) int {
	fs := flag.NewFlagSet("posh setup", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	cfgPath := fs.String("config", "", "path to posh.yaml")
	repoRoot := fs.String("repo-root", ".", "repository root path")
	force := fs.Bool("force", false, "overwrite existing config template")
	dryRun := fs.Bool("dry-run", false, "display proposed changes without writing to disk")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	_, err := bootstrap.Run(context.Background(), bootstrap.SetupOptions{
		RepoRoot:   *repoRoot,
		ConfigPath: *cfgPath,
		Force:      *force,
		DryRun:     *dryRun,
		Out:        os.Stdout,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "posh setup: %v\n", err)
		return 1
	}
	return 0
}

func runCompletion(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "posh completion: missing required shell argument (usage: 'posh completion [bash|zsh|fish]')")
		return 2
	}
	shell := args[0]
	if err := completion.Generate(shell, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "posh completion: %v\n", err)
		return 2
	}
	return 0
}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "doctor":
			os.Exit(runDoctor(os.Args[2:]))
		case "arm":
			os.Exit(runArm(os.Args[2:]))
		case "dev":
			os.Exit(runDev(os.Args[2:]))
		case "tui":
			os.Exit(runTUI(os.Args[2:]))
		case "setup":
			os.Exit(runSetup(os.Args[2:]))
		case "completion":
			os.Exit(runCompletion(os.Args[2:]))
		case "replay":
			os.Exit(runReplay(os.Args[2:]))
		case "mock":
			os.Exit(runMock(os.Args[2:]))
		case "diff-pprof":
			os.Exit(runDiffPprof(os.Args[2:]))
		}
	}

	cfgPath := flag.String("config", "posh.yaml", "path to posh.yaml")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if flag.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "posh: unknown subcommand or positional argument %q (supported subcommands: 'dev', 'doctor', 'arm', 'tui', 'setup', 'completion', 'replay', 'mock', 'diff-pprof' or flags '-config', '-version')\n",
			flag.Arg(0))
		os.Exit(2)
	}

	if *showVersion {
		fmt.Printf("posh %s\n", versionString())
		return
	}

	// POSH_DEBUG=1 starts the dev-only loopback pprof endpoint in a goroutine:
	// a failed debug bind must not take the membrane down.
	go func() {
		if err := startPprofIfDebug("127.0.0.1:6060"); err != nil {
			fmt.Fprintf(os.Stderr, "posh: pprof listener stopped: %v\n", err)
		}
	}()

	logging.Init()
	log := logging.From()

	// Metrics counters are wired unconditionally (cheap increments); the
	// /metrics *endpoint* binds only when POSH_METRICS_ADDR is set.
	reg := metrics.New()
	andOnTransitionHook(reg)
	go func() {
		if err := startMetricsIfConfigured(reg); err != nil {
			fmt.Fprintf(os.Stderr, "posh: metrics listener stopped: %v\n", err)
		}
	}()

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		d := diag.ConfigMissing(*cfgPath)
		fmt.Fprintln(os.Stderr, d.Render(diag.ColorConfig{ForceColor: true}))
		log.Error("refused boot", slog.String("error", err.Error()))
		os.Exit(2)
	}

	srv := server.New(cfg.Socket, cfg.TCPAddr, dispatch).WithLogger(log).WithMetrics(reg).
		WithRegistry(adapter.DialectRegistry).WithConfig(cfg)
	if fdStr := os.Getenv("POSH_LISTEN_FD"); fdStr != "" {
		if fd, err := strconv.Atoi(fdStr); err == nil {
			f := os.NewFile(uintptr(fd), "inherited_listener")
			if ln, err := net.FileListener(f); err == nil {
				srv = srv.WithInheritedListener(ln)
			}
		}
	}

	if err := srv.Listen(); err != nil {
		d := diag.SocketCollision(cfg.Socket, 0)
		fmt.Fprintln(os.Stderr, d.Render(diag.ColorConfig{ForceColor: true}))
		log.Error("refused listen", slog.String("error", err.Error()))
		os.Exit(3)
	}
	attrs := []any{slog.String("socket", cfg.Socket)}
	if cfg.TCPAddr != "" {
		attrs = append(attrs, slog.String("tcp", cfg.TCPAddr))
	}
	log.Info("listening", attrs...)

	if err := srv.Serve(context.Background()); err != nil {
		log.Error("serve", slog.String("error", err.Error()))
		os.Exit(1)
	}
}

// dispatch routes an envelope to its admitted op, typing unknown ops as
// UPSTREAM errors (the op surface is upstream capability, not transport).
func dispatch(ctx context.Context, req *api.Request) *api.Response {
	h, ok := ops[strings.ToLower(req.Op)]
	if !ok {
		return api.NewError(req.ID, api.CodeUpstream, "unknown op %q", req.Op)
	}
	return h(ctx, req)
}

// echoOp is the first admitted op: it reflects params back in the result.
func echoOp(ctx context.Context, req *api.Request) *api.Response {
	return api.NewOK(req.ID, req.Params)
}

// runArm implements `posh arm` — mints a token from the smalt STS and lists
// resource groups from the ARM plane, printing status + body summary.
// Exit 0 on HTTP 200; typed nonzero otherwise (2 config, 4 unauthorized,
// 5 server, 6 transport, 7 turnstile mismatch, 8 other HTTP).
func runArm(args []string) int {
	fs := flag.NewFlagSet("arm", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	endpoint := os.Getenv("SMALT_ARM_ENDPOINT")
	tenant := os.Getenv("SMALT_TENANT")
	subscription := os.Getenv("SMALT_SUBSCRIPTION")
	clientID := os.Getenv("SMALT_CLIENT_ID")
	clientSecret := os.Getenv("SMALT_CLIENT_SECRET")
	if endpoint == "" || tenant == "" || subscription == "" {
		fmt.Fprintln(os.Stderr, "posh arm: SMALT_ARM_ENDPOINT, SMALT_TENANT and SMALT_SUBSCRIPTION are required")
		return 2
	}

	client := armclient.NewClient(armclient.Config{
		ARMEndpoint:  endpoint,
		Tenant:       tenant,
		Subscription: subscription,
		ClientID:     clientID,
		ClientSecret: clientSecret,
	})

	body, status, err := client.ListResourceGroups(context.Background())
	if err != nil {
		fmt.Fprintf(os.Stderr, "posh arm: %v\n", err)
		switch {
		case errors.Is(err, armclient.ErrUnauthorized):
			return 4
		case errors.Is(err, armclient.ErrServer):
			return 5
		case errors.Is(err, armclient.ErrTransport):
			return 6
		case errors.Is(err, armclient.ErrTurnstile):
			return 7
		}
		return 8
	}

	fmt.Printf("status=%d body=%s\n", status, summarizeBody(body))
	return 0
}

// summarizeBody renders a one-line body summary for `posh arm` output.
func summarizeBody(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 256 {
		s = s[:256] + "..."
	}
	return s
}

// runReplay implements `posh replay` — executes recorded requests against an
// in-memory or loopback membrane and cryptographically validates that the replayed
// BLAKE3 turnstile digest matches the recorded turnstile digest bit-for-bit.
func runReplay(args []string) int {
	fs := flag.NewFlagSet("posh replay", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	file := fs.String("file", "", "path to replay log (JSON or JSONL)")
	receiptHex := fs.String("hex", "", "direct BLAKE3 turnstile receipt hex (64 chars)")
	op := fs.String("op", "", "operation name (required with -hex)")
	timestamp := fs.Uint64("timestamp", 0, "turnstile timestamp in nanoseconds (with -hex)")
	payload := fs.String("payload", "", "request payload string (with -hex)")
	target := fs.String("target", "", "loopback HTTP target URL (e.g. http://127.0.0.1:9443); empty uses in-memory membrane")
	asJSON := fs.Bool("json", false, "emit machine-readable JSON output")
	strict := fs.Bool("strict", true, "fail immediately on any turnstile receipt mismatch")

	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *file == "" && fs.NArg() > 0 {
		*file = fs.Arg(0)
	}

	opts := []replay.Option{
		replay.WithStrict(*strict),
	}
	if *target != "" {
		opts = append(opts, replay.WithTargetURL(*target))
	} else {
		opts = append(opts, replay.WithMembraneHandler(dispatch))
	}

	replayer := replay.NewReplayer(opts...)
	ctx := context.Background()

	// Direct hex validation mode
	if *receiptHex != "" {
		if *op == "" {
			fmt.Fprintln(os.Stderr, "posh replay: -op is required when validating with -hex")
			return 2
		}
		rec, err := replay.ParseReceiptHex(*receiptHex, *op, *timestamp, []byte(*payload))
		if err != nil {
			fmt.Fprintf(os.Stderr, "posh replay: parse hex: %v\n", err)
			return 2
		}
		res, err := replayer.Execute(ctx, rec)
		if err != nil && res == nil {
			fmt.Fprintf(os.Stderr, "posh replay: execution error: %v\n", err)
			return 1
		}
		if *asJSON {
			b, _ := json.MarshalIndent(res, "", "  ")
			fmt.Println(string(b))
		} else {
			if res.Matched {
				fmt.Printf("REPLAY PASS: op=%s receipt=%s (byte-identical)\n", rec.Op, res.ReplayedReceipt)
			} else {
				fmt.Printf("REPLAY FAIL: op=%s expected=%s replayed=%s diff=%s\n", rec.Op, rec.Receipt, res.ReplayedReceipt, res.Diff)
			}
		}
		if !res.Matched || err != nil {
			return 1
		}
		return 0
	}

	// File / stdin log mode
	var records []*replay.Record
	var err error
	if *file == "-" || (*file == "" && fs.NArg() == 0) {
		stat, _ := os.Stdin.Stat()
		if (stat.Mode()&os.ModeCharDevice) == 0 || *file == "-" {
			records, err = replay.ParseLog(os.Stdin)
		} else {
			fmt.Fprintln(os.Stderr, "posh replay: specify a log file or pass receipt flags (-hex, -op, -payload, -timestamp)")
			return 2
		}
	} else {
		f, ferr := os.Open(*file)
		if ferr != nil {
			fmt.Fprintf(os.Stderr, "posh replay: open %s: %v\n", *file, ferr)
			return 2
		}
		defer f.Close()
		records, err = replay.ParseLog(f)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "posh replay: parse error: %v\n", err)
		return 2
	}

	summary, err := replayer.ReplayAll(ctx, records)
	if *asJSON {
		b, _ := json.MarshalIndent(summary, "", "  ")
		fmt.Println(string(b))
	} else {
		fmt.Printf("Replay Summary: %d total, %d matched, %d mismatched, %d errors (%s)\n",
			summary.Total, summary.Matched, summary.Mismatched, summary.Errors, summary.Duration)
		for _, r := range summary.Results {
			status := "PASS"
			if !r.Matched {
				status = "FAIL"
			}
			fmt.Printf("  [%s] op=%-16s id=%-10s replayed=%s\n", status, r.Record.Op, r.Record.ID, r.ReplayedReceipt)
			if !r.Matched && r.Diff != "" {
				fmt.Printf("         diff: %s\n", r.Diff)
			}
		}
	}

	if summary.Mismatched > 0 || summary.Errors > 0 || err != nil {
		return 1
	}
	return 0
}

// runMock implements `posh mock` — launches a zero-dependency Local Mock ARM Provider
// with in-memory state storage for local Terraform plan and apply execution.
func runMock(args []string) int {
	fs := flag.NewFlagSet("posh mock", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addr := fs.String("addr", "127.0.0.1:9443", "listen host:port for mock ARM provider")
	sub := fs.String("sub", mock.DefaultSubscriptionID, "default mock Azure subscription ID")
	quiet := fs.Bool("quiet", false, "suppress startup banner")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "posh mock: unknown positional argument(s): %s\n", strings.Join(fs.Args(), " "))
		return 2
	}

	srv := mock.NewServer(
		mock.WithAddr(*addr),
		mock.WithDefaultSubscription(*sub),
	)

	if err := srv.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "posh mock: start server: %v\n", err)
		return 1
	}
	defer srv.Close()

	if !*quiet {
		fmt.Printf("posh mock: ARM Provider listening on %s\n", srv.URL())
		fmt.Printf("  Metadata:     %s/metadata/endpoints?api-version=2020-01-01\n", srv.URL())
		fmt.Printf("  OAuth2 Token: %s/tenant/oauth2/v2.0/token\n", srv.URL())
		fmt.Printf("  Subscription: %s/subscriptions/%s\n", srv.URL(), *sub)
		fmt.Println("  Ready for terraform plan / terraform apply without BEAM/Elixir.")
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh

	if !*quiet {
		fmt.Println("\nposh mock: stopping...")
	}
	return 0
}

func runDiffPprof(args []string) int {
	fs := flag.NewFlagSet("posh diff-pprof", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	strict := fs.Bool("strict", true, "enforce zero-allocation invariant (exits with code 1 on regression)")
	asJSON := fs.Bool("json", false, "output differential analysis as JSON")
	noColor := fs.Bool("no-color", false, "disable ANSI color formatting")
	topN := fs.Int("top", 25, "number of top symbol deltas to display (0 for all)")
	sortBy := fs.String("sort", "bytes", "sort criterion: 'bytes', 'allocs', 'cpu', 'name'")
	maxDeltaBytes := fs.Int64("max-delta-bytes", 0, "max allowable alloc bytes delta")
	maxDeltaAllocs := fs.Int64("max-delta-allocs", 0, "max allowable alloc count delta")
	maxDeltaCPUPct := fs.Float64("max-delta-cpu-pct", 5.0, "max allowable CPU percent delta")

	if err := fs.Parse(args); err != nil {
		return 2
	}

	if fs.NArg() < 2 {
		fmt.Fprintln(os.Stderr, "posh diff-pprof: missing required profile arguments\nUsage: posh diff-pprof [flags] <baseline.pprof> <candidate.pprof>")
		return 2
	}

	baselinePath := fs.Arg(0)
	candPath := fs.Arg(1)

	baseFile, err := os.Open(baselinePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "posh diff-pprof: open baseline profile %q: %v\n", baselinePath, err)
		return 1
	}
	defer baseFile.Close()

	candFile, err := os.Open(candPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "posh diff-pprof: open candidate profile %q: %v\n", candPath, err)
		return 1
	}
	defer candFile.Close()

	opts := []diffpprof.Option{
		diffpprof.WithStrictZeroAlloc(*strict),
		diffpprof.WithTopN(*topN),
		diffpprof.WithSortBy(*sortBy),
		diffpprof.WithTolerance(*maxDeltaBytes, *maxDeltaAllocs, *maxDeltaCPUPct),
	}

	diff, err := diffpprof.Compare(baseFile, candFile, opts...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "posh diff-pprof: comparison failed: %v\n", err)
		return 1
	}

	if *asJSON {
		b, err := diff.FormatJSON()
		if err != nil {
			fmt.Fprintf(os.Stderr, "posh diff-pprof: format json: %v\n", err)
			return 1
		}
		fmt.Println(string(b))
	} else {
		color := !*noColor
		fmt.Print(diff.FormatTable(color))
	}

	if *strict && (diff.ExceedsZeroAlloc() || diff.HasRegression()) {
		return 1
	}

	return 0
}
