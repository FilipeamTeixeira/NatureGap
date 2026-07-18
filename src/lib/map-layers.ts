/**
 * Layer paint/visibility helpers extracted from MapView.tsx (step 2 of the
 * MapView split — these previously lived in lib/map-utils.ts after step 1,
 * moved out again in isolation since this is where the multi-city paint
 * bug fix lives). No logic changes from the original functions.
 */

import maplibregl from 'maplibre-gl';
import { PMTiles } from 'pmtiles';
import { getCityLayerStats } from '@/lib/data';
import { CITY, MAP_CONFIG } from '@/lib/config';
import type { HexPmtilesDataset } from '@/lib/pmtiles-storage';
import type { MapLayer } from '@/lib/types';
import {
  BIODIVERSITY_CIRCLES_LAYER_ID,
  CORRIDOR_LINES_LAYER_ID,
  hasHexOverlay,
  type HexLayerId,
  hexFillColorExpression,
  hexFillLayerId,
  hexFillOpacityForLayer,
  HEX_OUTLINE_LAYER_ID,
  INTERVENTION_RANK_BADGES_LAYER_ID,
  INTERVENTION_RANK_LABELS_LAYER_ID,
  LAYER_DRAW_ORDER,
  PATCH_FILL_LAYER_IDS,
  PATCH_FILL_LAYER_ORDER,
  patchFillColorExpressionForCities,
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

    for (const dataset of getHexDatasets(map)) {
      const cityStats = getCityLayerStats(dataset.cityId);
      for (const layerId of LAYER_DRAW_ORDER) {
        if (!hasHexOverlay(layerId)) continue;
        const mlId = hexFillLayerIdForDataset(dataset.sourceId, layerId);
        if (!map.getLayer(mlId)) continue;
        map.setPaintProperty(mlId, 'fill-color', hexFillColorExpression(layerId, cityStats));
      }
    }
  } catch { /* style not ready */ }
}

export function setLayerVisibility(map: maplibregl.Map, activeLayerId: HexLayerId, layers: MapLayer[]) {
  for (const layerId of PATCH_FILL_LAYER_ORDER) {
    setMapLayerVisibility(map, PATCH_FILL_LAYER_IDS[layerId], activeLayerId === layerId);
  }

  setMapLayerVisibility(map, BIODIVERSITY_CIRCLES_LAYER_ID, activeLayerId === 'biodiversity');
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

    try {
      const outlineLayerId = hexOutlineLayerId(dataset.sourceId);
      if (map.getLayer(outlineLayerId)) {
        map.setLayoutProperty(
          outlineLayerId,
          'visibility',
          layerEnabled(layers, 'cell-grid') || Boolean(activeLayerId) ? 'visible' : 'none',
        );
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

export function selectedHexFilter(cellId: string | null): maplibregl.FilterSpecification {
  return ['==', ['get', 'cellId'], cellId ?? ''];
}

export async function fitMapToPmtilesDatasets(map: maplibregl.Map, datasets: HexPmtilesDataset[]) {
  const primary = datasets.filter((dataset) => dataset.cityId === CITY.id);
  const toFit = primary.length > 0 ? primary : datasets;
  if (toFit.length === 0) return;

  const bounds = new maplibregl.LngLatBounds();
  const headers = await Promise.allSettled(
    toFit.map((dataset) => new PMTiles(dataset.publicUrl).getHeader()),
  );

  for (const headerResult of headers) {
    if (headerResult.status !== 'fulfilled') continue;
    const { minLon, minLat, maxLon, maxLat } = headerResult.value;
    if (![minLon, minLat, maxLon, maxLat].every(Number.isFinite)) continue;
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
    map.triggerRepaint();
  } catch {
    /* style not ready */
  }
}

export function applyCitizenLayerVisibility(map: maplibregl.Map, layers: MapLayer[]) {
  const biodiversityEnabled = layerEnabled(layers, 'biodiversity');
  const ids = [
    ['survey-points-layer', 'survey-points', biodiversityEnabled],
    ['survey-points-selected', 'survey-points', biodiversityEnabled],
    ['quick-sightings-layer', 'quick-sightings'],
    ['structured-surveys-layer', 'structured-surveys'],
  ] as const;
  for (const [mapLayerId, layerId, forceVisible] of ids) {
    if (!map.getLayer(mapLayerId)) continue;
    try {
      map.setLayoutProperty(mapLayerId, 'visibility', forceVisible || layerEnabled(layers, layerId) ? 'visible' : 'none');
    } catch { /* layer not ready */ }
  }
}
