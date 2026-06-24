import maplibregl from 'maplibre-gl';
import { Protocol } from 'pmtiles';
import { RASTER_LAYERS, type RasterLayerId } from './config';
import { resolvePipelineAssetUrl } from './storage-fetch';

let protocolRegistered = false;

function ensurePmtilesProtocol() {
  if (protocolRegistered) return;
  maplibregl.addProtocol('pmtiles', new Protocol().tile);
  protocolRegistered = true;
}

function pmtilesUrl(assetUrl: string): string {
  if (assetUrl.startsWith('blob:')) return `pmtiles://${assetUrl}`;
  if (assetUrl.startsWith('http')) return `pmtiles://${assetUrl}`;
  const origin = typeof window !== 'undefined' ? window.location.origin : '';
  return `pmtiles://${origin}${assetUrl.startsWith('/') ? assetUrl : `/${assetUrl}`}`;
}

/** Add or update a pipeline raster layer (PMTiles). Returns false if asset missing. */
export async function ensureRasterLayer(
  map: maplibregl.Map,
  layerId: RasterLayerId,
): Promise<boolean> {
  const spec = RASTER_LAYERS[layerId];
  const assetUrl = await resolvePipelineAssetUrl(spec.file);
  if (!assetUrl) return false;

  ensurePmtilesProtocol();

  if (!map.getSource(spec.sourceId)) {
    map.addSource(spec.sourceId, {
      type: 'raster',
      url: pmtilesUrl(assetUrl),
      tileSize: 256,
    });

    // Build paint — apply a colour ramp if the spec provides colour stops.
    // MapLibre ≥ 4 supports raster-color + raster-value for single-band rasters.
    const paint: maplibregl.RasterLayerSpecification['paint'] = {
      'raster-opacity': spec.opacity,
    };
    if (spec.colorStops && spec.colorStops.length >= 2) {
      const stops = spec.colorStops;
      // Build ['interpolate', ['linear'], ['raster-value'], stop0, color0, ...]
      // raster-value / raster-color are supported in MapLibre ≥ 4 but not yet
      // reflected in the bundled TypeScript types, so we cast through unknown.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (paint as any)['raster-color'] = [
        'interpolate', ['linear'], ['raster-value'],
        ...stops.flatMap(([v, c]) => [v, c]),
      ];
    }

    map.addLayer(
      {
        id: spec.layerId,
        type: 'raster',
        source: spec.sourceId,
        paint,
        layout: { visibility: 'none' },
      },
      'hex-fill',
    );
  }
  return true;
}

export function setRasterLayerVisibility(
  map: maplibregl.Map,
  layerId: RasterLayerId,
  visible: boolean,
) {
  const spec = RASTER_LAYERS[layerId];
  try {
    map.setLayoutProperty(spec.layerId, 'visibility', visible ? 'visible' : 'none');
  } catch {
    /* layer not added yet — asset may be missing */
  }
}

export async function syncRasterLayers(
  map: maplibregl.Map,
  enabled: Record<RasterLayerId, boolean>,
): Promise<void> {
  for (const id of Object.keys(RASTER_LAYERS) as RasterLayerId[]) {
    if (!enabled[id]) {
      setRasterLayerVisibility(map, id, false);
      continue;
    }
    const ok = await ensureRasterLayer(map, id);
    if (ok) setRasterLayerVisibility(map, id, true);
  }
}
