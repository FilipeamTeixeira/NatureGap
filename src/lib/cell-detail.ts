import { MAX_EXPECTED_RICHNESS } from './config';
import { supabase } from './supabase';
import type { CellData, HabitatPotential, ImpactStatus, Intervention, Species } from './types';

export type RenderCellProperties = {
  cellId: string;
  parkId?: string;
  parkName?: string;
  impactScore?: number;
  natureGapScore?: number | null;
  expectedRichness?: number | null;
  ecologicalResidual?: number | null;
  ecologicalResidualNormalized?: number | null;
  habitatQuality?: number | null;
  observedRichness?: number | null;
  corridorImportance?: number | null;
  betweennessCentrality?: number | null;
  treeCover?: number | null;
  meanCanopy?: number | null;
  canopyHeightIdx?: number | null;
  heatExposure?: number | null;
  meanLst?: number | null;
  lstIdx?: number | null;
  landUseGreen?: number | null;
  interventionRank?: number | null;
};

type CellAttributeRow = {
  cell_id: string;
  impact_score: number | null;
  nature_gap_score: number | null;
  habitat_quality: number | null;
  habitat_quality_index: number | null;
  species_richness_raw: number | null;
  observed_richness: number | null;
  expected_richness: number | null;
  effort_corrected_richness: number | null;
  ecological_residual: number | null;
  max_expected_richness: number | null;
  is_unsampled: boolean | null;
  temporal_bias_flag: boolean | null;
  path_km: number | null;
  n_obs: number | null;
  n_survey_dates: number | null;
  habitat_potential: string | null;
  observer_effort_score: number | null;
  taxonomic_diversity: number | null;
  species: unknown;
  corridor_importance: number | null;
  intervention_rank: number | null;
  heat_exposure: number | null;
  fragmentation: number | null;
  connectivity_score: number | null;
  tree_cover: number | null;
  land_use_green: number | null;
  pressures: unknown;
  interventions: unknown;
};

function pct(value: number | null | undefined): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 0;
  return Math.round(Math.max(0, Math.min(100, value <= 1 ? value * 100 : value)));
}

function impactStatus(score: number): ImpactStatus {
  if (score < -20) return 'much-worse';
  if (score < -10) return 'worse';
  if (score < 5) return 'as-expected';
  if (score < 15) return 'better';
  return 'much-better';
}

function habitatPotential(habitatQuality: number): HabitatPotential {
  if (habitatQuality >= 70) return 'high';
  if (habitatQuality >= 40) return 'moderate';
  return 'low';
}

function speciesArray(value: unknown): Species[] {
  if (!Array.isArray(value)) {
    return [
      { type: 'plant', count: 0 },
      { type: 'bird', count: 0 },
      { type: 'insect', count: 0 },
      { type: 'mammal', count: 0 },
      { type: 'fungi', count: 0 },
    ];
  }
  return value.filter((item): item is Species => (
    typeof item === 'object' &&
    item !== null &&
    typeof (item as Species).type === 'string' &&
    typeof (item as Species).count === 'number'
  ));
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : [];
}

function interventionArray(value: unknown): Intervention[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is Intervention => (
    typeof item === 'object' &&
    item !== null &&
    typeof (item as Intervention).id === 'string' &&
    typeof (item as Intervention).title === 'string' &&
    typeof (item as Intervention).description === 'string'
  ));
}

function detailFromRow(
  row: CellAttributeRow | null,
  render: RenderCellProperties,
  coordinates: [number, number],
): CellData {
  const expectedRichness = Number(row?.expected_richness ?? render.expectedRichness ?? 0);
  const observedRichness = row?.observed_richness ?? row?.effort_corrected_richness ?? render.observedRichness ?? null;
  const ecologicalResidual = row?.ecological_residual ?? render.ecologicalResidual ?? null;
  const natureGapScore = Number(row?.nature_gap_score ?? render.natureGapScore ?? 0);
  const impactScore = natureGapScore;
  const habitatQuality = pct(row?.habitat_quality ?? render.habitatQuality);
  const corridorImportance = pct(row?.corridor_importance ?? render.corridorImportance);
  const heatExposure = pct(row?.heat_exposure ?? render.heatExposure);
  const fragmentationIndex = pct(row?.fragmentation);
  const habitatPotentialValue = row?.habitat_potential;
  const displayName = render.parkName && render.parkName !== 'city-green'
    ? render.parkName
    : 'Green area';

  return {
    id: render.cellId,
    name: displayName,
    nameJa: displayName,
    coordinates,
    impactScore,
    natureGapScore,
    habitatQuality,
    habitatQualityIndex: row?.habitat_quality_index ?? habitatQuality / 100,
    speciesRichnessRaw: Number(row?.species_richness_raw ?? 0),
    observedRichness,
    effortCorrectedRichness: observedRichness,
    expectedRichness,
    maxExpectedRichness: Number(row?.max_expected_richness ?? MAX_EXPECTED_RICHNESS),
    ecologicalResidual,
    isUnsampled: row?.is_unsampled ?? undefined,
    temporalBiasFlag: row?.temporal_bias_flag ?? undefined,
    pathKm: row?.path_km ?? undefined,
    nObs: Number(row?.n_obs ?? 0),
    nSurveyDates: Number(row?.n_survey_dates ?? 0),
    status: impactStatus(impactScore),
    habitatPotential: habitatPotentialValue === 'high' || habitatPotentialValue === 'moderate' || habitatPotentialValue === 'low'
      ? habitatPotentialValue
      : habitatPotential(habitatQuality),
    observerEffortScore: Number(row?.observer_effort_score ?? 0),
    taxonomicDiversity: Number(row?.taxonomic_diversity ?? 0),
    species: speciesArray(row?.species),
    corridorImportance,
    betweennessCentrality: pct(render.betweennessCentrality),
    fragmentationIndex,
    treeCover: pct(row?.tree_cover ?? render.treeCover),
    meanCanopy: pct(render.meanCanopy),
    canopyHeightIdx: pct(render.canopyHeightIdx),
    heatExposure,
    meanLst: pct(render.meanLst),
    lstIdx: pct(render.lstIdx),
    landUseGreen: pct(row?.land_use_green ?? render.landUseGreen),
    pressures: stringArray(row?.pressures),
    interventions: interventionArray(row?.interventions),
  };
}

export async function fetchCellDetail(
  render: RenderCellProperties,
  coordinates: [number, number],
): Promise<CellData | null> {
  if (!render.cellId) return null;

  if (!supabase) return detailFromRow(null, render, coordinates);

  const { data, error } = await supabase
    .from('cell_attributes')
    .select(
      [
        'cell_id',
        'impact_score',
        'nature_gap_score',
        'habitat_quality',
        'habitat_quality_index',
        'species_richness_raw',
        'observed_richness',
        'expected_richness',
        'effort_corrected_richness',
        'ecological_residual',
        'max_expected_richness',
        'is_unsampled',
        'temporal_bias_flag',
        'path_km',
        'n_obs',
        'n_survey_dates',
        'habitat_potential',
        'observer_effort_score',
        'taxonomic_diversity',
        'species',
        'corridor_importance',
        'intervention_rank',
        'heat_exposure',
        'fragmentation',
        'connectivity_score',
        'tree_cover',
        'land_use_green',
        'pressures',
        'interventions',
      ].join(', '),
    )
    .eq('cell_id', render.cellId)
    .maybeSingle<CellAttributeRow>();

  if (error) {
    console.warn('[cell-detail] Failed to load cell detail:', error);
  }

  return detailFromRow(data ?? null, render, coordinates);
}
