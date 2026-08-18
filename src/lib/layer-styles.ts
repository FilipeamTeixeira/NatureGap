import type {
  CircleLayerSpecification,
  ExpressionSpecification,
  FilterSpecification,
  LineLayerSpecification,
  SymbolLayerSpecification,
} from 'maplibre-gl';
import { POINT_ICON_ID } from './map-icons';
import type { CityLayerStats } from './data';
import type { LayerId } from './types';

export interface LayerLegendItem {
  color: string;
  label: string;
}

export interface LayerStyleSpec {
  title: string;
  /** Vector tile feature property for data-driven colouring. */
  property?: string;
  /** Raw metric name in city_layer_stats for legend bounds lookup. */
  rawMetric?: string;
  /** Shown under the legend — states what a mark on this layer actually is. */
  note?: string;
  legend: LayerLegendItem[];
}

/** Bottom → top draw order when multiple cell layers are enabled. */
export const LAYER_DRAW_ORDER = [
  'impact',
  'expected',
  'residual',
  'intervention',
  'habitat',
  'treecover',
  'biodiversity',
  'connectivity',
  'heat',
  'landuse',
] as const satisfies readonly LayerId[];

export type HexLayerId = (typeof LAYER_DRAW_ORDER)[number];
export const THEMATIC_LAYER_IDS = LAYER_DRAW_ORDER;

/** MapLibre layer IDs — must match the visualisation spec exactly. */
export const PATCH_OUTLINE_LAYER_ID = 'patch-outline-always';
export const HEX_OUTLINE_LAYER_ID = 'hex-outline-always';
export const CORRIDOR_LINES_LAYER_ID = 'corridor-lines';
export const INTERVENTION_RANK_BADGES_LAYER_ID = 'intervention-rank-badges';
export const INTERVENTION_RANK_LABELS_LAYER_ID = 'intervention-rank-labels';
export type PatchFillLayerId = HexLayerId;

export const PATCH_FILL_LAYER_IDS: Record<PatchFillLayerId, string> = {
  impact: 'nature-gap-patch-fill',
  expected: 'expected-richness-patch-fill',
  residual: 'ecological-residual-patch-fill',
  intervention: 'intervention-patch-fill',
  habitat: 'habitat-quality-patch-fill',
  treecover: 'tree-cover-patch-fill',
  biodiversity: 'biodiversity-patch-fill',
  connectivity: 'connectivity-patch-fill',
  heat: 'heat-exposure-patch-fill',
  landuse: 'land-use-patch-fill',
};

export const HEX_FILL_LAYER_IDS: Record<HexLayerId, string> = {
  impact: 'nature-gap-hex-fill',
  expected: 'expected-richness-hex-fill',
  residual: 'ecological-residual-hex-fill',
  intervention: 'intervention-hex-fill',
  habitat: 'habitat-quality-hex-fill',
  treecover: 'tree-cover-hex-fill',
  biodiversity: 'biodiversity-hex-fill',
  connectivity: 'connectivity-hex-fill',
  heat: 'heat-exposure-hex-fill',
  landuse: 'land-use-hex-fill',
};

export const PATCH_FILL_LAYER_ORDER = LAYER_DRAW_ORDER.filter(
  (id): id is PatchFillLayerId => id in PATCH_FILL_LAYER_IDS,
);

/**
 * How each thematic layer is drawn.
 *
 * A value that is fundamentally attached to the 20 m analytical cell stays on
 * the grid — including land use, whose classes come from WorldCover raster
 * fractions per cell rather than from any native polygon dataset, and canopy
 * height, which is a *mean over the cell's ~348 m²*. A mean over an area has no
 * location inside that area to put a mark on: the cell's value can come
 * entirely from trees along one edge while its centre sits in open water, so a
 * point there asserts a position the data never had. A continuous fill also
 * needs no presence threshold, and canopy height has no natural one — the
 * exported means are sub-metre nearly everywhere (87% of Amsterdam's cells
 * exceed 0 m, 54% exceed 1 m), so any cut-off for "draw a dot here" would be
 * arbitrary. Shading states the value instead of thresholding it.
 *
 * Only a discrete, countable per-cell quantity is drawn as points: nObs is a
 * record count, so a graduated symbol claims something the data supports and
 * `> 0` is a real threshold rather than an invented one. Connectivity is left
 * exactly as it was this iteration.
 */
export type LayerRepresentation = 'surface' | 'point';

export const LAYER_REPRESENTATION: Record<HexLayerId, LayerRepresentation> = {
  impact: 'surface',
  expected: 'surface',
  residual: 'surface',
  intervention: 'surface',
  habitat: 'surface',
  heat: 'surface',
  landuse: 'surface',
  connectivity: 'surface',
  treecover: 'surface',
  biodiversity: 'point',
};

export type PointLayerId = 'biodiversity';

export function isPointLayer(layerId: HexLayerId): layerId is PointLayerId {
  return LAYER_REPRESENTATION[layerId] === 'point';
}

/** Detail-zoom symbol layers over the hex source; overview circles over park centroids. */
export const POINT_LAYER_IDS: Record<PointLayerId, { detail: string; overview: string }> = {
  biodiversity: {
    detail: 'biodiversity-cell-points',
    overview: 'biodiversity-cell-points-overview',
  },
};

export const POINT_LAYER_ORDER = LAYER_DRAW_ORDER.filter(isPointLayer);

/**
 * Cartographic zoom regimes for the 20 m hex source.
 *
 * These are *drawing* thresholds only. Every cell keeps its exported value at
 * every zoom; nothing is aggregated, averaged or recomputed because the user
 * zoomed out. The breakpoints come from how wide a 20 m cell actually is on
 * screen — Web Mercator, so a cell covers more pixels at higher latitude:
 *
 *        Porto (41.2°N)   Amsterdam (52.4°N)
 *   z11        0.3 px            0.4 px
 *   z12        0.7 px            0.9 px
 *   z13        1.4 px            1.7 px
 *   z14        2.8 px            3.4 px
 *   z15        5.6 px            6.9 px
 *   z16       11.1 px           13.7 px
 *   z17       22.2 px           27.4 px
 *   z18       44.5 px           54.9 px
 *
 * Across the whole far regime a cell is smaller than a pixel or barely over it.
 * What made that read as a honeycomb was not the cell size but `fill-antialias`,
 * which is on by default and feathers every polygon edge: a 2.8 px hexagon is
 * mostly edge, so the whole grid rendered as a lattice of seams laid over the
 * colour. Turning antialiasing off makes adjacent fills abut exactly and the
 * field goes continuous — no data change, no new layer, no raster.
 *
 * Zooming in then reverses that in two stages, so the structure emerges instead
 * of appearing all at once:
 *
 *   far        z11   – 15.5  antialias off, no cell edge → continuous surface
 *   medium     z15.5 – 16.5  antialias on, edge still transparent → cells begin
 *                            to separate but the layer still reads as a field
 *   close      z16.5 – 18    cell edge fades in → hexagons clearly individual
 *   veryClose  z18 +         edge at full strength → explicit 20 m grid
 *
 * z11 is the floor because that is where the PMTiles archives start, which is
 * already wider than any city's analysis extent — Porto's is 7.2 x 4.3 km and
 * a z11 screen spans tens of kilometres. Below it the analytical layers draw
 * nothing rather than fall back to a different geometry; see hasOverviewFill().
 */
export const HEX_REGIME = {
  /** Hex source minzoom; must stay equal to MapView's DETAIL_ZOOM. */
  far: 11,
  medium: 15.5,
  close: 16.5,
  veryClose: 18,
} as const;

/**
 * The single most important property in this file.
 *
 * `fill-antialias` defaults to true, which is right for large polygons and
 * catastrophic for a 20 m grid at city zoom — see HEX_REGIME. Off below the
 * medium regime, on above it, which is also what starts revealing cell
 * structure as the user zooms in.
 */
export function hexFillAntialias(): ExpressionSpecification {
  return ['step', ['zoom'], false, HEX_REGIME.medium, true] as ExpressionSpecification;
}

/**
 * Per-cell edge on the analytical fill itself, so hexagons become legible
 * without the optional grid overlay having to be switched on. Fully
 * transparent until the close regime, so it cannot reintroduce the honeycomb
 * at wide zoom. MapLibre only draws this when fill-antialias is true, which
 * hexFillAntialias() guarantees from HEX_REGIME.medium up.
 */
export function hexFillOutlineColor(): ExpressionSpecification {
  // The first stop must be at HEX_REGIME.medium with alpha 0: `interpolate`
  // clamps to its first stop below that stop, so starting at .close would paint
  // a visible edge across the whole far regime and put the honeycomb straight
  // back. Antialiasing is off below .medium anyway — this keeps the two
  // properties agreeing rather than relying on that.
  return [
    'interpolate', ['linear'], ['zoom'],
    HEX_REGIME.medium, 'rgba(255,255,255,0)',
    HEX_REGIME.close, 'rgba(255,255,255,0.08)',
    HEX_REGIME.veryClose, 'rgba(255,255,255,0.22)',
    20, 'rgba(255,255,255,0.34)',
  ] as ExpressionSpecification;
}

/**
 * The optional 20 m grid overlay, ramped so that enabling it at city zoom
 * shows a faint hint rather than a wall of white. Independent of the fill: the
 * analytical surface never depends on this layer being on.
 */
export function hexOutlineOverlayPaint(): LineLayerSpecification['paint'] {
  return {
    'line-color': '#ffffff',
    'line-width': [
      'interpolate', ['linear'], ['zoom'],
      HEX_REGIME.far, 0.2,
      HEX_REGIME.close, 0.45,
      HEX_REGIME.veryClose, 0.7,
      20, 1,
    ],
    'line-opacity': [
      'interpolate', ['linear'], ['zoom'],
      HEX_REGIME.far, 0.10,
      HEX_REGIME.medium, 0.22,
      HEX_REGIME.close, 0.38,
      HEX_REGIME.veryClose, 0.55,
    ],
  } as LineLayerSpecification['paint'];
}

/**
 * No analytical layer has a park-polygon overview any more.
 *
 * Canopy height was already exempt, for a reason that turned out to apply to
 * every layer: shading a whole green space answers a different question than
 * the layer asks — "what is this park's average" rather than "where is it" —
 * and only the grid can answer the second. The park fills also came from a
 * different geometry entirely (OSM polygons), so zooming out swapped the 20 m
 * analytical surface for a set of hard-edged park shapes that looked like
 * analysis but was not the same dataset.
 *
 * The reason it existed at all was that hexgrid.pmtiles started at zoom 14 and
 * something had to cover wider views. The archives now carry zoom 11
 * (pipeline/06_export/export.R), which is the whole analysis extent and then
 * some, so the grid covers every zoom worth showing it at and the fallback has
 * nothing left to do. Below zoom 11 the analytical layers simply draw nothing
 * and the park outlines carry the geographic context on their own — the
 * behaviour canopy height already had.
 */
export const HAS_PATCH_OVERVIEW = false;

const OBS_VALUE: ExpressionSpecification = ['coalesce', ['get', 'nObs'], 0];

/** Cells with no records at all are not markers — biodiversity is the only point layer. */
export function pointLayerFilter(): FilterSpecification {
  return ['>', OBS_VALUE, 0] as FilterSpecification;
}

/**
 * A biodiversity mark is a *cell count*, not an occurrence.
 *
 * nObs is the number of records the pipeline attributed to the 20 m cell, so
 * the mark sits at the cell centre and is deliberately large and translucent —
 * it reads as an area carrying N records. The Supabase survey and structured
 * survey layers stay small, opaque and hard-edged, because those are real
 * coordinates. The two must never look like the same kind of thing.
 */
export function biodiversityCellLayout(): SymbolLayerSpecification['layout'] {
  return {
    visibility: 'none',
    'icon-image': POINT_ICON_ID,
    'icon-allow-overlap': ['step', ['zoom'], false, 16, true],
    'icon-ignore-placement': ['step', ['zoom'], false, 16, true],
    'icon-padding': ['interpolate', ['linear'], ['zoom'], 14, 4, 17, 1],
    // Busiest cells place first, so thinning never drops the richest cells.
    'symbol-sort-key': ['-', 0, OBS_VALUE],
    // Deliberately does NOT track the grid the way vegetation does: these are
    // discrete counts, so they must stay separable markers rather than merge
    // into a surface. Spacing is ~24px at z16 and ~45px at z17.
    'icon-size': [
      'interpolate', ['linear'], ['zoom'],
      14, ['interpolate', ['linear'], OBS_VALUE, 0, 0.55, 50, 1.15],
      17, ['interpolate', ['linear'], OBS_VALUE, 0, 0.80, 50, 1.80],
      19, ['interpolate', ['linear'], OBS_VALUE, 0, 1.00, 50, 2.20],
    ],
  } as SymbolLayerSpecification['layout'];
}

export function biodiversityCellPaint(): SymbolLayerSpecification['paint'] {
  return {
    'icon-color': buildBiodiversityObsExpression(),
    // Translucent throughout — an aggregate marker, never a sharp record.
    'icon-opacity': ['interpolate', ['linear'], ['zoom'], 14, 0.55, 18, 0.42],
  } as SymbolLayerSpecification['paint'];
}

/** Overview zoom (below the hex source's minzoom): one point per green space. */
export function overviewPointPaint(
  layerId: PointLayerId,
  cityIds: string[],
  allCityStats: CityLayerStats[],
): CircleLayerSpecification['paint'] {
  const color = patchFillColorExpressionForCities(layerId, cityIds, allCityStats);

  return {
    'circle-color': color,
    'circle-radius': ['interpolate', ['linear'], ['zoom'],
      10, ['interpolate', ['linear'], OBS_VALUE, 0, 3, 50, 9],
      13, ['interpolate', ['linear'], OBS_VALUE, 0, 5, 50, 16],
    ],
    'circle-opacity': 0.5,
    'circle-stroke-color': '#ffffff',
    'circle-stroke-width': 0.8,
  } as CircleLayerSpecification['paint'];
}

export function hasHexOverlay(layerId: HexLayerId): boolean {
  return Boolean(HEX_FILL_LAYER_IDS[layerId]);
}

export function hexFillLayerId(layerId: HexLayerId): string {
  return HEX_FILL_LAYER_IDS[layerId];
}

export function getEnabledLayerIds(layers: { id: LayerId; enabled: boolean }[]): HexLayerId[] {
  return LAYER_DRAW_ORDER.filter((id) => layers.some((l) => l.id === id && l.enabled));
}

/** First enabled layer — used for default legend focus. */
export function getActiveLayerId(layers: { id: LayerId; enabled: boolean }[]): HexLayerId {
  return getEnabledLayerIds(layers)[0] ?? 'impact';
}

const DIVERGING_STOPS: [number, string][] = [
  [-1, '#C95B4B'],
  [-0.4, '#E8A44C'],
  [0, '#B8C9AE'],
  [0.4, '#73A56D'],
  [1, '#2E6F40'],
];

/** Saturated ramps — even low values stay visible on the light basemap. */
const LAYER_RAMPS: Record<Exclude<HexLayerId, 'impact' | 'residual' | 'landuse'>, [number, string][]> = {
  expected:     [[0, '#deebf7'], [0.25, '#9ecae1'], [0.5, '#4292c6'], [0.75, '#08519c'], [1, '#08306b']],
  intervention: [[0, '#d8a7df'], [0.3, '#ab47bc'], [0.6, '#8e24aa'], [0.8, '#6a1b9a'], [1, '#4a148c']],
  habitat:      [[0, '#8ecf9a'], [0.25, '#52a868'], [0.5, '#3d8b57'], [0.75, '#2E6F40'], [1, '#1a4a28']],
  treecover:    [[0, '#66bb6a'], [0.25, '#43a047'], [0.5, '#2e7d32'], [0.75, '#1b5e20'], [1, '#0d3d12']],
  biodiversity: [[0, '#42a5f5'], [5, '#1e88e5'], [15, '#1565c0'], [30, '#0d47a1'], [50, '#002171']],
  connectivity: [[0, '#ab47bc'], [0.25, '#8e24aa'], [0.5, '#7b1fa2'], [0.75, '#6a1b9a'], [1, '#4a148c']],
  heat:         [[0, '#4575b4'], [0.25, '#74add1'], [0.5, '#fdae61'], [0.75, '#f46d43'], [1, '#a50026']],
};

function buildDivergingExpression(
  normProperty: string,
  rawProperty: string,
  stat: CityLayerStats | undefined,
): ExpressionSpecification {
  const bound = stat?.bound;
  const valueExpression: ExpressionSpecification = bound != null && bound > 0
    ? [
        'coalesce',
        ['get', normProperty],
        ['/', ['get', rawProperty], bound],
        0,
      ] as ExpressionSpecification
    : ['coalesce', ['get', normProperty], 0] as ExpressionSpecification;

  return [
    'interpolate',
    ['linear'],
    valueExpression,
    ...DIVERGING_STOPS.flatMap(([value, color]) => [value, color]),
  ] as ExpressionSpecification;
}

/** Map a 0–1 float or 0–100 pct_index integer to the unit interval. */
function unitInterval(property: string): ExpressionSpecification {
  return [
    'case',
    ['>', ['coalesce', ['get', property], -1], 1],
    ['/', ['coalesce', ['get', property], 0], 100],
    ['coalesce', ['get', property], 0],
  ] as ExpressionSpecification;
}

/** Canonical canopy-height value from vector tile / park aggregate properties (0–1). */
function treeCoverValueExpression(): ExpressionSpecification {
  return [
    'to-number',
    [
      'coalesce',
      ['get', 'canopyHeightIdx'],
      ['get', 'treeCoverNorm'],
      ['/', ['coalesce', ['get', 'treeCover'], 0], 100],
    ],
  ] as ExpressionSpecification;
}

/** Patch parks export heatExposure (0–100); hex tiles export lstNorm (0–1). */
function buildHeatExpression(cityStats: CityLayerStats[] = []): ExpressionSpecification {
  const stat = statForMetric(cityStats, 'lst_idx');
  const low = stat?.p05 ?? stat?.minVal;
  const high = stat?.p95 ?? stat?.maxVal;
  const rawValue = unitInterval('heatExposure');
  const fromRaw: ExpressionSpecification = low != null && high != null && high > low
    ? ['max', 0, ['min', 1, ['/', ['-', rawValue, low], ['-', high, low]]]] as ExpressionSpecification
    : rawValue;

  return [
    'interpolate',
    ['linear'],
    ['coalesce', ['get', 'lstNorm'], ['get', 'meanLstNorm'], fromRaw, 0],
    ...LAYER_RAMPS.heat.flatMap(([value, color]) => [value, color]),
  ] as ExpressionSpecification;
}

/** Observation-count heatmap — darker blue = more iNaturalist/GBIF records in the hex. */
export function buildBiodiversityObsExpression(): ExpressionSpecification {
  return [
    'interpolate',
    ['linear'],
    ['coalesce', ['get', 'nObs'], 0],
    ...LAYER_RAMPS.biodiversity.flatMap(([value, color]) => [value, color]),
  ] as ExpressionSpecification;
}

function buildSequentialExpression(
  normProperty: string,
  rawProperty: string,
  ramp: [number, string][],
  stat: CityLayerStats | undefined,
  rawIsPercentIndex = false,
): ExpressionSpecification {
  const low = stat?.p05 ?? stat?.minVal;
  const high = stat?.p95 ?? stat?.maxVal;
  const rawValue: ExpressionSpecification = rawIsPercentIndex
    ? unitInterval(rawProperty)
    : ['coalesce', ['get', rawProperty], 0] as ExpressionSpecification;
  const valueExpression: ExpressionSpecification = low != null && high != null && high > low
    ? [
        'coalesce',
        ['get', normProperty],
        [
          'max',
          0,
          ['min', 1, ['/', ['-', rawValue, low], ['-', high, low]]],
        ],
        rawValue,
        0,
      ] as ExpressionSpecification
    : ['coalesce', ['get', normProperty], rawValue, 0] as ExpressionSpecification;

  return [
    'interpolate',
    ['linear'],
    valueExpression,
    ...ramp.flatMap(([value, color]) => [value, color]),
  ] as ExpressionSpecification;
}

/** Expected richness — patch and hex export different norm property names. */
function buildExpectedExpression(
  cityStats: CityLayerStats[] = [],
  ramp: [number, string][],
): ExpressionSpecification {
  const stat = statForMetric(cityStats, 'expected_richness');
  const low = stat?.p05 ?? stat?.minVal;
  const high = stat?.p95 ?? stat?.maxVal;
  const rawValue = unitInterval('expectedRichness');
  const fromRaw: ExpressionSpecification = low != null && high != null && high > low
    ? ['max', 0, ['min', 1, ['/', ['-', rawValue, low], ['-', high, low]]]] as ExpressionSpecification
    : rawValue;

  return [
    'interpolate',
    ['linear'],
    ['coalesce', ['get', 'expectedRichnessNorm'], ['get', 'expectedNorm'], fromRaw, 0],
    ...ramp.flatMap(([value, color]) => [value, color]),
  ] as ExpressionSpecification;
}

/**
 * Canopy height stretched to the city's own p05–p95 range (0–1).
 *
 * canopyHeightIdx is an absolute 0–20 m index, so its raw values are tiny in a
 * dense city — Porto's p95 is 0.116 against a max of 0.619. Anything keyed on
 * the raw 0–1 range collapses to its bottom end, which is why both the colour
 * ramp and the point sizing go through this stretch.
 */
export function canopyStretchedExpression(cityStats: CityLayerStats[] = []): ExpressionSpecification {
  const stat = statForMetric(cityStats, 'canopy_height_idx');
  const low = stat?.p05 ?? stat?.minVal;
  const high = stat?.p95 ?? stat?.maxVal;
  const valueExpression = treeCoverValueExpression();
  return low != null && high != null && high > low
    ? ['max', 0, ['min', 1, ['/', ['-', valueExpression, low], ['-', high, low]]]] as ExpressionSpecification
    : valueExpression;
}

/** Canopy height — absolute 0–20 m index from PMTiles, stretched to the city's p05–p95 range. */
function buildTreecoverExpression(cityStats: CityLayerStats[] = []): ExpressionSpecification {
  return [
    'interpolate',
    ['linear'],
    canopyStretchedExpression(cityStats),
    ...LAYER_RAMPS.treecover.flatMap(([value, color]) => [value, color]),
  ] as ExpressionSpecification;
}

function statForMetric(stats: CityLayerStats[], metric: string | undefined): CityLayerStats | undefined {
  if (!metric) return undefined;
  return stats.find((entry) => entry.metric === metric);
}

/**
 * Flat grey for cells/parks with no recorded observations — distinct from the
 * diverging ramp's neutral midpoint (#B8C9AE) so "not enough data yet" never
 * reads as "biodiversity roughly matches habitat potential".
 */
export const UNSAMPLED_FILL_COLOR = '#C9CDC5';

const UNSAMPLED_AWARE_LAYERS = new Set(['impact', 'residual', 'intervention']);

/** Render observed-richness-dependent layers as flat grey when the feature is unsampled. */
function withUnsampledFallback(layerId: string, expression: ExpressionSpecification): ExpressionSpecification {
  if (!UNSAMPLED_AWARE_LAYERS.has(layerId)) return expression;
  return [
    'case',
    ['==', ['get', 'isUnsampled'], true],
    UNSAMPLED_FILL_COLOR,
    expression,
  ] as ExpressionSpecification;
}

function landUseColorExpression(): ExpressionSpecification {
  return [
    'match',
    ['coalesce', ['get', 'landUseClass'], ['get', 'land_use_class'], ['get', 'dominant_land_use'], 'unknown'],
    'tree', '#1b5e20',
    'shrub', '#4f8a3d',
    'grass', '#9ccc65',
    'water', '#4575b4',
    'built', '#b87f4f',
    'bare', '#d8c7a3',
    'mixed', '#8e7cc3',
    '#c9c9c9',
  ] as ExpressionSpecification;
}

/** Patch-level fill colour (zoom ≤ 13). */
export function patchFillColorExpression(
  layerId: PatchFillLayerId,
  cityStats: CityLayerStats[] = [],
): ExpressionSpecification {
  const spec = LAYER_STYLE_SPECS[layerId];
  const stat = statForMetric(cityStats, spec.rawMetric);

  switch (layerId) {
    case 'impact':
      return withUnsampledFallback(layerId, buildDivergingExpression('natureGapScoreNorm', 'natureGapScore', stat));
    case 'residual':
      return withUnsampledFallback(layerId, buildDivergingExpression('ecologicalResidualNorm', 'ecologicalResidual', stat));
    case 'expected':
      return buildExpectedExpression(cityStats, LAYER_RAMPS.expected);
    case 'intervention':
      return withUnsampledFallback(layerId, buildSequentialExpression('interventionRankNorm', 'interventionRank', LAYER_RAMPS.intervention, stat));
    case 'habitat':
      return buildSequentialExpression('habitatQualityNorm', 'habitatQualityIndex', LAYER_RAMPS.habitat, stat);
    case 'treecover':
      return buildTreecoverExpression(cityStats);
    case 'connectivity':
      return buildSequentialExpression('corridorImportanceNorm', 'corridorImportance', LAYER_RAMPS.connectivity, stat);
    case 'heat':
      return buildHeatExpression(cityStats);
    case 'landuse':
      return landUseColorExpression();
    case 'biodiversity':
      return buildBiodiversityObsExpression();
  }
}

/**
 * Patch-level fill colour across every city sharing the 'parks' source.
 * Dispatches per-feature on cityId so each city's polygons are coloured
 * against that city's own stat range, instead of one hardcoded default.
 */
export function patchFillColorExpressionForCities(
  layerId: PatchFillLayerId,
  cityIds: string[],
  allCityStats: CityLayerStats[],
): ExpressionSpecification {
  if (cityIds.length === 0) return patchFillColorExpression(layerId, []);
  if (cityIds.length === 1) {
    return patchFillColorExpression(layerId, allCityStats.filter((s) => s.cityId === cityIds[0]));
  }

  const [fallbackCityId, ...matchedCityIds] = cityIds;
  const cases = matchedCityIds.flatMap((cityId) => [
    cityId,
    patchFillColorExpression(layerId, allCityStats.filter((s) => s.cityId === cityId)),
  ]);
  const fallback = patchFillColorExpression(layerId, allCityStats.filter((s) => s.cityId === fallbackCityId));

  return [
    'match',
    ['get', 'cityId'],
    ...cases,
    fallback,
  ] as unknown as ExpressionSpecification;
}

/** Hex-level fill colour (zoom ≥ 14). */
export function hexFillColorExpression(
  layerId: HexLayerId,
  cityStats: CityLayerStats[] = [],
): ExpressionSpecification {
  if (layerId === 'impact') {
    return withUnsampledFallback(layerId, buildDivergingExpression(
      'natureGapScoreNorm',
      'natureGapScore',
      statForMetric(cityStats, 'nature_gap_score'),
    ));
  }

  if (layerId === 'residual') {
    return withUnsampledFallback(layerId, buildDivergingExpression(
      'residualNorm',
      'ecologicalResidual',
      statForMetric(cityStats, 'ecological_residual'),
    ));
  }

  if (layerId === 'landuse') {
    return landUseColorExpression();
  }

  if (layerId === 'expected') {
    return buildExpectedExpression(cityStats, LAYER_RAMPS.expected);
  }

  if (layerId === 'treecover') {
    return buildTreecoverExpression(cityStats);
  }

  if (layerId === 'biodiversity') {
    return buildBiodiversityObsExpression();
  }

  if (layerId === 'heat') {
    return buildHeatExpression(cityStats);
  }

  const spec = LAYER_STYLE_SPECS[layerId];
  const ramp = LAYER_RAMPS[layerId as keyof typeof LAYER_RAMPS];
  if (!spec.property || !ramp) {
    return ['literal', '#B8C9AE'] as ExpressionSpecification;
  }

  const rawPropertyByLayer: Partial<Record<HexLayerId, string>> = {
    intervention: 'interventionRank',
    habitat: 'habitatQuality',
    connectivity: 'betweennessCentrality',
  };

  return withUnsampledFallback(layerId, buildSequentialExpression(
    spec.property,
    rawPropertyByLayer[layerId] ?? spec.property,
    ramp,
    statForMetric(cityStats, spec.rawMetric),
  ));
}

/** Nature gap is the default layer and sits lighter so the basemap stays readable. */
const HEX_FILL_OPACITY: Partial<Record<HexLayerId, number>> = { impact: 0.5 };
const HEX_FILL_OPACITY_DEFAULT = 0.78;

/**
 * Zoom ramp around a layer's base opacity.
 *
 * Slightly firmer at wide zoom: with antialiasing off the fill no longer has
 * light seams running through it, so it needs a little more weight to stay the
 * dominant thing on the map. Slightly softer once cells are large, where the
 * basemap underneath is what tells you *where* you are looking. Cosmetic only —
 * the value being shaded is identical at every zoom.
 */
function hexOpacityRamp(base: number): ExpressionSpecification {
  return [
    'interpolate', ['linear'], ['zoom'],
    HEX_REGIME.far, Math.min(0.95, base + 0.08),
    HEX_REGIME.close, base,
    HEX_REGIME.veryClose + 1, Math.max(0.3, base - 0.06),
  ] as ExpressionSpecification;
}

export function hexFillOpacityForLayer(layerId: HexLayerId): number | ExpressionSpecification {
  // Point layers keep their hex fill in the style at zero opacity: nothing is
  // drawn, but queryRenderedFeatures still returns the cell, so clicking
  // anywhere inside the grid still opens that cell's analytical detail.
  if (isPointLayer(layerId)) return 0;
  return hexOpacityRamp(HEX_FILL_OPACITY[layerId] ?? HEX_FILL_OPACITY_DEFAULT);
}

export function patchFillOpacityExpression(layerId: PatchFillLayerId): number | ExpressionSpecification {
  // Point layers draw their overview representation on park centroids instead;
  // the patch fill is hidden outright and 'park-area' keeps park clicks working.
  if (isPointLayer(layerId)) return 0;
  if (layerId === 'connectivity') {
    return ['interpolate', ['linear'], ['zoom'], 13, 0.7, 14, 0.2] as ExpressionSpecification;
  }
  return 0.7;
}

export const LAYER_STYLE_SPECS: Record<HexLayerId, LayerStyleSpec> = {
  impact: {
    title: 'Nature Gap',
    property: 'natureGapScoreNorm',
    rawMetric: 'nature_gap_score',
    legend: [
      { color: '#2E6F40', label: 'Strong surplus' },
      { color: '#73A56D', label: 'Surplus' },
      { color: '#B8C9AE', label: 'Near expected' },
      { color: '#E8A44C', label: 'Pressure' },
      { color: '#C95B4B', label: 'Strong pressure' },
    ],
  },
  expected: {
    title: 'Expected Richness',
    property: 'expectedNorm',
    rawMetric: 'expected_richness',
    // Patch uses expectedRichnessNorm; hex tiles export expectedNorm — coalesce both in expressions.
    legend: [
      { color: '#08306b', label: 'Very high' },
      { color: '#08519c', label: 'High' },
      { color: '#4292c6', label: 'Moderate' },
      { color: '#9ecae1', label: 'Low' },
      { color: '#deebf7', label: 'Very low' },
    ],
  },
  residual: {
    title: 'Ecological Residual',
    property: 'residualNorm',
    rawMetric: 'ecological_residual',
    legend: [
      { color: '#2E6F40', label: 'Far fewer recorded' },
      { color: '#73A56D', label: 'Fewer recorded' },
      { color: '#B8C9AE', label: 'Near expected' },
      { color: '#E8A44C', label: 'More recorded' },
      { color: '#C95B4B', label: 'Far more recorded' },
    ],
  },
  intervention: {
    title: 'Intervention Ranking',
    property: 'interventionRankNorm',
    rawMetric: 'intervention_rank',
    legend: [
      { color: '#4a148c', label: 'Top priority' },
      { color: '#6a1b9a', label: 'High' },
      { color: '#8e24aa', label: 'Medium' },
      { color: '#ab47bc', label: 'Lower' },
      { color: '#d8a7df', label: 'Background' },
    ],
  },
  habitat: {
    title: 'Habitat Quality',
    property: 'habitatQualityNorm',
    rawMetric: 'habitat_quality',
    legend: [
      { color: '#1a4a28', label: 'High' },
      { color: '#2E6F40', label: 'Good' },
      { color: '#3d8b57', label: 'Moderate' },
      { color: '#52a868', label: 'Low' },
      { color: '#8ecf9a', label: 'Very low' },
    ],
  },
  treecover: {
    title: 'Canopy height',
    property: 'canopyHeightIdx',
    rawMetric: 'canopy_height_idx',
    note: 'Mean canopy height per 20 m cell, shaded continuously. Shown from zoom 14 in — not aggregated to whole green spaces when zoomed further out.',
    legend: [
      { color: '#0d3d12', label: '15–20 m' },
      { color: '#1b5e20', label: '10–15 m' },
      { color: '#2e7d32', label: '5–10 m' },
      { color: '#43a047', label: '1–5 m' },
      { color: '#66bb6a', label: '0–1 m' },
    ],
  },
  biodiversity: {
    title: 'Observed biodiversity',
    property: 'nObs',
    rawMetric: 'n_obs',
    note: 'Each mark is a 20 m cell containing N records, drawn at the cell centre — not an individual observation. Survey points and structured surveys are real coordinates.',
    legend: [
      { color: '#002171', label: '50+ records' },
      { color: '#0d47a1', label: '30+ records' },
      { color: '#1565c0', label: '15+ records' },
      { color: '#1e88e5', label: '5+ records' },
      { color: '#42a5f5', label: '1–4 records' },
    ],
  },
  connectivity: {
    title: 'Connectivity',
    property: 'betweennessNorm',
    rawMetric: 'betweenness_centrality',
    legend: [
      { color: '#4a148c', label: 'Critical corridor' },
      { color: '#6a1b9a', label: 'High' },
      { color: '#7b1fa2', label: 'Moderate' },
      { color: '#8e24aa', label: 'Low' },
      { color: '#ab47bc', label: 'Isolated' },
    ],
  },
  heat: {
    title: 'Heat Exposure',
    property: 'lstNorm',
    rawMetric: 'lst_idx',
    legend: [
      { color: '#a50026', label: 'Very hot' },
      { color: '#f46d43', label: 'Hot' },
      { color: '#fdae61', label: 'Warm' },
      { color: '#74add1', label: 'Cool' },
      { color: '#4575b4', label: 'Cooler' },
    ],
  },
  landuse: {
    title: 'Land Use',
    legend: [
      { color: '#1b5e20', label: 'Tree canopy' },
      { color: '#4f8a3d', label: 'Shrub' },
      { color: '#9ccc65', label: 'Grass' },
      { color: '#4575b4', label: 'Water' },
      { color: '#b87f4f', label: 'Built' },
      { color: '#d8c7a3', label: 'Bare' },
      { color: '#8e7cc3', label: 'Mixed' },
    ],
  },
};

/** Layer switcher groups in the visualisation spec. */
export const THEMATIC_LAYER_GROUPS = [
  {
    title: 'Overview',
    ids: ['impact', 'residual', 'intervention'] as const satisfies readonly HexLayerId[],
  },
  {
    title: 'Biodiversity',
    ids: ['biodiversity', 'expected'] as const satisfies readonly HexLayerId[],
  },
  {
    title: 'Habitat',
    ids: ['habitat', 'treecover', 'connectivity', 'heat', 'landuse'] as const satisfies readonly HexLayerId[],
  },
] as const;
