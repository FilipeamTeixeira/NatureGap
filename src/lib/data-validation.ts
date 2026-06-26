import type { CellStatsFields, HabitatPotential, ImpactStatus, Intervention, Species } from './types';
import type { GreenSpace } from './green-spaces';

export type ParkStats = CellStatsFields;

const IMPACT_STATUSES = ['much-worse', 'worse', 'as-expected', 'better', 'much-better'] satisfies ImpactStatus[];
const HABITAT_POTENTIALS = ['low', 'moderate', 'high'] satisfies HabitatPotential[];
const SPECIES_TYPES = ['plant', 'bird', 'insect', 'mammal', 'fungi'];
const INTERVENTION_IMPACTS = ['high', 'medium', 'low'];
const INTERVENTION_CATEGORIES = ['canopy', 'corridor', 'pollinator', 'water', 'ground'];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isString(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0;
}

function isNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

function isNullableNumber(value: unknown): value is number | null {
  return value === null || isNumber(value);
}

function isStringArray(value: unknown): value is string[] {
  if (typeof value === 'string') return true;
  return Array.isArray(value) && value.every((v) => typeof v === 'string');
}

function normalizeStringArray(value: unknown): string[] {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.filter((v): v is string => typeof v === 'string');
  return [];
}

function isLngLat(value: unknown): value is [number, number] {
  return Array.isArray(value) && value.length === 2 && isNumber(value[0]) && isNumber(value[1]);
}

function isSpecies(value: unknown): value is Species {
  if (!isRecord(value)) return false;
  const namesOk =
    value.names === undefined ||
    (Array.isArray(value.names) && value.names.every((n) => typeof n === 'string')) ||
    typeof value.names === 'string';
  return (
    typeof value.type === 'string' &&
    SPECIES_TYPES.includes(value.type) &&
    isNumber(value.count) &&
    namesOk
  );
}

function isIntervention(value: unknown): value is Intervention {
  return (
    isRecord(value) &&
    isString(value.id) &&
    isString(value.title) &&
    isString(value.description) &&
    typeof value.impact === 'string' &&
    INTERVENTION_IMPACTS.includes(value.impact) &&
    typeof value.category === 'string' &&
    INTERVENTION_CATEGORIES.includes(value.category) &&
    (value.connectivityGain === undefined || isNumber(value.connectivityGain))
  );
}

function assertCellStats(value: unknown, id: string): asserts value is CellStatsFields {
  if (!isRecord(value)) throw new Error(`Invalid stats entry for ${id}: expected object`);

  const valid =
    isNumber(value.impactScore) &&
    isNumber(value.habitatQuality) &&
    isNumber(value.habitatQualityIndex) &&
    isNumber(value.speciesRichnessRaw) &&
    isNullableNumber(value.observedRichness) &&
    (value.effortCorrectedRichness === undefined || isNullableNumber(value.effortCorrectedRichness)) &&
    isNumber(value.expectedRichness) &&
    isNumber(value.maxExpectedRichness) &&
    isNullableNumber(value.ecologicalResidual) &&
    (value.isUnsampled === undefined || typeof value.isUnsampled === 'boolean') &&
    (value.temporalBiasFlag === undefined || typeof value.temporalBiasFlag === 'boolean') &&
    (value.pathKm === undefined || isNumber(value.pathKm)) &&
    isNumber(value.nObs) &&
    isNumber(value.nSurveyDates) &&
    typeof value.status === 'string' &&
    IMPACT_STATUSES.includes(value.status as ImpactStatus) &&
    typeof value.habitatPotential === 'string' &&
    HABITAT_POTENTIALS.includes(value.habitatPotential as HabitatPotential) &&
    isNumber(value.observerEffortScore) &&
    isNumber(value.taxonomicDiversity) &&
    isNumber(value.corridorImportance) &&
    isNumber(value.fragmentationIndex) &&
    Array.isArray(value.species) &&
    value.species.every(isSpecies) &&
    isStringArray(value.pressures) &&
    Array.isArray(value.interventions) &&
    value.interventions.every(isIntervention);

  if (!valid) throw new Error(`Invalid stats entry for ${id}`);
}

function normalizeSpeciesNames(species: Species[]): Species[] {
  return species.map((s) => ({
    ...s,
    names: s.names
      ? Array.isArray(s.names)
        ? s.names
        : [s.names]
      : undefined,
  }));
}

function normalizeCellStats(value: Record<string, unknown>): CellStatsFields {
  assertCellStats(value, 'entry');
  const stats = value as CellStatsFields;
  return {
    ...stats,
    species: normalizeSpeciesNames(stats.species),
    pressures: normalizeStringArray(value.pressures),
  };
}

export function parseGreenSpaces(value: unknown): GreenSpace[] {
  if (!Array.isArray(value)) throw new Error('Invalid green-spaces data: expected array');

  return value.map((space, index) => {
    if (!isRecord(space)) throw new Error(`Invalid green space at index ${index}: expected object`);
    if (!isString(space.id)) throw new Error(`Invalid green space at index ${index}: missing id`);
    if (!isString(space.name)) throw new Error(`Invalid green space ${space.id}: missing name`);
    if (!isString(space.nameJa)) throw new Error(`Invalid green space ${space.id}: missing nameJa`);
    if (!isString(space.wardId)) throw new Error(`Invalid green space ${space.id}: missing wardId`);
    if (!Array.isArray(space.ring) || !space.ring.every(isLngLat)) {
      throw new Error(`Invalid green space ${space.id}: ring must be [lng, lat][]`);
    }

    const [first] = space.ring;
    const last = space.ring[space.ring.length - 1];
    if (!first || !last || first[0] !== last[0] || first[1] !== last[1]) {
      throw new Error(`Invalid green space ${space.id}: ring must be closed`);
    }

    return {
      id: space.id,
      name: space.name,
      nameJa: space.nameJa,
      wardId: space.wardId,
      ring: space.ring,
    };
  });
}

export function parseParkStats(value: unknown): Record<string, ParkStats> {
  if (!isRecord(value)) throw new Error('Invalid park-stats data: expected object keyed by park id');

  const out: Record<string, ParkStats> = {};
  for (const [id, stats] of Object.entries(value)) {
    if (!isRecord(stats)) throw new Error(`Invalid park-stats entry for ${id}: expected object`);
    out[id] = normalizeCellStats(stats);
  }
  return out;
}

export function parseCellsJson(value: unknown): Record<string, ParkStats> {
  if (!isRecord(value)) throw new Error('Invalid cells.json: expected object keyed by cell id');

  const out: Record<string, ParkStats> = {};
  for (const [id, stats] of Object.entries(value)) {
    if (!isRecord(stats)) throw new Error(`Invalid cells.json entry for ${id}: expected object`);
    out[id] = normalizeCellStats(stats);
  }
  return out;
}
