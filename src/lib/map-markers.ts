/**
 * Popup content and marker sync helpers extracted from MapView.tsx
 * (step 3 of the MapView split — the final extraction, after
 * lib/map-utils.ts (step 1) and lib/map-layers.ts (step 2)).
 * No logic changes from the original functions.
 */

import maplibregl from 'maplibre-gl';
import { getParks, getParkStats, type GreenSpace } from '@/lib/green-spaces';
import type { MapLayer } from '@/lib/types';
import { layerEnabled } from '@/lib/map-layers';
import {
  finiteNumber,
  type ParkStats,
  polygonCentroid,
  primaryRing,
  safeColor,
  scoreColor,
} from '@/lib/map-utils';

export function createPopupContent({
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

export function clearLandUseDonutMarkers(markers: maplibregl.Marker[]) {
  for (const marker of markers) marker.remove();
  markers.length = 0;
}

export function applyLandUseDonutZoom(map: maplibregl.Map, markers: maplibregl.Marker[]) {
  const zoom = map.getZoom();
  const display = zoom <= 13 ? 'block' : 'none';
  for (const marker of markers) {
    marker.getElement().style.display = display;
  }
}

export function createLandUseDonutElement(park: GreenSpace, stats: ParkStats): HTMLElement | null {
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

export function syncLandUseDonutMarkers(
  map: maplibregl.Map,
  layers: MapLayer[],
  markers: maplibregl.Marker[],
  cityId: string,
) {
  clearLandUseDonutMarkers(markers);
  if (!layerEnabled(layers, 'landuse')) return;

  const statsByPark = getParkStats();
  // Parks from other cities can be geographically very far away (e.g. Yokohama
  // vs. Amsterdam); projecting their lng/lat while viewing a different city
  // places these DOM markers absurdly far off-screen. Restrict to the city
  // currently on screen — GL-rendered layers (patches, circles) don't need
  // this since they're naturally clipped to the viewport.
  for (const park of getParks().filter((p) => p.cityId === cityId)) {
    const stats = statsByPark[park.id];
    if (!stats) continue;
    const el = createLandUseDonutElement(park, stats);
    if (!el) continue;
    markers.push(new maplibregl.Marker({ element: el }).setLngLat(polygonCentroid(primaryRing(park.geometry))).addTo(map));
  }
  applyLandUseDonutZoom(map, markers);
}
