// N-6 lane: on-demand revalidation trigger (revalidatePath) for bench slugs.

import { revalidatePath } from "next/cache";

export const dynamic = "force-dynamic";

export async function POST(req: Request) {
  const body = await req.json().catch(() => ({}));
  const slugs: string[] = Array.isArray(body.slugs) ? body.slugs : [];
  if (slugs.length === 0) {
    return Response.json({ ok: false, error: "slugs[] required" }, { status: 400 });
  }
  const t0 = Date.now();
  for (const slug of slugs) revalidatePath(`/bench/news/${slug}`);
  return Response.json({ ok: true, revalidated: slugs.length, ms: Date.now() - t0 });
}
