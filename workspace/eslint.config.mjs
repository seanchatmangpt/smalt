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
  ],
};

const eslintConfig = [
  ...nextFlat,
  ...typescript,
  {
    rules: airGapRules,
  },
  {
    ignores: ["node_modules/**", ".next/**", "out/**"],
  },
];

export default eslintConfig;
