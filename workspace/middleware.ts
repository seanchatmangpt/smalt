/**
 * Next.js middleware (workspace root — Next 16 single-location convention,
 * no src/app split: the app dir is workspace/app). Server-side complement to
 * the client-side air-gap guard in lib/smalt.ts.
 *
 * Next middleware intercepts INBOUND requests, so the honest enforcement
 * here is redirect-hygiene: any inbound request to a console API route that
 * carries a redirect-ish query parameter (url / redirect / next / target /
 * continue / returnTo) pointing off-loopback — in particular an open-redirect
 * to *.azure.com / *.microsoft.com — is refused 400 before any handler runs.
 * Loopback targets pass through untouched.
 *
 * The OUTBOUND half of the air gap is src/lib/airgap-fetch.ts (global fetch
 * allowlisting); the two together close both directions.
 */

// "next/server.js" (concrete file, not the subpath) so the court can run the
// middleware under plain `node --test` — node ESM needs a real file since the
// next package ships no exports map. Next's bundler resolves it identically.
import { NextResponse, type NextRequest } from "next/server.js";

const REDIRECT_KEYS = ["url", "redirect", "next", "target", "continue", "returnto"];

const FORBIDDEN_SUFFIXES = [".azure.com", ".microsoft.com", ".windows.net", ".msftauth.net"];

function isLoopback(host: string): boolean {
  return ["127.0.0.1", "localhost", "::1", "[::1]"].includes(host);
}

function isForbiddenHost(host: string): boolean {
  const h = host.toLowerCase();
  return FORBIDDEN_SUFFIXES.some((s) => h === s.slice(1) || h.endsWith(s));
}

/** Pure decision core (unit-testable without the Next runtime). */
export function airgapRedirectDecision(
  target: string,
): { allow: true } | { allow: false; reason: string } {
  let u: URL;
  try {
    u = new URL(target, "http://127.0.0.1:9443");
  } catch {
    return { allow: false, reason: `unparseable redirect target: ${target}` };
  }
  if (isForbiddenHost(u.hostname)) {
    return { allow: false, reason: `open-redirect to cloud host refused: ${u.hostname}` };
  }
  if (!isLoopback(u.hostname)) {
    return { allow: false, reason: `redirect target off-loopback refused: ${u.hostname}` };
  }
  return { allow: true };
}

export function middleware(request: NextRequest) {
  const params = request.nextUrl.searchParams;
  for (const key of REDIRECT_KEYS) {
    const value = params.get(key);
    if (value === null) continue;
    const decision = airgapRedirectDecision(value);
    if (!decision.allow) {
      return NextResponse.json(
        {
          error: {
            code: "AirGapRedirectRefused",
            message: `Air-gap middleware: ${decision.reason}`,
            param: key,
          },
        },
        { status: 400 },
      );
    }
  }
  // Popcorn wasm BEAM host: the /popcorn page embeds /popcorn/index.html in a
  // same-origin iframe. The global X-Frame-Options: DENY (next.config.mjs)
  // would make the browser refuse to frame it, so rewrite to SAMEORIGIN here
  // (middleware headers run after config headers). Anti-clickjacking posture
  // is preserved: only this workspace origin may frame the bundle host.
  if (
    request.nextUrl.pathname === "/popcorn" ||
    request.nextUrl.pathname.startsWith("/popcorn/")
  ) {
    const res = NextResponse.next();
    res.headers.set("x-frame-options", "SAMEORIGIN");
    // The wasm BEAM boots threads on SharedArrayBuffer, which requires a
    // cross-origin-isolated document (COOP + COEP). Scoped to /popcorn/ only:
    // the iframe document's subresources are all same-origin vendored files,
    // so require-corp is satisfied without affecting console routes.
    res.headers.set("cross-origin-opener-policy", "same-origin");
    res.headers.set("cross-origin-embedder-policy", "require-corp");
    return res;
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/api/:path*", "/popcorn/:path*"],
};
