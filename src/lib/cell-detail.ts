import { MAX_EXPECTED_RICHNESS, CITY, CITIES } from './config';
import { getParkStats, getParks } from './green-spaces';
import {
  basename,
  dirname,
  fetchStorageJson,
  joinPath,
  listActivePipelineDatasets,
  resolveDatasetFile,
} from './pipeline-manifest';
import type { CellData, HabitatPotential, ImpactStatus, Intervention, Species } from './types';

const CITY_ID_PREFIXES = Object.keys(CITIES);

/** Map tiles use local cell ids; PostgreSQL stores `{cityId}-{localId}`. */
export function resolveCellId(cellId: string, cityId?: string): string {
  const trimmed = cellId.trim();
  if (!trimmed) return trimmed;

  for (const prefix of CITY_ID_PREFIXES) {
    if (trimmed.startsWith(`${prefix}-`)) return trimmed;
  }

  const city = cityId ?? CITY.id;
  return `${city}-${trimmed}`;
}

export type RenderCellProperties = {
  cellId: string;
  /** Pipeline city slug this feature belongs to — present on hex-tile properties. */
  cityId?: string;
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
  heatExposure?: number | null;
  meanLst?: number | null;
  lstIdx?: number | null;
  landUseGreen?: number | null;
  landUseClass?: CellData['landUseClass'];
  canopyHeightIdx?: number | null;
  treeCoverNorm?: number | null;
  ndviNorm?: number | null;
  lstNorm?: number | null;
  disturbanceNorm?: number | null;
  betweennessNorm?: number | null;
  expectedNorm?: number | null;
  habitatQualityNorm?: number | null;
  residualNorm?: number | null;
  natureGapScoreNorm?: number | null;
  interventionRank?: number | null;
  interventionRankNorm?: number | null;
  /** Optional map-tile fallback before Supabase load completes. */
  nObs?: number;
  speciesRichnessRaw?: number;
  isUnsampled?: boolean;
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
  data_availability_ratio: number | null;
  fragmentation: number | null;
  connectivity_score: number | null;
  tree_cover: number | null;
  tree_cover_norm: number | null;
  land_use_green: number | null;
  land_use_class: CellData['landUseClass'] | null;
  habitat_quality_norm: number | null;
  effort_corrected_richness_norm: number | null;
  expected_richness_norm: number | null;
  corridor_importance_norm: number | null;
  mean_lst_norm: number | null;
  ecological_residual_norm: number | null;
  nature_gap_score_norm: number | null;
  intervention_rank_norm: number | null;
  pressures: unknown;
  interventions: unknown;
};

type CellDetailManifest = {
  shardCount?: unknown;
  pathTemplate?: unknown;
  shards?: unknown;
};

const CELL_DETAIL_MANIFEST = 'cell-details.manifest.json';
const cellDetailManifestCache = new Map<string, Promise<CellDetailManifest | null>>();
const cellDetailShardCache = new Map<string, Promise<Record<string, CellAttributeRow>>>();

function pct(value: number | null | undefined): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 0;
  return Math.round(Math.max(0, Math.min(100, value <= 1 ? value * 100 : value)));
}

function impactStatus(score: number): ImpactStatus {
  if (score < -15) return 'much-better';
  if (score < -5) return 'better';
  if (score < 10) return 'as-expected';
  if (score < 20) return 'worse';
  return 'much-worse';
}

function habitatPotential(habitatQuality: number): HabitatPotential {
  if (habitatQuality >= 70) return 'high';
  if (habitatQuality >= 40) return 'moderate';
  return 'low';
}

/**
 * The R pipeline serialises species/pressures/interventions with jsonlite::toJSON,
 * so cell_attributes may store them as JSON-encoded strings rather than arrays.
 * Parse those back before validating.
 */
function parseMaybeJson(value: unknown): unknown {
  if (typeof value !== 'string') return value;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

function asObject(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function cellDetailShard(cellId: string, shardCount: number): number {
  const localId = cellId.replace(new RegExp(`^(${CITY_ID_PREFIXES.join('|')})-`), '');
  const numericId = Number.parseInt(localId, 10);
  const hash = Number.isFinite(numericId)
    ? numericId
    : Array.from(localId).reduce((sum, char) => sum + char.charCodeAt(0), 0);
  return ((hash % shardCount) + shardCount) % shardCount;
}

function formatShardPath(template: string, shard: number): string {
  return template.replace('{shard}', String(shard).padStart(3, '0'));
}

async function fetchCellDetailManifest(
  manifestPath: string,
  cacheKey: string,
): Promise<CellDetailManifest | null> {
  const cached = cellDetailManifestCache.get(cacheKey);
  if (cached) return cached;

  const promise = (async () => {
    const manifest = asObject(await fetchStorageJson(manifestPath));
    return manifest as CellDetailManifest | null;
  })();
  cellDetailManifestCache.set(cacheKey, promise);
  return promise;
}

async function fetchStorageCellDetail(cellId: string, cityId: string): Promise<CellAttributeRow | null> {
  const dataset = (await listActivePipelineDatasets()).find((item) => item.cityId === cityId);
  if (!dataset || !dataset.files[CELL_DETAIL_MANIFEST]) return null;

  const manifestPath = resolveDatasetFile(dataset, CELL_DETAIL_MANIFEST);
  const manifestCacheKey = `${dataset.cityId}/${dataset.dataVersion}/${CELL_DETAIL_MANIFEST}`;
  const manifest = await fetchCellDetailManifest(manifestPath, manifestCacheKey);
  const shardCount = Number(manifest?.shardCount);
  if (!Number.isInteger(shardCount) || shardCount <= 0) return null;

  const shard = cellDetailShard(cellId, shardCount);
  const shards = Array.isArray(manifest?.shards) ? manifest.shards : [];
  const shardFromList = asString(shards[shard]);
  const template = asString(manifest?.pathTemplate) ?? 'cell-details/cell-details-{shard}.json';
  const shardPath = shardFromList ?? formatShardPath(template, shard);
  const resolvedShardPath = joinPath(dirname(manifestPath), basename(shardPath) === shardPath ? shardPath : shardPath);
  const cacheKey = `${dataset.cityId}/${dataset.dataVersion}/${resolvedShardPath}`;

  const shardPromise = cellDetailShardCache.get(cacheKey) ?? (async () => {
    const payload = asObject(await fetchStorageJson(resolvedShardPath));
    return (payload ?? {}) as Record<string, CellAttributeRow>;
  })();
  cellDetailShardCache.set(cacheKey, shardPromise);

  const records = await shardPromise;
  return records[cellId] ?? null;
}

function speciesArray(value: unknown): Species[] {
  const parsed = parseMaybeJson(value);
  if (!Array.isArray(parsed)) return [];
  return parsed.filter((item): item is Species => (
    typeof item === 'object' &&
    item !== null &&
    typeof (item as Species).type === 'string' &&
    typeof (item as Species).count === 'number'
  ));
}

function stringArray(value: unknown): string[] {
  const parsed = parseMaybeJson(value);
  return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === 'string') : [];
}

function interventionArray(value: unknown): Intervention[] {
  const parsed = parseMaybeJson(value);
  if (!Array.isArray(parsed)) return [];
  return parsed.filter((item): item is Intervention => (
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
  const treeCover = pct(row?.tree_cover ?? render.treeCover ?? render.canopyHeightIdx);
  const meanLst = pct(render.meanLst);
  const landUseClass = row?.land_use_class ?? render.landUseClass ?? 'unknown';
  const habitatPotentialValue = row?.habitat_potential;
  const displayName = render.parkName && render.parkName !== 'city-green'
    ? render.parkName
    : 'Green area';

  const species = speciesArray(row?.species);
  const pressures = stringArray(row?.pressures);
  const interventions = interventionArray(row?.interventions);

  return {
    id: render.cellId,
    cityId: render.cityId ?? CITY.id,
    name: displayName,
    nameJa: displayName,
    coordinates,
    impactScore,
    natureGapScore,
    habitatQuality,
    habitatQualityIndex: row?.habitat_quality_index ?? habitatQuality / 100,
    speciesRichnessRaw: Number(row?.species_richness_raw ?? render.speciesRichnessRaw ?? 0),
    observedRichness,
    effortCorrectedRichness: observedRichness,
    expectedRichness,
    maxExpectedRichness: Number(row?.max_expected_richness ?? MAX_EXPECTED_RICHNESS),
    ecologicalResidual,
    ecologicalResidualNormalized: row?.ecological_residual_norm ?? render.ecologicalResidualNormalized ?? render.residualNorm ?? undefined,
    dataAvailabilityRatio: row?.data_availability_ratio ?? undefined,
    isUnsampled: row?.is_unsampled ?? render.isUnsampled ?? undefined,
    temporalBiasFlag: row?.temporal_bias_flag ?? undefined,
    pathKm: row?.path_km ?? undefined,
    nObs: Number(row?.n_obs ?? render.nObs ?? 0),
    nSurveyDates: Number(row?.n_survey_dates ?? 0),
    status: impactStatus(impactScore),
    habitatPotential: habitatPotentialValue === 'high' || habitatPotentialValue === 'moderate' || habitatPotentialValue === 'low'
      ? habitatPotentialValue
      : habitatPotential(habitatQuality),
    observerEffortScore: Number(row?.observer_effort_score ?? 0),
    taxonomicDiversity: Number(row?.taxonomic_diversity ?? 0),
    species,
    corridorImportance,
    betweennessCentrality: pct(render.betweennessCentrality),
    treeCover,
    treeCoverNorm: row?.tree_cover_norm ?? render.treeCoverNorm ?? undefined,
    heatExposure,
    meanLst,
    lstIdx: pct(render.lstIdx),
    landUseGreen: pct(row?.land_use_green ?? render.landUseGreen),
    landUseClass,
    pressures,
    interventions,
    habitatQualityNorm: row?.habitat_quality_norm ?? render.habitatQualityNorm ?? undefined,
    effortCorrectedRichnessNorm: row?.effort_corrected_richness_norm ?? undefined,
    expectedRichnessNorm: row?.expected_richness_norm ?? render.expectedNorm ?? undefined,
    corridorImportanceNorm: row?.corridor_importance_norm ?? render.betweennessNorm ?? undefined,
    meanLstNorm: row?.mean_lst_norm ?? render.lstNorm ?? undefined,
    ecologicalResidualNorm: row?.ecological_residual_norm ?? render.residualNorm ?? undefined,
    natureGapScoreNorm: row?.nature_gap_score_norm ?? render.natureGapScoreNorm ?? undefined,
    interventionRank: row?.intervention_rank ?? render.interventionRank ?? undefined,
    interventionRankNorm: row?.intervention_rank_norm ?? render.interventionRankNorm ?? undefined,
  };
}

/** Immediate panel payload from map tile properties — no Storage fetch. */
export function cellDetailFromRender(
  render: RenderCellProperties,
  coordinates: [number, number],
): CellData | null {
  if (!render.cellId) return null;
  return detailFromRow(null, render, coordinates);
}

export async function fetchCellDetail(
  render: RenderCellProperties,
  coordinates: [number, number],
): Promise<CellData | null> {
  if (!render.cellId) return null;

  const lookupCellId = resolveCellId(render.cellId, render.cityId);
  const lookupCityId = render.cityId ?? CITY.id;

  const storageRow = await fetchStorageCellDetail(lookupCellId, lookupCityId);
  if (storageRow) {
    return detailFromRow(storageRow, render, coordinates);
  }

  return detailFromRow(null, render, coordinates);
}

/** Patch-level detail from aggregated park stats (biodiversity circles / park click). */
export async function fetchParkDetail(
  parkId: string,
  coordinates: [number, number],
): Promise<CellData | null> {
  const stats = getParkStats()[parkId];
  if (!stats) return null;

  const park = getParks().find((entry) => entry.id === parkId);

  return {
    id: parkId,
    cityId: park?.cityId ?? CITY.id,
    name: park?.name ?? parkId,
    nameJa: park?.nameJa ?? park?.name ?? parkId,
    coordinates,
    ...stats,
    species: stats.species ?? [],
    pressures: stats.pressures ?? [],
    interventions: stats.interventions ?? [],
  };
}
