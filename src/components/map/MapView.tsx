'use client';

import { useEffect, useRef, useState } from 'react';
import maplibregl from 'maplibre-gl';
import { getCityLayerStats, wardCentroidsGeoJSON } from '@/lib/data';
import { CITY, MAP_CONFIG } from '@/lib/config';
import { listHexPmtilesDatasets } from '@/lib/pmtiles-storage';
import type { RenderCellProperties } from '@/lib/cell-detail';
import type { MapLayer } from '@/lib/types';
import {
  CORRIDOR_LINES_LAYER_ID,
  hasHexOverlay,
  type HexLayerId,
  hexFillColorExpression,
  hexFillOpacityForLayer,
  getEnabledLayerIds,
  INTERVENTION_RANK_BADGES_LAYER_ID,
  INTERVENTION_RANK_LABELS_LAYER_ID,
  LAYER_DRAW_ORDER,
  LAYER_STYLE_SPECS,
  PATCH_FILL_LAYER_IDS,
  PATCH_FILL_LAYER_ORDER,
  patchFillColorExpressionForCities,
  patchFillOpacityExpression,
  PATCH_OUTLINE_LAYER_ID,
} from '@/lib/layer-styles';
import {
  emptyFeatureCollection,
  fetchCorridorLinksGeoJSON,
  parkCentroidsGeoJSON,
  parkPolygonsGeoJSON,
  registerPmtilesProtocol,
  renderCellProperties,
} from '@/lib/map-utils';
import {
  createPopupContent,
} from '@/lib/map-markers';
import {
  activeThematicLayerId,
  applyCitizenLayerVisibility,
  applyLayerPaintExpressions,
  fitMapToPmtilesDatasets,
  getHexDatasets,
  hexFillLayerIdForDataset,
  hexInteractiveLayerIds,
  hexOutlineLayerId,
  hexSelectedLayerId,
  refreshHexLayers,
  cityIdFromHexLayerId,
  selectedHexFilter,
  setHexDatasets,
  setLayerVisibility,
  visibleHexInteractiveLayerIds,
} from '@/lib/map-layers';

interface MapViewProps {
  layers: MapLayer[];
  selectedCellId: string | null;
  /** cityId of whatever's currently selected/displayed — drives the legend's numeric ranges. */
  displayCityId?: string;
  onHexClick: (
    cell: RenderCellProperties,
    coordinates: [number, number],
  ) => void;
  onParkClick?: (parkId: string, coordinates: [number, number]) => void;
  flyToTarget?: { center: [number, number]; zoom: number } | null;
  dataRevision?: number;
  structuredSurveysGeoJSON?: GeoJSON.FeatureCollection;
  surveyPointsGeoJSON?: GeoJSON.FeatureCollection;
  selectedSurveyPointId?: string | null;
  onSurveyPointSelect?: (id: string, coordinates: [number, number]) => void;
}

const DETAIL_ZOOM = 14;

export default function MapView({
  layers,
  selectedCellId,
  displayCityId,
  onHexClick,
  onParkClick,
  flyToTarget,
  dataRevision,
  structuredSurveysGeoJSON,
  surveyPointsGeoJSON,
  selectedSurveyPointId,
  onSurveyPointSelect,
}: MapViewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const popupRef = useRef<maplibregl.Popup | null>(null);
  const onClickRef = useRef(onHexClick);
  const onParkClickRef = useRef(onParkClick);
  const layersAddedRef = useRef(false);
  const layersRef = useRef(layers);
  const onSurveyPointSelectRef = useRef(onSurveyPointSelect);
  const structuredSurveysRef = useRef<GeoJSON.FeatureCollection | undefined>(structuredSurveysGeoJSON);
  const surveyPointsRef = useRef<GeoJSON.FeatureCollection | undefined>(surveyPointsGeoJSON);
  const displayCityIdRef = useRef(displayCityId ?? CITY.id);
  const [mapZoom, setMapZoom] = useState<number>(MAP_CONFIG.zoom);
  const enabledLayerIds = getEnabledLayerIds(layers);
  const activeThematic = activeThematicLayerId(layers);
  const enabledLegends = enabledLayerIds.map((id: HexLayerId) => LAYER_STYLE_SPECS[id]);

  useEffect(() => {
    onClickRef.current = onHexClick;
  }, [onHexClick]);

  useEffect(() => {
    onParkClickRef.current = onParkClick;
  }, [onParkClick]);

  useEffect(() => {
    layersRef.current = layers;
  }, [layers]);

  useEffect(() => {
    displayCityIdRef.current = displayCityId ?? CITY.id;
  }, [displayCityId]);

  useEffect(() => {
    onSurveyPointSelectRef.current = onSurveyPointSelect;
  }, [onSurveyPointSelect]);

  useEffect(() => {
    structuredSurveysRef.current = structuredSurveysGeoJSON;
    surveyPointsRef.current = surveyPointsGeoJSON;
  }, [structuredSurveysGeoJSON, surveyPointsGeoJSON]);

  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;
    registerPmtilesProtocol();
    const pmtilesDatasetsPromise = listHexPmtilesDatasets();

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

      const initialCityStats = getCityLayerStats();
      const initialCityIds = Array.from(new Set(initialCityStats.map((stat) => stat.cityId)));
      for (const layerId of PATCH_FILL_LAYER_ORDER) {
        map.addLayer({
          id: PATCH_FILL_LAYER_IDS[layerId],
          type: 'fill',
          source: 'parks',
          maxzoom: DETAIL_ZOOM,
          layout: { visibility: 'none' },
          paint: {
            'fill-color': patchFillColorExpressionForCities(layerId, initialCityIds, initialCityStats),
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

      layersAddedRef.current = true;
      refreshHexLayers(map, layersRef.current);

      void (async () => {
        const pmtilesDatasets = await pmtilesDatasetsPromise;
        if (mapRef.current !== map) return;
        if (pmtilesDatasets.length === 0) {
          console.warn('[MapView] No hexgrid PMTiles datasets available.');
          return;
        }

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
              minzoom: DETAIL_ZOOM,
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
            minzoom: DETAIL_ZOOM,
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
            minzoom: DETAIL_ZOOM,
            filter: selectedHexFilter(null),
            paint: {
              'fill-color': '#1F2A1F',
              'fill-opacity': 0.25,
              'fill-outline-color': '#1F2A1F',
            },
          });
        }

        await fitMapToPmtilesDatasets(map, pmtilesDatasets);
        if (mapRef.current !== map) return;
        refreshHexLayers(map, layersRef.current);

        const onHexSourceData = (event: maplibregl.MapSourceDataEvent) => {
          if (!pmtilesDatasets.some((dataset) => dataset.sourceId === event.sourceId)) return;
          if (!map.isSourceLoaded(event.sourceId)) return;
          refreshHexLayers(map, layersRef.current);
        };
        map.on('sourcedata', onHexSourceData);

        map.once('idle', () => {
          if (mapRef.current !== map) return;
          refreshHexLayers(map, layersRef.current);
        });
      })();

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

      map.on('zoom', () => {
        setMapZoom(map.getZoom());
      });
      setMapZoom(map.getZoom());

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
        const interactiveLayerIds = visibleHexInteractiveLayerIds(map);
        const hexFeatures = interactiveLayerIds.length
          ? map.queryRenderedFeatures(e.point, { layers: interactiveLayerIds })
          : [];
        const f = hexFeatures[0];
        if (!f) return;
        e.preventDefault();
        const props = renderCellProperties(f.properties);
        if (!props) return;
        onClickRef.current(
          { ...props, cityId: cityIdFromHexLayerId(map, f.layer.id) ?? props.cityId },
          [e.lngLat.lng, e.lngLat.lat],
        );
      });

      map.on('click', 'park-area', (e) => {
        if (e.defaultPrevented) return;
        const interactiveLayerIds = visibleHexInteractiveLayerIds(map);
        const hexFeatures = interactiveLayerIds.length
          ? map.queryRenderedFeatures(e.point, { layers: interactiveLayerIds })
          : [];
        const props = renderCellProperties(hexFeatures[0]?.properties);
        if (props) {
          e.preventDefault();
          const hexFeature = hexFeatures[0];
          onClickRef.current(
            {
              ...props,
              cityId: hexFeature
                ? cityIdFromHexLayerId(map, hexFeature.layer.id) ?? props.cityId
                : props.cityId,
            },
            [e.lngLat.lng, e.lngLat.lat],
          );
          return;
        }
        // At hex zoom the panel is cell-scoped — never open park-level aggregates.
        if (map.getZoom() >= DETAIL_ZOOM) return;
        const parkId = e.features?.[0]?.properties?.parkId;
        if (typeof parkId === 'string') {
          e.preventDefault();
          onParkClickRef.current?.(parkId, [e.lngLat.lng, e.lngLat.lat]);
        }
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
        setLayerVisibility(map, activeThematicLayerId(layers), layers);
        applyLayerPaintExpressions(map);
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
    const centroidSrc = map.getSource('park-centroids') as maplibregl.GeoJSONSource | undefined;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    parkSrc?.setData(parkPolygonsGeoJSON() as any);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    centroidSrc?.setData(parkCentroidsGeoJSON() as any);
    try {
      refreshHexLayers(map, layersRef.current);
    } catch { /* ignore */ }
  }, [dataRevision]);

  useEffect(() => {
    if (!mapRef.current || !layersAddedRef.current) return;
    const map = mapRef.current;
    const surveyPoints = map.getSource('survey-points') as maplibregl.GeoJSONSource | undefined;
    const structuredSurveys = map.getSource('structured-surveys') as maplibregl.GeoJSONSource | undefined;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    surveyPoints?.setData((surveyPointsGeoJSON ?? { type: 'FeatureCollection', features: [] }) as any);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    structuredSurveys?.setData((structuredSurveysGeoJSON ?? { type: 'FeatureCollection', features: [] }) as any);
  }, [structuredSurveysGeoJSON, surveyPointsGeoJSON]);

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
                    const statsList = getCityLayerStats(displayCityId ?? CITY.id);
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
                      } else if (s.metric === 'canopy_height_idx') {
                        if (isTop && s.p95 != null) formattedLabel = `${label} (> ${Math.round(s.p95 * 20)} m)`;
                        else if (isBottom && s.p05 != null) formattedLabel = `${label} (< ${Math.round(s.p05 * 20)} m)`;
                      } else if (['habitat_quality', 'lst_idx', 'betweenness_centrality'].includes(s.metric)) {
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
