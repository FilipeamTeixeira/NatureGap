/**
 * City-level and methodology configuration.
 * All values that would change for a second city live here.
 * Nothing in this file is hardcoded inside components.
 */

// ── City identity ────────────────────────────────────────────────────────────

export const CITY = {
  /** Pipeline city slug — must match pipeline-export/<id>/ and city_layer_stats.city_id. */
  id:     'porto-center',
  name:   'Porto',
  nameJa: 'Porto',
  badge:  'Porto · Beta',
  country: 'Portugal',
} as const;

// ── Multi-city registry ──────────────────────────────────────────────────────
//
// CITY above stays as the default/fallback city. Anything that displays the
// name of whatever's actually on screen (a selected cell, a selected ward,
// the sidebar location label) should look itself up here by cityId instead.

export interface CityMeta {
  name: string;
  nameJa: string;
  badge: string;
  country: string;
}

export const CITIES: Record<string, CityMeta> = {
  'yokohama-honmoku': {
    name:   'Yokohama',
    nameJa: '横浜市',
    badge:  'Yokohama · Beta',
    country: 'Japan',
  },
  'amsterdam-schimmelstraat': {
    name:   'Amsterdam',
    nameJa: 'Amsterdam',
    badge:  'Amsterdam · Beta',
    country: 'Netherlands',
  },
  'porto-center': {
    name:   'Porto',
    nameJa: 'Porto',
    badge:  'Porto · Beta',
    country: 'Portugal',
  },
};

/** Looks up display metadata for a cityId, falling back to the default CITY. */
export function cityMeta(cityId: string | null | undefined): CityMeta {
  return (cityId && CITIES[cityId]) || CITIES[CITY.id];
}

// ── Map defaults ─────────────────────────────────────────────────────────────

export const MAP_CONFIG = {
  /** Initial map center — Porto analysis extent centroid. */
  center:    [-8.6123, 41.1593] as [number, number],
  /**
   * Opening zoom, and the ceiling fitMapToPmtilesDatasets() fits to.
   *
   * Must be >= MapView's DETAIL_ZOOM (11), below which no hex tiles exist. 14
   * rather than 11 because it frames one city's analysis extent almost exactly
   * — Porto's is 7.2 km wide and a 1400 px map at z14 spans about 10 km — so
   * the view opens on the analytical surface filling the screen rather than on
   * a small patch adrift in a region.
   */
  zoom:      14,
  minZoom:   0,
  maxZoom:   20,
  /** OpenFreeMap Positron — free, no API key, Carto-Positron-compatible style. */
  basemapUrl: 'https://tiles.openfreemap.org/styles/positron',
  /** Single font stack — OpenFreeMap glyph URLs reject comma-separated fallbacks. */
  mapFonts:  ['Noto Sans Regular'] as string[],
} as const;

// ── Hex grid ─────────────────────────────────────────────────────────────────

// Unused by current code — the grid arrives pre-built in hexgrid.pmtiles. Kept
// as the documented cell geometry; there is no synthetic hex generation left.
export const HEX_CONFIG = {
  /** Circumradius in metres — half of CELL_SIZE in pipeline/config.R. */
  radiusM: 10,
  /** Legacy score clamp from synthetic hex generation. */
  minScore: -48,
  maxScore:  48,
} as const;

// ── Score methodology ─────────────────────────────────────────────────────────
//
// These thresholds define the 5-band Nature Gap score scale.
//
// The score is HIGHER THE WORSE a cell performs: residuals.R builds
// nature_gap_score from expected − observed richness plus habitat and
// connectivity deficits, so a positive score means fewer species recorded than
// the habitat predicts (pressure) and a negative score means more (surplus).
// See docs/methodology.md §8.
//
// Single source of truth for the band edges — used by utils.ts (colour/label),
// cell-detail.ts (ImpactStatus) and ScoreGauge.tsx. Change them here only.

export const SCORE_THRESHOLDS = {
  /** score < MUCH_BETTER → "Much better than expected" */
  MUCH_BETTER: -15,
  /** score < BETTER      → "Better than expected" */
  BETTER:       -5,
  /** score < AS_EXPECTED → "As expected" */
  AS_EXPECTED:  10,
  /** score < WORSE       → "Worse than expected" */
  WORSE:        20,
  // score >= WORSE       → "Much worse than expected"

  /** Badge switches to "underperforming" style above this value. */
  BADGE_UNDERPERFORMING: 5,

  /** Default gauge range. */
  GAUGE_MIN: -50,
  GAUGE_MAX: 100,
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
  /** Cities to try without relying on Supabase Storage list permissions. */
  PIPELINE_CITY_IDS: (process.env.NEXT_PUBLIC_PIPELINE_CITY_IDS ?? 'porto-center')
    .split(',')
    .map((city) => city.trim())
    .filter(Boolean),
  /** Logical export names resolved through pipeline-export/<city>/current.json. */
  PARK_STATS_KEY:  'park-stats.json',
  HEXGRID_PMTILES_KEY: 'hexgrid.pmtiles',
  HEXGRID_SOURCE_LAYER: 'hexgrid',
} as const;

/** Must match MAX_EXPECTED_RICHNESS in pipeline/config.R */
export const MAX_EXPECTED_RICHNESS = 350;
