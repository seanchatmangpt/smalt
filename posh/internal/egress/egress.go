// Package egress enforces the POSH-008 fail-closed egress allowlist at two
// distinct layers of Go's net/http and net stack:
//
//  1. Pre-DNS Hostname Fence (http.Transport.DialContext & http.Client.CheckRedirect):
//     Before any DNS query or redirect hop executes, the target hostname is
//     normalized and checked against Config.Admits(host). Unadmitted hosts fail
//     immediately with api.NewRefusedEgress (errors.Is(..., api.ErrRefusedEgress)).
//
//  2. Post-DNS Socket Tripwire (net.Dialer.Control):
//     Before the OS connect(2) syscall fires on the resolved socket address,
//     netip.ParseAddrPort(address).Addr().Unmap() strips IPv4-mapped IPv6
//     wrappers (e.g. [::ffff:169.254.169.254]) and unconditionally refuses
//     cloud IMDS / link-local ranges (169.254.0.0/16, fe80::/10), including
//     NAT64-synthesized forms (64:ff9b::/96, 64:ff9b:1::/96). NOTE: the
//     Control hook enforces the IP-level tripwire only — it does NOT consult
//     the hostname allowlist post-DNS. Allowlist enforcement is pre-DNS (§1),
//     so a rebind of an allowlisted hostname to an arbitrary public IP is not
//     blocked here; default-deny on hostnames bounds that exposure.
package egress

import (
	"context"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"syscall"
	"time"

	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/config"
)

// NormalizeHost extracts the lowercase hostname (or bare IP literal) from an
// allowlist entry or URL host (which may be a full URL like
// "http://127.0.0.1:9443", a "host:port" pair, or a bare hostname).
func NormalizeHost(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	if strings.Contains(s, "://") {
		if u, err := url.Parse(s); err == nil && u.Host != "" {
			s = u.Host
		}
	}
	if h, _, err := net.SplitHostPort(s); err == nil {
		s = h
	}
	s = strings.TrimPrefix(strings.TrimSuffix(s, "]"), "[")
	return strings.ToLower(s)
}

// AdmitsHost checks whether targetHost is admitted by cfg.EgressAllowlist,
// normalizing both URL-shaped entries ("http://127.0.0.1:9443") and bare
// hostnames ("smalt.internal", "127.0.0.1").
func AdmitsHost(cfg *config.Config, targetHost string) bool {
	if cfg == nil {
		return false
	}
	want := NormalizeHost(targetHost)
	if want == "" {
		return false
	}
	if cfg.Admits(want) {
		return true
	}
	for _, entry := range cfg.EgressAllowlist {
		if NormalizeHost(entry) == want {
			return true
		}
	}
	return false
}

// isIMDSOrLinkLocal reports whether ip (after Unmap of IPv4-in-IPv6) falls in
// a link-local, cloud Instance Metadata Service (169.254.0.0/16, fe80::/10),
// or unspecified (0.0.0.0, ::) range. POSH never permits IMDS or unspecified
// egress regardless of DNS resolution.
func isIMDSOrLinkLocal(ip netip.Addr) bool {
	u := ip.Unmap()
	if u.IsLinkLocalUnicast() || u.IsLinkLocalMulticast() || u.IsUnspecified() {
		return true
	}
	// SHIM-COURT KD-POSH-6: NAT64 synthesis wraps an IPv4 target inside
	// 64:ff9b::/96 (well-known) or 64:ff9b:1::/96 (local-use). Unmap does not
	// decompose these; the embedded IPv4 must be extracted and re-checked so a
	// NAT64-encoded IMDS literal is refused before connect(2).
	if v4, ok := nat64EmbeddedIPv4(ip); ok {
		return isIMDSOrLinkLocal(v4)
	}
	return false
}

// nat64EmbeddedIPv4 detects well-known (64:ff9b::/96) and local-use
// (64:ff9b:1::/96) NAT64 prefixes and returns the embedded IPv4 address.
// Per RFC 6052 the final 32 bits of the /96 form carry the IPv4 address.
func nat64EmbeddedIPv4(ip netip.Addr) (netip.Addr, bool) {
	if !ip.Is6() || ip.Zone() != "" {
		return netip.Addr{}, false
	}
	b := ip.As16()
	// Prefix discriminator: b[0..3] = 00 64 ff 9b for both forms; b[4..5]
	// separates well-known (00 00) from RFC 8215 local-use (00 01).
	if b[0] != 0 || b[1] != 0x64 || b[2] != 0xff || b[3] != 0x9b || b[4] != 0 {
		return netip.Addr{}, false
	}
	var zeroStart int
	switch b[5] {
	case 0x00: // 64:ff9b::/96 well-known: bytes 6-11 must also be zero.
		zeroStart = 6
	case 0x01: // 64:ff9b:1::/96 RFC 8215 local-use: bytes 6-11 must be zero.
		zeroStart = 6
	default:
		return netip.Addr{}, false
	}
	for _, x := range b[zeroStart:12] {
		if x != 0 {
			return netip.Addr{}, false
		}
	}
	return netip.AddrFrom4([4]byte{b[12], b[13], b[14], b[15]}), true
}

// NewFencedTransport constructs an *http.Transport whose DialContext and
// kernel pre-connect Control callback enforce POSH-008 fail-closed egress.
func NewFencedTransport(cfg *config.Config) *http.Transport {
	baseDialer := &net.Dialer{
		Timeout:   10 * time.Second,
		KeepAlive: 30 * time.Second,
		Control: func(network, address string, c syscall.RawConn) error {
			ap, err := netip.ParseAddrPort(address)
			if err != nil {
				return api.NewRefusedEgress("egress.control", err, "invalid resolved address %q", address)
			}
			ip := ap.Addr().Unmap()
			if isIMDSOrLinkLocal(ip) {
				return api.NewRefusedEgress("egress.control", nil, "REFUSED(egress-imds): link-local/IMDS/unspecified address %s forbidden", ip)
			}
			return nil
		},
	}

	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConns = 128
	tr.MaxIdleConnsPerHost = 64
	tr.IdleConnTimeout = 90 * time.Second
	tr.DisableCompression = true
	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		host := NormalizeHost(addr)
		if !AdmitsHost(cfg, host) {
			return nil, api.NewRefusedEgress("egress.dial", nil, "REFUSED(egress-allowlist): host %q not in posh.yaml allowlist", host)
		}
		return baseDialer.DialContext(ctx, network, addr)
	}
	return tr
}

// NewFencedClient constructs an *http.Client that enforces POSH-008 on both
// initial requests (via NewFencedTransport) and every HTTP 3xx redirect hop
// (via CheckRedirect).
func NewFencedClient(cfg *config.Config, timeout time.Duration) *http.Client {
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	return &http.Client{
		Transport: NewFencedTransport(cfg),
		Timeout:   timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return api.NewUpstream("egress.redirect", nil, "stopped after 10 redirects")
			}
			host := NormalizeHost(req.URL.Host)
			if !AdmitsHost(cfg, host) {
				return api.NewRefusedEgress("egress.redirect", nil, "REFUSED(egress-allowlist): redirect to unadmitted host %q", host)
			}
			if len(via) > 0 && !strings.EqualFold(req.URL.Host, via[0].URL.Host) {
				req.Header.Del("Authorization")
			}
			return nil
		},
	}
}
