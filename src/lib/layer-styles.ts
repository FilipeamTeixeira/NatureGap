import type {
  ExpressionSpecification,
  LineLayerSpecification,
} from 'maplibre-gl';
import type { CityLayerStats } from './data';
import type { LayerId } from './types';

/**
 * How a legend row draws its mark. Every layer but connectivity is a graduated
 * fill and uses the default swatch; the derived network needs to distinguish
 * node tiers from corridor classes, because they are different kinds of thing
 * rather than steps on one ramp.
 */
export type LegendSymbol = 'swatch' | 'node-major' | 'node-secondary' | 'node-stepping' | 'line';

export interface LayerLegendItem {
  color: string;
  label: string;
  symbol?: LegendSymbol;
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
  'vegetation',
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
/**
 * Derived ecological network. Three separate node layers rather than one with a
 * data-driven radius, so each tier can be zoom-gated independently — stepping
 * stones would otherwise speckle the overview scale.
 */
export const CORRIDOR_LINES_LAYER_ID = 'corridor-lines';
export const NETWORK_NODE_MAJOR_LAYER_ID = 'network-node-major';
export const NETWORK_NODE_SECONDARY_LAYER_ID = 'network-node-secondary';
export const NETWORK_NODE_STEPPING_LAYER_ID = 'network-node-stepping';

export const NETWORK_LAYER_IDS = [
  CORRIDOR_LINES_LAYER_ID,
  NETWORK_NODE_MAJOR_LAYER_ID,
  NETWORK_NODE_SECONDARY_LAYER_ID,
  NETWORK_NODE_STEPPING_LAYER_ID,
] as const;

/**
 * Zoom hand-over between the two representations of the same data. The network
 * owns the overview and transition scales; the 20 m cells take over for
 * analytical inspection. They overlap slightly on purpose so the cells fade in
 * under the network rather than replacing it in one jump.
 */
export const NETWORK_REGIME = {
  /** Stepping stones and secondary nodes stay hidden below this. */
  detail: 12.5,
  /** Above this the analytical cells lead and the network steps back. */
  handover: 15,
} as const;

/**
 * Corridor quality classes, weakest first — order matches the legend. There is
 * no 'fragmented' class: the pipeline rejects a route that bad outright, and a
 * corridor that is broken rather than merely poor is described by its bottleneck
 * sections instead of by its average.
 */
export const CORRIDOR_STRENGTH_COLORS = {
  weak: '#e8862a',
  moderate: '#d4b106',
  strong: '#5a9e46',
  strongest: '#1f6b3a',
} as const;

/** Bottleneck sections — a real interruption inside an otherwise useful corridor. */
export const CORRIDOR_BOTTLENECK_COLOR = '#d1495b';

/**
 * Network hierarchy. A corridor's rank comes from the node tiers it connects,
 * so it survives the overview scale by mattering, not by being long.
 */
export type CorridorRank = 'primary' | 'secondary' | 'minor';

export function corridorLineColor(): ExpressionSpecification {
  // Every section of a corridor carries the same dominant class, so the line
  // holds one colour along its length. Only a bottleneck breaks that, and it is
  // painted as the interruption it is rather than as another quality step.
  return [
    'case',
    ['==', ['get', 'kind'], 'bottleneck'], CORRIDOR_BOTTLENECK_COLOR,
    [
      'match',
      ['get', 'strength'],
      'strongest', CORRIDOR_STRENGTH_COLORS.strongest,
      'strong', CORRIDOR_STRENGTH_COLORS.strong,
      'moderate', CORRIDOR_STRENGTH_COLORS.moderate,
      CORRIDOR_STRENGTH_COLORS.weak,
    ],
  ] as ExpressionSpecification;
}

/** Bottlenecks read slightly heavier than the corridor they interrupt. */
function bottleneckWidthFactor(): ExpressionSpecification {
  return ['case', ['==', ['get', 'kind'], 'bottleneck'], 1.4, 1] as ExpressionSpecification;
}

function corridorWidthAt(low: number, high: number): ExpressionSpecification {
  return [
    '*',
    bottleneckWidthFactor(),
    ['interpolate', ['linear'], ['get', 'importance'], 0, low, 1, high],
  ] as ExpressionSpecification;
}

/**
 * Width carries route quality and scales with zoom. Kept deliberately modest —
 * a restrained ecological network, not glowing arteries.
 */
export function corridorLineWidth(): ExpressionSpecification {
  return [
    'interpolate', ['linear'], ['zoom'],
    11, corridorWidthAt(0.9, 2.4),
    14, corridorWidthAt(1.5, 4),
    17, corridorWidthAt(2, 6),
  ] as ExpressionSpecification;
}

function rankOpacity(primary: number, secondary: number, minor: number): ExpressionSpecification {
  return [
    'match', ['get', 'rank'],
    'primary', primary,
    'secondary', secondary,
    minor,
  ] as ExpressionSpecification;
}

export function corridorLineOpacity(): ExpressionSpecification {
  // The zoom hierarchy lives here rather than in the pipeline: one network is
  // generated, and each scale reveals the part of it that matters. Overview
  // shows corridors between significant cores only; secondary connections fade
  // in through the transition scale, minor ones last; everything steps back once
  // the analytical cells take over.
  //
  // Rank gating, not importance gating — a weak corridor between two major
  // cores is a finding worth seeing at city scale, and suppressing it by quality
  // is how the map ended up showing only what the model liked best.
  return [
    'interpolate', ['linear'], ['zoom'],
    11, rankOpacity(0.95, 0, 0),
    NETWORK_REGIME.detail, rankOpacity(0.95, 0.9, 0),
    NETWORK_REGIME.detail + 1, rankOpacity(0.95, 0.9, 0.85),
    NETWORK_REGIME.handover, rankOpacity(0.85, 0.8, 0.75),
    19, rankOpacity(0.4, 0.35, 0.3),
  ] as ExpressionSpecification;
}

export type NetworkNodeTier = 'major' | 'secondary' | 'stepping-stone';

/** Radii in px, from the spec: major 12-16 dia, secondary 7-10, stepping 4-6. */
const NETWORK_NODE_RADIUS: Record<NetworkNodeTier, [number, number]> = {
  major: [6, 8],
  secondary: [3.5, 5],
  'stepping-stone': [2, 3],
};

export function networkNodeRadius(tier: NetworkNodeTier): ExpressionSpecification {
  const [near, far] = NETWORK_NODE_RADIUS[tier];
  return ['interpolate', ['linear'], ['zoom'], 11, near, 17, far] as ExpressionSpecification;
}

export function networkNodeFill(tier: NetworkNodeTier): string {
  // Major reads as a filled habitat concentration; the lighter tiers step back
  // so the hierarchy is legible without colour doing the work twice.
  if (tier === 'major') return '#1f6b3a';
  if (tier === 'secondary') return '#4c8f5a';
  return '#8fb08a';
}

export function networkNodeOpacity(): ExpressionSpecification {
  return [
    'interpolate', ['linear'], ['zoom'],
    11, 0.95,
    NETWORK_REGIME.handover, 0.9,
    19, 0.4,
  ] as ExpressionSpecification;
}

/**
 * Minimum zoom per tier. Only major nodes and their corridors survive the
 * overview scale, which is what makes the map read as a network rather than a
 * field of dots.
 */
export function networkNodeMinZoom(tier: NetworkNodeTier): number {
  if (tier === 'major') return 0;
  if (tier === 'secondary') return NETWORK_REGIME.detail;
  return NETWORK_REGIME.detail + 1;
}
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
  vegetation: 'vegetation-patch-fill',
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
  vegetation: 'vegetation-hex-fill',
  biodiversity: 'biodiversity-hex-fill',
  connectivity: 'connectivity-hex-fill',
  heat: 'heat-exposure-hex-fill',
  landuse: 'land-use-hex-fill',
};

export const PATCH_FILL_LAYER_ORDER = LAYER_DRAW_ORDER.filter(
  (id): id is PatchFillLayerId => id in PATCH_FILL_LAYER_IDS,
);

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

// Both diverging metrics (nature_gap_score, ecological_residual) are built from
// expected − observed, so POSITIVE is the bad end: fewer species recorded than
// the habitat predicts. Red therefore sits at +1, green at -1.
const DIVERGING_STOPS: [number, string][] = [
  [-1, '#2E6F40'],
  [-0.4, '#73A56D'],
  [0, '#B8C9AE'],
  [0.4, '#E8A44C'],
  [1, '#C95B4B'],
];

/** Saturated ramps — even low values stay visible on the light basemap. */
const LAYER_RAMPS: Record<Exclude<HexLayerId, 'impact' | 'residual' | 'landuse'>, [number, string][]> = {
  expected:     [[0, '#deebf7'], [0.25, '#9ecae1'], [0.5, '#4292c6'], [0.75, '#08519c'], [1, '#08306b']],
  intervention: [[0, '#d8a7df'], [0.3, '#ab47bc'], [0.6, '#8e24aa'], [0.8, '#6a1b9a'], [1, '#4a148c']],
  habitat:      [[0, '#8ecf9a'], [0.25, '#52a868'], [0.5, '#3d8b57'], [0.75, '#2E6F40'], [1, '#1a4a28']],
  treecover:    [[0, '#66bb6a'], [0.25, '#43a047'], [0.5, '#2e7d32'], [0.75, '#1b5e20'], [1, '#0d3d12']],
  vegetation:   [[0, '#f7fcb9'], [0.25, '#d9f0a3'], [0.5, '#addd8e'], [0.75, '#78c679'], [1, '#41ab5d']],
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
    'case',
    ['<=', ['coalesce', ['get', 'nObs'], 0], 0],
    UNSAMPLED_FILL_COLOR,
    [
      'interpolate',
      ['linear'],
      ['get', 'nObs'],
      ...LAYER_RAMPS.biodiversity.flatMap(([value, color]) => [value, color]),
    ],
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

/**
 * CIR vegetated fraction stretched to the city's own p05–p95 range (0–1).
 *
 * veg_fraction is a true 0–1 share of 0.5 m pixels, so unlike canopyHeightIdx
 * it has a meaningful absolute scale. It is still heavily bottom-weighted in a
 * dense city — Porto's mean is 0.21 and 82% of cells read zero tree cover — so
 * the same p05–p95 stretch keeps low-but-nonzero vegetation legible. Falls back
 * to the raw fraction when the city has no veg_fraction stat, which is the case
 * until export.R publishes one.
 */
export function vegetationStretchedExpression(cityStats: CityLayerStats[] = []): ExpressionSpecification {
  const stat = statForMetric(cityStats, 'veg_fraction');
  const low = stat?.p05 ?? stat?.minVal;
  const high = stat?.p95 ?? stat?.maxVal;
  const valueExpression = unitInterval('vegFraction');
  return low != null && high != null && high > low
    ? ['max', 0, ['min', 1, ['/', ['-', valueExpression, low], ['-', high, low]]]] as ExpressionSpecification
    : valueExpression;
}

/** Vegetated fraction — share of 0.5 m CIR pixels above the NDVI threshold. */
function buildVegetationExpression(cityStats: CityLayerStats[] = []): ExpressionSpecification {
  return [
    'interpolate',
    ['linear'],
    vegetationStretchedExpression(cityStats),
    ...LAYER_RAMPS.vegetation.flatMap(([value, color]) => [value, color]),
  ] as ExpressionSpecification;
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
    case 'vegetation':
      return buildVegetationExpression(cityStats);
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

  if (layerId === 'vegetation') {
    return buildVegetationExpression(cityStats);
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
    connectivity: 'corridorImportance',
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
  if (layerId === 'connectivity') {
    // Connectivity is the one layer with a second, derived representation. The
    // cells stay invisible until the network hands over, so the overview scale
    // reads as an ecological network rather than a hexagonal raster — but they
    // stay in the style at zero opacity so clicking a cell still opens its
    // analytical detail at any zoom.
    const base = HEX_FILL_OPACITY.connectivity ?? HEX_FILL_OPACITY_DEFAULT;
    return [
      'interpolate', ['linear'], ['zoom'],
      NETWORK_REGIME.handover - 0.5, 0,
      NETWORK_REGIME.handover + 1, base * 0.6,
      HEX_REGIME.veryClose, base * 0.75,
    ] as ExpressionSpecification;
  }
  return hexOpacityRamp(HEX_FILL_OPACITY[layerId] ?? HEX_FILL_OPACITY_DEFAULT);
}

export function patchFillOpacityExpression(layerId: PatchFillLayerId): number | ExpressionSpecification {
  if (layerId === 'connectivity') {
    // The derived network is the overview representation now. This patch fill
    // was the second semi-transparent purple layer that made the grid read as a
    // dark mesh where it blended with the hex fill.
    return 0;
  }
  return 0.7;
}

export const LAYER_STYLE_SPECS: Record<HexLayerId, LayerStyleSpec> = {
  impact: {
    title: 'Nature Gap',
    property: 'natureGapScoreNorm',
    rawMetric: 'nature_gap_score',
    legend: [
      { color: '#C95B4B', label: 'Strong pressure' },
      { color: '#E8A44C', label: 'Pressure' },
      { color: '#B8C9AE', label: 'Near expected' },
      { color: '#73A56D', label: 'Surplus' },
      { color: '#2E6F40', label: 'Strong surplus' },
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
      { color: '#C95B4B', label: 'Far fewer recorded' },
      { color: '#E8A44C', label: 'Fewer recorded' },
      { color: '#B8C9AE', label: 'Near expected' },
      { color: '#73A56D', label: 'More recorded' },
      { color: '#2E6F40', label: 'Far more recorded' },
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
  vegetation: {
    title: 'Vegetation (0.5 m)',
    property: 'vegFraction',
    rawMetric: 'veg_fraction',
    note: 'Share of 0.5 m colour-infrared pixels above the NDVI threshold — any vegetation, tree or not. Available only where a national CIR orthophoto exists (Netherlands, Portugal).',
    legend: [
      { color: '#41ab5d', label: 'Mostly vegetated' },
      { color: '#78c679', label: 'Substantial' },
      { color: '#addd8e', label: 'Moderate' },
      { color: '#d9f0a3', label: 'Sparse' },
      { color: '#f7fcb9', label: 'Bare or built' },
    ],
  },
  biodiversity: {
    title: 'Observed biodiversity',
    property: 'nObs',
    rawMetric: 'n_obs',
    note: 'Record count per 20 m cell. Cells with no records are grey — not treated as zero richness. Survey points and structured surveys are real coordinates.',
    legend: [
      { color: '#002171', label: '50+ records' },
      { color: '#0d47a1', label: '30+ records' },
      { color: '#1565c0', label: '15+ records' },
      { color: '#1e88e5', label: '5+ records' },
      { color: '#42a5f5', label: '1–4 records' },
      { color: '#C9CDC5', label: 'No records' },
    ],
  },
  connectivity: {
    title: 'Connectivity',
    // corridorImportance is a percentile rank over the habitat-resistance
    // graph, spanning 0-1. betweennessNorm (the previous property here)
    // stretches raw dispersal-limited betweenness, which peaks around 8e-05
    // with a median of 0 — almost no visible signal once stretched. This still
    // drives the 20 m cell fill, which now only appears at analytical zoom;
    // the network layers below carry the overview representation.
    property: 'corridorImportanceNorm',
    // Deliberately no rawMetric: the legend rows below are node tiers and
    // corridor classes, not steps on one ramp, so appending percentile bounds
    // to the first and last row (see MapView's legend formatter) would be
    // nonsense.
    note: 'Nodes are habitat cores; corridors are least-cost routes between them across the connectivity surface. A corridor may cross degraded ground — its colour is the quality of the whole route.',
    legend: [
      { color: networkNodeFill('major'), label: 'Major node', symbol: 'node-major' },
      { color: networkNodeFill('secondary'), label: 'Secondary node', symbol: 'node-secondary' },
      { color: networkNodeFill('stepping-stone'), label: 'Stepping stone', symbol: 'node-stepping' },
      { color: CORRIDOR_STRENGTH_COLORS.strongest, label: 'Strongest corridor', symbol: 'line' },
      { color: CORRIDOR_STRENGTH_COLORS.strong, label: 'Strong corridor', symbol: 'line' },
      { color: CORRIDOR_STRENGTH_COLORS.moderate, label: 'Moderate corridor', symbol: 'line' },
      { color: CORRIDOR_STRENGTH_COLORS.weak, label: 'Weak corridor', symbol: 'line' },
      // Drawn only where a corridor is genuinely interrupted for 120 m or more,
      // which is why this row can be listed: unlike fragmentation_index, the
      // symbol corresponds to something the pipeline actually derives.
      { color: CORRIDOR_BOTTLENECK_COLOR, label: 'Bottleneck', symbol: 'line' },
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
    ids: ['habitat', 'treecover', 'vegetation', 'connectivity', 'heat', 'landuse'] as const satisfies readonly HexLayerId[],
  },
] as const;
