'use client';

import { useEffect, useRef, useState } from 'react';
import maplibregl from 'maplibre-gl';
import { PMTiles, Protocol } from 'pmtiles';
import { getCityLayerStats, wardCentroidsGeoJSON } from '@/lib/data';
import { getParks, getParkStats, type GreenSpace } from '@/lib/green-spaces';
import { CITY, MAP_CONFIG } from '@/lib/config';
import { listHexPmtilesDatasets, type HexPmtilesDataset } from '@/lib/pmtiles-storage';
import { fetchPipelineJson, mergeFeatureCollections } from '@/lib/storage-fetch';
import type { RenderCellProperties } from '@/lib/cell-detail';
import type { MapLayer } from '@/lib/types';
import {
  BIODIVERSITY_CIRCLES_LAYER_ID,
  CORRIDOR_LINES_LAYER_ID,
  getEnabledLayerIds,
  hasHexOverlay,
  type HexLayerId,
  hexFillColorExpression,
  hexFillLayerId,
  hexFillOpacityForLayer,
  HEX_OUTLINE_LAYER_ID,
  INTERVENTION_RANK_BADGES_LAYER_ID,
  INTERVENTION_RANK_LABELS_LAYER_ID,
  LAYER_DRAW_ORDER,
  LAYER_STYLE_SPECS,
  PATCH_FILL_LAYER_IDS,
  PATCH_FILL_LAYER_ORDER,
  patchFillColorExpression,
  patchFillOpacityExpression,
  PATCH_OUTLINE_LAYER_ID,
  THEMATIC_LAYER_IDS,
} from '@/lib/layer-styles';

interface MapViewProps {
  layers: MapLayer[];
  selectedCellId: string | null;
  onHexClick: (
    cell: RenderCellProperties,
    coordinates: [number, number],
  ) => void;
  flyToTarget?: { center: [number, number]; zoom: number } | null;
  dataRevision?: number;
  quickSightingsGeoJSON?: GeoJSON.FeatureCollection;
  structuredSurveysGeoJSON?: GeoJSON.FeatureCollection;
  surveyPointsGeoJSON?: GeoJSON.FeatureCollection;
  selectedSurveyPointId?: string | null;
  onSurveyPointSelect?: (id: string, coordinates: [number, number]) => void;
}

const PMTILES_PROTOCOL_KEY = '__naturegap_pmtiles_protocol__';
const DETAIL_ZOOM = 14;

function registerPmtilesProtocol() {
  const globalState = globalThis as typeof globalThis & {
    [PMTILES_PROTOCOL_KEY]?: Protocol;
  };
  if (globalState[PMTILES_PROTOCOL_KEY]) return;

  const protocol = new Protocol();
  maplibregl.addProtocol('pmtiles', protocol.tile);
  globalState[PMTILES_PROTOCOL_KEY] = protocol;
}

type ParkStats = ReturnType<typeof getParkStats>[string];

function finiteNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function statsProperties(stats: ParkStats | undefined) {
  return {
    impactScore: finiteNumber(stats?.impactScore),
    natureGapScore: finiteNumber(stats?.natureGapScore),
    expectedRichness: finiteNumber(stats?.expectedRichness),
    ecologicalResidual: finiteNumber(stats?.ecologicalResidual),
    ecologicalResidualNormalized: finiteNumber(stats?.ecologicalResidualNormalized),
    dataAvailabilityRatio: finiteNumber(stats?.dataAvailabilityRatio),
    habitatQuality: finiteNumber(stats?.habitatQuality),
    habitatQualityIndex: finiteNumber(stats?.habitatQualityIndex),
    observedRichness: finiteNumber(stats?.observedRichness),
    effortCorrectedRichness: finiteNumber(stats?.effortCorrectedRichness ?? stats?.observedRichness),
    taxonomicDiversity: finiteNumber(stats?.taxonomicDiversity),
    corridorImportance: finiteNumber(stats?.corridorImportance),
    betweennessCentrality: finiteNumber(stats?.betweennessCentrality ?? stats?.corridorImportance),
    treeCover: finiteNumber(stats?.treeCover),
    meanCanopy: finiteNumber(stats?.meanCanopy ?? stats?.treeCover),
    canopyHeightIdx: finiteNumber(stats?.canopyHeightIdx ?? stats?.treeCover),
    heatExposure: finiteNumber(stats?.heatExposure),
    meanLst: finiteNumber(stats?.meanLst ?? stats?.heatExposure),
    lstIdx: finiteNumber(stats?.lstIdx ?? stats?.heatExposure),
    landUseGreen: finiteNumber(stats?.landUseGreen),
    landUseClass: stats?.landUseClass ?? 'unknown',
    interventionRank: finiteNumber(stats?.interventionRank),
    habitatQualityNorm: finiteNumber(stats?.habitatQualityNorm),
    effortCorrectedRichnessNorm: finiteNumber(stats?.effortCorrectedRichnessNorm),
    expectedRichnessNorm: finiteNumber(stats?.expectedRichnessNorm),
    corridorImportanceNorm: finiteNumber(stats?.corridorImportanceNorm),
    meanCanopyNorm: finiteNumber(stats?.meanCanopyNorm),
    meanLstNorm: finiteNumber(stats?.meanLstNorm),
    ecologicalResidualNorm: finiteNumber(stats?.ecologicalResidualNorm),
    natureGapScoreNorm: finiteNumber(stats?.natureGapScoreNorm),
    interventionRankNorm: finiteNumber(stats?.interventionRankNorm),
  };
}

function primaryRing(geometry: GeoJSON.Polygon | GeoJSON.MultiPolygon): [number, number][] {
  return geometry.type === 'Polygon'
    ? geometry.coordinates[0] as [number, number][]
    : geometry.coordinates[0]?.[0] as [number, number][] ?? [];
}

function polygonCentroid(ring: [number, number][]): [number, number] {
  const points = ring.length > 1 ? ring.slice(0, -1) : ring;
  let twiceArea = 0;
  let cx = 0;
  let cy = 0;

  for (let i = 0; i < points.length; i += 1) {
    const current = points[i];
    const next = points[(i + 1) % points.length];
    const cross = current[0] * next[1] - next[0] * current[1];
    twiceArea += cross;
    cx += (current[0] + next[0]) * cross;
    cy += (current[1] + next[1]) * cross;
  }

  if (Math.abs(twiceArea) > 1e-12) {
    return [cx / (3 * twiceArea), cy / (3 * twiceArea)];
  }

  const sum = points.reduce(
    (acc, point) => [acc[0] + point[0], acc[1] + point[1]] as [number, number],
    [0, 0] as [number, number],
  );
  return [sum[0] / Math.max(points.length, 1), sum[1] / Math.max(points.length, 1)];
}

/** Build a GeoJSON FeatureCollection from parks for patch-level rendering. */
function parkPolygonsGeoJSON() {
  const statsByPark = getParkStats();
  return {
    type: 'FeatureCollection' as const,
    features: getParks().map((p) => ({
      type: 'Feature' as const,
      properties: {
        parkId: p.id,
        parkName: p.name,
        wardId: p.wardId,
        cityId: p.cityId,
        ...statsProperties(statsByPark[p.id]),
      },
      geometry: p.geometry,
    })),
  };
}

function parkCentroidsGeoJSON() {
  const statsByPark = getParkStats();
  return {
    type: 'FeatureCollection' as const,
    features: getParks().map((p) => ({
      type: 'Feature' as const,
      properties: {
        parkId: p.id,
        parkName: p.name,
        wardId: p.wardId,
        cityId: p.cityId,
        ...statsProperties(statsByPark[p.id]),
      },
      geometry: { type: 'Point' as const, coordinates: polygonCentroid(primaryRing(p.geometry)) },
    })),
  };
}

function emptyFeatureCollection(): GeoJSON.FeatureCollection {
  return { type: 'FeatureCollection', features: [] };
}

function mergeFeatureCollectionChunks(parts: unknown[]): GeoJSON.FeatureCollection {
  return mergeFeatureCollections(parts);
}

function isFeatureCollection(value: unknown): value is GeoJSON.FeatureCollection {
  return (
    typeof value === 'object' &&
    value !== null &&
    (value as GeoJSON.FeatureCollection).type === 'FeatureCollection' &&
    Array.isArray((value as GeoJSON.FeatureCollection).features)
  );
}

async function fetchCorridorLinksGeoJSON(): Promise<GeoJSON.FeatureCollection> {
  const data = await fetchPipelineJson(
    'corridor-links.geojson',
    'corridor-links.manifest.json',
    mergeFeatureCollectionChunks,
  );
  return isFeatureCollection(data) ? data : emptyFeatureCollection();
}

function safeColor(color: unknown) {
  return typeof color === 'string' && /^#[0-9a-f]{6}$/i.test(color) ? color : '#3d6b2f';
}

function scoreColor(score: number | undefined) {
  if (typeof score !== 'number' || !Number.isFinite(score)) return '#B8C9AE';
  if (score < -20) return '#C95B4B';
  if (score < -10) return '#E8A44C';
  if (score < 5) return '#B8C9AE';
  if (score < 15) return '#73A56D';
  return '#2E6F40';
}

function layerEnabled(layers: MapLayer[], id: string): boolean {
  return layers.some((layer) => layer.id === id && layer.enabled);
}

function setMapLayerVisibility(map: maplibregl.Map, layerId: string, visible: boolean) {
  if (!map.getLayer(layerId)) return;
  try {
    map.setLayoutProperty(layerId, 'visibility', visible ? 'visible' : 'none');
  } catch { /* layer not ready */ }
}

function activeThematicLayerId(layers: MapLayer[]): HexLayerId {
  return THEMATIC_LAYER_IDS.find((id) => layerEnabled(layers, id)) ?? 'impact';
}

function applyLayerPaintExpressions(map: maplibregl.Map) {
  const defaultCityStats = getCityLayerStats(CITY.id);
  try {
    for (const layerId of PATCH_FILL_LAYER_ORDER) {
      const layer = PATCH_FILL_LAYER_IDS[layerId];
      if (!map.getLayer(layer)) continue;
      map.setPaintProperty(layer, 'fill-color', patchFillColorExpression(layerId, defaultCityStats));
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

function setLayerVisibility(map: maplibregl.Map, activeLayerId: HexLayerId, layers: MapLayer[]) {
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

function hexFillLayerIdForDataset(sourceId: string, layerId: HexLayerId): string {
  return `${hexFillLayerId(layerId)}-${sourceId}`;
}

function hexOutlineLayerId(sourceId: string): string {
  return `${HEX_OUTLINE_LAYER_ID}-${sourceId}`;
}

function hexSelectedLayerId(sourceId: string): string {
  return `hex-selected-${sourceId}`;
}

function getHexDatasets(map: maplibregl.Map): HexPmtilesDataset[] {
  return ((map as unknown as { __naturegapHexDatasets?: HexPmtilesDataset[] }).__naturegapHexDatasets ?? []);
}

function setHexDatasets(map: maplibregl.Map, datasets: HexPmtilesDataset[]) {
  (map as unknown as { __naturegapHexDatasets?: HexPmtilesDataset[] }).__naturegapHexDatasets = datasets;
}

function hexInteractiveLayerIds(map: maplibregl.Map): string[] {
  return getHexDatasets(map).flatMap((dataset) => LAYER_DRAW_ORDER
    .filter(hasHexOverlay)
    .map((layerId) => hexFillLayerIdForDataset(dataset.sourceId, layerId))
    .filter((layerId) => map.getLayer(layerId)));
}

function selectedHexFilter(cellId: string | null): maplibregl.FilterSpecification {
  return ['==', ['get', 'cellId'], cellId ?? ''];
}

async function fitMapToPmtilesDatasets(map: maplibregl.Map, datasets: HexPmtilesDataset[]) {
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

function renderCellProperties(properties: maplibregl.GeoJSONFeature['properties']): RenderCellProperties | null {
  if (!properties) return null;
  const cellId = String(properties.cellId ?? '');
  if (!cellId) return null;

  return {
    cellId,
    parkId: properties.parkId != null ? String(properties.parkId) : undefined,
    parkName: properties.parkName != null ? String(properties.parkName) : undefined,
    impactScore: Number(properties.impactScore ?? 0),
    natureGapScore: properties.natureGapScore == null ? null : Number(properties.natureGapScore),
    expectedRichness: properties.expectedRichness == null ? null : Number(properties.expectedRichness),
    ecologicalResidual: properties.ecologicalResidual == null ? null : Number(properties.ecologicalResidual),
    ecologicalResidualNormalized: properties.ecologicalResidualNormalized == null ? null : Number(properties.ecologicalResidualNormalized),
    habitatQuality: properties.habitatQuality == null ? null : Number(properties.habitatQuality),
    observedRichness: properties.observedRichness == null ? null : Number(properties.observedRichness),
    corridorImportance: properties.corridorImportance == null ? null : Number(properties.corridorImportance),
    betweennessCentrality: properties.betweennessCentrality == null ? null : Number(properties.betweennessCentrality),
    treeCover: properties.treeCover == null ? null : Number(properties.treeCover),
    meanCanopy: properties.meanCanopy == null ? null : Number(properties.meanCanopy),
    canopyHeightIdx: properties.canopyHeightIdx == null ? null : Number(properties.canopyHeightIdx),
    heatExposure: properties.heatExposure == null ? null : Number(properties.heatExposure),
    meanLst: properties.meanLst == null ? null : Number(properties.meanLst),
    lstIdx: properties.lstIdx == null ? null : Number(properties.lstIdx),
    landUseGreen: properties.landUseGreen == null ? null : Number(properties.landUseGreen),
    interventionRank: properties.interventionRank == null ? null : Number(properties.interventionRank),
  };
}

function applyCitizenLayerVisibility(map: maplibregl.Map, layers: MapLayer[]) {
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

function createPopupContent({
  parkName,
  score,
  showScore,
}: {
  parkName?: string;
  score?: number;
  showScore: boolean;
}) {
  const root = document.createElement('div');
  root.style.fontFamily = "'Inter', system-ui, -apple-system, sans-serif";
  root.style.padding = '10px 14px';
  root.style.minWidth = '140px';

  if (parkName) {
    const title = document.createElement('div');
    title.textContent = parkName;
    title.style.fontSize = '12px';
    title.style.fontWeight = '600';
    title.style.color = '#1F2A1F';
    title.style.marginBottom = showScore ? '6px' : '4px';
    title.style.lineHeight = '1.4';
    root.append(title);
  }

  if (showScore && typeof score === 'number') {
    const labelEl = document.createElement('div');
    labelEl.textContent = 'Nature Gap score';
    labelEl.style.fontSize = '10px';
    labelEl.style.fontWeight = '500';
    labelEl.style.color = '#667066';
    labelEl.style.letterSpacing = '0.03em';
    labelEl.style.marginBottom = '2px';
    root.append(labelEl);

    const value = document.createElement('div');
    value.textContent = score > 0 ? `+${score}` : String(score);
    value.style.fontSize = '18px';
    value.style.fontWeight = '700';
    value.style.color = safeColor(scoreColor(score));
    value.style.lineHeight = '1.2';
    root.append(value);
  }

  const divider = document.createElement('div');
  divider.style.height = '1px';
  divider.style.background = '#E4E7E1';
  divider.style.margin = showScore ? '8px -14px 6px' : '6px -14px 4px';
  root.append(divider);

  const hint = document.createElement('div');
  hint.textContent = 'Click to explore →';
  hint.style.fontSize = '10px';
  hint.style.fontWeight = '500';
  hint.style.color = '#2E6F40';
  root.append(hint);

  return root;
}

function clearLandUseDonutMarkers(markers: maplibregl.Marker[]) {
  for (const marker of markers) marker.remove();
  markers.length = 0;
}

function applyLandUseDonutZoom(map: maplibregl.Map, markers: maplibregl.Marker[]) {
  const zoom = map.getZoom();
  const display = zoom <= 13 ? 'block' : 'none';
  for (const marker of markers) {
    marker.getElement().style.display = display;
  }
}

function createLandUseDonutElement(park: GreenSpace, stats: ParkStats): HTMLElement | null {
  const green = finiteNumber(stats.landUseGreen);
  if (green === null) return null;
  const clampedGreen = Math.max(0, Math.min(100, green));
  const el = document.createElement('button');
  el.type = 'button';
  el.title = `${park.name}: land use`;
  el.style.width = '34px';
  el.style.height = '34px';
  el.style.borderRadius = '999px';
  el.style.border = '2px solid #ffffff';
  el.style.padding = '0';
  el.style.boxShadow = '0 1px 5px rgba(31,42,31,0.22)';
  el.style.background = `conic-gradient(#1b5e20 0 ${clampedGreen}%, #b87f4f ${clampedGreen}% 100%)`;
  el.style.position = 'relative';
  el.style.cursor = 'default';

  const hole = document.createElement('span');
  hole.style.position = 'absolute';
  hole.style.inset = '9px';
  hole.style.borderRadius = '999px';
  hole.style.background = '#ffffff';
  hole.style.border = '1px solid rgba(31,42,31,0.14)';
  el.append(hole);
  return el;
}

function syncLandUseDonutMarkers(
  map: maplibregl.Map,
  layers: MapLayer[],
  markers: maplibregl.Marker[],
) {
  clearLandUseDonutMarkers(markers);
  if (!layerEnabled(layers, 'landuse')) return;

  const statsByPark = getParkStats();
  for (const park of getParks()) {
    const stats = statsByPark[park.id];
    if (!stats) continue;
    const el = createLandUseDonutElement(park, stats);
    if (!el) continue;
    markers.push(new maplibregl.Marker({ element: el }).setLngLat(polygonCentroid(primaryRing(park.geometry))).addTo(map));
  }
  applyLandUseDonutZoom(map, markers);
}

export default function MapView({
  layers,
  selectedCellId,
  onHexClick,
  flyToTarget,
  dataRevision,
  quickSightingsGeoJSON,
  structuredSurveysGeoJSON,
  surveyPointsGeoJSON,
  selectedSurveyPointId,
  onSurveyPointSelect,
}: MapViewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const popupRef = useRef<maplibregl.Popup | null>(null);
  const onClickRef = useRef(onHexClick);
  const layersAddedRef = useRef(false);
  const layersRef = useRef(layers);
  const onSurveyPointSelectRef = useRef(onSurveyPointSelect);
  const quickSightingsRef = useRef<GeoJSON.FeatureCollection | undefined>(quickSightingsGeoJSON);
  const structuredSurveysRef = useRef<GeoJSON.FeatureCollection | undefined>(structuredSurveysGeoJSON);
  const surveyPointsRef = useRef<GeoJSON.FeatureCollection | undefined>(surveyPointsGeoJSON);
  const landUseMarkersRef = useRef<maplibregl.Marker[]>([]);
  const [mapZoom, setMapZoom] = useState<number>(MAP_CONFIG.zoom);
  const enabledLayerIds = getEnabledLayerIds(layers);
  const activeThematic = activeThematicLayerId(layers);
  const enabledLegends = enabledLayerIds.map((id: HexLayerId) => LAYER_STYLE_SPECS[id]);

  useEffect(() => {
    onClickRef.current = onHexClick;
  }, [onHexClick]);

  useEffect(() => {
    layersRef.current = layers;
  }, [layers]);

  useEffect(() => {
    onSurveyPointSelectRef.current = onSurveyPointSelect;
  }, [onSurveyPointSelect]);

  useEffect(() => {
    quickSightingsRef.current = quickSightingsGeoJSON;
    structuredSurveysRef.current = structuredSurveysGeoJSON;
    surveyPointsRef.current = surveyPointsGeoJSON;
  }, [quickSightingsGeoJSON, structuredSurveysGeoJSON, surveyPointsGeoJSON]);

  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;
    registerPmtilesProtocol();

    const map = new maplibregl.Map({
      container: containerRef.current,
      style: MAP_CONFIG.basemapUrl,
      center: MAP_CONFIG.center,
      zoom: MAP_CONFIG.zoom,
      minZoom: MAP_CONFIG.minZoom,
      maxZoom: MAP_CONFIG.maxZoom,
      attributionControl: false,
    });

    mapRef.current = map;
    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-left');
    map.addControl(new maplibregl.AttributionControl({ compact: true }), 'bottom-right');

    map.on('load', async () => {
      map.addSource('parks', { type: 'geojson', data: parkPolygonsGeoJSON() });
      map.addSource('park-centroids', { type: 'geojson', data: parkCentroidsGeoJSON() });
      map.addSource('corridor-links', {
        type: 'geojson',
        data: emptyFeatureCollection(),
      });
      void fetchCorridorLinksGeoJSON().then((fc) => {
        if (mapRef.current !== map) return;
        const source = map.getSource('corridor-links') as maplibregl.GeoJSONSource | undefined;
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        source?.setData(fc as any);
      }).catch(() => {
        /* Optional export: keep the line layer empty until corridor-links.geojson exists. */
      });

      for (const layerId of PATCH_FILL_LAYER_ORDER) {
        map.addLayer({
          id: PATCH_FILL_LAYER_IDS[layerId],
          type: 'fill',
          source: 'parks',
          maxzoom: DETAIL_ZOOM,
          layout: { visibility: 'none' },
          paint: {
            'fill-color': patchFillColorExpression(layerId, getCityLayerStats(CITY.id)),
            'fill-opacity': patchFillOpacityExpression(layerId),
          },
        });
      }

      map.addLayer({
        id: 'park-area',
        type: 'fill',
        source: 'parks',
        paint: { 'fill-color': '#3d6b2f', 'fill-opacity': 0 },
      });

      map.addLayer({
        id: PATCH_OUTLINE_LAYER_ID,
        type: 'line',
        source: 'parks',
        paint: {
          'line-color': '#2d6a2d',
          'line-width': 0.8,
          'line-opacity': 0.5,
        },
      });

      const pmtilesDatasets = await listHexPmtilesDatasets();
      if (mapRef.current !== map) return;
      setHexDatasets(map, pmtilesDatasets);

      for (const dataset of pmtilesDatasets) {
        map.addSource(dataset.sourceId, {
          type: 'vector',
          url: `pmtiles://${dataset.publicUrl}`,
        });

        for (const layerId of LAYER_DRAW_ORDER) {
          if (!hasHexOverlay(layerId)) continue;
          map.addLayer({
            id: hexFillLayerIdForDataset(dataset.sourceId, layerId),
            type: 'fill',
            source: dataset.sourceId,
            'source-layer': dataset.sourceLayer,
            minzoom: 14,
            layout: { visibility: 'none' },
            paint: {
              'fill-color': hexFillColorExpression(layerId, getCityLayerStats(dataset.cityId)),
              'fill-opacity': hexFillOpacityForLayer(layerId),
            },
          });
        }

        map.addLayer({
          id: hexOutlineLayerId(dataset.sourceId),
          type: 'line',
          source: dataset.sourceId,
          'source-layer': dataset.sourceLayer,
          minzoom: 14,
          paint: {
            'line-color': '#ffffff',
            'line-width': 0.3,
            'line-opacity': 0.4,
          },
        });

        map.addLayer({
          id: hexSelectedLayerId(dataset.sourceId),
          type: 'fill',
          source: dataset.sourceId,
          'source-layer': dataset.sourceLayer,
          minzoom: 14,
          filter: selectedHexFilter(null),
          paint: {
            'fill-color': '#1F2A1F',
            'fill-opacity': 0.25,
            'fill-outline-color': '#1F2A1F',
          },
        });
      }

      map.addLayer({
        id: CORRIDOR_LINES_LAYER_ID,
        type: 'line',
        source: 'corridor-links',
        layout: { visibility: 'none', 'line-cap': 'round', 'line-join': 'round' },
        paint: {
          'line-color': '#5b2a86',
          'line-width': [
            'interpolate',
            ['linear'],
            ['coalesce', ['get', 'importance'], ['get', 'weight'], 0],
            0, 0.5,
            0.5, 2,
            1, 5,
          ],
          'line-opacity': [
            'interpolate',
            ['linear'],
            ['coalesce', ['get', 'importance'], ['get', 'weight'], 0],
            0, 0.2,
            0.5, 0.55,
            1, 0.9,
          ],
        },
      });

      map.addLayer({
        id: BIODIVERSITY_CIRCLES_LAYER_ID,
        type: 'circle',
        source: 'park-centroids',
        layout: { visibility: 'none' },
        paint: {
          'circle-radius': [
            'interpolate',
            ['linear'],
            ['coalesce', ['get', 'effortCorrectedRichness'], 0],
            0, 5,
            25, 13,
            75, 24,
          ],
          'circle-color': [
            'interpolate',
            ['linear'],
            ['coalesce', ['get', 'taxonomicDiversity'], 0],
            0, '#42a5f5',
            0.5, '#1565c0',
            1.5, '#002171',
          ],
          'circle-opacity': 0.78,
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 2,
        },
      });

      map.addLayer({
        id: INTERVENTION_RANK_BADGES_LAYER_ID,
        type: 'circle',
        source: 'park-centroids',
        minzoom: 12,
        maxzoom: DETAIL_ZOOM,
        filter: ['<=', ['get', 'interventionRank'], 10],
        layout: { visibility: 'none' },
        paint: {
          'circle-radius': 13,
          'circle-color': '#ffffff',
          'circle-opacity': 0.96,
          'circle-stroke-color': '#4a148c',
          'circle-stroke-width': 2,
        },
      });

      map.addLayer({
        id: INTERVENTION_RANK_LABELS_LAYER_ID,
        type: 'symbol',
        source: 'park-centroids',
        minzoom: 12,
        maxzoom: DETAIL_ZOOM,
        filter: ['<=', ['get', 'interventionRank'], 10],
        layout: {
          visibility: 'none',
          'text-field': ['to-string', ['get', 'interventionRank']],
          'text-size': 11,
          'text-font': MAP_CONFIG.mapFonts,
          'text-anchor': 'center',
          'text-allow-overlap': true,
        },
        paint: {
          'text-color': '#4a148c',
          'text-halo-color': '#ffffff',
          'text-halo-width': 0.8,
        },
      });

      setLayerVisibility(map, activeThematicLayerId(layersRef.current), layersRef.current);
      applyLayerPaintExpressions(map);
      syncLandUseDonutMarkers(map, layersRef.current, landUseMarkersRef.current);
      map.on('zoom', () => {
        applyLandUseDonutZoom(map, landUseMarkersRef.current);
        setMapZoom(map.getZoom());
      });
      setMapZoom(map.getZoom());
      await fitMapToPmtilesDatasets(map, pmtilesDatasets);
      if (mapRef.current !== map) return;

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      map.addSource('ward-labels', { type: 'geojson', data: wardCentroidsGeoJSON() as any });
      map.addLayer({
        id: 'ward-label-text',
        type: 'symbol',
        source: 'ward-labels',
        layout: {
          'text-field': ['get', 'nameJa'],
          'text-size': ['interpolate', ['linear'], ['zoom'], 10, 9, 14, 13],
          'text-font': MAP_CONFIG.mapFonts,
          'text-anchor': 'center',
          'text-allow-overlap': false,
        },
        paint: {
          'text-color': '#1a1a1a',
          'text-halo-color': 'rgba(255,255,255,0.9)',
          'text-halo-width': 1.5,
        },
      });

      map.addSource('survey-points', { type: 'geojson', data: surveyPointsRef.current ?? { type: 'FeatureCollection', features: [] } as GeoJSON.FeatureCollection });
      map.addLayer({
        id: 'survey-points-layer',
        type: 'circle',
        source: 'survey-points',
        minzoom: 14,
        paint: {
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 10, 4, 16, 8],
          'circle-color': '#1F2A1F',
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 2,
          'circle-opacity': 0.88,
        },
      });
      map.addLayer({
        id: 'survey-points-selected',
        type: 'circle',
        source: 'survey-points',
        minzoom: 14,
        filter: ['==', ['get', 'id'], ''],
        paint: {
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 10, 8, 16, 13],
          'circle-color': 'rgba(46,111,64,0.18)',
          'circle-stroke-color': '#2E6F40',
          'circle-stroke-width': 2,
        },
      });

      map.addSource('quick-sightings', { type: 'geojson', data: quickSightingsRef.current ?? { type: 'FeatureCollection', features: [] } as GeoJSON.FeatureCollection });
      map.addLayer({
        id: 'quick-sightings-layer',
        type: 'circle',
        source: 'quick-sightings',
        minzoom: 14,
        paint: {
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 10, 3, 16, 6],
          'circle-color': [
            'match',
            ['get', 'taxonGroup'],
            'bird', '#3A6A8A',
            'insect', '#E8A44C',
            'plant', '#2E6F40',
            'amphibian', '#6A8A3A',
            '#667066',
          ],
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 1,
          'circle-opacity': 0.84,
        },
      });

      map.addSource('structured-surveys', { type: 'geojson', data: structuredSurveysRef.current ?? { type: 'FeatureCollection', features: [] } as GeoJSON.FeatureCollection });
      map.addLayer({
        id: 'structured-surveys-layer',
        type: 'circle',
        source: 'structured-surveys',
        minzoom: 14,
        paint: {
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 10, 4, 16, 7],
          'circle-color': ['case', ['get', 'submitted'], '#2E6F40', '#B07A2A'],
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 1.5,
          'circle-opacity': 0.88,
        },
      });

      applyCitizenLayerVisibility(map, layersRef.current);

      layersAddedRef.current = true;

      map.on('mouseenter', 'park-area', () => { map.getCanvas().style.cursor = 'pointer'; });
      map.on('mouseleave', 'park-area', () => {
        map.getCanvas().style.cursor = '';
        popupRef.current?.remove();
        popupRef.current = null;
      });

      map.on('mousemove', (e) => {
        const interactiveLayerIds = hexInteractiveLayerIds(map);
        const hexFeatures = interactiveLayerIds.length
          ? map.queryRenderedFeatures(e.point, { layers: interactiveLayerIds })
          : [];
        map.getCanvas().style.cursor = hexFeatures.length > 0 ? 'pointer' : '';

        const f = hexFeatures[0];
        if (!f) return;

        const props = renderCellProperties(f.properties);
        if (!props) return;
        const numericScore = Number(props.natureGapScore);
        const impactOn = getEnabledLayerIds(layersRef.current).includes('impact');

        popupRef.current?.remove();
        popupRef.current = new maplibregl.Popup({
          closeButton: false, closeOnClick: false, offset: 8, className: 'naturegap-popup',
        })
          .setLngLat(e.lngLat)
          .setDOMContent(createPopupContent({
            parkName: props.parkName,
            score: numericScore,
            showScore: impactOn && !Number.isNaN(numericScore),
          }))
          .addTo(map);
      });

      map.on('mousemove', 'park-area', (e) => {
        const interactiveLayerIds = hexInteractiveLayerIds(map);
        const hexFeatures = interactiveLayerIds.length
          ? map.queryRenderedFeatures(e.point, { layers: interactiveLayerIds })
          : [];
        if (hexFeatures.length > 0) return;

        const f = e.features?.[0];
        if (!f) return;
        const { parkName } = f.properties as { parkName: string };

        popupRef.current?.remove();
        popupRef.current = new maplibregl.Popup({
          closeButton: false, closeOnClick: false, offset: 8, className: 'naturegap-popup',
        })
          .setLngLat(e.lngLat)
          .setDOMContent(createPopupContent({ parkName, showScore: false }))
          .addTo(map);
      });

      map.on('click', (e) => {
        const interactiveLayerIds = hexInteractiveLayerIds(map);
        const hexFeatures = interactiveLayerIds.length
          ? map.queryRenderedFeatures(e.point, { layers: interactiveLayerIds })
          : [];
        const f = hexFeatures[0];
        if (!f) return;
        e.preventDefault();
        const props = renderCellProperties(f.properties);
        if (!props) return;
        onClickRef.current(props, [e.lngLat.lng, e.lngLat.lat]);
      });

      map.on('click', 'park-area', (e) => {
        if (e.defaultPrevented) return;
        const interactiveLayerIds = hexInteractiveLayerIds(map);
        const hexFeatures = interactiveLayerIds.length
          ? map.queryRenderedFeatures(e.point, { layers: interactiveLayerIds })
          : [];
        const props = renderCellProperties(hexFeatures[0]?.properties);
        if (!props) return;
        onClickRef.current(props, [e.lngLat.lng, e.lngLat.lat]);
      });

      map.on('mouseenter', 'survey-points-layer', () => { map.getCanvas().style.cursor = 'pointer'; });
      map.on('mouseleave', 'survey-points-layer', () => { map.getCanvas().style.cursor = ''; });
      map.on('click', 'survey-points-layer', (e) => {
        const feature = e.features?.[0];
        const id = feature?.properties?.id;
        if (typeof id !== 'string') return;
        onSurveyPointSelectRef.current?.(id, [e.lngLat.lng, e.lngLat.lat]);
      });
    });

    const landUseMarkers = landUseMarkersRef.current;
    return () => {
      layersAddedRef.current = false;
      popupRef.current?.remove();
      clearLandUseDonutMarkers(landUseMarkers);
      map.remove();
      mapRef.current = null;
    };
  }, []);

  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const apply = () => {
      try {
        for (const dataset of getHexDatasets(map)) {
          map.setFilter(hexSelectedLayerId(dataset.sourceId), selectedHexFilter(selectedCellId));
        }
      } catch { /* style not ready */ }
    };
    if (map.isStyleLoaded()) apply();
    else map.once('load', apply);
  }, [selectedCellId]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !layersAddedRef.current) return;

    const apply = () => {
      try {
        setLayerVisibility(map, activeThematicLayerId(layers), layers);
        applyLayerPaintExpressions(map);
        applyCitizenLayerVisibility(map, layers);
        syncLandUseDonutMarkers(map, layers, landUseMarkersRef.current);
      } catch { /* layers not ready yet */ }
    };

    if (map.isStyleLoaded()) apply();
    else map.once('load', apply);
  }, [layers]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !layersAddedRef.current) return;
    try {
      map.setFilter('survey-points-selected', ['==', ['get', 'id'], selectedSurveyPointId ?? '']);
    } catch { /* layer not ready */ }
  }, [selectedSurveyPointId]);

  useEffect(() => {
    if (!mapRef.current || !layersAddedRef.current || dataRevision === 0) return;
    const map = mapRef.current;
    const parkSrc = map.getSource('parks') as maplibregl.GeoJSONSource | undefined;
    const centroidSrc = map.getSource('park-centroids') as maplibregl.GeoJSONSource | undefined;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    parkSrc?.setData(parkPolygonsGeoJSON() as any);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    centroidSrc?.setData(parkCentroidsGeoJSON() as any);
    try {
      setLayerVisibility(map, activeThematicLayerId(layersRef.current), layersRef.current);
      applyLayerPaintExpressions(map);
      syncLandUseDonutMarkers(map, layersRef.current, landUseMarkersRef.current);
    } catch { /* ignore */ }
  }, [dataRevision]);

  useEffect(() => {
    if (!mapRef.current || !layersAddedRef.current) return;
    const map = mapRef.current;
    const surveyPoints = map.getSource('survey-points') as maplibregl.GeoJSONSource | undefined;
    const quickSightings = map.getSource('quick-sightings') as maplibregl.GeoJSONSource | undefined;
    const structuredSurveys = map.getSource('structured-surveys') as maplibregl.GeoJSONSource | undefined;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    surveyPoints?.setData((surveyPointsGeoJSON ?? { type: 'FeatureCollection', features: [] }) as any);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    quickSightings?.setData((quickSightingsGeoJSON ?? { type: 'FeatureCollection', features: [] }) as any);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    structuredSurveys?.setData((structuredSurveysGeoJSON ?? { type: 'FeatureCollection', features: [] }) as any);
  }, [quickSightingsGeoJSON, structuredSurveysGeoJSON, surveyPointsGeoJSON]);

  useEffect(() => {
    if (!flyToTarget || !mapRef.current) return;
    mapRef.current.flyTo({ center: flyToTarget.center, zoom: flyToTarget.zoom, duration: 900 });
  }, [flyToTarget]);

  return (
    <div className="relative w-full h-full" style={{ minHeight: 0 }}>
      <div ref={containerRef} className="w-full h-full" style={{ position: 'absolute', inset: 0 }} />

      {activeThematic === 'impact' && mapZoom >= DETAIL_ZOOM && (
        <div className="absolute bottom-4 left-1/2 -translate-x-1/2 z-10 pointer-events-none">
          <p className="text-[11px] text-[#667066] bg-white/92 backdrop-blur-sm border border-[#E4E7E1] rounded-full px-3 py-1.5 shadow-sm">
            Within-park values are indicative
          </p>
        </div>
      )}

      <div className="absolute top-3 right-3 bg-white/96 backdrop-blur-sm rounded-2xl border border-[#E4E7E1] p-4 max-h-[70vh] overflow-y-auto" style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}>
        {enabledLegends.length === 0 ? (
          <p className="text-[10px] text-[#667066]">No layers enabled</p>
        ) : (
          enabledLegends.map((legend, index) => (
            <div key={legend.title} className={index > 0 ? 'mt-4 pt-4 border-t border-[#E4E7E1]' : undefined}>
              <p className="text-[9px] font-semibold text-[#667066] uppercase tracking-widest mb-3">
                {legend.title}
              </p>
              <div className="flex flex-col gap-1.5">
                {legend.legend.map(({ color, label }, i, arr) => {
                  let formattedLabel = label;
                  if (legend.rawMetric) {
                    const statsList = getCityLayerStats(CITY.id);
                    const stats = statsList.filter(s => s.metric === legend.rawMetric);
                    if (stats.length === 1) {
                      const s = stats[0];
                      const isTop = i === 0;
                      const isBottom = i === arr.length - 1;

                      if (s.bound != null) {
                        const val = i === 0 ? s.bound :
                                    i === 1 ? s.bound * 0.4 :
                                    i === 2 ? 0 :
                                    i === 3 ? -s.bound * 0.4 :
                                    -s.bound;
                        formattedLabel = i === 2 ? `${label} (~0)` : `${label} (${val > 0 ? '+' : ''}${Math.round(val)})`;
                      } else if (s.metric === 'intervention_rank') {
                        if (isTop && s.minVal != null) formattedLabel = `${label} (~#${Math.round(s.minVal)})`;
                        else if (isBottom && s.maxVal != null) formattedLabel = `${label} (~#${Math.round(s.maxVal)})`;
                      } else if (['habitat_quality', 'canopy_height_idx', 'lst_idx', 'betweenness_centrality'].includes(s.metric)) {
                        if (isTop && s.p95 != null) formattedLabel = `${label} (> ${Math.round(s.p95 * 100)}%)`;
                        else if (isBottom && s.p05 != null) formattedLabel = `${label} (< ${Math.round(s.p05 * 100)}%)`;
                      } else {
                        if (isTop && s.p95 != null) formattedLabel = `${label} (> ${Math.round(s.p95)})`;
                        else if (isBottom && s.p05 != null) formattedLabel = `${label} (< ${Math.round(s.p05)})`;
                      }
                    }
                  }
                  
                  return (
                    <div key={label} className="flex items-center gap-2.5">
                      <div className="w-2.5 h-2.5 rounded-[3px] flex-shrink-0" style={{ backgroundColor: color }} />
                      <span className="text-[10px] text-[#667066] leading-tight">{formattedLabel}</span>
                    </div>
                  );
                })}
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
