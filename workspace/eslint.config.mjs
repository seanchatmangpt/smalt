import nextFlat from "eslint-config-next";
import typescript from "eslint-config-next/typescript";

/**
 * Air-gap invariant: no network egress except the local smalt emulator.
 * Enforced mechanically — see the no-restricted-* rules below.
 */
const airGapRules = {
  "no-restricted-globals": [
    "error",
    {
      name: "XMLHttpRequest",
      message:
        "Air-gapped console: use fetch against NEXT_PUBLIC_SMALT_ARM / NEXT_PUBLIC_SMALT_EGRESS (localhost) only.",
    },
  ],
  "no-restricted-imports": [
    "error",
    {
      patterns: [
        {
          group: ["http*", "https*", "ws*", "axios", "got", "node-fetch", "undici", "superagent", "ky"],
          message:
            "Air-gapped console: zero egress. Use fetch() with a localhost smalt base URL only.",
        },
      ],
    },
  ],
  // Air-gap: fetch() may never take a URL string literal — it must build URLs
  // from SMALT_ARM / SMALT_EGRESS constants (lib/smalt.ts) so the only
  // possible hosts are the localhost emulator endpoints.
  "no-restricted-syntax": [
    "error",
    {
      selector: "CallExpression[callee.name='fetch'] > Literal",
      message:
        "Air-gap invariant: fetch() must not take a string literal URL. Use SMALT_ARM / SMALT_EGRESS from lib/smalt.ts (localhost only).",
    },
    {
      selector: "CallExpression[callee.name='fetch'] > TemplateLiteral",
      message:
        "Air-gap invariant: fetch() must not take a template-literal URL. Use smaltFetch/assertLocalUrl from lib/smalt.ts (localhost only).",
    },
  ],
};

// Air-gap: in production runtime source (lib/, app/, components/), a raw
// fetch() with a computed URL is only lawful when it carries the full guarded
// posture — assertLocalUrl around the URL argument AND redirect:"error" (the
// smaltFetch shape). Anything else is banned. Same-origin asset fetches in
// workers/sw and loopback probe harnesses in scripts/test are out of scope
// for this posture rule (the literal-URL rules above still apply everywhere).
const fetchPostureRule = {
  "no-restricted-syntax": [
    "error",
    {
      selector:
        "CallExpression[callee.name='fetch']:not(:has(Argument > Identifier[name='assertLocalUrl'])):not(:has(Argument > CallExpression[callee.name='assertLocalUrl'])):not(:has(ObjectExpression > Property[key.name='redirect'][value.value='error']))",
      message:
        "Air-gap invariant: raw fetch() must be smaltFetch (lib/smalt.ts) or carry the full guarded posture — assertLocalUrl(...) around the URL AND redirect:'error'.",
    },
  ],
};

const eslintConfig = [
  ...nextFlat,
  ...typescript,
  {
    rules: {
      ...airGapRules,
      // `_`-prefixed params/vars are deliberate interface-required or
      // positional-unused (e.g. WASI shim, checkpoint collector, gap methods).
      "@typescript-eslint/no-unused-vars": [
        "warn",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_", ignoreRestSiblings: true },
      ],
    },
  },
  {
    ignores: ["node_modules/**", ".next/**", "out/**", "public/popcorn/**"], // public/popcorn = vendored popcorn_demo build artifacts (beam.wasm bundle), not workspace source
  },
  {
    files: ["lib/**/*.ts", "app/**/*.ts", "app/**/*.tsx", "components/**/*.ts", "components/**/*.tsx", "middleware.ts", "src/**/*.ts", "src/**/*.tsx"],
    // *.test.ts legs already assertLocalUrl-guard their URLs; the posture rule
    // targets the production runtime egress surface, not the test harness.
    ignores: ["**/*.test.ts", "**/*.test.tsx"],
    rules: fetchPostureRule,
  },
];

export default eslintConfig;
