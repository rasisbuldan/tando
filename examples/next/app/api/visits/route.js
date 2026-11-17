// Writes to data/ (mapped by tando to the app's shared/ directory, survives releases).
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
export const dynamic = 'force-dynamic';
const file = path.join(process.cwd(), 'data', 'visits.json');
export async function POST() {
  let n = 0;
  try { n = JSON.parse(await readFile(file, 'utf8')).n; } catch {}
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, JSON.stringify({ n: n + 1 }));
  return Response.json({ n: n + 1 });
}
