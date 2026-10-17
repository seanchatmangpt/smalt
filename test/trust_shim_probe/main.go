// Command trust_shim_probe proves the smalt darwin trust shim end to end.
//
// It serves TLS over loopback and performs a REAL Security.framework trust
// evaluation of the presented chain (SecTrustEvaluateWithError via cgo) — the
// exact surface the shim interposes.
//
// Modes:
//
//	real  - present the smalt dev leaf + CA chain (the honest subject)
//	forge - H1 attacker sim: present a SELF-MADE leaf with SAN localhost
//	        plus the PUBLIC smalt CA cert. Under chain-membership pinning
//	        this forged chain was trusted with no private key; under the
//	        exact-leaf pin it MUST be rejected.
//	evil  - non-loopback SAN leaf (no localhost/127.0.0.1/::1 in SAN set)
//
// Legs (see scripts/trust_shim/README.md):
//
//	1. BEFORE, no shim, mode=real: evaluation fails (untrusted smalt dev CA)
//	2. AFTER, shim + correct leaf pin, mode=real: evaluation succeeds
//	3. NEGATIVE, shim + wrong pin, mode=real: fails (pin is not vacuous)
//	4. shim + correct pin, mode=evil: fails (loopback gate)
//	5. shim + correct pin, mode=forge: fails (the H1 forge is refused)
//
// Exit: 0 = outcome matched -want; 1 = mismatch; 2 = transport failure.
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

var want = flag.String("want", "pass", "expected outcome: pass|fail")
var tlsDir = flag.String("tls-dir", ".smalt/tls", "smalt TLS material dir")
var mode = flag.String("mode", "real", "server chain: real|forge|evil")
var sysroot = flag.Bool("sysroot", false,
	"real crypto/tls dial with RootCAs=nil (Go system verification path; roots=nil -> x509 systemVerify -> SecTrustEvaluateWithError)")
var anchorProbe = flag.Bool("anchor-probe", false,
	"cgo SecTrustCopyAnchorCertificates: pass iff the pinned CA (SMALT_CA_FILE) is present in the returned anchor array")
var settingsProbe = flag.Bool("settings-probe", false,
	"cgo SecTrustSettingsCopyCertificates (user/admin/system domains): pass iff the pinned CA appears in any domain's cert list")

var errSecTrustFailed = errors.New("security.framework: trust evaluation rejected the chain")

// mintSelfSigned makes an attacker-controlled self-signed leaf with the given
// DNS SANs — no smalt private key involved (the H1 forge primitive). Returns
// the DER plus the key (needed as the server-side crypto.Signer).
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

// poisonAnchor mints a fresh per-run self-signed cert used as the EXCLUSIVE
// trust anchor during evaluation (hermetic baseline; see secTrustEvaluate).
func poisonAnchor() []byte {
	der, _ := mintSelfSigned([]string{"smalt-probe-poison-anchor.invalid"})
	return der
}

// --- cgo helpers (C pointers stay behind unsafe.Pointer walls) ----------

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

// secTrustEvaluate builds certs + SSL policy(hostname) + trust, then runs the
// real SecTrustEvaluateWithError. true = trusted.
//
// HERMETIC BASELINE: a fresh per-run poison anchor is installed with
// SecTrustSetAnchorCertificatesOnly(trust, true), so the ONLY trusted anchor
// for this evaluation is one nothing can chain to. The baseline therefore
// ALWAYS fails without the shim — the operator's keychain state (which may
// legitimately hold a trusted smalt-dev-ca from the opt-in fallback) cannot
// fake the flip, in either direction.
func secTrustEvaluate(chain [][]byte, hostname string) bool {
	certs := cfMutableArray(len(chain))
	defer cfRelease(certs)
	for _, der := range chain {
		d := cfData(der)
		if d == nil {
			return false
		}
		defer cfRelease(d)
		crt := unsafe.Pointer(C.SecCertificateCreateWithData(0, C.CFDataRef(d)))
		if crt == nil {
			return false
		}
		defer cfRelease(crt)
		cfArrayAppend(certs, crt)
	}
	var hp C.CFStringRef
	if hostname != "" {
		ch := C.CString(hostname)
		defer C.free(unsafe.Pointer(ch))
		hp = C.CFStringCreateWithCString(0, ch, C.kCFStringEncodingUTF8)
		defer C.CFRelease(C.CFTypeRef(unsafe.Pointer(hp)))
	}
	policy := unsafe.Pointer(C.SecPolicyCreateSSL(1, hp))
	defer cfRelease(policy)
	var trust C.SecTrustRef
	st := C.SecTrustCreateWithCertificates(C.CFTypeRef(unsafe.Pointer(certs)), C.CFTypeRef(policy), &trust)
	if st != 0 || unsafe.Pointer(trust) == nil {
		return false
	}
	tp := unsafe.Pointer(trust)
	if tp == nil {
		return false
	}
	defer C.CFRelease(C.CFTypeRef(tp))

	// Exclusive poison anchor: baseline fails without the shim, hermetically.
	anchors := cfMutableArray(1)
	defer cfRelease(anchors)
	pd := cfData(poisonAnchor())
	if pd == nil {
		return false
	}
	defer cfRelease(pd)
	pcrt := unsafe.Pointer(C.SecCertificateCreateWithData(0, C.CFDataRef(pd)))
	if pcrt == nil {
		return false
	}
	defer cfRelease(pcrt)
	cfArrayAppend(anchors, pcrt)
	C.SecTrustSetAnchorCertificates(C.SecTrustRef(tp), C.CFArrayRef(anchors))
	C.SecTrustSetAnchorCertificatesOnly(C.SecTrustRef(tp), 1)
	var cfErr C.CFErrorRef
	return bool(C.SecTrustEvaluateWithError(C.SecTrustRef(tp), &cfErr))
}

func main() {
	flag.Parse()

	// anchor-probe leg: direct witness for the v2 anchor-enumeration
	// interpose. Go never calls SecTrustCopyAnchorCertificates (witnessed:
	// go1.23.4 root_darwin.go), so this leg calls it via cgo itself and
	// checks the pinned CA landed in the returned array.
	if *anchorProbe {
		caFile := os.Getenv("SMALT_CA_FILE")
		if caFile == "" {
			fmt.Fprintln(os.Stderr, "anchor-probe needs SMALT_CA_FILE")
			os.Exit(2)
		}
		caPEM, err := os.ReadFile(caFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, "read ca:", err)
			os.Exit(2)
		}
		caDER := loadPEMOnly(caPEM)
		if len(caDER) == 0 {
			caDER = caPEM // raw DER file
		}
		d := cfData(caDER)
		if d == nil {
			os.Exit(2)
		}
		defer cfRelease(d)
		crt := unsafe.Pointer(C.SecCertificateCreateWithData(0, C.CFDataRef(d)))
		if crt == nil {
			fmt.Fprintln(os.Stderr, "parse ca cert failed")
			os.Exit(2)
		}
		defer cfRelease(crt)
		var anchors C.CFArrayRef
		st := C.SecTrustCopyAnchorCertificates(&anchors)
		if st != 0 || unsafe.Pointer(anchors) == nil {
			fmt.Fprintln(os.Stderr, "SecTrustCopyAnchorCertificates failed:", st)
			os.Exit(2)
		}
		defer C.CFRelease(C.CFTypeRef(unsafe.Pointer(anchors)))
		found := false
		for i := C.CFIndex(0); i < C.CFArrayGetCount(anchors); i++ {
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
		fmt.Printf("ANCHORS: %s (pinned CA in SecTrustCopyAnchorCertificates output=%v, n=%d)\n",
			got, found, C.CFArrayGetCount(anchors))
		legExit(got)
	}

	// settings-probe leg: witness for the SecTrustSettingsCopyCertificates
	// interpose across the user/admin/system trust domains.
	if *settingsProbe {
		caFile := os.Getenv("SMALT_CA_FILE")
		if caFile == "" {
			fmt.Fprintln(os.Stderr, "settings-probe needs SMALT_CA_FILE")
			os.Exit(2)
		}
		caPEM, err := os.ReadFile(caFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, "read ca:", err)
			os.Exit(2)
		}
		caDER := loadPEMOnly(caPEM)
		if len(caDER) == 0 {
			caDER = caPEM
		}
		d := cfData(caDER)
		if d == nil {
			os.Exit(2)
		}
		defer cfRelease(d)
		crt := unsafe.Pointer(C.SecCertificateCreateWithData(0, C.CFDataRef(d)))
		if crt == nil {
			fmt.Fprintln(os.Stderr, "parse ca cert failed")
			os.Exit(2)
		}
		defer cfRelease(crt)
		found := false
		var domains []C.SecTrustSettingsDomain
		for _, dom := range []C.SecTrustSettingsDomain{C.kSecTrustSettingsDomainUser, C.kSecTrustSettingsDomainAdmin, C.kSecTrustSettingsDomainSystem} {
			domains = append(domains, dom)
		}
		seen := map[C.SecTrustSettingsDomain]int{}
		for _, dom := range domains {
			var arr C.CFArrayRef
			st := C.SecTrustSettingsCopyCertificates(dom, &arr)
			if st != 0 || unsafe.Pointer(arr) == nil {
				continue
			}
			n := C.CFArrayGetCount(arr)
			seen[dom] = int(n)
			for i := C.CFIndex(0); i < n; i++ {
				e := C.CFArrayGetValueAtIndex(arr, i)
				if e != nil && C.CFEqual(C.CFTypeRef(e), C.CFTypeRef(crt)) != 0 {
					found = true
				}
			}
			C.CFRelease(C.CFTypeRef(unsafe.Pointer(arr)))
		}
		got := "fail"
		if found {
			got = "pass"
		}
		fmt.Printf("SETTINGS: %s (pinned CA in SecTrustSettingsCopyCertificates output=%v, counts=%v)\n",
			got, found, seen)
		legExit(got)
	}

	caPEM, err := os.ReadFile(filepath.Join(*tlsDir, "ca-cert.pem"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "read ca:", err)
		os.Exit(2)
	}
	caDER := loadPEMOnly(caPEM)

	var serverCert tls.Certificate
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
		serverCert, err = tls.X509KeyPair(append(certPEM, caPEM...), keyPEM)
		if err != nil {
			fmt.Fprintln(os.Stderr, "keypair:", err)
			os.Exit(2)
		}
	case "forge", "evil":
		sans := []string{"localhost", "127.0.0.1"}
		if *mode == "evil" {
			sans = []string{"evil.example", "portal.azure.com"}
		}
		// Self-made leaf (own key) + the PUBLIC smalt CA appended — the H1
		// attacker chain: membership of the CA no longer grants anything.
		leafDER, signer := mintSelfSigned(sans)
		serverCert = tls.Certificate{
			Certificate: [][]byte{leafDER, caDER},
			PrivateKey:  signer,
		}
	default:
		fmt.Fprintln(os.Stderr, "unknown -mode:", *mode)
		os.Exit(2)
	}

	srv := httptest.NewUnstartedServer(nil)
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{serverCert}}
	srv.StartTLS()
	defer srv.Close()
	url := strings.Replace(srv.URL, "127.0.0.1", "localhost", 1)

	// sysroot legs: a REAL crypto/tls dial with RootCAs=nil — Go's actual
	// system verification path (x509 systemVerify on darwin = the
	// SecTrustEvaluateWithError surface the shim interposes). No cgo
	// orchestration, no poison anchor: the verdict is Go's own.
	if *sysroot {
		client := &http.Client{Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: nil}, // system roots
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

	trusted := false
	client := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				// Transport-level skip only; the verdict comes from the real
				// Security.framework evaluation over the presented chain.
				InsecureSkipVerify: true,
				VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
					trusted = secTrustEvaluate(rawCerts, "localhost")
					if trusted {
						return nil
					}
					return errSecTrustFailed
				},
			},
		},
	}
	resp, err := client.Get(url)
	if err != nil {
		if errors.Is(err, errSecTrustFailed) {
			fmt.Printf("SEC-TRUST: fail (mode=%s, SecTrustEvaluateWithError rejected the chain), url: %s\n", *mode, url)
			legExit("fail")
		}
		fmt.Println("TRANSPORT-FAIL:", err)
		os.Exit(2)
	}
	resp.Body.Close()

	fmt.Printf("SEC-TRUST: pass (mode=%s, SecTrustEvaluateWithError accepted the chain), url: %s\n", *mode, url)
	legExit("pass")
}

func loadPEMOnly(b []byte) []byte {
	var der []byte
	for {
		var p *pem.Block
		p, b = pem.Decode(b)
		if p == nil {
			break
		}
		if p.Type == "CERTIFICATE" {
			der = append(der, p.Bytes...)
		}
	}
	return der
}

func legExit(got string) {
	if got == *want {
		fmt.Println("LEG OK: want=" + *want + " got=" + got)
		os.Exit(0)
	}
	fmt.Println("LEG MISMATCH: want=" + *want + " got=" + got)
	os.Exit(1)
}
