import Link from "next/link";

export const dynamic = "force-dynamic";

export default function AuditIndex() {
  return (
    <main data-page="bench-audit-index">
      <h1>Bench Audit Index</h1>
      <ul>
        {[1, 2, 3, 4, 5].map((n) => (
          <li key={n}>
            <Link href={`/bench/audit/${n}`}>audit-{n}</Link>
          </li>
        ))}
      </ul>
    </main>
  );
}
