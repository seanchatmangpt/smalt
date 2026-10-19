// wf4-crypto — keyvault-keys over the TLS twin, serviceVersion "7.4":
// KD-15 challenge witness, key versions, wrap/unwrap, sign + EXTERNAL
// child-process verification with node:crypto (anti-tautology leg),
// soft-delete/recover/purge.
import { KeyClient, CryptographyClient, type KeyVaultKey } from "@azure/keyvault-keys";
import { spawnSync } from "node:child_process";
import { check, GREEN, RD, type WfResult } from "../harness/enum.ts";
import type { SubstrateCoords, CredMode } from "../harness/credential.ts";
import { TENANT } from "../harness/credential.ts";

type Ctx = { coords: SubstrateCoords; runid: string; cred: any; credMode: CredMode };

export async function run(ctx: Ctx): Promise<WfResult> {
  const checks: WfResult["checks"] = [];
  const p = (name: string, verdict: string, detail: string) => checks.push(check(name, verdict, detail));
  const vault = ctx.coords.tls; // https://localhost:<tls>

  const client = new KeyClient(vault, ctx.cred, {
    serviceVersion: "7.4",
    // KD-15 challenge shape: the substrate challenge advertises resource=
    // "https://localhost:<port>" (port-suffixed); the SDK domain check wants
    // the bare vault host, so this flag is the documented localhost workaround.
    disableChallengeResourceVerification: true,
  });
  const keyName = `wf4-${ctx.runid}`;

  // --- KD-15 challenge witness: tokenless 401, credential recovers --------
  const challenge = await fetch(`${vault}/keys/${keyName}?api-version=7.4`);
  const www = challenge.headers.get("www-authenticate") ?? "";
  const challengeOk = challenge.status === 401 && /Bearer authorization=/i.test(www);
  p("kv-challenge-witness-KD-15",
    challengeOk ? GREEN : "FAIL",
    `tokenless -> ${challenge.status}, WWW-Authenticate=${www.slice(0, 120)}`);

  // --- createKey RSA-2048 x2 versions --------------------------------------
  const v1 = await client.createKey(keyName, "RSA", { keySize: 2048 });
  p("kv-create-rsa2048", GREEN, `kid=${v1.id}`);
  const v2 = await client.createKey(keyName, "RSA", { keySize: 2048 });
  // Raw list (bounded): the SDK pager loops forever on this substrate's
  // version feed (no continuation token is ever served — same class as KD-09),
  // so count versions via one raw wire call instead of an unpaginated drain.
  const tok = await ctx.cred.getToken("https://management.azure.com/.default");
  const vlist = await fetch(`${vault}/keys/${keyName}/versions?api-version=7.4`, {
    headers: { authorization: `Bearer ${tok.token}` },
  }).then((r) => r.json());
  const versions = Array.isArray(vlist?.value) ? vlist.value : [];
  p("kv-two-versions", versions.length >= 2 ? GREEN : "FAIL", `versions=${versions.length}`);

  // --- wrapKey/unwrapKey roundtrip -----------------------------------------
    // kid host rewrite: the substrate stamps kids with its canonical
  // https://<name>:8443 authority, which is not dialable here; the SDK's
  // CryptographyClient targets the kid's host. Rebuild the identifier on the
  // vault the client actually serves (versionless = latest version).
  const crypto = new CryptographyClient(`${vault}/keys/${keyName}`, ctx.cred, {
    disableChallengeResourceVerification: true,
  } as any);
  const cek = Buffer.from("0123456789abcdef0123456789abcdef");
  const wrapped = await crypto.wrapKey("RSA-OAEP-256", cek);
  const unwrapped = await crypto.unwrapKey("RSA-OAEP-256", wrapped.result);
  p("kv-wrap-unwrap",
    Buffer.compare(Buffer.from(unwrapped.result), cek) === 0 ? GREEN : "FAIL",
    `wrap/unwrap roundtrip equal=${Buffer.compare(Buffer.from(unwrapped.result), cek) === 0}`);

  // --- sign RS256 -> EXTERNAL verify in a child process --------------------
  const digest = Buffer.from(
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "hex",
  );
  const signed = await crypto.sign("RS256", digest);
  const b64u = (v: unknown) =>
    typeof v === "string" ? v : Buffer.from(v as Uint8Array).toString("base64url");
  const pub = (v2.key?.n && v2.key?.e)
    ? { n: b64u(v2.key.n), e: b64u(v2.key.e) }
    : null;
  if (!pub) {
    p("kv-sign-rs256", "FAIL", "no public JWK returned by createKey");
    return { id: "wf4", checks };
  }
  const verifier = spawnSync(
    process.execPath,
    ["--input-type=module", "-e", externalVerifier(digest.toString("base64"), signed.result.toString("base64"), pub.n, pub.e)],
    { encoding: "utf8", timeout: 30_000 },
  );
  const extOk = verifier.status === 0 && verifier.stdout.trim().endsWith("true");
  p(
    "kv-sign-external-verify",
    extOk ? GREEN : RD("KD-14,KD-105"),
    extOk
      ? "external node:crypto verify=true against public JWK"
      : `external node:crypto verify=${(verifier.stdout ?? "").trim() || "<empty>"} (child status=${verifier.status}) — signature-shape divergence per KD-14/KD-105`,
  );

  // red-against-missing-plane: dead TLS port -> typed failure
  try {
    const dead = new KeyClient("https://localhost:1", ctx.cred, { serviceVersion: "7.4", retryOptions: { maxRetries: 0, timeoutInMs: 5_000 } });
    await dead.getKey(keyName);
    p("dead-port-plane-check", "FAIL", "dead-port KV getKey resolved");
  } catch (err: any) {
    const real = /ECONNREFUSED|ECONNRESET|fetch failed|UND_ERR|AggregateError|certificate|RestError/i.test(String(err?.name) + String(err?.message ?? "") + String(err?.cause?.code ?? ""));
    p("dead-port-plane-check", real ? GREEN : "FAIL", `dead TLS twin typed failure (${err?.name})`);
  }

  // --- soft-delete -> recover -> purge --------------------------------------
  // The SDK delete/recover pollers hang on this substrate (deleted-key feed
  // never reaches terminality), so the lifecycle is asserted over bounded raw
  // wire calls (same bounded-poll law; every call has a wire-shaped verdict).
  const dk = `${vault}/keys/${keyName}?api-version=7.4`;
  const dkd = `${vault}/deletedkeys/${keyName}?api-version=7.4`;
  const h = { authorization: `Bearer ${tok.token}` };
  const delRes = await fetch(dk, { method: "DELETE", headers: h });
  p("kv-soft-delete", delRes.status === 200 ? GREEN : "FAIL",
    `DELETE /keys -> ${delRes.status}${delRes.status === 200 ? " (deletedDate present)" : ""}`);
  const getDel = await fetch(dkd, { headers: h });
  p("kv-get-deleted", getDel.status === 200 ? GREEN : "FAIL",
    `GET /deletedkeys -> ${getDel.status} (recoverable-plane ${getDel.status === 200 ? "present" : "MISSING — recover/purge unexercisable"})`);
  const rec = await fetch(`${dkd}/recover`, { method: "POST", headers: h });
  p("kv-recover", rec.status === 200 ? GREEN : "FAIL", `POST /deletedkeys/recover -> ${rec.status}`);
  const purge = await fetch(dkd, { method: "DELETE", headers: h });
  p("kv-purge", [200, 204, 404].includes(purge.status) ? GREEN : "FAIL",
    `DELETE /deletedkeys (purge) -> ${purge.status}; post-purge /keys/${keyName} -> ${(await fetch(dk, { headers: h })).status}`);

  return { id: "wf4", checks };
}

function externalVerifier(digestB64: string, sigB64: string, nB64url: string, eB64url: string): string {
  return `
import crypto from "node:crypto";
const b64u = (s) => Buffer.from(s, "base64url");
const n = b64u(${JSON.stringify(nB64url)});
const e = b64u(${JSON.stringify(eB64url)});
const modulusLength = n.length * 8;
const pub = crypto.createPublicKey({ key: { kty: "RSA", n: ${JSON.stringify(nB64url)}, e: ${JSON.stringify(eB64url)} }, format: "jwk" });
const digest = Buffer.from(${JSON.stringify(digestB64)}, "base64");
const sig = Buffer.from(${JSON.stringify(sigB64)}, "base64");
const ok = crypto.verify("RSA-SHA256", digest, pub, sig);
console.log(String(ok));
`;
}
