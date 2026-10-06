import { open, readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Serves the repo's pipeline-export/ folder to the dev-only local preview
 * (lib/local-pipeline.ts). 404 unless `next dev` runs with
 * NEXT_PUBLIC_PIPELINE_LOCAL_EXPORT=1, so a deployed build never exposes it.
 *
 * Two things a static file server would not do:
 * - `<city>/current.json` points at the city's newest local dataset folder,
 *   not the copy of the published pointer kept on disk — the point of the
 *   preview is the export that has not been published yet;
 * - byte ranges, which PMTiles reads archives with.
 */
const ROOT = path.resolve(process.cwd(), 'pipeline-export');
const DATASET_FOLDER = /^\d{8}T\d{6}Z$/;

const CONTENT_TYPES: Record<string, string> = {
  '.json': 'application/json',
  '.geojson': 'application/geo+json',
  '.gz': 'application/gzip',
  '.pmtiles': 'application/octet-stream',
};

function enabled(): boolean {
  return process.env.NODE_ENV === 'development'
    && process.env.NEXT_PUBLIC_PIPELINE_LOCAL_EXPORT === '1';
}

function notFound(): Response {
  return new Response('Not found', { status: 404 });
}

async function newestPointer(cityId: string): Promise<Response> {
  const cityDir = path.resolve(ROOT, cityId);
  if (!cityDir.startsWith(ROOT + path.sep)) return notFound();
  const entries = await readdir(cityDir, { withFileTypes: true }).catch(() => []);
  const versions = entries
    .filter((entry) => entry.isDirectory() && DATASET_FOLDER.test(entry.name))
    .map((entry) => entry.name)
    .sort()
    .reverse();
  for (const version of versions) {
    const manifest = await stat(path.join(cityDir, version, 'manifest.json')).catch(() => null);
    if (!manifest?.isFile()) continue;
    return Response.json({
      schemaVersion: 1,
      cityId,
      datasetId: version,
      dataVersion: version,
      manifest: `${version}/manifest.json`,
    }, { headers: { 'Cache-Control': 'no-store' } });
  }
  return notFound();
}

export async function GET(
  request: Request,
  context: { params: Promise<{ path: string[] }> },
) {
  if (!enabled()) return notFound();
  const { path: segments } = await context.params;
  if (segments.length === 2 && segments[1] === 'current.json') return newestPointer(segments[0]);

  const file = path.resolve(ROOT, ...segments);
  if (!file.startsWith(ROOT + path.sep)) return notFound();
  const info = await stat(file).catch(() => null);
  if (!info?.isFile()) return notFound();

  const headers: Record<string, string> = {
    'Content-Type': CONTENT_TYPES[path.extname(file)] ?? 'application/octet-stream',
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store',
  };

  const range = /^bytes=(\d*)-(\d*)$/.exec(request.headers.get('range') ?? '');
  if (!range) {
    const body = new Uint8Array(await readFile(file));
    return new Response(body, { headers: { ...headers, 'Content-Length': String(body.byteLength) } });
  }

  const [, from, to] = range;
  const start = from === '' ? Math.max(0, info.size - Number(to)) : Number(from);
  const end = from === '' || to === '' ? info.size - 1 : Math.min(Number(to), info.size - 1);
  if (!Number.isFinite(start) || start > end || start >= info.size) {
    return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${info.size}` } });
  }

  const handle = await open(file, 'r');
  try {
    const body = new Uint8Array(end - start + 1);
    await handle.read(body, 0, body.byteLength, start);
    return new Response(body, {
      status: 206,
      headers: {
        ...headers,
        'Content-Range': `bytes ${start}-${end}/${info.size}`,
        'Content-Length': String(body.byteLength),
      },
    });
  } finally {
    await handle.close();
  }
}
