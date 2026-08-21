'use client';

import { useEffect, useRef, useState } from 'react';
import maplibregl from 'maplibre-gl';
import { getCityLayerStats, wardCentroidsGeoJSON } from '@/lib/data';
import { CITY, MAP_CONFIG } from '@/lib/config';
import { hexDatasetsForMapView, listHexPmtilesDatasets } from '@/lib/pmtiles-storage';
import type { RenderCellProperties } from '@/lib/cell-detail';
import type { MapLayer } from '@/lib/types';
import {
  biodiversityCellLayout,
  biodiversityCellPaint,
  CORRIDOR_LINES_LAYER_ID,
  NETWORK_NODE_MAJOR_LAYER_ID,
  NETWORK_NODE_SECONDARY_LAYER_ID,
  NETWORK_NODE_STEPPING_LAYER_ID,
  corridorLineColor,
  corridorLineWidth,
  corridorLineOpacity,
  networkNodeRadius,
  networkNodeFill,
  networkNodeOpacity,
  networkNodeMinZoom,
  hasHexOverlay,
  hexFillAntialias,
  hexFillOutlineColor,
  hexOutlineOverlayPaint,
  type HexLayerId,
  hexFillColorExpression,
  hexFillOpacityForLayer,
  getEnabledLayerIds,
  INTERVENTION_RANK_BADGES_LAYER_ID,
  INTERVENTION_RANK_LABELS_LAYER_ID,
  LAYER_DRAW_ORDER,
  LAYER_STYLE_SPECS,
  overviewPointPaint,
  PATCH_FILL_LAYER_IDS,
  PATCH_FILL_LAYER_ORDER,
  patchFillColorExpressionForCities,
  patchFillOpacityExpression,
  PATCH_OUTLINE_LAYER_ID,
  POINT_LAYER_IDS,
  POINT_LAYER_ORDER,
  pointLayerFilter,
} from '@/lib/layer-styles';
import { registerPointIcons } from '@/lib/map-icons';
import {
  emptyFeatureCollection,
  fetchConnectivityNetworkEdges,
  fetchConnectivityNetworkNodes,
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
  pointLayerIdForDataset,
  refreshHexLayers,
  cityIdForViewport,
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
  flyToTarget?: { center: [number, number]; zoom: number } | { cityId: string } | null;
  dataRevision?: number;
  structuredSurveysGeoJSON?: GeoJSON.FeatureCollection;
  surveyPointsGeoJSON?: GeoJSON.FeatureCollection;
  selectedSurveyPointId?: string | null;
  onSurveyPointSelect?: (id: string, coordinates: [number, number]) => void;
  /** Fires when the view moves over a different city's exported extent. */
  onViewCityChange?: (cityId: string | undefined) => void;
}

// Must match --minimum-zoom in pipeline/06_export/export.R and HEX_REGIME.far
// in lib/layer-styles.ts: the hexgrid PMTiles archives contain no tiles below
// this zoom, so lowering it here alone would just make MapLibre request tiles
// that 404. Archives exported before this was 11 can be extended in place with
// scripts/backfill-low-zoom-tiles.mjs instead of re-running the R pipeline.
const DETAIL_ZOOM = 11;

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
  onViewCityChange,
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
  const onViewCityChangeRef = useRef(onViewCityChange);
  const viewCityIdRef = useRef<string | undefined>(undefined);
  const pendingCityFocusRef = useRef<string | undefined>(undefined);
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
    onViewCityChangeRef.current = onViewCityChange;
  }, [onViewCityChange]);

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

    const reportViewCity = () => {
      const cityId = cityIdForViewport(map);
      if (cityId === viewCityIdRef.current) return;
      viewCityIdRef.current = cityId;
      onViewCityChangeRef.current?.(cityId);
    };

    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-left');
    map.addControl(new maplibregl.AttributionControl({ compact: true }), 'bottom-right');

    map.on('load', async () => {
      map.addSource('parks', { type: 'geojson', data: parkPolygonsGeoJSON() });
      map.addSource('park-centroids', { type: 'geojson', data: parkCentroidsGeoJSON() });
      // Derived ecological network: corridor centrelines and tiered nodes. Two
      // small GeoJSON exports rather than the 20 m cell source, so the overview
      // scale can show a network instead of a hexagonal raster.
      map.addSource('corridor-network', { type: 'geojson', data: emptyFeatureCollection() });
      map.addSource('network-nodes', { type: 'geojson', data: emptyFeatureCollection() });
      void fetchConnectivityNetworkEdges().then((fc) => {
        if (mapRef.current !== map) return;
        const source = map.getSource('corridor-network') as maplibregl.GeoJSONSource | undefined;
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        source?.setData(fc as any);
      }).catch(() => {
        /* Layers stay empty until 04_connectivity + 06_export have produced the network. */
      });
      void fetchConnectivityNetworkNodes().then((fc) => {
        if (mapRef.current !== map) return;
        const source = map.getSource('network-nodes') as maplibregl.GeoJSONSource | undefined;
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        source?.setData(fc as any);
      }).catch(() => {
        /* As above. */
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

      registerPointIcons(map);

      // Overview representation for the point layers. The hex source has no
      // tiles below DETAIL_ZOOM, so below that a point layer falls back to one
      // point per green space rather than to a fill. No aggregation happens
      // here — these are the park-level values the pipeline already exported.
      for (const layerId of POINT_LAYER_ORDER) {
        map.addLayer({
          id: POINT_LAYER_IDS[layerId].overview,
          type: 'circle',
          source: 'park-centroids',
          // Below z10 a dot per green space across every loaded city is noise
          // rather than information, so the layer simply drops out.
          minzoom: 10,
          maxzoom: DETAIL_ZOOM,
          filter: pointLayerFilter(),
          layout: { visibility: 'none' },
          paint: overviewPointPaint(layerId, initialCityIds, initialCityStats),
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
        maxzoom: DETAIL_ZOOM,
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

        const activeHexDatasets = hexDatasetsForMapView(pmtilesDatasets);
        setHexDatasets(map, activeHexDatasets);

        for (const dataset of activeHexDatasets) {
          map.addSource(dataset.sourceId, {
            type: 'vector',
            url: `pmtiles://${dataset.publicUrl}`,
            minzoom: DETAIL_ZOOM,
            maxzoom: dataset.maxZoom,
            bounds: dataset.bounds,
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
                // See HEX_REGIME in layer-styles.ts. These two properties are the
                // whole zoom progression: antialiasing off at city zoom removes
                // the per-cell edge feather that made the grid read as a
                // honeycomb, and the cell outline fades in only once cells are
                // large enough to be worth inspecting individually.
                'fill-antialias': hexFillAntialias(),
                'fill-outline-color': hexFillOutlineColor(),
              },
            });
          }

          // Biodiversity's point representation over the same hex source. A
          // `circle` layer on polygon geometry would draw one circle per hexagon
          // vertex; a `symbol` layer places exactly one icon at the polygon's
          // pole of inaccessibility, which for a regular hexagon is its centre.
          // Each icon therefore stands on its own 20 m analytical cell and
          // carries that cell's cellId.
          map.addLayer({
            id: pointLayerIdForDataset(dataset.sourceId, 'biodiversity'),
            type: 'symbol',
            source: dataset.sourceId,
            'source-layer': dataset.sourceLayer,
            minzoom: DETAIL_ZOOM,
            filter: pointLayerFilter(),
            layout: biodiversityCellLayout(),
            paint: biodiversityCellPaint(),
          });

          // Optional inspection aid, off by default (MAP_LAYERS 'cell-grid').
          // Starts hidden so it can never flash a full-city honeycomb in the
          // frames before refreshHexLayers() syncs overlay visibility.
          map.addLayer({
            id: hexOutlineLayerId(dataset.sourceId),
            type: 'line',
            source: dataset.sourceId,
            'source-layer': dataset.sourceLayer,
            minzoom: DETAIL_ZOOM,
            layout: { visibility: 'none' },
            paint: hexOutlineOverlayPaint(),
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

        // Preferred city, not every loaded dataset: fitting Porto + Amsterdam +
        // Yokohama together produces a near-world view, which no maxZoom can
        // pull back into the hex regime because fitBounds has to zoom *out* to
        // contain them. One city's AOI fits comfortably inside MAP_CONFIG.zoom.
        const focusCityId = pendingCityFocusRef.current ?? displayCityIdRef.current;
        await fitMapToPmtilesDatasets(map, activeHexDatasets, focusCityId);
        pendingCityFocusRef.current = undefined;
        if (mapRef.current !== map) return;
        refreshHexLayers(map, layersRef.current);
        // Datasets only become known here, so the initial view has to be
        // re-evaluated once — 'moveend' has already fired by this point.
        reportViewCity();

        const hexSourcesStyled = new Set<string>();
        const onHexSourceData = (event: maplibregl.MapSourceDataEvent) => {
          if (event.sourceDataType !== 'metadata') return;
          if (!activeHexDatasets.some((dataset) => dataset.sourceId === event.sourceId)) return;
          if (hexSourcesStyled.has(event.sourceId)) return;
          hexSourcesStyled.add(event.sourceId);
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
        source: 'corridor-network',
        layout: { visibility: 'none', 'line-cap': 'round', 'line-join': 'round' },
        paint: {
          'line-color': corridorLineColor(),
          'line-width': corridorLineWidth(),
          'line-opacity': corridorLineOpacity(),
        },
      });

      // Nodes drawn over the corridors, weakest tier first so a major node is
      // never occluded by a stepping stone sitting on the same cell.
      ([
        ['stepping-stone', NETWORK_NODE_STEPPING_LAYER_ID],
        ['secondary', NETWORK_NODE_SECONDARY_LAYER_ID],
        ['major', NETWORK_NODE_MAJOR_LAYER_ID],
      ] as const).forEach(([tier, layerId]) => {
        map.addLayer({
          id: layerId,
          type: 'circle',
          source: 'network-nodes',
          minzoom: networkNodeMinZoom(tier),
          filter: ['==', ['get', 'tier'], tier],
          layout: { visibility: 'none' },
          paint: {
            'circle-radius': networkNodeRadius(tier),
            'circle-color': tier === 'secondary' ? '#FFFFFF' : networkNodeFill(tier),
            'circle-opacity': networkNodeOpacity(),
            // Secondary nodes read as hollow rings, matching the legend's ○.
            'circle-stroke-width': tier === 'stepping-stone' ? 0 : tier === 'secondary' ? 1.5 : 1,
            'circle-stroke-color': tier === 'secondary' ? networkNodeFill('secondary') : '#FFFFFF',
            'circle-stroke-opacity': networkNodeOpacity(),
          },
        });
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

      map.on('moveend', reportViewCity);

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
      // Real coordinates, so: small, opaque, hard-edged. Deliberately unlike the
      // large translucent cell-count markers, which stand for "this 20 m cell
      // contains N records" rather than for a record at that spot.
      map.addLayer({
        id: 'survey-points-layer',
        type: 'circle',
        source: 'survey-points',
        minzoom: 14,
        paint: {
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 14, 3, 18, 6],
          'circle-color': '#1F2A1F',
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 1.5,
          'circle-opacity': 1,
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
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 14, 3, 18, 5.5],
          'circle-color': ['case', ['get', 'submitted'], '#2E6F40', '#B07A2A'],
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 1.5,
          'circle-opacity': 1,
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
        if (!f) {
          // Leaving a tile onto empty map clears the popup — the 'park-area'
          // handlers only fire while the cursor is over that layer.
          const parkFeatures = map.getLayer('park-area')
            ? map.queryRenderedFeatures(e.point, { layers: ['park-area'] })
            : [];
          if (parkFeatures.length === 0) {
            popupRef.current?.remove();
            popupRef.current = null;
          }
          return;
        }

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
    // Deliberately ungated. The obvious `if (map.isStyleLoaded()) ... else
    // map.once('load'|'idle', ...)` is wrong twice over: `load` fires exactly
    // once at startup, so anything queued on it later is dropped for good, and
    // isStyleLoaded() is `!style._changed && sourcesLoaded` — _changed only
    // clears inside a render frame, so it sticks true whenever the render loop
    // is throttled (background tab, low-power mode), which also stops `idle`
    // firing. Observed here with every source loaded and areTilesLoaded true.
    // apply() is safe to call at any time: it is wrapped in try/catch and the
    // helpers it calls check map.getLayer() per layer. styledata is the
    // catch-up for the genuine early case where the layers do not exist yet;
    // unlike `load` it fires on every style mutation.
    apply();
    map.once('styledata', apply);
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

    // Ungated for the reason spelled out in the selected-cell effect above.
    // This is the one where it showed: a layer toggle arriving while
    // isStyleLoaded() was false left the sidebar and legend on the newly picked
    // layer while the map went on drawing the previous one, permanently.
    apply();
    map.once('styledata', apply);
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
    const map = mapRef.current;
    if ('cityId' in flyToTarget) {
      pendingCityFocusRef.current = flyToTarget.cityId;
      const datasets = getHexDatasets(map);
      if (datasets.length === 0) return;
      void fitMapToPmtilesDatasets(map, datasets, flyToTarget.cityId, {
        duration: 900,
        requirePreferred: true,
      });
      pendingCityFocusRef.current = undefined;
      return;
    }
    pendingCityFocusRef.current = undefined;
    map.flyTo({ center: flyToTarget.center, zoom: flyToTarget.zoom, duration: 900 });
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
                {legend.legend.map(({ color, label, symbol }, i, arr) => {
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
                      <span className="w-2.5 h-2.5 flex-shrink-0 flex items-center justify-center">
                        {symbol === 'line' ? (
                          <span className="w-2.5 h-[2px] rounded-full" style={{ backgroundColor: color }} />
                        ) : symbol === 'node-major' ? (
                          <span className="w-2.5 h-2.5 rounded-full" style={{ backgroundColor: color }} />
                        ) : symbol === 'node-secondary' ? (
                          <span
                            className="w-[7px] h-[7px] rounded-full border-[1.5px]"
                            style={{ borderColor: color, backgroundColor: 'transparent' }}
                          />
                        ) : symbol === 'node-stepping' ? (
                          <span className="w-[4px] h-[4px] rounded-full" style={{ backgroundColor: color }} />
                        ) : (
                          <span className="w-2.5 h-2.5 rounded-[3px]" style={{ backgroundColor: color }} />
                        )}
                      </span>
                      <span className="text-[10px] text-[#667066] leading-tight">{formattedLabel}</span>
                    </div>
                  );
                })}
              </div>
              {legend.note && (
                <p className="text-[9px] text-[#A8B4A8] leading-snug mt-2.5 max-w-[190px]">
                  {legend.note}
                </p>
              )}
            </div>
          ))
        )}
      </div>
    </div>
  );
}
