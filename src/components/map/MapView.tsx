'use client';

import { useEffect, useRef } from 'react';
import maplibregl from 'maplibre-gl';
import { PMTiles, Protocol } from 'pmtiles';
import { wardCentroidsGeoJSON } from '@/lib/data';
import { getParks } from '@/lib/green-spaces';
import { MAP_CONFIG } from '@/lib/config';
import { listHexPmtilesDatasets, type HexPmtilesDataset } from '@/lib/pmtiles-storage';
import type { RenderCellProperties } from '@/lib/cell-detail';
import type { MapLayer } from '@/lib/types';
import {
  getEnabledLayerIds,
  type HexLayerId,
  hexFillColorExpression,
  hexFillLayerId,
  hexFillOpacity,
  LAYER_DRAW_ORDER,
  LAYER_STYLE_SPECS,
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

function registerPmtilesProtocol() {
  const globalState = globalThis as typeof globalThis & {
    [PMTILES_PROTOCOL_KEY]?: Protocol;
  };
  if (globalState[PMTILES_PROTOCOL_KEY]) return;

  const protocol = new Protocol();
  maplibregl.addProtocol('pmtiles', protocol.tile);
  globalState[PMTILES_PROTOCOL_KEY] = protocol;
}

/** Build a GeoJSON FeatureCollection from parks for park-level click zones. */
function parkPolygonsGeoJSON() {
  return {
    type: 'FeatureCollection' as const,
    features: getParks().map((p) => ({
      type: 'Feature' as const,
      properties: { parkId: p.id, parkName: p.name, wardId: p.wardId },
      geometry: { type: 'Polygon' as const, coordinates: [p.ring] },
    })),
  };
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

function applyHexLayerVisibility(map: maplibregl.Map, layers: MapLayer[]) {
  const enabledIds = getEnabledLayerIds(layers);
  const opacity = hexFillOpacity(enabledIds.length);
  const datasets = getHexDatasets(map);

  for (const dataset of datasets) {
    for (const layerId of LAYER_DRAW_ORDER) {
      const mlId = hexFillLayerIdForDataset(dataset.sourceId, layerId);
      const enabled = enabledIds.includes(layerId);
      try {
        map.setLayoutProperty(mlId, 'visibility', enabled ? 'visible' : 'none');
        if (enabled) map.setPaintProperty(mlId, 'fill-opacity', opacity);
      } catch { /* layer not ready */ }
    }

    try {
      map.setLayoutProperty(
        hexOutlineLayerId(dataset.sourceId),
        'visibility',
        layerEnabled(layers, 'cell-grid') || enabledIds.length > 0 ? 'visible' : 'none',
      );
      map.setLayoutProperty(hexSelectedLayerId(dataset.sourceId), 'visibility', enabledIds.length > 0 ? 'visible' : 'none');
    } catch { /* ignore */ }
  }
}

function hexFillLayerIdForDataset(sourceId: string, layerId: HexLayerId): string {
  return `${hexFillLayerId(layerId)}-${sourceId}`;
}

function hexOutlineLayerId(sourceId: string): string {
  return `hex-outline-${sourceId}`;
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
  return getHexDatasets(map).flatMap((dataset) => LAYER_DRAW_ORDER.map((layerId) => (
    hexFillLayerIdForDataset(dataset.sourceId, layerId)
  )));
}

function selectedHexFilter(cellId: string | null): maplibregl.FilterSpecification {
  return ['==', ['get', 'cellId'], cellId ?? ''];
}

async function fitMapToPmtilesDatasets(map: maplibregl.Map, datasets: HexPmtilesDataset[]) {
  if (datasets.length === 0) return;

  const bounds = new maplibregl.LngLatBounds();
  const headers = await Promise.allSettled(
    datasets.map((dataset) => new PMTiles(dataset.publicUrl).getHeader()),
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
    expectedRichness: properties.expectedRichness == null ? null : Number(properties.expectedRichness),
    ecologicalResidual: properties.ecologicalResidual == null ? null : Number(properties.ecologicalResidual),
    habitatQuality: properties.habitatQuality == null ? null : Number(properties.habitatQuality),
    observedRichness: properties.observedRichness == null ? null : Number(properties.observedRichness),
    corridorImportance: properties.corridorImportance == null ? null : Number(properties.corridorImportance),
    treeCover: properties.treeCover == null ? null : Number(properties.treeCover),
    heatExposure: properties.heatExposure == null ? null : Number(properties.heatExposure),
    landUseGreen: properties.landUseGreen == null ? null : Number(properties.landUseGreen),
    interventionRank: properties.interventionRank == null ? null : Number(properties.interventionRank),
  };
}

function applyCitizenLayerVisibility(map: maplibregl.Map, layers: MapLayer[]) {
  const ids = [
    ['survey-points-layer', 'survey-points'],
    ['survey-points-selected', 'survey-points'],
    ['quick-sightings-layer', 'quick-sightings'],
    ['structured-surveys-layer', 'structured-surveys'],
  ] as const;
  for (const [mapLayerId, layerId] of ids) {
    try {
      map.setLayoutProperty(mapLayerId, 'visibility', layerEnabled(layers, layerId) ? 'visible' : 'none');
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
    labelEl.textContent = 'Nature impact score';
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
  const enabledLayerIds = getEnabledLayerIds(layers);
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

      map.addLayer({
        id: 'park-area',
        type: 'fill',
        source: 'parks',
        paint: { 'fill-color': '#3d6b2f', 'fill-opacity': 0 },
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
          map.addLayer({
            id: hexFillLayerIdForDataset(dataset.sourceId, layerId),
            type: 'fill',
            source: dataset.sourceId,
            'source-layer': dataset.sourceLayer,
            layout: { visibility: 'none' },
            paint: {
              'fill-color': hexFillColorExpression(layerId),
              'fill-opacity': 0.78,
            },
          });
        }

        map.addLayer({
          id: hexOutlineLayerId(dataset.sourceId),
          type: 'line',
          source: dataset.sourceId,
          'source-layer': dataset.sourceLayer,
          paint: { 'line-color': '#5a6b5a', 'line-width': 0.4, 'line-opacity': 0.55 },
        });

        map.addLayer({
          id: hexSelectedLayerId(dataset.sourceId),
          type: 'fill',
          source: dataset.sourceId,
          'source-layer': dataset.sourceLayer,
          filter: selectedHexFilter(null),
          paint: {
            'fill-color': '#1F2A1F',
            'fill-opacity': 0.25,
            'fill-outline-color': '#1F2A1F',
          },
        });
      }

      applyHexLayerVisibility(map, layersRef.current);
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
        const numericScore = Number(props.impactScore);
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

    return () => {
      layersAddedRef.current = false;
      popupRef.current?.remove();
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
        applyHexLayerVisibility(map, layers);
        applyCitizenLayerVisibility(map, layers);
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
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    parkSrc?.setData(parkPolygonsGeoJSON() as any);
    try {
      applyHexLayerVisibility(map, layersRef.current);
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
                {legend.legend.map(({ color, label }) => (
                  <div key={label} className="flex items-center gap-2.5">
                    <div className="w-2.5 h-2.5 rounded-[3px] flex-shrink-0" style={{ backgroundColor: color }} />
                    <span className="text-[10px] text-[#667066] leading-tight">{label}</span>
                  </div>
                ))}
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
