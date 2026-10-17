// Process-mining console page — server-rendered read surface over the OCEL sink.
// No client fetch: the summary is computed at request time (dynamic) and
// rendered as static tables.

import { readOcelSummary } from "@/lib/process/ocel";

export const dynamic = "force-dynamic";

export default function ProcessPage() {
  const s = readOcelSummary();

  if (!s.available) {
    return (
      <main className="mx-auto max-w-4xl p-8">
        <h1 className="text-2xl font-bold">Process Mining</h1>
        <p className="mt-4 text-red-400">OCEL sink unavailable: {s.reason}</p>
      </main>
    );
  }

  return (
    <main className="mx-auto max-w-6xl p-8">
      <h1 className="text-2xl font-bold">Process Mining</h1>
      <p className="mt-1 text-sm text-neutral-400">
        {s.totalEvents} events over {s.totalObjects} objects · {s.eventsPath}
      </p>

      <h2 className="mt-8 text-lg font-semibold">Activities</h2>
      <table className="mt-2 w-full text-sm">
        <thead>
          <tr className="text-left text-neutral-400">
            <th className="py-1">Event type</th>
            <th className="py-1">Count</th>
          </tr>
        </thead>
        <tbody>
          {s.eventTypes.map((t) => (
            <tr key={t.name} className="border-t border-neutral-800">
              <td className="py-1 font-mono">{t.name}</td>
              <td className="py-1">{t.count}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <h2 className="mt-8 text-lg font-semibold">Objects</h2>
      <table className="mt-2 w-full text-sm">
        <thead>
          <tr className="text-left text-neutral-400">
            <th className="py-1">Object type</th>
            <th className="py-1">Count</th>
          </tr>
        </thead>
        <tbody>
          {s.objectTypes.map((t) => (
            <tr key={t.name} className="border-t border-neutral-800">
              <td className="py-1 font-mono">{t.name}</td>
              <td className="py-1">{t.count}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <h2 className="mt-8 text-lg font-semibold">Recent Events</h2>
      <table className="mt-2 w-full text-sm">
        <thead>
          <tr className="text-left text-neutral-400">
            <th className="py-1">Time</th>
            <th className="py-1">Type</th>
            <th className="py-1">ID</th>
          </tr>
        </thead>
        <tbody>
          {s.recentEvents.map((ev) => (
            <tr key={ev.id} className="border-t border-neutral-800">
              <td className="py-1 font-mono text-xs">{ev.time}</td>
              <td className="py-1 font-mono">{ev.type}</td>
              <td className="py-1 font-mono text-xs">{ev.id}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <h2 className="mt-8 text-lg font-semibold">Object Traces</h2>
      {s.perObjectTraces.map((t) => (
        <div key={t.objectId} className="mt-3">
          <p className="font-mono text-sm">
            {t.objectId} <span className="text-neutral-400">({t.objectType})</span>
          </p>
          <ol className="mt-1 list-decimal pl-6 text-xs text-neutral-300">
            {t.trace.map((e, i) => (
              <li key={`${e.id}-${i}`}>
                {e.time} {e.type}
              </li>
            ))}
          </ol>
        </div>
      ))}

      {s.powlModel !== undefined && (
        <>
          <h2 className="mt-8 text-lg font-semibold">Discovered Model (PowlBridge)</h2>
          <pre className="mt-2 overflow-auto rounded bg-neutral-900 p-3 text-xs">
            {JSON.stringify(s.powlModel, null, 2)}
          </pre>
        </>
      )}
    </main>
  );
}
