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

const LAYER_RAMPS: Record<Exclude<LayerId, 'impact'>, [number, string][]> = {
  habitat:      [[0, '#f0f4ef'], [25, '#d4edda'], [50, '#74c67a'], [75, '#2E6F40'], [100, '#1a4a28']],
  treecover:    [[0, '#f1f8f2'], [25, '#e8f5e9'], [50, '#81c784'], [75, '#388e3c'], [100, '#1b5e20']],
  biodiversity: [[0, '#f5f9ff'], [5, '#e3f2fd'], [15, '#64b5f6'], [30, '#1976d2'], [50, '#0d47a1']],
  connectivity: [[0, '#faf5fb'], [25, '#f3e5f5'], [50, '#ba68c8'], [75, '#7b1fa2'], [100, '#4a148c']],
  heat:         [[0, '#4575b4'], [25, '#74add1'], [50, '#fee090'], [75, '#f46d43'], [100, '#a50026']],
  landuse:      [[0, '#fafafa'], [25, '#fff9c4'], [50, '#aed581'], [75, '#558b2f'], [100, '#33691e']],
};

/** Build MapLibre fill-color expression for the active data layer. */
export function hexFillColorExpression(layerId: LayerId): ExpressionSpecification {
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

export const LAYER_STYLE_SPECS: Record<LayerId, LayerStyleSpec> = {
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
  habitat: {
    title: 'Habitat Quality',
    property: 'habitatQuality',
    legend: [
      { color: '#1a4a28', label: 'High' },
      { color: '#2E6F40', label: 'Good' },
      { color: '#74c67a', label: 'Moderate' },
      { color: '#d4edda', label: 'Low' },
      { color: '#f0f4ef', label: 'Very low' },
    ],
  },
  treecover: {
    title: 'Tree Cover',
    property: 'treeCover',
    legend: [
      { color: '#1b5e20', label: 'Dense canopy' },
      { color: '#388e3c', label: 'High' },
      { color: '#81c784', label: 'Moderate' },
      { color: '#e8f5e9', label: 'Sparse' },
      { color: '#f1f8f2', label: 'None' },
    ],
  },
  biodiversity: {
    title: 'Biodiversity (observed)',
    property: 'observedRichness',
    legend: [
      { color: '#0d47a1', label: 'Very high' },
      { color: '#1976d2', label: 'High' },
      { color: '#64b5f6', label: 'Moderate' },
      { color: '#e3f2fd', label: 'Low' },
      { color: '#f5f9ff', label: 'None recorded' },
    ],
  },
  connectivity: {
    title: 'Connectivity',
    property: 'corridorImportance',
    legend: [
      { color: '#4a148c', label: 'Critical corridor' },
      { color: '#7b1fa2', label: 'High' },
      { color: '#ba68c8', label: 'Moderate' },
      { color: '#f3e5f5', label: 'Low' },
      { color: '#faf5fb', label: 'Isolated' },
    ],
  },
  heat: {
    title: 'Heat Exposure',
    property: 'heatExposure',
    legend: [
      { color: '#a50026', label: 'Very hot' },
      { color: '#f46d43', label: 'Hot' },
      { color: '#fee090', label: 'Warm' },
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
      { color: '#aed581', label: 'Mixed' },
      { color: '#fff9c4', label: 'Sparse' },
      { color: '#fafafa', label: 'Built / bare' },
    ],
  },
};

export function getActiveLayerId(layers: { id: LayerId; enabled: boolean }[]): LayerId {
  return layers.find((l) => l.enabled)?.id ?? 'impact';
}
