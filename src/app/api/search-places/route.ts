import { NextResponse } from 'next/server';
import type { GeocodingSearchResult } from '@/lib/map-search';

export const runtime = 'nodejs';

interface NominatimPlace {
  place_id: number;
  display_name: string;
  lat: string;
  lon: string;
  name?: string;
  class?: string;
  type?: string;
  boundingbox?: [string, string, string, string];
  address?: {
    city?: string;
    town?: string;
    village?: string;
    municipality?: string;
    county?: string;
    state?: string;
    country?: string;
  };
}

const NOMINATIM_URL = 'https://nominatim.openstreetmap.org/search';
const SEARCH_TIMEOUT_MS = 4500;

function subLabel(place: NominatimPlace): string {
  const parts = [
    place.address?.city,
    place.address?.town,
    place.address?.village,
    place.address?.municipality,
    place.address?.county,
    place.address?.state,
    place.address?.country,
  ].filter((part): part is string => Boolean(part));

  if (parts.length > 0) return Array.from(new Set(parts)).join(', ');
  return place.display_name.split(',').slice(1, 4).map((part) => part.trim()).filter(Boolean).join(', ');
}

function toResult(place: NominatimPlace): GeocodingSearchResult | null {
  const lon = Number(place.lon);
  const lat = Number(place.lat);
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;

  const bbox = place.boundingbox?.map(Number);
  return {
    id: String(place.place_id),
    label: place.name?.trim() || place.display_name.split(',')[0]?.trim() || 'Place',
    sub: subLabel(place),
    center: [lon, lat],
    bbox: bbox?.length === 4 && bbox.every(Number.isFinite)
      ? [bbox[2], bbox[0], bbox[3], bbox[1]]
      : undefined,
    sourceType: 'geocode',
  };
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const query = searchParams.get('q')?.trim() ?? '';
  if (query.length < 2) return NextResponse.json({ results: [] });

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), SEARCH_TIMEOUT_MS);

  try {
    const url = new URL(NOMINATIM_URL);
    url.searchParams.set('format', 'jsonv2');
    url.searchParams.set('addressdetails', '1');
    url.searchParams.set('limit', '8');
    url.searchParams.set('accept-language', 'en');
    url.searchParams.set('q', query);

    const response = await fetch(url, {
      signal: controller.signal,
      headers: {
        Accept: 'application/json',
        'User-Agent': 'NatureGap/0.1 global geocoding',
      },
    });

    if (!response.ok) return NextResponse.json({ results: [] });

    const places = (await response.json()) as NominatimPlace[];
    const results = places
      .map(toResult)
      .filter((result): result is GeocodingSearchResult => result !== null);

    return NextResponse.json({ results });
  } catch {
    return NextResponse.json({ results: [] });
  } finally {
    clearTimeout(timeout);
  }
}
