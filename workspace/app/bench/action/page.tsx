import type { Metadata } from "next";
import { cookies } from "next/headers";
import { revalidateTag } from "next/cache";
import { benchAls, mintRequestId, type BenchRequestContext } from "./store";

export const metadata: Metadata = {
  title: "N2 action storm bench",
};

export type BenchActionState = {
  ok: boolean;
  requestId?: string;
  clientToken?: string;
  error?: string;
};

// Plain (Zod-like shape) validation — no new deps; zod is not in
// workspace/package.json dependencies so validation is hand-rolled to the
// same shape contract a schema would enforce.
type ParsedOrder = {
  name: string;
  qty: number;
  sku: string;
  clientToken: string;
};

function parseOrderForm(formData: FormData):
  | { ok: true; order: ParsedOrder }
  | { ok: false; error: string } {
  const rawName = formData.get("name");
  const rawQty = formData.get("qty");
  const rawSku = formData.get("sku");
  const rawToken = formData.get("clientToken");

  if (typeof rawName !== "string" || typeof rawQty !== "string" || typeof rawSku !== "string" || typeof rawToken !== "string") {
    return { ok: false, error: "missing_or_non_string_field" };
  }
  const name = rawName.trim();
  if (name.length < 1 || name.length > 64) {
    return { ok: false, error: "name_length_out_of_range" };
  }
  const qty = Number(rawQty);
  if (!Number.isInteger(qty) || qty < 1 || qty > 100) {
    return { ok: false, error: "qty_not_integer_1_100" };
  }
  if (!/^[A-Z]{3}-\d{4}$/.test(rawSku)) {
    return { ok: false, error: "sku_pattern_mismatch" };
  }
  if (!/^[0-9a-f]{16}$/.test(rawToken)) {
    return { ok: false, error: "client_token_pattern_mismatch" };
  }
  return {
    ok: true,
    order: {
      name,
      qty,
      // Normalize sku after pattern check.
      sku: rawSku,
      clientToken: rawToken,
    },
  };
}

// Echo helper: reads the request id ONLY through AsyncLocalStorage so a
// polluted (shared/stale) context shows up as a duplicate or foreign id.
function readContextViaAls(): BenchRequestContext | undefined {
  return benchAls.getStore();
}

export async function submitBenchAction(
  formData: FormData,
): Promise<void> {
  "use server";
  const startedAtMs = Date.now();
  const parsed = parseOrderForm(formData);

  if (!parsed.ok) {
    // Invalid payload: mark rejection observably (cookie verdict) and refuse.
    const jar = await cookies();
    jar.set("n2_verdict", "rejected", {
      httpOnly: true,
      sameSite: "lax",
      path: "/",
      maxAge: 60,
    });
    jar.set("n2_reject_reason", parsed.error, {
      httpOnly: true,
      sameSite: "lax",
      path: "/",
      maxAge: 60,
    });
    return;
  }

  const requestId = mintRequestId();
  const ctx: BenchRequestContext = {
    requestId,
    clientToken: parsed.order.clientToken,
    startedAtMs,
  };

  await benchAls.run(ctx, async () => {
    const seen = readContextViaAls();
    // ALS propagation sanity: context must be present and match what we set.
    if (!seen || seen.requestId !== requestId) {
      throw new Error("n2_als_context_lost");
    }

    // Tagged-cache revalidate: the bench tag exists only in this lane; an
    // unused tag is a legal revalidate target (marks the tag stale globally).
    revalidateTag("bench-n2-action", "max");

    // Simulated multi-step tail work (kept sub-ms so p99 budget isolates
    // framework overhead rather than artificial sleep).
    let acc = 0;
    for (let i = 0; i < 512; i++) {
      acc = (acc * 31 + i) % 100003;
    }
    if (acc < 0) {
      throw new Error("unreachable");
    }

    const jar = await cookies();
    jar.set("n2_rid", requestId, {
      httpOnly: true,
      sameSite: "lax",
      path: "/",
      maxAge: 60,
    });
  });
}

export default function BenchActionPage() {
  return (
    <main>
      <h1>N2 action storm bench</h1>
      <form action={submitBenchAction} method="post">
        <label>
          name
          <input type="text" name="name" defaultValue="bench-order" />
        </label>
        <label>
          qty
          <input type="text" name="qty" defaultValue="7" />
        </label>
        <label>
          sku
          <input type="text" name="sku" defaultValue="ABC-1234" />
          <input type="text" name="clientToken" defaultValue="0123456789abcdef" />
        </label>
        <button type="submit">submit</button>
      </form>
    </main>
  );
}
