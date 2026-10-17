/*
 * smalt_trust_shim.c - zero-touch darwin trust shim
 *
 * Injected via DYLD_INSERT_LIBRARIES; interposes Security.framework trust
 * surfaces:
 *   v1: SecTrustEvaluateWithError (modern) + SecTrustEvaluate (legacy)
 *   v2: SecTrustCopyAnchorCertificates + SecTrustSettingsCopyCertificates
 *       (all three trust domains) — the anchor-enumeration surface some
 *       root-loading clients read. go1.23.4 crypto/x509 does NOT call these
 *       (witnessed: root_darwin.go uses SecTrustEvaluateWithError directly),
 *       so for Go the v1 interpose is the enforcement surface; v2 keeps the
 *       shim honest for clients that enumerate anchors.
 *
 * Anchor append (v2) is gated on the launcher env contract — BOTH
 * SMALT_CA_FILE (the pinned CA, DER or PEM, launchers set it) and a leaf pin
 * (SMALT_LEAF_SHA256 / back-compat SMALT_CA_SHA256) must be present. The
 * anchor APIs carry no trust object, so leaf-pin + loopback cannot be
 * evaluated there; enforcement remains at the SecTrustEvaluate* interposes.
 * Leaf-pin + loopback gating (below) is UNCHANGED from v1.
 *
 * Grants trust ONLY when ALL of:
 *  (a) loopback target: decided from the leaf SAN set (the trust object
 *      does not expose the policy hostname via public API). A readable SAN
 *      set is DECISIVE - localhost / 127.0.0.1 / ::1 grants the loopback
 *      channel; a readable set without a loopback entry refuses.
 *      Unreachable (no chain / no SAN dict) -> conservatively fall through.
 *  (b) EXACT-LEAF PIN (2026-10-16, H1 fix): cert[0] of the PRESENTED chain
 *      must byte-match (SHA-256) the pinned fingerprint — SMALT_LEAF_SHA256,
 *      or SMALT_CA_SHA256 (back-compat env read; launchers now pin the leaf).
 *      Colons and case ignored. Mismatch -> real function -> normal x509
 *      failure. Fingerprint-pinned, NOT a blanket bypass.
 *
 * H1 (security review, fixed): the previous rule accepted trust on
 * PRESENTED-chain MEMBERSHIP — an attacker minting a leaf with SAN localhost
 * and presenting the public smalt CA cert passed both gates with no private
 * key. Membership scanning is removed; only the exact leaf matches.
 *
 * Non-loopback hosts: ALWAYS fall through.
 *
 * Codesigning constraint: DYLD_INSERT_LIBRARIES only applies to binaries
 * without the hardened-runtime restriction. Go release binaries are ad-hoc
 * signed and non-hardened - they qualify. Verify:
 *   codesign -dv --verbose=2 <binary> | grep -i flags
 * (a "runtime" flag means hardened; the shim will NOT inject there.)
 *
 * Requires macOS 12+ (SecTrustCopyCertificateChain). Build:
 * scripts/trust_shim/build.sh
 */

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* SHIM-COURT: the interposed bodies below are the mutation surface. */

#define PIN_MAX 128
static char g_pin[PIN_MAX + 1];
static int  g_pin_loaded = 0;

static void hexnorm(const char *in, char *out, size_t outsz) {
    size_t j = 0;
    if (!in) { out[0] = 0; return; }
    for (size_t i = 0; in[i] != 0 && j + 1 < outsz; i++) {
        char c = in[i];
        if (c == ':' || c == ' ') continue;
        if (c >= 'A' && c <= 'F') c = (char)(c + 32);
        out[j++] = c;
    }
    out[j] = 0;
}

static const char *get_pin(void) {
    if (!g_pin_loaded) {
        g_pin_loaded = 1;
        /* SHIM-COURT: leaf pin preferred; SMALT_CA_SHA256 kept back-compat. */
        hexnorm(getenv("SMALT_LEAF_SHA256"), g_pin, sizeof(g_pin));
        if (g_pin[0] == 0) hexnorm(getenv("SMALT_CA_SHA256"), g_pin, sizeof(g_pin));
    }
    return (g_pin[0] != 0) ? g_pin : NULL;
}

static int host_is_loopback(const char *h) {
    if (!h) return 0;
    return strcmp(h, "localhost") == 0 ||
           strcmp(h, "127.0.0.1") == 0 ||
           strcmp(h, "::1") == 0;
}

/* 1 = loopback, 0 = readable NOT loopback (refuse), -1 = unreachable */
static int leaf_san_loopback(SecTrustRef trust) {
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    if (!chain) return -1;
    int rv = -1;
    if (CFArrayGetCount(chain) > 0) {
        SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
        if (leaf) {
            CFTypeRef keys[1] = { kSecOIDSubjectAltName };
            CFArrayRef keysArr = CFArrayCreate(NULL, keys, 1, &kCFTypeArrayCallBacks);
            CFDictionaryRef vals = SecCertificateCopyValues(leaf, keysArr, NULL);
            if (keysArr) CFRelease(keysArr);
            if (vals) {
                rv = 0; /* SAN readable: decisive */
                /* darwin 25 shape (witnessed): {OID: {"value": [ {label,value}... ]}}
                 * where DNS/IP SANs arrive as CFStrings ("localhost", "127.0.0.1") */
                CFDictionaryRef sanSec = (CFDictionaryRef)CFDictionaryGetValue(vals, kSecOIDSubjectAltName);
                if (sanSec && CFGetTypeID(sanSec) == CFDictionaryGetTypeID()) {
                    CFTypeRef arrRef = CFDictionaryGetValue(sanSec, CFSTR("value"));
                    if (arrRef && CFGetTypeID(arrRef) == CFArrayGetTypeID()) {
                        CFArrayRef arr = (CFArrayRef)arrRef;
                        for (CFIndex k = 0; k < CFArrayGetCount(arr); k++) {
                            CFDictionaryRef e = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, k);
                            CFTypeRef v = e ? CFDictionaryGetValue(e, kSecPropertyKeyValue) : NULL;
                            if (!v) continue;
                            if (CFGetTypeID(v) == CFStringGetTypeID()) {
                                char buf[256];
                                if (CFStringGetCString((CFStringRef)v, buf, sizeof(buf),
                                                       kCFStringEncodingUTF8) &&
                                    host_is_loopback(buf)) {
                                    rv = 1;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            if (vals) CFRelease(vals);
        }
    }
    CFRelease(chain);
    return rv;
}

/* SHA-256 hex of ONE certificate (helper for the exact-leaf pin). */
static void cert_sha256_hex(SecCertificateRef c, char *hex, size_t hexsz) {
    static const char hx[] = "0123456789abcdef";
    hex[0] = 0;
    if (!c || hexsz < 2 * CC_SHA256_DIGEST_LENGTH + 1) return;
    CFDataRef der = SecCertificateCopyData(c);
    if (!der) return;
    uint8_t dig[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), dig);
    CFRelease(der);
    for (int k = 0; k < CC_SHA256_DIGEST_LENGTH; k++) {
        hex[2 * k]     = hx[dig[k] >> 4];
        hex[2 * k + 1] = hx[dig[k] & 0x0f];
    }
    hex[2 * CC_SHA256_DIGEST_LENGTH] = 0;
}

/* EXACT-LEAF PIN (SHIM-COURT fix for H1): cert[0] of the PRESENTED chain
 * must byte-match the pin. No chain-membership scanning — presenting the
 * public smalt CA under an attacker-minted leaf no longer grants trust;
 * forging the leaf requires the smalt dev CA private key. */
static int leaf_matches_pin(SecTrustRef trust, const char *pin) {
    if (SecTrustGetCertificateCount(trust) < 1) return 0;
    SecCertificateRef leaf = SecTrustGetCertificateAtIndex(trust, 0);
    if (!leaf) return 0;
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    cert_sha256_hex(leaf, hex, sizeof(hex));
    return hex[0] != 0 && strcmp(hex, pin) == 0;
}

/* 1 = shim trusts, 0 = fall through to the real function */
static int shim_should_trust(SecTrustRef trust) {
    const char *pin = get_pin();
    if (!pin) { if (getenv("SMALT_SHIM_DEBUG")) fprintf(stderr, "[shim] gate: no pin\n"); return 0; }
    int loop = leaf_san_loopback(trust);
    if (getenv("SMALT_SHIM_DEBUG")) fprintf(stderr, "[shim] gate: pin ok, san=%d\n", loop);
    if (loop != 1) return 0;                  /* not loopback / unreachable */
    if (!leaf_matches_pin(trust, pin)) { if (getenv("SMALT_SHIM_DEBUG")) fprintf(stderr, "[shim] gate: PIN MISMATCH\n"); return 0; }
    return 1;
}

static Boolean shim_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef *error) {
    if (trust && shim_should_trust(trust)) {
        if (error && *error) { CFRelease(*error); *error = NULL; }
        return 1; /* SHIM-COURT: AFTER flip lives here */
    }
    return SecTrustEvaluateWithError(trust, error);
}

static OSStatus shim_SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result) {
    if (trust && shim_should_trust(trust) && result) {
        *result = kSecTrustResultUnspecified;
        return errSecSuccess; /* SHIM-COURT: AFTER flip lives here */
    }
    return SecTrustEvaluate(trust, result);
}

/* ---- v2: anchor-enumeration surface ---------------------------------- */

/* Pinned CA cert, loaded once from SMALT_CA_FILE (launchers set it).
 * Process-lifetime cache: the CFArrayAppendValue retain is balanced because
 * the cache itself is never released. */
static SecCertificateRef g_ca = NULL;
static int g_ca_loaded = 0;

/* Minimal base64 decoder for the PEM fallback path. Returns decoded length,
 * or -1 on bad input. */
static long b64dec(const char *in, unsigned char *out, long outsz) {
    static signed char T[256];
    static int Tinit = 0;
    if (!Tinit) {
        memset(T, -1, sizeof T);
        const char *alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (int i = 0; alpha[i]; i++) T[(unsigned char)alpha[i]] = (signed char)i;
        Tinit = 1;
    }
    long n = 0;
    unsigned acc = 0;
    int bits = 0;
    for (; in && *in && n < outsz; in++) {
        signed char v = T[(unsigned char)*in];
        if (v < 0 || *in == '=') continue;
        acc = (acc << 6) | (unsigned)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = (unsigned char)((acc >> bits) & 0xff);
        }
    }
    return n; /* leftover bits (0-5) are standard base64 padding zeros */
}

static SecCertificateRef pinned_ca(void) {
    if (!g_ca_loaded) {
        g_ca_loaded = 1;
        const char *path = getenv("SMALT_CA_FILE");
        if (path && path[0]) {
            FILE *f = fopen(path, "rb");
            if (f) {
                fseek(f, 0, SEEK_END);
                long n = ftell(f);
                fseek(f, 0, SEEK_SET);
                if (n > 0) {
                    unsigned char *buf = malloc((size_t)n);
                    if (buf && fread(buf, 1, (size_t)n, f) == (size_t)n) {
                        CFDataRef d = CFDataCreate(NULL, buf, (CFIndex)n);
                        if (d) {
                            /* SHIM-COURT: anchor append subject.
                             * DER first; PEM fallback (launchers point at
                             * .smalt/tls/ca-cert.pem, which is PEM). */
                            g_ca = SecCertificateCreateWithData(NULL, d);
                            CFRelease(d);
                        }
                        if (!g_ca && n < 64 * 1024) {
                            const char *b = (const char *)buf;
                            const char *beg = strstr(b, "-----BEGIN CERTIFICATE-----");
                            const char *end = beg ? strstr(beg, "-----END CERTIFICATE-----") : NULL;
                            if (beg && end) {
                                beg += strlen("-----BEGIN CERTIFICATE-----");
                                while (*beg && *beg != '\n' && beg < end) beg++; /* skip header line */
                                if (*beg == '\n') beg++;
                                long body = (long)(end - beg);
                                unsigned char *der = malloc((size_t)body);
                                long dn = b64dec(beg, der, body);
                                if (getenv("SMALT_SHIM_DEBUG")) fprintf(stderr, "[shim] pem: begoff=%ld body=%ld dn=%ld\n", (long)(beg - b), body, dn);
                                if (dn > 0) {
                                    CFDataRef dd = CFDataCreate(NULL, der, (CFIndex)dn);
                                    if (dd) {
                                        g_ca = SecCertificateCreateWithData(NULL, dd);
                                        CFRelease(dd);
                                    }
                                }
                                free(der);
                            }
                        }
                    }
                    free(buf);
                }
                fclose(f);
            }
        }
    }
    return g_ca;
}

/* Anchor-append gate. NOTE: SecTrustCopyAnchorCertificates() and
 * SecTrustSettingsCopyCertificates() take NO trust object, so the leaf-pin +
 * loopback gates CANNOT be evaluated here — there is no peer chain to check.
 * The gate is therefore the launcher env CONTRACT (both SMALT_CA_FILE and a
 * leaf pin present). Enforcement of leaf-pin + loopback stays at the
 * SecTrustEvaluate* interposes above, which every evaluation passes through. */
static int anchor_append_allowed(void) {
    return pinned_ca() != NULL && get_pin() != NULL;
}

/* CFArray of anchors with the pinned smalt dev CA appended (+1). Caller owns
 * the returned array; the appended cert is retained by the array and balanced
 * by the process-lifetime cache (no leak, no over-release, per-handshake safe). */
static CFMutableArrayRef anchors_with_ca(CFArrayRef real) {
    CFIndex n = real ? CFArrayGetCount(real) : 0;
    CFMutableArrayRef out = real
        ? CFArrayCreateMutableCopy(NULL, n + 1, (CFArrayRef)real)
        : (CFMutableArrayRef)CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    if (!out) return NULL;
    CFArrayAppendValue(out, pinned_ca());
    if (real) CFRelease(real);
    return out;
}

static OSStatus shim_SecTrustCopyAnchorCertificates(CFArrayRef *anchors) {
    OSStatus st = SecTrustCopyAnchorCertificates(anchors);
    if (getenv("SMALT_SHIM_DEBUG")) fprintf(stderr, "[shim] SecTrustCopyAnchorCertificates st=%d allowed=%d n=%ld\n",
        (int)st, anchor_append_allowed(), (long)(anchors && *anchors ? CFArrayGetCount(*anchors) : -1));
    if (st != errSecSuccess || !anchors || !anchor_append_allowed()) return st;
    CFMutableArrayRef m = anchors_with_ca((CFArrayRef)*anchors);
    if (m) *anchors = (CFArrayRef)m; /* SHIM-COURT: AFTER flip lives here */
    return st;
}

static OSStatus shim_SecTrustSettingsCopyCertificates(SecTrustSettingsDomain domain,
                                                      CFArrayRef *certs) {
    OSStatus st = SecTrustSettingsCopyCertificates(domain, certs);
    if (st != errSecSuccess || !certs || !anchor_append_allowed()) return st;
    CFMutableArrayRef m;
    if (*certs) {
        m = CFArrayCreateMutableCopy(NULL, CFArrayGetCount(*certs) + 1, *certs);
        CFRelease(*certs);
    } else {
        m = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    }
    if (!m) return st;
    CFArrayAppendValue(m, pinned_ca());
    *certs = m; /* SHIM-COURT: AFTER flip lives here */
    return st;
}

typedef struct { const void *replacement; const void *original; } shim_pair;

__attribute__((used))
static shim_pair shim_interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)shim_SecTrustEvaluateWithError, (const void *)SecTrustEvaluateWithError },
    { (const void *)shim_SecTrustEvaluate,          (const void *)SecTrustEvaluate },
    { (const void *)shim_SecTrustCopyAnchorCertificates, (const void *)SecTrustCopyAnchorCertificates },
    { (const void *)shim_SecTrustSettingsCopyCertificates, (const void *)SecTrustSettingsCopyCertificates },
};
