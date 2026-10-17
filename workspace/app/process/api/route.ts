// OCEL process-mining read API (server-side only).
// GET -> OcelSummary JSON; missing sink yields available:false, never a 500.

import { readOcelSummary } from "@/lib/process/ocel";

export const dynamic = "force-dynamic";

export async function GET() {
  return Response.json(readOcelSummary());
}
