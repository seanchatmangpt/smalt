package egress

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/config"
)

func TestAdmittedLoopbackRoundTrip(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, `{"value":[]}`)
	}))
	defer srv.Close()

	cfg := &config.Config{
		EgressAllowlist: []string{"http://127.0.0.1:9443"},
	}
	client := NewFencedClient(cfg, 5*time.Second)

	resp, err := client.Get(srv.URL + "/subscriptions/000/resourcegroups")
	if err != nil {
		t.Fatalf("expected admitted request to succeed, got: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
}

func TestUnadmittedHostRefusedBeforeDial(t *testing.T) {
	cfg := &config.Config{
		EgressAllowlist: []string{"smalt.internal"},
	}
	client := NewFencedClient(cfg, 2*time.Second)

	_, err := client.Get("http://127.0.0.1:9443/healthz")
	if err == nil {
		t.Fatal("expected unadmitted host to be refused")
	}
	if !errors.Is(err, api.ErrRefusedEgress) {
		t.Fatalf("expected errors.Is(err, api.ErrRefusedEgress), got: %v", err)
	}
	if got := api.Mapping(err); got != api.CodeRefusedEgress {
		t.Fatalf("api.Mapping(err) = %q, want %q", got, api.CodeRefusedEgress)
	}
}

func TestRedirectEscapeToUnadmittedHostRefused(t *testing.T) {
	for _, code := range []int{http.StatusMovedPermanently, http.StatusFound, http.StatusTemporaryRedirect} {
		t.Run(fmt.Sprintf("%d", code), func(t *testing.T) {
			// Target is a second httptest server NOT in the allowlist; its
			// handler counts requests atomically so we can assert zero
			// emitted traffic reached the unadmitted host.
			var hits atomic.Int64
			target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				hits.Add(1)
				w.WriteHeader(http.StatusOK)
			}))
			defer target.Close()

			// The allowlist admits the literal "127.0.0.1" only; address the
			// target by its "localhost" name (same socket, different host
			// identity) so the redirect target is genuinely unadmitted.
			unadmittedTargetURL := strings.Replace(target.URL, "127.0.0.1", "localhost", 1) + "/secret"
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				http.Redirect(w, r, unadmittedTargetURL, code)
			}))
			defer srv.Close()

			cfg := &config.Config{
				EgressAllowlist: []string{"127.0.0.1"},
			}
			client := NewFencedClient(cfg, 5*time.Second)

			_, err := client.Get(srv.URL)
			if err == nil {
				t.Fatal("expected redirect to unadmitted host to fail")
			}
			if !errors.Is(err, api.ErrRefusedEgress) {
				t.Fatalf("expected REFUSED_EGRESS on redirect escape, got: %v", err)
			}
			if got := api.Mapping(err); got != api.CodeRefusedEgress {
				t.Fatalf("api.Mapping(err) = %q, want %q", got, api.CodeRefusedEgress)
			}
			// Typed-op pin: the CheckRedirect layer must stamp its own op,
			// not just the shared REFUSED_EGRESS code.
			var me *api.MembraneError
			if !errors.As(err, &me) {
				t.Fatalf("err %v is not *api.MembraneError", err)
			}
			if me.Op != "egress.redirect" {
				t.Fatalf("MembraneError.Op = %q, want %q", me.Op, "egress.redirect")
			}
			if n := hits.Load(); n != 0 {
				t.Fatalf("unadmitted target received %d requests, want 0", n)
			}
		})
	}
}

// TestControlHookRefusesLinkLocalEndToEnd proves the post-DNS socket Control
// tripwire fires on real dials for IMDS/link-local addresses, including when
// the operator mistakenly allowlists the address: the pre-DNS fence admits,
// then the kernel pre-connect hook refuses before connect(2).
func TestControlHookRefusesLinkLocalEndToEnd(t *testing.T) {
	for _, host := range []string{
		"169.254.169.254:80",
		"[fe80::1]:80",
		"[::ffff:169.254.169.254]:80",
		"[fe80::8000:1234:5678:9abc]:80",
		"[febf::1]:80",
	} {
		t.Run(host, func(t *testing.T) {
			cfg := &config.Config{
				EgressAllowlist: []string{host},
			}
			client := NewFencedClient(cfg, 2*time.Second)

			_, err := client.Get("http://" + host + "/metadata/instance")
			if err == nil {
				t.Fatalf("dial to link-local %s unexpectedly succeeded", host)
			}
			if !errors.Is(err, api.ErrRefusedEgress) {
				t.Fatalf("Get(%s) err = %v, want errors.Is(err, api.ErrRefusedEgress)", host, err)
			}
			if got := api.Mapping(err); got != api.CodeRefusedEgress {
				t.Fatalf("api.Mapping(err) = %q, want %q", got, api.CodeRefusedEgress)
			}
			// Typed-op pin: the socket Control hook stamps "egress.control".
			var me *api.MembraneError
			if !errors.As(err, &me) {
				t.Fatalf("Get(%s) err %v is not *api.MembraneError", host, err)
			}
			if me.Op != "egress.control" {
				t.Fatalf("MembraneError.Op = %q, want %q", me.Op, "egress.control")
			}
		})
	}
}

func TestIMDSAndIPv4MappedIPv6BlockedAtSocketControl(t *testing.T) {
	for _, raw := range []string{
		"169.254.169.254",
		"::ffff:169.254.169.254",
		"fe80::1",
	} {
		ip, err := netip.ParseAddr(raw)
		if err != nil {
			t.Fatalf("parse %s: %v", raw, err)
		}
		if !isIMDSOrLinkLocal(ip) {
			t.Errorf("isIMDSOrLinkLocal(%s) = false, want true", raw)
		}
	}

	// Even if an operator mistakenly puts 169.254.169.254 in the allowlist,
	// the post-DNS socket Control hook refuses it before connect(2).
	cfg := &config.Config{
		EgressAllowlist: []string{"169.254.169.254"},
	}
	client := NewFencedClient(cfg, 2*time.Second)
	_, err := client.Get("http://169.254.169.254/metadata/instance")
	if !errors.Is(err, api.ErrRefusedEgress) {
		t.Fatalf("expected IMDS socket tripwire to return ErrRefusedEgress, got: %v", err)
	}
}

func TestF_GO_03_IMDSIPv4MappedIPv6AndUnspecifiedBlocked(t *testing.T) {
	// 1. Admitted loopback server responds 302 Found to IPv4-mapped IPv6 IMDS address.
	redirectSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://[::ffff:169.254.169.254]/latest/meta-data/", http.StatusFound)
	}))
	defer redirectSrv.Close()

	cfg := &config.Config{
		EgressAllowlist: []string{
			"127.0.0.1",
			"::ffff:169.254.169.254",
			"0.0.0.0",
			"::",
		},
	}
	client := NewFencedClient(cfg, 2*time.Second)

	_, err := client.Get(redirectSrv.URL)
	if !errors.Is(err, api.ErrRefusedEgress) {
		t.Fatalf("redirect to [::ffff:169.254.169.254] err = %v, want errors.Is(err, api.ErrRefusedEgress)", err)
	}

	// 2. Verify 0.0.0.0 and :: are rejected by isIMDSOrLinkLocal and socket Control.
	for _, unspec := range []string{"0.0.0.0", "::"} {
		ip, parseErr := netip.ParseAddr(unspec)
		if parseErr != nil {
			t.Fatalf("parse %s: %v", unspec, parseErr)
		}
		if !isIMDSOrLinkLocal(ip) {
			t.Fatalf("isIMDSOrLinkLocal(%s) = false, want true", unspec)
		}
	}
	for _, rawURL := range []string{"http://0.0.0.0:9443/probe", "http://[::]:9443/probe"} {
		_, uerr := client.Get(rawURL)
		if !errors.Is(uerr, api.ErrRefusedEgress) {
			t.Fatalf("client.Get(%s) err = %v, want errors.Is(err, api.ErrRefusedEgress)", rawURL, uerr)
		}
	}

	// 3. Cross-origin redirect between two admitted httptest.Server instances
	// must strip the Authorization header on the second hop.
	var secondHopAuth string
	hop2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		secondHopAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))
	defer hop2.Close()

	hop1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, hop2.URL+"/landed", http.StatusFound)
	}))
	defer hop1.Close()

	req, err := http.NewRequest(http.MethodGet, hop1.URL+"/start", nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	req.Header.Set("Authorization", "Bearer top-secret-token")

	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("cross-origin admitted redirect failed: %v", err)
	}
	resp.Body.Close()
	if secondHopAuth != "" {
		t.Fatalf("Authorization leaked across redirect hop: got %q, want empty", secondHopAuth)
	}
}

// TestControlHookRefusesNAT64SynthesizedIMDS proves the KD-POSH-6 close: a
// NAT64-synthesized IMDS literal (64:ff9b::/96 well-known and 64:ff9b:1::/96
// local-use) embedded in an admitted dial is decomposed by the Control
// tripwire and refused before connect(2) — Unmap alone does not cover these.
func TestControlHookRefusesNAT64SynthesizedIMDS(t *testing.T) {
	for _, host := range []string{
		"[64:ff9b::169.254.169.254]:80",
		"[64:ff9b:1::169.254.169.254]:80",
	} {
		t.Run(host, func(t *testing.T) {
			// The NAT64 literal itself is allowlisted (operator mistake): the
			// pre-DNS fence admits, then the kernel Control hook must refuse.
			cfg := &config.Config{
				EgressAllowlist: []string{host},
			}
			client := NewFencedClient(cfg, 2*time.Second)

			_, err := client.Get("http://" + host + "/metadata/instance")
			if err == nil {
				t.Fatalf("NAT64 IMDS dial to %s unexpectedly succeeded", host)
			}
			if !errors.Is(err, api.ErrRefusedEgress) {
				t.Fatalf("Get(%s) err = %v, want errors.Is(err, api.ErrRefusedEgress)", host, err)
			}
			// Typed-op pin: refusal must come from the socket Control hook,
			// not the allowlist fence.
			var me *api.MembraneError
			if !errors.As(err, &me) {
				t.Fatalf("Get(%s) err %v is not *api.MembraneError", host, err)
			}
			if me.Op != "egress.control" {
				t.Fatalf("MembraneError.Op = %q, want %q", me.Op, "egress.control")
			}
		})
	}

	// Unit pin: nat64EmbeddedIPv4 decomposes both prefixes and rejects
	// lookalikes (non-NAT64 globals keep their own address).
	for raw, want := range map[string]string{
		"64:ff9b::169.254.169.254":   "169.254.169.254",
		"64:ff9b:1::169.254.169.254": "169.254.169.254",
		"64:ff9b::1.2.3.4":           "1.2.3.4",
		"2001:db8::1":                "",
		"64:ff9b:2::a9fe:a9fe":       "",
	} {
		ip, perr := netip.ParseAddr(raw)
		if perr != nil {
			t.Fatalf("parse %s: %v", raw, perr)
		}
		got, ok := nat64EmbeddedIPv4(ip)
		if want == "" {
			if ok {
				t.Errorf("nat64EmbeddedIPv4(%s) = %v, want none", raw, got)
			}
			if isIMDSOrLinkLocal(ip) {
				t.Errorf("isIMDSOrLinkLocal(%s) = true for non-NAT64 address", raw)
			}
			continue
		}
		if !ok || got.String() != want {
			t.Errorf("nat64EmbeddedIPv4(%s) = (%v,%v), want %s", raw, got, ok, want)
		}
		// IMDS-ness comes from the embedded IPv4, not the NAT64 wrapper:
		// 169.254.169.254 trips the check; 1.2.3.4 (global) does not.
		wantIMDS := want == "169.254.169.254"
		if got := isIMDSOrLinkLocal(ip); got != wantIMDS {
			t.Errorf("isIMDSOrLinkLocal(%s) = %v, want %v", raw, got, wantIMDS)
		}
	}

	// Negative control: a NAT64-synthesized non-IMDS global IPv4 is NOT
	// refused by the Control hook class — isIMDSOrLinkLocal must be false so
	// only the allowlist (egress.dial) governs it.
	globalIP, _ := netip.ParseAddr("64:ff9b::8.8.8.8")
	if isIMDSOrLinkLocal(globalIP) {
		t.Errorf("isIMDSOrLinkLocal(64:ff9b::8.8.8.8) = true, want false (global embedded IPv4)")
	}
	if embedded, ok := nat64EmbeddedIPv4(globalIP); !ok || embedded.String() != "8.8.8.8" {
		t.Errorf("nat64EmbeddedIPv4(64:ff9b::8.8.8.8) = (%v,%v), want 8.8.8.8", embedded, ok)
	}
}
