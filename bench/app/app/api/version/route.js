import { VERSION } from '../../../lib/version';
export const dynamic = 'force-dynamic';
// A release whose version starts with "broken" fails its health check (used by the benchmarks).
export function GET() {
  if (VERSION.startsWith('broken')) return Response.json({ error: 'broken release' }, { status: 500 });
  return Response.json({ version: VERSION });
}
