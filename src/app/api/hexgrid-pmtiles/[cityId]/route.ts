import { NextResponse } from 'next/server';
import { STORAGE } from '@/lib/config';
import { listActivePipelineDatasets, resolveHexgridPath } from '@/lib/pipeline-manifest';
import { supabase } from '@/lib/supabase';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

function isSafeCityId(value: string): boolean {
  return /^[a-z0-9][a-z0-9-]*$/i.test(value)
    && (STORAGE.PIPELINE_CITY_IDS as readonly string[]).includes(value);
}

async function upstreamHexgridUrl(cityId: string): Promise<string | null> {
  if (!supabase) return null;

  const dataset = (await listActivePipelineDatasets())
    .find((entry) => entry.cityId === cityId);
  if (!dataset) return null;

  const objectPath = resolveHexgridPath(dataset);
  return supabase.storage
    .from(STORAGE.PIPELINE_BUCKET)
    .getPublicUrl(objectPath)
    .data.publicUrl;
}

async function proxyHexgridRequest(request: Request, cityId: string): Promise<NextResponse> {
  const upstreamUrl = await upstreamHexgridUrl(cityId);
  if (!upstreamUrl) {
    return NextResponse.json({ error: 'Hex grid not found' }, { status: 404 });
  }

  const headers = new Headers();
  const range = request.headers.get('range');
  if (range) headers.set('Range', range);

  const upstream = await fetch(upstreamUrl, {
    method: request.method === 'HEAD' ? 'HEAD' : 'GET',
    headers,
  });

  if (!upstream.ok && upstream.status !== 206) {
    console.warn(`[hexgrid-pmtiles] upstream ${upstream.status} for ${cityId}`);
    return NextResponse.json(
      { error: 'Hex grid unavailable' },
      { status: upstream.status === 400 ? 404 : upstream.status },
    );
  }

  const responseHeaders = new Headers({
    'Content-Type': 'application/vnd.pmtiles',
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'public, max-age=300',
  });

  const contentLength = upstream.headers.get('Content-Length');
  const contentRange = upstream.headers.get('Content-Range');
  if (contentLength) responseHeaders.set('Content-Length', contentLength);
  if (contentRange) responseHeaders.set('Content-Range', contentRange);

  if (request.method === 'HEAD') {
    return new NextResponse(null, { status: upstream.status, headers: responseHeaders });
  }

  return new NextResponse(upstream.body, { status: upstream.status, headers: responseHeaders });
}

export async function GET(
  request: Request,
  context: { params: Promise<{ cityId: string }> },
) {
  const { cityId } = await context.params;
  if (!isSafeCityId(cityId)) {
    return NextResponse.json({ error: 'Invalid cityId' }, { status: 400 });
  }
  return proxyHexgridRequest(request, cityId);
}

export async function HEAD(
  request: Request,
  context: { params: Promise<{ cityId: string }> },
) {
  const { cityId } = await context.params;
  if (!isSafeCityId(cityId)) {
    return NextResponse.json({ error: 'Invalid cityId' }, { status: 400 });
  }
  return proxyHexgridRequest(request, cityId);
}
