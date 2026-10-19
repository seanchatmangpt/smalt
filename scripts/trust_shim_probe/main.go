// Command trust_shim_probe exercises the smalt darwin trust surface end to
// end: it presents a TLS chain on loopback (or dials a live endpoint with
// -addr) and renders a TRUST VERDICT from a real Apple Security.framework
// evaluation (SecTrustEvaluateWithError via cgo) over the presented chain.
//
// Why cgo/Security.framework: on darwin, Go's crypto/x509 routes every
// verification through Apple Security.framework (see docs/TERRAFORM_TRUST.md);
// SSL_CERT_FILE is ignored there, so the only honest verdict about what the
// Go toolchain (and azidentity) will decide is the framework's own.
//
// Modes (-mode):
//
//	real  - serve the smalt dev leaf + CA chain (the honest subject)
//	forge - H1 attacker sim: self-minted leaf (own key, SAN localhost) with
//	        the PUBLIC smalt CA appended. Chain-membership grants nothing.
//	evil  - self-minted leaf with non-loopback SANs (no localhost/127.0.0.1/::1)
//
// Legs:
//
//	-addr host:port   dial a live TLS endpoint, evaluate its served chain
//	-sysroot          real crypto/tls dial with RootCAs=nil (Go's own system
//	                  verification path; no cgo orchestration, Go's verdict)
//	-anchor-probe     cgo SecTrustCopyAnchorCertificates: pass iff the pinned
//	                  CA (SMALT_CA_FILE) is in the anchor array
//	-settings-probe   cgo SecTrustSettingsCopyCertificates over user/admin/
//	                  system domains: pass iff the pinned CA appears
//	default           loopback TLS server + SecTrustEvaluateWithError with an
//	                  exclusive per-run poison anchor (hermetic baseline:
//	                  ALWAYS fails without the shim, so keychain state cannot
//	                  fake the flip in either direction)
//
// Exit: 0 = outcome matched -want; 1 = mismatch (typed UNTRUSTED); 2 =
// transport/usage failure. Without trust the probe reports UNTRUSTED
// ("LEG MISMATCH" / "fail"); it never crashes on an untrusted chain.
package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	/*
	 #cgo LDFLAGS: -framework Security -framework CoreFoundation
	 #include <Security/Security.h>
	 #include <CoreFoundation/CoreFoundation.h>
	*/
	"C"
)

var (
	want         = flag.String("want", "pass", "expected verdict: pass|fail")
	tlsDir       = flag.String("tls-dir", ".smalt/tls", "smalt TLS material dir")
	mode         = flag.String("mode", "real", "server chain: real|forge|evil")
	addr         = flag.String("addr", "", "dial host:port and evaluate the live endpoint's chain instead of serving loopback")
	sysroot      = flag.Bool("sysroot", false, "real crypto/tls dial with RootCAs=nil (Go system verification path)")
	anchorProbe  = flag.Bool("anchor-probe", false, "cgo SecTrustCopyAnchorCertificates witness leg")
	settingsProbe = flag.Bool("settings-probe", false, "cgo SecTrustSettingsCopyCertificates witness leg")
)

var errSecTrustFailed = errors.New("security.framework: trust evaluation rejected the chain")

func main() {
	flag.Parse()

	switch {
	case *anchorProbe:
		runAnchorProbe()
	case *settingsProbe:
		runSettingsProbe()
	case *addr != "":
		runDial()
	case *sysroot:
		runSysroot()
	default:
		runLoopback()
	}
}

// legExit renders the verdict line and enforces the -want contract:
// exit 0 = match, 1 = mismatch (typed UNTRUSTED / UNEXPECTED-TRUST).
func legExit(got string) {
	if got == *want {
		fmt.Println("LEG OK: want=" + *want + " got=" + got)
		os.Exit(0)
	}
	fmt.Println("LEG MISMATCH: want=" + *want + " got=" + got)
	os.Exit(1)
}

// --- trust evaluation (the Apple-specific surface) -----------------------

func cfData(b []byte) unsafe.Pointer {
	if len(b) == 0 {
		return nil
	}
	return unsafe.Pointer(C.CFDataCreate(0, (*C.UInt8)(&b[0]), C.CFIndex(len(b))))
}

func cfRelease(p unsafe.Pointer) {
	if p != nil {
		C.CFRelease(C.CFTypeRef(p))
	}
}

func cfMutableArray(n int) unsafe.Pointer {
	return unsafe.Pointer(C.CFArrayCreateMutable(0, C.CFIndex(n), &C.kCFTypeArrayCallBacks))
}

func cfArrayAppend(arr, p unsafe.Pointer) {
	C.CFArrayAppendValue(C.CFMutableArrayRef(arr), unsafe.Pointer(p))
}

func secCert(der []byte) (unsafe.Pointer, func()) {
	d := cfData(der)
	if d == nil {
		return nil, func() {}
	}
	crt := unsafe.Pointer(C.SecCertificateCreateWithData(0, C.CFDataRef(d)))
	if crt == nil {
		cfRelease(d)
		return nil, func() {}
	}
	release := func() { cfRelease(crt); cfRelease(d) }
	return crt, release
}

// evaluateTrust builds a SecTrust from the presented chain under an SSL
// policy for hostname and runs the real SecTrustEvaluateWithError.
// true = trusted.
//
// HERMETIC BASELINE: a fresh per-run poison anchor is installed with
// SecTrustSetAnchorCertificatesOnly(trust, true), so the ONLY anchor for
// this evaluation is one nothing can chain to. The baseline therefore ALWAYS
// fails without the shim — the operator's keychain (which may legitimately
// hold a trusted smalt-dev-ca from the opt-in fallback) cannot fake the
// flip, in either direction.
func evaluateTrust(chain [][]byte, hostname string) bool {
	certs := cfMutableArray(len(chain))
	defer cfRelease(certs)
	for _, der := range chain {
		crt, rel := secCert(der)
		if crt == nil {
			return false
		}
		defer rel()
		cfArrayAppend(certs, crt)
	}
	var hostnameRef unsafe.Pointer
	if hostname != "" {
		cs := C.CString(hostname)
		defer C.free(unsafe.Pointer(cs))
		hostnameRef = unsafe.Pointer(C.CFStringCreateWithCString(0, cs, C.kCFStringEncodingUTF8))
		defer cfRelease(hostnameRef)
	}
	policy := unsafe.Pointer(C.SecPolicyCreateSSL(1, C.CFStringRef(hostnameRef)))
	defer cfRelease(policy)
	var trust C.SecTrustRef
	if C.SecTrustCreateWithCertificates(C.CFTypeRef(certs), C.CFTypeRef(policy), &trust) != 0 ||
		unsafe.Pointer(trust) == nil {
		return false
	}
	defer cfRelease(unsafe.Pointer(trust))

	anchors := cfMutableArray(1)
	defer cfRelease(anchors)
	poisonDER, _ := mintSelfSigned([]string{"smalt-probe-poison-anchor.invalid"})
	pCrt, pRel := secCert(poisonDER)
	if pCrt == nil {
		return false
	}
	defer pRel()
	cfArrayAppend(anchors, pCrt)
	C.SecTrustSetAnchorCertificates(C.SecTrustRef(trust), C.CFArrayRef(anchors))
	C.SecTrustSetAnchorCertificatesOnly(C.SecTrustRef(trust), 1)

	var cfErr C.CFErrorRef
	return bool(C.SecTrustEvaluateWithError(C.SecTrustRef(trust), &cfErr))
}

// loadCertificates extracts all DER bodies from a PEM bundle (falls back to
// treating the bytes as raw DER).
func loadCertificates(b []byte) [][]byte {
	var ders [][]byte
	rest := b
	for {
		var blk *pem.Block
		blk, rest = pem.Decode(rest)
		if blk == nil {
			break
		}
		if blk.Type == "CERTIFICATE" {
			ders = append(ders, blk.Bytes)
		}
	}
	if len(ders) == 0 && len(b) > 0 {
		ders = [][]byte{b}
	}
	return ders
}

func firstCertificate(b []byte) []byte {
	ders := loadCertificates(b)
	if len(ders) == 0 {
		return nil
	}
	return ders[0]
}

// --- attacker-chain primitives -------------------------------------------

// mintSelfSigned makes an attacker-controlled self-signed leaf with the given
// DNS SANs — no smalt private key involved (the H1 forge primitive).
func mintSelfSigned(dnsNames []string) ([]byte, crypto.Signer) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		fmt.Fprintln(os.Stderr, "keygen:", err)
		os.Exit(2)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: dnsNames[0]},
		DNSNames:     dnsNames,
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		IsCA:         true,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		fmt.Fprintln(os.Stderr, "mint:", err)
		os.Exit(2)
	}
	return der, key
}

// --- legs -----------------------------------------------------------------

// runDial: given a live host:port, complete a TLS handshake with
// verification disabled at the transport level ONLY, then render the trust
// verdict from a real SecTrustEvaluateWithError over the chain the endpoint
// actually served.
func runDial() {
	host, _, err := net.SplitHostPort(*addr)
	if err != nil {
		host = *addr
	}
	d := &net.Dialer{Timeout: 5 * time.Second}
	raw, err := tls.DialWithDialer(d, "tcp", *addr, &tls.Config{
		ServerName: host,
		// Transport-level skip only; the verdict comes from the real
		// Security.framework evaluation over the served chain below.
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if evaluateTrust(rawCerts, host) {
				return nil
			}
			return errSecTrustFailed
		},
	})
	if err != nil {
		if errors.Is(err, errSecTrustFailed) {
			fmt.Printf("SEC-TRUST: fail (addr=%s, SecTrustEvaluateWithError rejected the served chain) — UNTRUSTED\n", *addr)
			legExit("fail")
		}
		fmt.Println("TRANSPORT-FAIL:", err)
		os.Exit(2)
	}
	raw.Close()
	fmt.Printf("SEC-TRUST: pass (addr=%s, SecTrustEvaluateWithError accepted the served chain)\n", *addr)
	legExit("pass")
}

// runSysroot: a REAL crypto/tls dial with RootCAs=nil — Go's actual system
// verification path (x509 systemVerify on darwin = the SecTrust surface the
// shim interposes). No cgo orchestration; the verdict is Go's own.
func runSysroot() {
	url := startLoopbackServer()
	defer closeLoopbackServer()
	client := &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: nil},
	}}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Printf("SYSROOT: fail (mode=%s, Go system verification rejected: %v), url: %s\n", *mode, err, url)
		legExit("fail")
	}
	resp.Body.Close()
	fmt.Printf("SYSROOT: pass (mode=%s, Go system verification accepted the chain), url: %s\n", *mode, url)
	legExit("pass")
}

// runAnchorProbe: direct witness for the anchor-enumeration interpose. Go
// itself never calls SecTrustCopyAnchorCertificates (witnessed go1.23.4
// root_darwin.go), so this leg calls it via cgo and checks the pinned CA
// landed in the returned array.
func runAnchorProbe() {
	caDER := pinnedCA()
	d := cfData(caDER)
	if d == nil {
		os.Exit(2)
	}
	defer cfRelease(d)
	crt, rel := secCert(caDER)
	if crt == nil {
		fmt.Fprintln(os.Stderr, "parse ca cert failed")
		os.Exit(2)
	}
	defer rel()
	var anchors C.CFArrayRef
	if C.SecTrustCopyAnchorCertificates(&anchors) != 0 || unsafe.Pointer(anchors) == nil {
		fmt.Fprintln(os.Stderr, "SecTrustCopyAnchorCertificates failed")
		os.Exit(2)
	}
	defer cfRelease(unsafe.Pointer(anchors))
	n := C.CFArrayGetCount(anchors)
	found := false
	for i := C.CFIndex(0); i < n; i++ {
		e := C.CFArrayGetValueAtIndex(anchors, i)
		if e != nil && C.CFEqual(C.CFTypeRef(e), C.CFTypeRef(crt)) != 0 {
			found = true
			break
		}
	}
	got := "fail"
	if found {
		got = "pass"
	}
	fmt.Printf("ANCHORS: %s (pinned CA in SecTrustCopyAnchorCertificates output=%v, n=%d)\n", got, found, n)
	legExit(got)
}

// runSettingsProbe: witness for the SecTrustSettingsCopyCertificates
// interpose across the user/admin/system trust domains.
func runSettingsProbe() {
	caDER := pinnedCA()
	crt, rel := secCert(caDER)
	if crt == nil {
		fmt.Fprintln(os.Stderr, "parse ca cert failed")
		os.Exit(2)
	}
	defer rel()
	found := false
	seen := map[string]int{}
	names := map[C.SecTrustSettingsDomain]string{
		C.kSecTrustSettingsDomainUser:   "user",
		C.kSecTrustSettingsDomainAdmin:  "admin",
		C.kSecTrustSettingsDomainSystem: "system",
	}
	for dom, name := range names {
		var arr C.CFArrayRef
		if C.SecTrustSettingsCopyCertificates(dom, &arr) != 0 || unsafe.Pointer(arr) == nil {
			continue
		}
		n := C.CFArrayGetCount(arr)
		seen[name] = int(n)
		for i := C.CFIndex(0); i < n; i++ {
			e := C.CFArrayGetValueAtIndex(arr, i)
			if e != nil && C.CFEqual(C.CFTypeRef(e), C.CFTypeRef(crt)) != 0 {
				found = true
			}
		}
		cfRelease(unsafe.Pointer(arr))
	}
	got := "fail"
	if found {
		got = "pass"
	}
	fmt.Printf("SETTINGS: %s (pinned CA in SecTrustSettingsCopyCertificates output=%v, counts=%v)\n", got, found, seen)
	legExit(got)
}

func pinnedCA() []byte {
	caFile := os.Getenv("SMALT_CA_FILE")
	if caFile == "" {
		fmt.Fprintln(os.Stderr, "this leg needs SMALT_CA_FILE")
		os.Exit(2)
	}
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "read ca:", err)
		os.Exit(2)
	}
	der := firstCertificate(caPEM)
	if der == nil {
		der = caPEM // raw DER file
	}
	return der
}

// --- loopback serving ------------------------------------------------------

var loopbackURL string
var loopbackSrv *httptest.Server

// serverChain builds the chain to present, per -mode.
func serverChain() tls.Certificate {
	caPEM, err := os.ReadFile(filepath.Join(*tlsDir, "ca-cert.pem"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "read ca:", err)
		os.Exit(2)
	}
	caDER := firstCertificate(caPEM)
	switch *mode {
	case "real":
		certPEM, err := os.ReadFile(filepath.Join(*tlsDir, "dev-cert.pem"))
		if err != nil {
			fmt.Fprintln(os.Stderr, "read leaf:", err)
			os.Exit(2)
		}
		keyPEM, err := os.ReadFile(filepath.Join(*tlsDir, "dev-key.pem"))
		if err != nil {
			fmt.Fprintln(os.Stderr, "read key:", err)
			os.Exit(2)
		}
		// Present leaf + CA so the evaluator sees the full presented chain.
		serverCert, err := tls.X509KeyPair(append(certPEM, caPEM...), keyPEM)
		if err != nil {
			fmt.Fprintln(os.Stderr, "keypair:", err)
			os.Exit(2)
		}
		return serverCert
	case "forge", "evil":
		sans := []string{"localhost", "127.0.0.1"}
		if *mode == "evil" {
			sans = []string{"evil.example", "portal.azure.com"}
		}
		leafDER, signer := mintSelfSigned(sans)
		return tls.Certificate{
			Certificate: [][]byte{leafDER, caDER},
			PrivateKey:  signer,
		}
	default:
		fmt.Fprintln(os.Stderr, "unknown -mode:", *mode)
		os.Exit(2)
	}
	return tls.Certificate{}
}

// startLoopbackServer serves TLS over loopback with the -mode chain.
func startLoopbackServer() string {
	srv := httptest.NewUnstartedServer(nil)
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{serverChain()}}
	srv.StartTLS()
	loopbackSrv = srv
	loopbackURL = strings.Replace(srv.URL, "127.0.0.1", "localhost", 1)
	return loopbackURL
}

func closeLoopbackServer() {
	if loopbackSrv != nil {
		loopbackSrv.Close()
	}
}

// runLoopback: the default leg — serve the -mode chain on loopback, then
// fetch it with transport verification skipped and the verdict rendered by
// a real SecTrustEvaluateWithError over the presented chain.
func runLoopback() {
	url := startLoopbackServer()
	defer closeLoopbackServer()

	trusted := false
	client := &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{
			// Transport-level skip only; the verdict comes from the real
			// Security.framework evaluation over the presented chain.
			InsecureSkipVerify: true,
			VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
				trusted = evaluateTrust(rawCerts, "localhost")
				if trusted {
					return nil
				}
				return errSecTrustFailed
			},
		},
	}}
	resp, err := client.Get(url)
	if err != nil {
		if errors.Is(err, errSecTrustFailed) {
			fmt.Printf("SEC-TRUST: fail (mode=%s, SecTrustEvaluateWithError rejected the chain), url: %s — UNTRUSTED\n", *mode, url)
			legExit("fail")
		}
		fmt.Println("TRANSPORT-FAIL:", err)
		os.Exit(2)
	}
	resp.Body.Close()
	fmt.Printf("SEC-TRUST: pass (mode=%s, SecTrustEvaluateWithError accepted the chain), url: %s\n", *mode, url)
	legExit("pass")
}
