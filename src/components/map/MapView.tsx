'use client';

import { useEffect, useRef } from 'react';
import maplibregl from 'maplibre-gl';
import { wardCentroidsGeoJSON } from '@/lib/data';
import { getHexGrid } from '@/lib/hex-grid';
import { getParks } from '@/lib/green-spaces';
import { IMPACT_LEGEND } from '@/lib/utils';
import { MAP_CONFIG, type RasterLayerId } from '@/lib/config';
import type { MapLayer } from '@/lib/types';
import { syncRasterLayers } from '@/lib/pmtiles-loader';

interface MapViewProps {
  layers: MapLayer[];
  selectedCellId: string | null;
  onHexClick: (
    parkId: string,
    cellId: string,
    coordinates: [number, number],
    parkName?: string,
  ) => void;
  flyToTarget?: { center: [number, number]; zoom: number } | null;
  dataRevision?: number;
}


const LAYER_MAP: Partial<Record<string, string[]>> = {
  impact: ['hex-fill', 'hex-outline', 'hex-selected', 'park-area'],
  habitat: ['raster-habitat'],
  ndvi: ['raster-ndvi'],
  lst: ['raster-lst'],
};

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

function medianHexForPark(parkId: string) {
  const hexes = getHexGrid().features
    .filter((feature) => feature.properties?.parkId === parkId)
    .map((feature) => ({
      cellId: String(feature.properties?.cellId ?? ''),
      score: Number(feature.properties?.score),
    }))
    .filter((feature) => feature.cellId && !Number.isNaN(feature.score))
    .sort((a, b) => a.score - b.score);

  return hexes.length ? hexes[Math.floor(hexes.length / 2)] : null;
}

function createPopupContent({
  parkName,
  score,
  color,
  showScore,
}: {
  parkName?: string;
  score?: number;
  color?: string;
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
    value.style.color = safeColor(color);
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

export default function MapView({ layers, selectedCellId, onHexClick, flyToTarget, dataRevision }: MapViewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const popupRef = useRef<maplibregl.Popup | null>(null);
  const onClickRef = useRef(onHexClick);
  /** Set to true once our custom sources/layers have been added to the map. */
  const layersAddedRef = useRef(false);
  /** Latest layers prop — readable inside async map callbacks without stale closures. */
  const layersRef = useRef(layers);
  const impactLayerEnabled = layers.some((layer) => layer.id === 'impact' && layer.enabled);

  useEffect(() => {
    onClickRef.current = onHexClick;
  }, [onHexClick]);

  useEffect(() => {
    layersRef.current = layers;
  }, [layers]);

  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;

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

    map.on('load', () => {
      // ── Park polygon source (click zones + boundary) ───────────────────────
      map.addSource('parks', { type: 'geojson', data: parkPolygonsGeoJSON() });

      // Transparent fill — the primary click target (works at any zoom)
      map.addLayer({
        id: 'park-area',
        type: 'fill',
        source: 'parks',
        paint: { 'fill-color': '#3d6b2f', 'fill-opacity': 0 },
      });

      // ── Hex grid source ────────────────────────────────────────────────────
      const hexGrid = getHexGrid();
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      map.addSource('hexgrid', { type: 'geojson', data: hexGrid as any });

      map.addLayer({
        id: 'hex-fill',
        type: 'fill',
        source: 'hexgrid',
        paint: { 'fill-color': ['get', 'color'], 'fill-opacity': 0.65 },
      });

      map.addLayer({
        id: 'hex-outline',
        type: 'line',
        source: 'hexgrid',
        paint: { 'line-color': ['get', 'color'], 'line-width': 0.5, 'line-opacity': 0.8 },
      });

      map.addLayer({
        id: 'hex-selected',
        type: 'fill',
        source: 'hexgrid',
        filter: ['==', ['get', 'cellId'], ''],
        paint: { 'fill-color': ['get', 'color'], 'fill-opacity': 0.85 },
      });

      // ── Ward labels (on top) ───────────────────────────────────────────────
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

      // Mark our layers as ready and apply current visibility state
      layersAddedRef.current = true;
      for (const layer of layersRef.current) {
        const mlIds = LAYER_MAP[layer.id];
        if (!mlIds) continue;
        const vis = layer.enabled ? 'visible' : 'none';
        for (const id of mlIds) {
          try { map.setLayoutProperty(id, 'visibility', vis); } catch { /* ignore */ }
        }
      }

      // ── Cursor ────────────────────────────────────────────────────────────
      map.on('mouseenter', 'park-area', () => { map.getCanvas().style.cursor = 'pointer'; });
      map.on('mouseleave', 'park-area', () => {
        map.getCanvas().style.cursor = '';
        popupRef.current?.remove();
        popupRef.current = null;
      });

      // ── Hover tooltip — hex score when close enough, park name otherwise ──
      map.on('mousemove', 'hex-fill', (e) => {
        const f = e.features?.[0];
        if (!f) return;
        const { score, color, parkName } = f.properties as {
          score: number; color: string; parkName?: string;
        };
        const numericScore = Number(score);

        popupRef.current?.remove();
        popupRef.current = new maplibregl.Popup({
          closeButton: false, closeOnClick: false, offset: 8, className: 'naturegap-popup',
        })
          .setLngLat(e.lngLat)
          .setDOMContent(createPopupContent({
            parkName,
            score: numericScore,
            color,
            showScore: !Number.isNaN(numericScore),
          }))
          .addTo(map);
      });

      map.on('mousemove', 'park-area', (e) => {
        // Only show park-level tooltip when not over a hex (hex tooltip takes priority)
        const hexFeatures = map.queryRenderedFeatures(e.point, { layers: ['hex-fill'] });
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

      // ── Click — hex takes priority, park boundary is fallback ─────────────
      map.on('click', 'hex-fill', (e) => {
        e.preventDefault();
        const props = e.features?.[0]?.properties;
        if (!props) return;
        const parkId = String(props.parkId ?? '');
        const cellId = String(props.cellId ?? parkId);
        const parkName = props.parkName != null ? String(props.parkName) : undefined;
        if (!parkId || !cellId) return;
        onClickRef.current(parkId, cellId, [e.lngLat.lng, e.lngLat.lat], parkName);
      });

      map.on('click', 'park-area', (e) => {
        if (e.defaultPrevented) return;
        const props = e.features?.[0]?.properties;
        if (!props) return;
        const parkId = String(props.parkId ?? '');
        if (!parkId) return;
        const medianHex = medianHexForPark(parkId);
        const cellId = medianHex?.cellId ?? parkId;
        onClickRef.current(parkId, cellId, [e.lngLat.lng, e.lngLat.lat]);
      });
    });

    return () => {
      popupRef.current?.remove();
      map.remove();
      mapRef.current = null;
    };
  }, []);

  // ── Sync selected highlight ────────────────────────────────────────────────
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const apply = () => {
      try {
        map.setFilter('hex-selected', ['==', ['get', 'cellId'], selectedCellId ?? '']);
      } catch { /* style not ready */ }
    };
    if (map.isStyleLoaded()) apply();
    else map.once('load', apply);
  }, [selectedCellId]);

  // ── Sync layer visibility ──────────────────────────────────────────────────
  useEffect(() => {
    if (!mapRef.current || !layersAddedRef.current) return;
    const map = mapRef.current;

    for (const layer of layers) {
      const mlIds = LAYER_MAP[layer.id];
      if (!mlIds) continue;
      const vis = layer.enabled ? 'visible' : 'none';
      for (const id of mlIds) {
        try { map.setLayoutProperty(id, 'visibility', vis); } catch { /* ignore */ }
      }
    }

    const rasterEnabled = {
      habitat: layers.some((l) => l.id === 'habitat' && l.enabled),
      ndvi: layers.some((l) => l.id === 'ndvi' && l.enabled),
      lst: layers.some((l) => l.id === 'lst' && l.enabled),
    } satisfies Record<RasterLayerId, boolean>;

    void syncRasterLayers(map, rasterEnabled);
  }, [layers]);

  // ── Refresh hex + park sources when pipeline data loads from Storage ────────
  useEffect(() => {
    if (!mapRef.current || !layersAddedRef.current || dataRevision === 0) return;
    const map = mapRef.current;
    const hexSrc = map.getSource('hexgrid') as maplibregl.GeoJSONSource | undefined;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    hexSrc?.setData(getHexGrid() as any);
    const parkSrc = map.getSource('parks') as maplibregl.GeoJSONSource | undefined;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    parkSrc?.setData(parkPolygonsGeoJSON() as any);
  }, [dataRevision]);

  // ── Fly to a programmatic target (search selection) ───────────────────────
  useEffect(() => {
    if (!flyToTarget || !mapRef.current) return;
    mapRef.current.flyTo({ center: flyToTarget.center, zoom: flyToTarget.zoom, duration: 900 });
  }, [flyToTarget]);

  return (
    <div className="relative w-full h-full" style={{ minHeight: 0 }}>
      <div ref={containerRef} className="w-full h-full" style={{ position: 'absolute', inset: 0 }} />

      {impactLayerEnabled && (
        <div className="absolute top-3 right-3 bg-white/96 backdrop-blur-sm rounded-2xl border border-[#E4E7E1] p-4" style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}>
          <p className="text-[9px] font-semibold text-[#667066] uppercase tracking-widest mb-3">
            Nature Impact Gap
          </p>
          <div className="flex flex-col gap-1.5">
            {IMPACT_LEGEND.map(({ color, label }) => (
              <div key={label} className="flex items-center gap-2.5">
                <div className="w-2.5 h-2.5 rounded-[3px] flex-shrink-0" style={{ backgroundColor: color }} />
                <span className="text-[10px] text-[#667066] leading-tight">{label}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
