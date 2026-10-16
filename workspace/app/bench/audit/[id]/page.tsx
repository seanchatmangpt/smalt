import { Suspense } from "react";

export const dynamic = "force-dynamic";

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function Chunk({
  id,
  label,
  ms,
}: {
  id: string;
  label: string;
  ms: number;
}) {
  await delay(ms);
  return (
    <section data-chunk={label} data-id={id}>
      <h2>
        Chunk {label} (audit {id})
      </h2>
      <p>
        Streamed after {ms}ms for audit {id}.
      </p>
    </section>
  );
}

export default async function AuditPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return (
    <main data-page="bench-audit">
      <h1>Bench Audit {id}</h1>
      <nav data-siblings>
        {[1, 2, 3, 4, 5].map((n) => (
          <a key={n} href={`/bench/audit/${n}`}>
            audit-{n}
          </a>
        ))}
      </nav>
      <Suspense fallback={<div data-fallback="a">loading-a…</div>}>
        <Chunk id={id} label="a" ms={100} />
      </Suspense>
      <Suspense fallback={<div data-fallback="b">loading-b…</div>}>
        <Chunk id={id} label="b" ms={300} />
      </Suspense>
      <Suspense fallback={<div data-fallback="c">loading-c…</div>}>
        <Chunk id={id} label="c" ms={600} />
      </Suspense>
    </main>
  );
}
