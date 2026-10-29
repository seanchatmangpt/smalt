/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // WI-3 (BK-TOPO matrix, cell 2b): standalone output for the console
  // container image — emits .next/standalone with a bundled server.js and
  // only the node_modules subset the build traced. `next dev` is unaffected
  // (standalone is a build-output mode only); the BFF faces
  // (force-dynamic route handlers) stay server-served — this is NOT
  // BK-P20's falsified static export.
  output: "standalone",
  // Air-gapped evaluation console: never allow image/font/script egress.
  images: { unoptimized: true },
  async headers() {
    return [
      {
        source: "/(.*)",
        headers: [
          { key: "X-Frame-Options", value: "DENY" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "no-referrer" },
          // W3C-E row 10: origin isolation — unlocks SharedArrayBuffer for
          // zero-copy UI<->worker transfer; Spectre-class mitigation posture.
          { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
          { key: "Cross-Origin-Embedder-Policy", value: "require-corp" },
        ],
      },
    ];
  },
};

export default nextConfig;
