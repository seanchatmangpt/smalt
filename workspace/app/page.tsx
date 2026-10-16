const ARM = process.env.NEXT_PUBLIC_SMALT_ARM ?? "http://127.0.0.1:9443";
const EGRESS = process.env.NEXT_PUBLIC_SMALT_EGRESS ?? "http://127.0.0.1:8443";

export default function Home() {
  return (
    <main className="mx-auto max-w-3xl p-8">
      <h1 className="text-2xl font-semibold mb-4">Smalt Sovereign Console</h1>
      <p className="mb-6" style={{ color: "var(--smalt-muted)" }}>
        Air-gapped evaluation console. All traffic targets the local smalt
        emulator only; no cloud, no external network.
      </p>
      <ul className="text-sm space-y-2">
        <li>
          ARM gateway: <code>{ARM}</code>
        </li>
        <li>
          Egress router: <code>{EGRESS}</code>
        </li>
      </ul>
    </main>
  );
}
