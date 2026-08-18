'use client';

/**
 * Runtime SDF circle icons for the point-rendered layers.
 *
 * Point layers are symbol layers drawn over the hex PMTiles source: a MapLibre
 * `circle` layer draws one circle per polygon *vertex* (six per hexagon), while
 * a `symbol` layer places exactly one icon at each polygon's pole of
 * inaccessibility — the centre of a regular hexagon. The icons are generated
 * here instead of being pulled from a sprite so nothing in the point layers
 * reaches into the basemap style.
 */

import type maplibregl from 'maplibre-gl';

export const POINT_ICON_ID = 'naturegap-point';

/**
 * MapLibre's SDF alpha encoding (symbol_sdf.fragment.glsl): alpha 192 sits on
 * the shape edge, and one pixel of distance is 32 alpha units (256 / SDF_PX,
 * SDF_PX = 8). Values above the edge are inside the shape.
 */
const SDF_EDGE_ALPHA = 192;
const SDF_ALPHA_PER_PX = 32;
const ICON_PX = 24;
const ICON_RADIUS_PX = 9;

function circleSdfImage(size: number, radius: number) {
  const data = new Uint8Array(size * size * 4);
  const centre = (size - 1) / 2;

  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      const dx = x - centre;
      const dy = y - centre;
      const insidePx = radius - Math.sqrt(dx * dx + dy * dy);
      const alpha = Math.max(0, Math.min(255, Math.round(SDF_EDGE_ALPHA + insidePx * SDF_ALPHA_PER_PX)));
      const i = (y * size + x) * 4;
      data[i] = 255;
      data[i + 1] = 255;
      data[i + 2] = 255;
      data[i + 3] = alpha;
    }
  }

  return { width: size, height: size, data };
}

/** Idempotent — MapView re-runs this whenever the style reloads. */
export function registerPointIcons(map: maplibregl.Map) {
  if (map.hasImage(POINT_ICON_ID)) return;
  map.addImage(POINT_ICON_ID, circleSdfImage(ICON_PX, ICON_RADIUS_PX), { sdf: true });
}
