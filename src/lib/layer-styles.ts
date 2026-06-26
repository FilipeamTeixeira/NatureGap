import type { ExpressionSpecification } from 'maplibre-gl';
import type { LayerId } from './types';

export interface LayerLegendItem {
  color: string;
  label: string;
}

export interface LayerStyleSpec {
  title: string;
  /** GeoJSON feature property for data-driven colouring (impact uses precomputed `color`). */
  property?: string;
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

/** Saturated ramps — even low values stay visible on the light basemap. */
const LAYER_RAMPS: Record<Exclude<HexLayerId, 'impact'>, [number, string][]> = {
  expected:     [[0, '#deebf7'], [25, '#9ecae1'], [50, '#4292c6'], [75, '#08519c'], [100, '#08306b']],
  residual:     [[-50, '#C95B4B'], [-20, '#E8A44C'], [0, '#B8C9AE'], [20, '#73A56D'], [50, '#2E6F40']],
  intervention: [[1, '#4a148c'], [5, '#6a1b9a'], [10, '#8e24aa'], [20, '#ab47bc'], [50, '#d8a7df']],
  habitat:      [[0, '#8ecf9a'], [25, '#52a868'], [50, '#3d8b57'], [75, '#2E6F40'], [100, '#1a4a28']],
  treecover:    [[0, '#66bb6a'], [25, '#43a047'], [50, '#2e7d32'], [75, '#1b5e20'], [100, '#0d3d12']],
  biodiversity: [[0, '#42a5f5'], [5, '#1e88e5'], [15, '#1565c0'], [30, '#0d47a1'], [50, '#002171']],
  connectivity: [[0, '#ab47bc'], [25, '#8e24aa'], [50, '#7b1fa2'], [75, '#6a1b9a'], [100, '#4a148c']],
  heat:         [[0, '#4575b4'], [25, '#74add1'], [50, '#fdae61'], [75, '#f46d43'], [100, '#a50026']],
  landuse:      [[0, '#9ccc65'], [25, '#7cb342'], [50, '#689f38'], [75, '#558b2f'], [100, '#33691e']],
};

export function hexFillLayerId(layerId: HexLayerId): string {
  return `hex-fill-${layerId}`;
}

export function getEnabledLayerIds(layers: { id: LayerId; enabled: boolean }[]): HexLayerId[] {
  return LAYER_DRAW_ORDER.filter((id) => layers.some((l) => l.id === id && l.enabled));
}

/** First enabled layer — used for default legend focus. */
export function getActiveLayerId(layers: { id: LayerId; enabled: boolean }[]): HexLayerId {
  return getEnabledLayerIds(layers)[0] ?? 'impact';
}

/** Build MapLibre fill-color expression for a data layer. */
export function hexFillColorExpression(layerId: HexLayerId): ExpressionSpecification {
  if (layerId === 'impact') {
    return ['coalesce', ['get', 'color'], '#B8C9AE'] as ExpressionSpecification;
  }

  const spec = LAYER_STYLE_SPECS[layerId];
  const ramp = LAYER_RAMPS[layerId];
  if (!spec.property) {
    return ['literal', '#B8C9AE'] as ExpressionSpecification;
  }

  return [
    'interpolate',
    ['linear'],
    ['coalesce', ['get', spec.property], 0],
    ...ramp.flatMap(([value, color]) => [value, color]),
  ] as ExpressionSpecification;
}

/** Opacity per layer — thinner when stacked so blends stay readable. */
export function hexFillOpacity(enabledCount: number): number {
  if (enabledCount <= 1) return 0.78;
  if (enabledCount === 2) return 0.58;
  return 0.48;
}

export const LAYER_STYLE_SPECS: Record<HexLayerId, LayerStyleSpec> = {
  impact: {
    title: 'Nature Impact Gap',
    legend: [
      { color: '#2E6F40', label: 'Much better than expected' },
      { color: '#73A56D', label: 'Better than expected' },
      { color: '#B8C9AE', label: 'As expected' },
      { color: '#E8A44C', label: 'Worse than expected' },
      { color: '#C95B4B', label: 'Much worse than expected' },
    ],
  },
  expected: {
    title: 'Expected Richness',
    property: 'expectedRichness',
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
    property: 'ecologicalResidual',
    legend: [
      { color: '#2E6F40', label: 'Strong surplus' },
      { color: '#73A56D', label: 'Surplus' },
      { color: '#B8C9AE', label: 'Near expected' },
      { color: '#E8A44C', label: 'Underperforming' },
      { color: '#C95B4B', label: 'Strong gap' },
    ],
  },
  intervention: {
    title: 'Intervention Ranking',
    property: 'interventionRank',
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
    property: 'habitatQuality',
    legend: [
      { color: '#1a4a28', label: 'High' },
      { color: '#2E6F40', label: 'Good' },
      { color: '#3d8b57', label: 'Moderate' },
      { color: '#52a868', label: 'Low' },
      { color: '#8ecf9a', label: 'Very low' },
    ],
  },
  treecover: {
    title: 'Tree Cover',
    property: 'treeCover',
    legend: [
      { color: '#0d3d12', label: 'Dense canopy' },
      { color: '#1b5e20', label: 'High' },
      { color: '#2e7d32', label: 'Moderate' },
      { color: '#43a047', label: 'Sparse' },
      { color: '#66bb6a', label: 'None' },
    ],
  },
  biodiversity: {
    title: 'Biodiversity (observed)',
    property: 'observedRichness',
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
    property: 'corridorImportance',
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
    property: 'heatExposure',
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
    property: 'landUseGreen',
    legend: [
      { color: '#33691e', label: 'Mostly vegetated' },
      { color: '#558b2f', label: 'Green' },
      { color: '#689f38', label: 'Mixed' },
      { color: '#7cb342', label: 'Sparse' },
      { color: '#9ccc65', label: 'Built / bare' },
    ],
  },
};
