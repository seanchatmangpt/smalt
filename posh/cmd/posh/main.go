// Command posh is the POSH Go adapter membrane (SPAF Tier 2): a stateless
// protocol-translation listener between the BEAM core and hyperscaler
// ecosystems. Protocol translation only — zero domain state (charter law 2).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	_ "net/http/pprof"
	"os"
	"runtime/debug"
	"strings"

	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/armclient"
	"smalt.dev/posh/internal/config"
	"smalt.dev/posh/internal/doctor"
	"smalt.dev/posh/internal/logging"
	"smalt.dev/posh/internal/server"
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
	fix := fs.Bool("fix", false, "auto-heal stale sockets and transient dev_overrides")
	asJSON := fs.Bool("json", false, "emit machine-readable JSON report")
	strict := fs.Bool("strict", false, "treat YELLOW advisory warnings as non-zero exit")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "posh doctor: unknown positional argument(s): %s (expected flags only: --config, --fix, --json)\n",
			strings.Join(fs.Args(), " "))
		return 2
	}

	rep := doctor.Run(context.Background(), doctor.Options{
		ConfigPath: *cfgPath,
		RepoRoot:   *repoRoot,
		Fix:        *fix,
	})
	if *asJSON {
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

func main() {
	if len(os.Args) > 1 && os.Args[1] == "doctor" {
		os.Exit(runDoctor(os.Args[2:]))
	}
	if len(os.Args) > 1 && os.Args[1] == "arm" {
		os.Exit(runArm(os.Args[2:]))
	}

	cfgPath := flag.String("config", "posh.yaml", "path to posh.yaml")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if flag.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "posh: unknown subcommand or positional argument %q (supported subcommands: 'posh doctor [--fix] [--json]' or flags '-config', '-version')\n",
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

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Error("refused boot", slog.String("error", err.Error()))
		os.Exit(2)
	}

	srv := server.New(cfg.Socket, cfg.TCPAddr, dispatch).WithLogger(log)
	if err := srv.Listen(); err != nil {
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
