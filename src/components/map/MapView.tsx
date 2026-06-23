'use client';

import { useEffect, useRef } from 'react';
import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { WARD_GEOJSON, GLOBAL_STATS } from '@/lib/mock-data';
import { formatNumber } from '@/lib/utils';

interface MapViewProps {
  selectedCellId: string | null;
  onCellClick: (id: string) => void;
}

const LEGEND = [
  { color: '#16a34a', label: 'Much better than expected' },
  { color: '#22c55e', label: 'Better than expected' },
  { color: '#fbbf24', label: 'As expected' },
  { color: '#f59e0b', label: 'Worse than expected' },
  { color: '#dc2626', label: 'Much worse than expected' },
];

export default function MapView({ selectedCellId, onCellClick }: MapViewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const popupRef = useRef<maplibregl.Popup | null>(null);
  // Store callback in ref so the stable effect closure can always see the latest version
  const onClickRef = useRef(onCellClick);
  onClickRef.current = onCellClick;

  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;

    const map = new maplibregl.Map({
      container: containerRef.current,
      style: 'https://basemaps.cartocdn.com/gl/positron-gl-style/style.json',
      center: [139.595, 35.458],
      zoom: 10.6,
      minZoom: 9,
      maxZoom: 16,
      attributionControl: false,
    });

    mapRef.current = map;

    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-left');
    map.addControl(new maplibregl.AttributionControl({ compact: true }), 'bottom-right');

    map.on('load', () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      map.addSource('wards', { type: 'geojson', data: WARD_GEOJSON as any });

      // Circle fill
      map.addLayer({
        id: 'wards-circle',
        type: 'circle',
        source: 'wards',
        paint: {
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 9, 14, 11, 26, 13, 46],
          'circle-color': ['get', 'color'],
          'circle-opacity': 0.55,
          'circle-stroke-width': 1.5,
          'circle-stroke-color': ['get', 'color'],
          'circle-stroke-opacity': 0.85,
        },
      });

      // Selected highlight ring
      map.addLayer({
        id: 'wards-selected',
        type: 'circle',
        source: 'wards',
        filter: ['==', ['get', 'id'], ''],
        paint: {
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 9, 16, 11, 28, 13, 49],
          'circle-color': 'transparent',
          'circle-stroke-width': 2.5,
          'circle-stroke-color': '#1a1a1a',
          'circle-stroke-opacity': 1,
        },
      });

      // Ward name labels
      map.addLayer({
        id: 'wards-labels',
        type: 'symbol',
        source: 'wards',
        layout: {
          'text-field': ['get', 'nameJa'],
          'text-size': ['interpolate', ['linear'], ['zoom'], 10, 9, 13, 12],
          'text-font': ['Open Sans Regular', 'Arial Unicode MS Regular'],
          'text-anchor': 'center',
          'text-allow-overlap': false,
        },
        paint: {
          'text-color': '#ffffff',
          'text-halo-color': 'rgba(0,0,0,0.15)',
          'text-halo-width': 0.5,
        },
      });

      // Cursor and tooltip
      map.on('mouseenter', 'wards-circle', () => {
        map.getCanvas().style.cursor = 'pointer';
      });

      map.on('mouseleave', 'wards-circle', () => {
        map.getCanvas().style.cursor = '';
        popupRef.current?.remove();
        popupRef.current = null;
      });

      map.on('mousemove', 'wards-circle', (e) => {
        const feature = e.features?.[0];
        if (!feature) return;

        const { name, nameJa, score, color } = feature.properties as {
          name: string;
          nameJa: string;
          score: number;
          color: string;
        };
        const scoreStr = score > 0 ? `+${score}` : String(score);

        popupRef.current?.remove();
        popupRef.current = new maplibregl.Popup({
          closeButton: false,
          closeOnClick: false,
          offset: 34,
          className: 'naturegap-popup',
        })
          .setLngLat(e.lngLat)
          .setHTML(
            `<div style="font-family:Inter,system-ui,sans-serif;padding:10px 12px;min-width:140px;">
              <div style="font-weight:600;font-size:13px;color:#1a1a1a;margin-bottom:2px;">${name}</div>
              <div style="font-size:11px;color:#9ca3af;margin-bottom:6px;">${nameJa} · Yokohama</div>
              <div style="font-size:12px;font-weight:700;color:${color};">Impact score: ${scoreStr}</div>
            </div>`,
          )
          .addTo(map);
      });

      map.on('click', 'wards-circle', (e) => {
        const id = e.features?.[0]?.properties?.id as string | undefined;
        if (id) onClickRef.current(id);
      });
    });

    return () => {
      popupRef.current?.remove();
      map.remove();
      mapRef.current = null;
    };
  }, []); // stable — never re-runs

  // Update selected filter when prop changes
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;

    const apply = () => {
      try {
        map.setFilter('wards-selected', ['==', ['get', 'id'], selectedCellId ?? '']);
      } catch {
        // layer not ready yet
      }
    };

    if (map.isStyleLoaded()) {
      apply();
    } else {
      map.once('load', apply);
    }
  }, [selectedCellId]);

  return (
    <div className="relative w-full h-full">
      <div ref={containerRef} className="w-full h-full" />

      {/* Stats bar */}
      <div className="absolute bottom-0 left-0 right-0 bg-white/95 backdrop-blur-sm border-t border-[#e4e7e3] pointer-events-none">
        <div className="flex items-center gap-8 px-5 py-2.5">
          {[
            { label: 'Observations today', value: formatNumber(GLOBAL_STATS.observationsToday) },
            { label: 'Species observed', value: formatNumber(GLOBAL_STATS.speciesObserved) },
            { label: 'Areas improving', value: String(GLOBAL_STATS.areasImproving) },
          ].map(({ label, value }) => (
            <div key={label} className="flex items-baseline gap-2">
              <span className="text-sm font-semibold text-neutral-900">{value}</span>
              <span className="text-[11px] text-neutral-400">{label}</span>
            </div>
          ))}
        </div>
      </div>

      {/* Legend */}
      <div className="absolute top-12 right-3 bg-white/95 rounded-xl shadow-sm border border-[#e4e7e3] p-3">
        <p className="text-[9px] font-semibold text-neutral-400 uppercase tracking-widest mb-2.5">
          Nature Impact (gap)
        </p>
        {LEGEND.map(({ color, label }) => (
          <div key={label} className="flex items-center gap-2 py-0.5">
            <div
              className="w-2.5 h-2.5 rounded-full flex-shrink-0"
              style={{ backgroundColor: color }}
            />
            <span className="text-[10px] text-neutral-500">{label}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
