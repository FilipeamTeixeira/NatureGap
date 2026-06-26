import { fetchPipelineJson } from './storage-fetch';

export interface GreenSpace {
  /** Stable identifier — matches hexgrid `parkId` and park-stats `id`. */
  id: string;
  /** English display name. */
  name: string;
  /** Japanese display name. */
  nameJa: string;
  /** Yokohama ward slug — matches ALL_WARDS. */
  wardId: string;
  /** Closed polygon ring in [lng, lat] order (WGS-84). */
  ring: [number, number][];
}

let runtimeParks: GreenSpace[] = [];
let initParksCalled = false;

function deriveId(props: Record<string, unknown>): string {
  const raw = String(props.id ?? props.osm_id ?? '').trim();
  if (raw && raw !== 'undefined') return raw;
  const name = String(props.name ?? props['name:ja'] ?? props.nameJa ?? '').trim();
  if (name) return name;
  return '';
}

function featureToGreenSpace(f: Record<string, unknown>): GreenSpace | null {
  const props = (f.properties as Record<string, unknown>) ?? {};
  const id = deriveId(props);
  if (!id || id === 'undefined') return null;

  const geom = f.geometry as { type: string; coordinates: unknown } | null;
  if (!geom) return null;

  let ring: [number, number][];
  if (geom.type === 'Polygon') {
    ring = (geom.coordinates as [number, number][][])[0];
  } else if (geom.type === 'MultiPolygon') {
    ring = (geom.coordinates as [number, number][][][])[0][0];
  } else {
    return null;
  }

  if (!ring || ring.length < 4) return null;

  return {
    id,
    name:    String(props.name    ?? id),
    nameJa:  String(props.nameJa  ?? props['name:ja'] ?? props.name ?? id),
    wardId:  String(props.wardId  ?? ''),
    ring,
  };
}

/**
 * Fetch latest matching parks GeoJSON from Supabase Storage.
 */
export async function initParks(): Promise<void> {
  if (initParksCalled) return;
  initParksCalled = true;

  try {
    const fc = await fetchPipelineJson('parks.geojson', null) as { features?: Record<string, unknown>[] } | null;
    const parks = (fc?.features ?? [])
      .map(featureToGreenSpace)
      .filter((p): p is GreenSpace => p !== null);
    if (parks.length > 0) {
      runtimeParks = parks;
      console.info(`[green-spaces] Loaded ${parks.length} parks from Storage`);
    }
  } catch (e) {
    console.warn('[green-spaces] Failed to load parks:', e);
  }
}

export function getParks(): GreenSpace[] {
  return runtimeParks;
}
