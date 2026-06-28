import type { ExpressionSpecification } from 'maplibre-gl';
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
export const BIODIVERSITY_CIRCLES_LAYER_ID = 'biodiversity-circles';

export type PatchFillLayerId = Exclude<HexLayerId, 'biodiversity'>;

export const PATCH_FILL_LAYER_IDS: Record<PatchFillLayerId, string> = {
  impact: 'nature-gap-patch-fill',
  expected: 'expected-richness-patch-fill',
  residual: 'ecological-residual-patch-fill',
  intervention: 'intervention-patch-fill',
  habitat: 'habitat-quality-patch-fill',
  treecover: 'tree-cover-patch-fill',
  connectivity: 'connectivity-patch-fill',
  heat: 'heat-exposure-patch-fill',
  landuse: 'land-use-patch-fill',
};

export const HEX_FILL_LAYER_IDS: Partial<Record<HexLayerId, string>> = {
  impact: 'nature-gap-hex-fill',
  expected: 'expected-richness-hex-fill',
  residual: 'ecological-residual-hex-fill',
  intervention: 'intervention-hex-fill',
  habitat: 'habitat-quality-hex-fill',
  treecover: 'tree-cover-hex-fill',
  connectivity: 'connectivity-hex-fill',
  heat: 'heat-exposure-hex-fill',
  landuse: 'land-use-hex-fill',
};

export const PATCH_FILL_LAYER_ORDER = LAYER_DRAW_ORDER.filter(
  (id): id is PatchFillLayerId => id !== 'biodiversity',
);

export function hasHexOverlay(layerId: HexLayerId): boolean {
  return layerId in HEX_FILL_LAYER_IDS;
}

export function hexFillLayerId(layerId: HexLayerId): string {
  const id = HEX_FILL_LAYER_IDS[layerId];
  if (!id) throw new Error(`Layer ${layerId} has no hex fill`);
  return id;
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

/** Tree-cover value from vector tile properties (0–1). */
function treeCoverValueExpression(): ExpressionSpecification {
  return [
    'case',
    ['has', 'canopyHeightIdx'],
    ['to-number', ['get', 'canopyHeightIdx']],
    ['has', 'treeCover'],
    ['/', ['to-number', ['get', 'treeCover']], 100],
    ['has', 'treeCoverNorm'],
    ['to-number', ['get', 'treeCoverNorm']],
    0,
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

/** Canopy height — absolute 0–20 m index from PMTiles; treeCoverNorm for contrast. */
function buildTreecoverExpression(cityStats: CityLayerStats[] = []): ExpressionSpecification {
  const stat = statForMetric(cityStats, 'canopy_height_idx');
  const low = stat?.p05 ?? stat?.minVal;
  const high = stat?.p95 ?? stat?.maxVal;
  const valueExpression = treeCoverValueExpression();
  const stretched: ExpressionSpecification = low != null && high != null && high > low
    ? ['max', 0, ['min', 1, ['/', ['-', valueExpression, low], ['-', high, low]]]] as ExpressionSpecification
    : valueExpression;

  return [
    'interpolate',
    ['linear'],
    [
      'case',
      ['has', 'canopyHeightIdx'],
      ['to-number', ['get', 'canopyHeightIdx']],
      ['has', 'treeCover'],
      ['/', ['to-number', ['get', 'treeCover']], 100],
      ['has', 'treeCoverNorm'],
      ['to-number', ['get', 'treeCoverNorm']],
      stretched,
    ],
    ...LAYER_RAMPS.treecover.flatMap(([value, color]) => [value, color]),
  ] as ExpressionSpecification;
}

/**
 * Heat hex — lst_idx is a coolness index (1 − rank) in the pipeline.
 * Use heatExposure (lst_rank) so higher values render hotter/redder.
 */
function buildHeatHexExpression(cityStats: CityLayerStats[] = []): ExpressionSpecification {
  const stat = statForMetric(cityStats, 'lst_idx');
  const low = stat?.p05 ?? stat?.minVal;
  const high = stat?.p95 ?? stat?.maxVal;
  const meanLstValue: ExpressionSpecification = low != null && high != null && high > low
    ? ['max', 0, ['min', 1, ['/', ['-', unitInterval('meanLst'), low], ['-', high, low]]]] as ExpressionSpecification
    : unitInterval('meanLst');

  return [
    'interpolate',
    ['linear'],
    [
      'coalesce',
      unitInterval('heatExposure'),
      meanLstValue,
      ['-', 1, ['coalesce', ['get', 'lstNorm'], 0]],
      0,
    ],
    ...LAYER_RAMPS.heat.flatMap(([value, color]) => [value, color]),
  ] as ExpressionSpecification;
}

function statForMetric(stats: CityLayerStats[], metric: string | undefined): CityLayerStats | undefined {
  if (!metric) return undefined;
  return stats.find((entry) => entry.metric === metric);
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
      return buildDivergingExpression('natureGapScoreNorm', 'natureGapScore', stat);
    case 'residual':
      return buildDivergingExpression('ecologicalResidualNorm', 'ecologicalResidual', stat);
    case 'expected':
      return buildExpectedExpression(cityStats, LAYER_RAMPS.expected);
    case 'intervention':
      return buildSequentialExpression('interventionRankNorm', 'interventionRank', LAYER_RAMPS.intervention, stat);
    case 'habitat':
      return buildSequentialExpression('habitatQualityNorm', 'habitatQualityIndex', LAYER_RAMPS.habitat, stat);
    case 'treecover':
      return buildTreecoverExpression(cityStats);
    case 'connectivity':
      return buildSequentialExpression('corridorImportanceNorm', 'corridorImportance', LAYER_RAMPS.connectivity, stat);
    case 'heat':
      return buildSequentialExpression('meanLstNorm', 'meanLst', LAYER_RAMPS.heat, stat);
    case 'landuse':
      return landUseColorExpression();
  }
}

/** Hex-level fill colour (zoom ≥ 14). */
export function hexFillColorExpression(
  layerId: HexLayerId,
  cityStats: CityLayerStats[] = [],
): ExpressionSpecification {
  if (layerId === 'impact') {
    return buildDivergingExpression(
      'natureGapScoreNorm',
      'natureGapScore',
      statForMetric(cityStats, 'nature_gap_score'),
    );
  }

  if (layerId === 'residual') {
    return buildDivergingExpression(
      'residualNorm',
      'ecologicalResidual',
      statForMetric(cityStats, 'ecological_residual'),
    );
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

  if (layerId === 'heat') {
    return buildHeatHexExpression(cityStats);
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

  return buildSequentialExpression(
    spec.property,
    rawPropertyByLayer[layerId] ?? spec.property,
    ramp,
    statForMetric(cityStats, spec.rawMetric),
  );
}

export function hexFillOpacityForLayer(layerId: HexLayerId): number {
  if (layerId === 'impact') return 0.5;
  return 0.78;
}

export function patchFillOpacityExpression(layerId: PatchFillLayerId): number | ExpressionSpecification {
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
    property: 'treeCover',
    rawMetric: 'canopy_height_idx',
    legend: [
      { color: '#0d3d12', label: '15–20 m' },
      { color: '#1b5e20', label: '10–15 m' },
      { color: '#2e7d32', label: '5–10 m' },
      { color: '#43a047', label: '1–5 m' },
      { color: '#66bb6a', label: '0–1 m' },
    ],
  },
  biodiversity: {
    title: 'Biodiversity (observed)',
    property: 'effortCorrectedRichness',
    rawMetric: 'effort_corrected_richness',
    legend: [
      { color: '#002171', label: 'Very high' },
      { color: '#0d47a1', label: 'High' },
      { color: '#1565c0', label: 'Moderate' },
      { color: '#1e88e5', label: 'Low' },
      { color: '#42a5f5', label: 'None recorded' },
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
