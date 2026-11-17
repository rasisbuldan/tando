import { VERSION } from '../../../version';
export const dynamic = 'force-dynamic';
export function GET() {
  return Response.json({ version: VERSION });
}
