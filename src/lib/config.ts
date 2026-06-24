/**
 * City-level and methodology configuration.
 * All values that would change for a second city live here.
 * Nothing in this file is hardcoded inside components.
 */

// ── City identity ────────────────────────────────────────────────────────────

export const CITY = {
  name:   'Yokohama',
  nameJa: '横浜市',
  badge:  'Yokohama · Beta',
  country: 'Japan',
} as const;

// ── Map defaults ─────────────────────────────────────────────────────────────

export const MAP_CONFIG = {
  /** Initial map center — Honmoku Sancho Park centroid. */
  center:    [139.6606, 35.4255] as [number, number],
  zoom:      17,
  minZoom:   9,
  maxZoom:   20,
  /** OpenFreeMap Positron — free, no API key, Carto-Positron-compatible style. */
  basemapUrl: 'https://tiles.openfreemap.org/styles/positron',
  /** Fonts available on the OpenFreeMap tile server. */
  mapFonts:  ['Noto Sans Regular', 'Arial Unicode MS Regular'] as string[],
} as const;

// ── Hex grid ─────────────────────────────────────────────────────────────────

export const HEX_CONFIG = {
  /** Circumradius in metres — must match pipeline/06_export/export.R. */
  radiusM: 10,
  /** Score clamp applied during synthetic hex generation. */
  minScore: -48,
  maxScore:  48,
} as const;

// ── Score methodology ─────────────────────────────────────────────────────────
//
// These thresholds define the 5-band ecological residual scale.
// They are used in utils.ts, ScoreGauge.tsx, park-data.ts, and the
// data-contract.md colour table — change them here only.

export const SCORE_THRESHOLDS = {
  /** score < MUCH_WORSE  → "Much worse than expected" */
  MUCH_WORSE: -20,
  /** score < WORSE       → "Worse than expected" */
  WORSE:      -10,
  /** score < AS_EXPECTED → "As expected" */
  AS_EXPECTED:  5,
  /** score < BETTER      → "Better than expected" */
  BETTER:      15,
  // score >= BETTER      → "Much better than expected"

  /** Badge switches to "underperforming" style below this value. */
  BADGE_UNDERPERFORMING: -5,

  /** Default gauge range. */
  GAUGE_MIN: -50,
  GAUGE_MAX:  50,
} as const;

export const SCORE_COLORS = {
  MUCH_WORSE:  '#C95B4B',
  WORSE:       '#E8A44C',
  AS_EXPECTED: '#B8C9AE',
  BETTER:      '#73A56D',
  MUCH_BETTER: '#2E6F40',
} as const;

// ── Supabase storage ──────────────────────────────────────────────────────────

export const STORAGE = {
  PIPELINE_BUCKET: 'pipeline-export',
  /** Must match CITY_ID in pipeline/config.R — files live at <BUCKET>/<CITY_ID>/filename */
  CITY_ID:         'yokohama-honmoku',
  PARK_STATS_KEY:  'park-stats.json',
  CELLS_KEY:       'cells.json',
  CELLS_MANIFEST_KEY: 'cells.manifest.json',
  HEXGRID_MANIFEST_KEY: 'hexgrid.manifest.json',
} as const;

/** Must match MAX_EXPECTED_RICHNESS in pipeline/config.R */
export const MAX_EXPECTED_RICHNESS = 350;

// ── Pipeline raster layers (PMTiles from export step 06) ─────────────────────

export type RasterLayerId = 'habitat' | 'ndvi' | 'lst';

export const RASTER_LAYERS: Record<
  RasterLayerId,
  { file: string; sourceId: string; layerId: string; opacity: number }
> = {
  habitat: {
    file: 'habitat_quality.pmtiles',
    sourceId: 'raster-habitat',
    layerId: 'raster-habitat',
    opacity: 0.55,
  },
  ndvi: {
    file: 'ndvi.pmtiles',
    sourceId: 'raster-ndvi',
    layerId: 'raster-ndvi',
    opacity: 0.6,
  },
  lst: {
    file: 'lst.pmtiles',
    sourceId: 'raster-lst',
    layerId: 'raster-lst',
    opacity: 0.55,
  },
};
