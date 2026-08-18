/**
 * Layer paint/visibility helpers extracted from MapView.tsx (step 2 of the
 * MapView split — these previously lived in lib/map-utils.ts after step 1,
 * moved out again in isolation since this is where the multi-city paint
 * bug fix lives). No logic changes from the original functions.
 */

import maplibregl from 'maplibre-gl';
import { getCityLayerStats } from '@/lib/data';
import { CITY, MAP_CONFIG } from '@/lib/config';
import type { HexPmtilesDataset } from '@/lib/pmtiles-storage';
import type { MapLayer } from '@/lib/types';
import {
  CORRIDOR_LINES_LAYER_ID,
  hasHexOverlay,
  type HexLayerId,
  hexFillColorExpression,
  hexFillLayerId,
  hexFillOpacityForLayer,
  HEX_OUTLINE_LAYER_ID,
  INTERVENTION_RANK_BADGES_LAYER_ID,
  INTERVENTION_RANK_LABELS_LAYER_ID,
  hasOverviewFill,
  hexFillAntialias,
  hexFillOutlineColor,
  hexOutlineOverlayPaint,
  isPointLayer,
  LAYER_DRAW_ORDER,
  overviewPointPaint,
  PATCH_FILL_LAYER_IDS,
  PATCH_FILL_LAYER_ORDER,
  patchFillColorExpressionForCities,
  type PointLayerId,
  POINT_LAYER_IDS,
  POINT_LAYER_ORDER,
  THEMATIC_LAYER_IDS,
} from '@/lib/layer-styles';

export function layerEnabled(layers: MapLayer[], id: string): boolean {
  return layers.some((layer) => layer.id === id && layer.enabled);
}

export function setMapLayerVisibility(map: maplibregl.Map, layerId: string, visible: boolean) {
  if (!map.getLayer(layerId)) return;
  try {
    map.setLayoutProperty(layerId, 'visibility', visible ? 'visible' : 'none');
  } catch { /* layer not ready */ }
}

export function activeThematicLayerId(layers: MapLayer[]): HexLayerId {
  return THEMATIC_LAYER_IDS.find((id) => layerEnabled(layers, id)) ?? 'impact';
}

export function applyLayerPaintExpressions(map: maplibregl.Map) {
  const allCityStats = getCityLayerStats();
  const cityIds = Array.from(new Set(allCityStats.map((stat) => stat.cityId)));
  try {
    for (const layerId of PATCH_FILL_LAYER_ORDER) {
      const layer = PATCH_FILL_LAYER_IDS[layerId];
      if (!map.getLayer(layer)) continue;
      map.setPaintProperty(layer, 'fill-color', patchFillColorExpressionForCities(layerId, cityIds, allCityStats));
    }

    for (const layerId of POINT_LAYER_ORDER) {
      const layer = POINT_LAYER_IDS[layerId].overview;
      if (!map.getLayer(layer)) continue;
      const paint = overviewPointPaint(layerId, cityIds, allCityStats);
      map.setPaintProperty(layer, 'circle-color', paint?.['circle-color']);
      // Vegetation radius rides the same per-city canopy stretch as the colour.
      map.setPaintProperty(layer, 'circle-radius', paint?.['circle-radius']);
    }

    for (const dataset of getHexDatasets(map)) {
      const cityStats = getCityLayerStats(dataset.cityId);
      for (const layerId of LAYER_DRAW_ORDER) {
        if (!hasHexOverlay(layerId)) continue;
        const mlId = hexFillLayerIdForDataset(dataset.sourceId, layerId);
        if (!map.getLayer(mlId)) continue;
        map.setPaintProperty(mlId, 'fill-color', hexFillColorExpression(layerId, cityStats));
        // Re-asserted here, not just at addLayer time. These two carry the whole
        // zoom regime (see HEX_REGIME), and a layer created before this code
        // existed — a hot reload in dev, or any path that recreates the style
        // and skips the creation branch — would otherwise keep MapLibre's
        // default antialiasing and render the honeycomb regardless.
        map.setPaintProperty(mlId, 'fill-antialias', hexFillAntialias());
        map.setPaintProperty(mlId, 'fill-outline-color', hexFillOutlineColor());
      }
    }
  } catch { /* style not ready */ }
}

export function setLayerVisibility(map: maplibregl.Map, activeLayerId: HexLayerId, layers: MapLayer[]) {
  for (const layerId of PATCH_FILL_LAYER_ORDER) {
    // Point layers show park-centroid points at overview zoom instead of a fill,
    // and hasOverviewFill layers (canopy height) show nothing at all below the
    // hex source's minzoom rather than a park-level aggregate.
    setMapLayerVisibility(
      map,
      PATCH_FILL_LAYER_IDS[layerId],
      activeLayerId === layerId && !isPointLayer(layerId) && hasOverviewFill(layerId),
    );
  }

  for (const layerId of POINT_LAYER_ORDER) {
    setMapLayerVisibility(map, POINT_LAYER_IDS[layerId].overview, activeLayerId === layerId);
  }

  setMapLayerVisibility(map, INTERVENTION_RANK_BADGES_LAYER_ID, activeLayerId === 'intervention');
  setMapLayerVisibility(map, INTERVENTION_RANK_LABELS_LAYER_ID, activeLayerId === 'intervention');
  setMapLayerVisibility(map, CORRIDOR_LINES_LAYER_ID, false);

  const datasets = getHexDatasets(map);

  for (const dataset of datasets) {
    for (const layerId of LAYER_DRAW_ORDER) {
      if (!hasHexOverlay(layerId)) continue;
      const mlId = hexFillLayerIdForDataset(dataset.sourceId, layerId);
      if (!map.getLayer(mlId)) continue;
      try {
        const visible = activeLayerId === layerId;
        map.setLayoutProperty(mlId, 'visibility', visible ? 'visible' : 'none');
        if (visible) {
          map.setPaintProperty(mlId, 'fill-opacity', hexFillOpacityForLayer(layerId));
        }
      } catch { /* layer not ready */ }
    }

    for (const layerId of POINT_LAYER_ORDER) {
      setMapLayerVisibility(
        map,
        pointLayerIdForDataset(dataset.sourceId, layerId),
        activeLayerId === layerId,
      );
    }

    try {
      const outlineLayerId = hexOutlineLayerId(dataset.sourceId);
      if (map.getLayer(outlineLayerId)) {
        map.setLayoutProperty(
          outlineLayerId,
          'visibility',
          layerEnabled(layers, 'cell-grid') ? 'visible' : 'none',
        );
        // Same reason as the fill's antialias/outline: re-assert the zoom ramp
        // rather than trusting whatever paint the layer was created with.
        const outlinePaint = hexOutlineOverlayPaint();
        map.setPaintProperty(outlineLayerId, 'line-width', outlinePaint?.['line-width']);
        map.setPaintProperty(outlineLayerId, 'line-opacity', outlinePaint?.['line-opacity']);
      }

      const selectedLayerId = hexSelectedLayerId(dataset.sourceId);
      if (map.getLayer(selectedLayerId)) {
        map.setLayoutProperty(selectedLayerId, 'visibility', Boolean(activeLayerId) ? 'visible' : 'none');
      }
    } catch { /* ignore */ }
  }
}

export function hexFillLayerIdForDataset(sourceId: string, layerId: HexLayerId): string {
  return `${hexFillLayerId(layerId)}-${sourceId}`;
}

export function pointLayerIdForDataset(sourceId: string, layerId: PointLayerId): string {
  return `${POINT_LAYER_IDS[layerId].detail}-${sourceId}`;
}

export function hexOutlineLayerId(sourceId: string): string {
  return `${HEX_OUTLINE_LAYER_ID}-${sourceId}`;
}

export function hexSelectedLayerId(sourceId: string): string {
  return `hex-selected-${sourceId}`;
}

export function getHexDatasets(map: maplibregl.Map): HexPmtilesDataset[] {
  return ((map as unknown as { __naturegapHexDatasets?: HexPmtilesDataset[] }).__naturegapHexDatasets ?? []);
}

export function setHexDatasets(map: maplibregl.Map, datasets: HexPmtilesDataset[]) {
  (map as unknown as { __naturegapHexDatasets?: HexPmtilesDataset[] }).__naturegapHexDatasets = datasets;
}

export function hexInteractiveLayerIds(map: maplibregl.Map): string[] {
  return getHexDatasets(map).flatMap((dataset) => LAYER_DRAW_ORDER
    .filter(hasHexOverlay)
    .map((layerId) => hexFillLayerIdForDataset(dataset.sourceId, layerId))
    .filter((layerId) => map.getLayer(layerId)));
}

/** Hex fill layers currently visible — use for click hit-testing at detail zoom. */
export function visibleHexInteractiveLayerIds(map: maplibregl.Map): string[] {
  return hexInteractiveLayerIds(map).filter((layerId) => {
    try {
      return map.getLayoutProperty(layerId, 'visibility') === 'visible';
    } catch {
      return false;
    }
  });
}

export function selectedHexFilter(cellId: string | null): maplibregl.FilterSpecification {
  return ['==', ['get', 'cellId'], cellId ?? ''];
}

/** Derive pipeline city slug from a multi-city hex fill layer id. */
export function cityIdFromHexLayerId(map: maplibregl.Map, layerId: string): string | undefined {
  for (const dataset of getHexDatasets(map)) {
    if (layerId.endsWith(`-${dataset.sourceId}`)) return dataset.cityId;
  }
  return undefined;
}

/**
 * City the current view is looking at, from the registered hex dataset extents.
 * Nothing is selected most of the time, so without this the badge and the
 * sidebar location label sit on the default city no matter where the map is.
 * Containment of the view centre wins; otherwise the dataset overlapping the
 * viewport whose extent centre is nearest. Undefined when the view is off every
 * city — callers fall back to CITY.
 */
export function cityIdForViewport(map: maplibregl.Map): string | undefined {
  const datasets = getHexDatasets(map).filter((dataset) => dataset.bounds);
  if (datasets.length === 0) return undefined;

  const center = map.getCenter();
  const view = map.getBounds();
  let nearest: { cityId: string; distance: number } | undefined;

  for (const dataset of datasets) {
    const [minLon, minLat, maxLon, maxLat] = dataset.bounds;
    if (center.lng >= minLon && center.lng <= maxLon
      && center.lat >= minLat && center.lat <= maxLat) {
      return dataset.cityId;
    }

    const overlapsView = maxLon >= view.getWest() && minLon <= view.getEast()
      && maxLat >= view.getSouth() && minLat <= view.getNorth();
    if (!overlapsView) continue;

    const dLon = (minLon + maxLon) / 2 - center.lng;
    const dLat = (minLat + maxLat) / 2 - center.lat;
    const distance = dLon * dLon + dLat * dLat;
    if (!nearest || distance < nearest.distance) {
      nearest = { cityId: dataset.cityId, distance };
    }
  }

  return nearest?.cityId;
}

export async function fitMapToPmtilesDatasets(
  map: maplibregl.Map,
  datasets: HexPmtilesDataset[],
  preferredCityId?: string,
) {
  const primary = preferredCityId
    ? datasets.filter((dataset) => dataset.cityId === preferredCityId)
    : [];
  const toFit = primary.length > 0 ? primary : datasets;
  if (toFit.length === 0) return;

  const bounds = new maplibregl.LngLatBounds();
  for (const dataset of toFit) {
    if (!dataset.bounds) continue;
    const [minLon, minLat, maxLon, maxLat] = dataset.bounds;
    bounds.extend([minLon, minLat]);
    bounds.extend([maxLon, maxLat]);
  }

  if (bounds.isEmpty()) return;
  map.fitBounds(bounds, {
    padding: 80,
    maxZoom: MAP_CONFIG.zoom,
    duration: 0,
  });
}

export function refreshHexLayers(map: maplibregl.Map, layers: MapLayer[]) {
  try {
    setLayerVisibility(map, activeThematicLayerId(layers), layers);
    applyLayerPaintExpressions(map);
  } catch {
    /* style not ready */
  }
}

export function applyCitizenLayerVisibility(map: maplibregl.Map, layers: MapLayer[]) {
  const biodiversityEnabled = layerEnabled(layers, 'biodiversity');
  const ids = [
    ['survey-points-layer', 'survey-points', biodiversityEnabled],
    ['survey-points-selected', 'survey-points', biodiversityEnabled],
    ['structured-surveys-layer', 'structured-surveys'],
  ] as const;
  for (const [mapLayerId, layerId, forceVisible] of ids) {
    if (!map.getLayer(mapLayerId)) continue;
    try {
      map.setLayoutProperty(mapLayerId, 'visibility', forceVisible || layerEnabled(layers, layerId) ? 'visible' : 'none');
    } catch { /* layer not ready */ }
  }
}