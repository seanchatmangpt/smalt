// N-6 ISR stampede lane subject page.
//
// `revalidate = 10` + fetch-free deterministic fixture content. Every runtime
// execution of this render is a real ISR background rebuild (Next serves the
// stale entry to concurrent readers and re-renders once under its per-entry
// lock), so recordRegeneration() here IS the dedup witness: with the lock
// working, one 10s expiry under a 10k-request herd must produce exactly 1
// runtime regeneration for the slug.

import { notFound } from "next/navigation";
import {
  ALL_SLUGS,
  articleFor,
  recordRegeneration,
  REVALIDATE_SECONDS,
} from "@/lib/bench/isr-counter";

// N-3 unblock fix: segment config exports must be literals — Next rejects a
// non-literal `revalidate`. Value kept in lockstep with REVALIDATE_SECONDS (10).
export const revalidate = 10;

export function generateStaticParams() {
  return ALL_SLUGS.map((slug) => ({ slug }));
}

export default async function BenchNewsPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const article = articleFor(slug);
  if (!article) notFound();
  recordRegeneration(slug);

  return (
    <main>
      <div
        id="bench-marker"
        data-slug={article.slug}
        data-generated-at={article.generatedAt}
      />
      <h1>{article.title}</h1>
      <p>{article.body}</p>
      <p>Generated at {article.generatedAt}</p>
    </main>
  );
}
