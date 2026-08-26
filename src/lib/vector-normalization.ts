export type VectorLayer =
  | 'green-spaces'
  | 'hex-cells'
  | 'connectivity-network-edges'
  | 'connectivity-network-nodes';

type Primitive = string | number | boolean | null;
type Properties = Record<string, unknown>;
type StrictProperties = Record<string, Primitive>;

export type NormalizationDomain = {
  sourceField: string;
  outputField: string;
  p5: number | null;
  p95: number | null;
  min: number | null;
  max: number | null;
  count: number;
  lowerIsBetter?: boolean;
};

export type NormalizedFeatureCollection = GeoJSON.FeatureCollection & {
  metadata: {
    normalized: true;
    layer: VectorLayer;
    cityId?: string;
    featureCount: number;
    domains: Record<string, NormalizationDomain>;
  };
};

type MetricSpec = {
  sourceField: string;
  outputField: string;
  aliases: string[];
  lowerIsBetter?: boolean;
};

type MetricDomain = NormalizationDomain & {
  low: number | null;
  high: number | null;
};

const ECOLOGICAL_METRICS = [
  {
    sourceField: 'ecological_residual_normalized',
    outputField: 'ecologicalResidualNormalized',
    aliases: ['ecological_residual_normalized', 'ecologicalResidualNormalized', 'ecological_residual', 'ecologicalResidual'],
  },
  {
    sourceField: 'expected_richness',
    outputField: 'expectedRichness',
    aliases: ['expected_richness', 'expectedRichness'],
  },
  {
    sourceField: 'effort_corrected_richness',
    outputField: 'effortCorrectedRichness',
    aliases: ['effort_corrected_richness', 'effortCorrectedRichness', 'observed_richness', 'observedRichness'],
  },
  {
    sourceField: 'habitat_quality_index',
    outputField: 'habitatQualityIndex',
    aliases: ['habitat_quality_index', 'habitatQualityIndex', 'habitat_quality', 'habitatQuality'],
  },
  {
    sourceField: 'canopy_height_idx',
    outputField: 'treeCover',
    aliases: ['canopy_height_idx', 'canopyHeightIdx', 'treeCover', 'tree_cover'],
  },
  {
    sourceField: 'veg_fraction',
    outputField: 'vegFraction',
    aliases: ['veg_fraction', 'vegFraction'],
  },
  {
    sourceField: 'betweenness_centrality',
    outputField: 'betweennessCentrality',
    aliases: ['betweenness_centrality', 'betweennessCentrality', 'corridor_importance', 'corridorImportance', 'connectivity_score'],
  },
  {
    sourceField: 'lst_idx',
    outputField: 'lstIdx',
    aliases: ['lst_idx', 'lstIdx', 'heat_exposure', 'heatExposure', 'mean_lst', 'meanLst'],
  },
  {
    sourceField: 'intervention_rank',
    outputField: 'interventionRank',
    aliases: ['intervention_rank', 'interventionRank'],
    lowerIsBetter: true,
  },
] as const satisfies readonly MetricSpec[];

const ADDITIONAL_RENDER_METRICS = [
  {
    sourceField: 'nature_gap_score',
    outputField: 'natureGapScore',
    aliases: ['nature_gap_score', 'natureGapScore', 'impact_score', 'impactScore'],
  },
  {
    sourceField: 'observed_richness',
    outputField: 'observedRichness',
    aliases: ['observed_richness', 'observedRichness', 'effort_corrected_richness', 'effortCorrectedRichness'],
  },
  {
    sourceField: 'corridor_importance',
    outputField: 'corridorImportance',
    aliases: ['corridor_importance', 'corridorImportance', 'betweenness_centrality', 'betweennessCentrality', 'connectivity_score'],
  },
  {
    sourceField: 'heat_exposure',
    outputField: 'heatExposure',
    aliases: ['heat_exposure', 'heatExposure', 'lst_idx', 'lstIdx', 'mean_lst', 'meanLst'],
  },
  {
    sourceField: 'traffic_exposure',
    outputField: 'trafficExposure',
    aliases: ['traffic_exposure', 'trafficExposure'],
  },
  {
    sourceField: 'rank_stability',
    outputField: 'rankStability',
    aliases: ['rank_stability', 'rankStability'],
  },
  {
    sourceField: 'land_use_green',
    outputField: 'landUseGreen',
    aliases: ['land_use_green', 'landUseGreen'],
  },
] as const satisfies readonly MetricSpec[];

const NORMALIZED_METRICS = [
  ...ECOLOGICAL_METRICS,
  ...ADDITIONAL_RENDER_METRICS,
] as const satisfies readonly MetricSpec[];

const EMPTY_SPECIES_COUNTS = {
  plant: 0,
  bird: 0,
  insect: 0,
  mammal: 0,
  fungi: 0,
};

function asObject(value: unknown): Properties {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Properties
    : {};
}

function asNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value !== 'string' || value.trim() === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function asString(value: unknown, fallback = ''): string {
  if (value == null) return fallback;
  const str = String(value).trim();
  return str.length > 0 && str !== 'undefined' ? str : fallback;
}

function asBoolean(value: unknown): boolean {
  return value === true || value === 'true' || value === 1 || value === '1';
}

function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

function roundNormalized(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

function valueForMetric(props: Properties, spec: MetricSpec): number | null {
  for (const alias of spec.aliases) {
    const value = asNumber(props[alias]);
    if (value !== null) return value;
  }
  return null;
}

function percentile(sortedValues: number[], pct: number): number | null {
  if (sortedValues.length === 0) return null;
  if (sortedValues.length === 1) return sortedValues[0];

  const index = (sortedValues.length - 1) * pct;
  const lower = Math.floor(index);
  const upper = Math.ceil(index);
  const weight = index - lower;
  return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight;
}

function domainForValues(spec: MetricSpec, values: number[]): MetricDomain {
  const sorted = [...values].sort((a, b) => a - b);
  const min = sorted[0] ?? null;
  const max = sorted[sorted.length - 1] ?? null;
  const p5 = percentile(sorted, 0.05);
  const p95 = percentile(sorted, 0.95);
  const low = p5 !== null && p95 !== null && p95 > p5 ? p5 : min;
  const high = p5 !== null && p95 !== null && p95 > p5 ? p95 : max;

  return {
    sourceField: spec.sourceField,
    outputField: spec.outputField,
    p5,
    p95,
    min,
    max,
    low: low ?? null,
    high: high ?? null,
    count: sorted.length,
    ...(spec.lowerIsBetter ? { lowerIsBetter: true } : {}),
  };
}

function buildDomains(features: GeoJSON.Feature[], specs: readonly MetricSpec[]): Record<string, MetricDomain> {
  return Object.fromEntries(specs.map((spec) => {
    const values = features
      .map((feature) => valueForMetric(asObject(feature.properties), spec))
      .filter((value): value is number => value !== null);

    return [spec.outputField, domainForValues(spec, values)];
  }));
}

function normalizeMetric(value: number | null, domain: MetricDomain): number {
  if (value === null || domain.low === null || domain.high === null || domain.high <= domain.low) return 0;
  const scaled = domain.lowerIsBetter
    ? (domain.high - value) / (domain.high - domain.low)
    : (value - domain.low) / (domain.high - domain.low);
  return roundNormalized(clamp01(scaled));
}

function normalizedMetrics(props: Properties, domains: Record<string, MetricDomain>): StrictProperties {
  return Object.fromEntries(NORMALIZED_METRICS.map((spec) => [
    spec.outputField,
    normalizeMetric(valueForMetric(props, spec), domains[spec.outputField]),
  ]));
}

function rawNumber(props: Properties, aliases: string[], fallback = 0): number {
  for (const alias of aliases) {
    const value = asNumber(props[alias]);
    if (value !== null) return value;
  }
  return fallback;
}

function countArrayOrString(value: unknown): number {
  if (Array.isArray(value)) return value.length;
  if (typeof value === 'string' && value.trim().length > 0) return 1;
  return 0;
}

function speciesCounts(value: unknown): StrictProperties {
  if (!Array.isArray(value)) return { ...EMPTY_SPECIES_COUNTS };

  const counts: Record<string, number> = { ...EMPTY_SPECIES_COUNTS };
  for (const item of value) {
    const itemObject = asObject(item);
    const type = asString(itemObject.type);
    const count = rawNumber(itemObject, ['count'], 0);
    if (type in counts) counts[type] += count;
  }

  return counts;
}

function greenSpaceProperties(props: Properties, domains: Record<string, MetricDomain>): StrictProperties {
  const id = asString(props.id ?? props.osm_id, 'unknown-green-space');
  const name = asString(props.name, id);

  return {
    layer: 'green-spaces',
    id,
    parkId: id,
    name,
    parkName: name,
    nameJa: asString(props.nameJa ?? props['name:ja'], name),
    wardId: asString(props.wardId),
    ...normalizedMetrics(props, domains),
    ecologicalResidual: rawNumber(props, ['ecological_residual', 'ecologicalResidual']),
    impactScore: normalizeMetric(valueForMetric(props, ADDITIONAL_RENDER_METRICS[0]), domains.natureGapScore),
    habitatQuality: normalizeMetric(valueForMetric(props, ECOLOGICAL_METRICS[3]), domains.habitatQualityIndex),
    meanLst: normalizeMetric(valueForMetric(props, ECOLOGICAL_METRICS[6]), domains.lstIdx),
    landUseClass: asString(props.land_use_class ?? props.landUseClass, 'unknown'),
    habitatQualityNorm: asNumber(props.habitatQualityNorm ?? props.habitat_quality_norm),
    effortCorrectedRichnessNorm: asNumber(props.effortCorrectedRichnessNorm ?? props.effort_corrected_richness_norm),
    expectedRichnessNorm: asNumber(props.expectedRichnessNorm ?? props.expected_richness_norm),
    corridorImportanceNorm: asNumber(props.corridorImportanceNorm ?? props.corridor_importance_norm),
    meanLstNorm: asNumber(props.meanLstNorm ?? props.mean_lst_norm),
    ecologicalResidualNorm: asNumber(props.ecologicalResidualNorm ?? props.ecological_residual_norm),
    natureGapScoreNorm: asNumber(props.natureGapScoreNorm ?? props.nature_gap_score_norm),
    interventionRankNorm: asNumber(props.interventionRankNorm ?? props.intervention_rank_norm),
    isUnsampled: asBoolean(props.is_unsampled ?? props.isUnsampled),
  };
}

function hexCellProperties(props: Properties, domains: Record<string, MetricDomain>): StrictProperties {
  const cellId = asString(props.cell_id ?? props.cellId, 'unknown-cell');
  const parkId = asString(props.park_id ?? props.parkId);
  const parkName = asString(props.park_name ?? props.parkName, parkId || 'Green area');
  const pressures = props.pressures;
  const interventions = props.interventions;

  return {
    layer: 'hex-cells',
    cellId,
    parkId,
    parkName,
    cityId: asString(props.city_id ?? props.cityId),
    datasetId: asString(props.dataset_id ?? props.datasetId),
    generatedAt: asString(props.generated_at ?? props.generatedAt),
    lastUpdated: asString(props.last_updated ?? props.lastUpdated),
    ...normalizedMetrics(props, domains),
    ecologicalResidual: rawNumber(props, ['ecological_residual', 'ecologicalResidual']),
    impactScore: normalizeMetric(valueForMetric(props, ADDITIONAL_RENDER_METRICS[0]), domains.natureGapScore),
    habitatQuality: normalizeMetric(valueForMetric(props, ECOLOGICAL_METRICS[3]), domains.habitatQualityIndex),
    meanLst: normalizeMetric(valueForMetric(props, ECOLOGICAL_METRICS[6]), domains.lstIdx),
    maxExpectedRichness: rawNumber(props, ['max_expected_richness', 'maxExpectedRichness']),
    speciesRichnessRaw: rawNumber(props, ['species_richness_raw', 'speciesRichnessRaw']),
    observerEffortScore: rawNumber(props, ['observer_effort_score', 'observerEffortScore']),
    taxonomicDiversity: rawNumber(props, ['taxonomic_diversity', 'taxonomicDiversity']),
    nObs: rawNumber(props, ['n_obs', 'nObs']),
    nSurveyDates: rawNumber(props, ['n_survey_dates', 'nSurveyDates']),
    pathKm: rawNumber(props, ['path_km', 'pathKm']),
    isUnsampled: asBoolean(props.is_unsampled ?? props.isUnsampled),
    temporalBiasFlag: asBoolean(props.temporal_bias_flag ?? props.temporalBiasFlag),
    habitatPotential: asString(props.habitat_potential ?? props.habitatPotential, 'low'),
    landUseClass: asString(props.land_use_class ?? props.landUseClass, 'unknown'),
    pressureCount: countArrayOrString(pressures),
    interventionCount: countArrayOrString(interventions),
    speciesCount: countArrayOrString(props.species),
    ...speciesCounts(props.species),
    ndviNorm: asNumber(props.ndviNorm ?? props.ndvi_norm),
    lstNorm: asNumber(props.lstNorm ?? props.lst_norm),
    disturbanceNorm: asNumber(props.disturbanceNorm ?? props.disturbance_norm),
    betweennessNorm: asNumber(props.betweennessNorm ?? props.betweenness_norm),
    residualNorm: asNumber(props.residualNorm ?? props.residual_norm),
  };
}

const CORRIDOR_STRENGTHS = ['weak', 'moderate', 'strong', 'strongest'] as const;
const CORRIDOR_RANKS = ['minor', 'secondary', 'primary'] as const;
const CORRIDOR_KINDS = ['corridor', 'bottleneck'] as const;
const NODE_TIERS = ['major', 'secondary', 'stepping-stone'] as const;

// The derived network arrives pre-classified from 04_connectivity: `importance`
// is already a 0-1 percentile and `strength`/`tier` are already bucketed, so
// nothing here re-derives them. Unknown class values fall back to the weakest
// bucket rather than being passed through, so a bad value cannot reach a
// MapLibre match expression and paint an undefined colour.
function networkEdgeProperties(props: Properties): StrictProperties {
  const strength = asString(props.strength);
  const rank = asString(props.rank);
  const kind = asString(props.kind);
  return {
    corridorId: asString(props.corridorId ?? props.corridor_id),
    sectionIndex: rawNumber(props, ['sectionIndex', 'section_index']),
    fromNode: asString(props.fromNode ?? props.from_node),
    toNode: asString(props.toNode ?? props.to_node),
    lengthM: rawNumber(props, ['lengthM', 'length_m']),
    meanResistance: rawNumber(props, ['meanResistance', 'mean_resistance']),
    bottlenecks: rawNumber(props, ['bottlenecks']),
    importance: roundNormalized(clamp01(asNumber(props.importance) ?? 0)),
    strength: (CORRIDOR_STRENGTHS as readonly string[]).includes(strength) ? strength : 'weak',
    // Rank drives the zoom hierarchy, so an unknown value must fall to the class
    // that appears last rather than the one that appears at city scale.
    rank: (CORRIDOR_RANKS as readonly string[]).includes(rank) ? rank : 'minor',
    kind: (CORRIDOR_KINDS as readonly string[]).includes(kind) ? kind : 'corridor',
  };
}

function networkNodeProperties(props: Properties): StrictProperties {
  const tier = asString(props.tier);
  return {
    cellId: asString(props.cellId ?? props.cell_id),
    tier: (NODE_TIERS as readonly string[]).includes(tier) ? tier : 'stepping-stone',
    degree: rawNumber(props, ['degree']),
    coreCells: rawNumber(props, ['coreCells', 'core_cells']),
    areaHa: rawNumber(props, ['areaHa', 'area_ha']),
    importance: roundNormalized(clamp01(asNumber(props.importance) ?? 0)),
  };
}

function stripDomain(domain: MetricDomain): NormalizationDomain {
  return {
    sourceField: domain.sourceField,
    outputField: domain.outputField,
    p5: domain.p5,
    p95: domain.p95,
    min: domain.min,
    max: domain.max,
    count: domain.count,
    ...(domain.lowerIsBetter ? { lowerIsBetter: true } : {}),
  };
}

function strictFeature(
  feature: GeoJSON.Feature,
  properties: StrictProperties,
): GeoJSON.Feature {
  return {
    type: 'Feature',
    properties,
    geometry: feature.geometry,
  };
}

export function normalizeVectorGeoJSON(
  input: GeoJSON.FeatureCollection,
  layer: VectorLayer,
  cityId?: string,
): NormalizedFeatureCollection {
  const features = Array.isArray(input.features) ? input.features : [];
  // The network layers carry their own already-normalised fields, so they need
  // no domain pass over the collection.
  const isNetwork = layer === 'connectivity-network-edges' || layer === 'connectivity-network-nodes';
  const domains = isNetwork ? {} : buildDomains(features, NORMALIZED_METRICS);

  const normalizedFeatures = features.map((feature) => {
    const props = asObject(feature.properties);
    if (layer === 'green-spaces') return strictFeature(feature, greenSpaceProperties(props, domains));
    if (layer === 'hex-cells') return strictFeature(feature, hexCellProperties(props, domains));
    if (layer === 'connectivity-network-nodes') return strictFeature(feature, networkNodeProperties(props));
    return strictFeature(feature, networkEdgeProperties(props));
  });

  return {
    type: 'FeatureCollection',
    features: normalizedFeatures,
    metadata: {
      normalized: true,
      layer,
      ...(cityId ? { cityId } : {}),
      featureCount: normalizedFeatures.length,
      domains: Object.fromEntries(Object.entries(domains).map(([key, domain]) => [key, stripDomain(domain)])),
    },
  };
}

export function isVectorLayer(value: string): value is VectorLayer {
  return value === 'green-spaces'
    || value === 'hex-cells'
    || value === 'connectivity-network-edges'
    || value === 'connectivity-network-nodes';
}
