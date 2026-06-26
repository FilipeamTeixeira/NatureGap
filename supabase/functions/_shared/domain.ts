import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.108.2';
import type { TaxonGroup } from './validation.ts';

export interface SpeciesReference {
  id: string;
  taxon_group: TaxonGroup;
  region_plausibility: Record<string, unknown>;
  requires_photo_on_first_record: boolean;
}

export async function findCellId(
  client: SupabaseClient,
  lng: number,
  lat: number,
): Promise<string | null> {
  const { data, error } = await client.rpc('find_cell_id_for_point', { lng, lat });
  if (error) throw error;
  return typeof data === 'string' && data.length > 0 ? data : null;
}

export async function findSurveyPointCellId(
  client: SupabaseClient,
  surveyPointId: string,
): Promise<string | null> {
  const { data, error } = await client.rpc('find_cell_id_for_survey_point', { point_id: surveyPointId });
  if (error) throw error;
  return typeof data === 'string' && data.length > 0 ? data : null;
}

export async function loadSpeciesReference(
  client: SupabaseClient,
  speciesId: string | null,
): Promise<SpeciesReference | null> {
  if (!speciesId) return null;

  const { data, error } = await client
    .from('species_reference')
    .select('id, taxon_group, region_plausibility, requires_photo_on_first_record')
    .eq('id', speciesId)
    .maybeSingle();

  if (error) throw error;
  if (!data) {
    throw Object.assign(new Error('species_id does not exist'), { status: 400 });
  }

  return data as SpeciesReference;
}

export function assertSpeciesTaxonGroup(
  species: SpeciesReference | null,
  taxonGroup: TaxonGroup,
): void {
  if (species && species.taxon_group !== taxonGroup) {
    throw Object.assign(new Error('species_id taxon group does not match taxon_group'), { status: 400 });
  }
}

export function plausibilityReasons(
  species: SpeciesReference | null,
  cellId: string | null,
  observedAt: Date,
): string[] {
  if (!species) return [];
  const plausibility = species.region_plausibility ?? {};
  const reasons: string[] = [];
  const month = observedAt.getUTCMonth() + 1;

  const cellIds = arrayOfStrings(plausibility.cell_ids ?? plausibility.cells);
  if (cellIds.length > 0 && (!cellId || !cellIds.includes(cellId))) {
    reasons.push('Species outside known cell range');
  }

  const months = arrayOfNumbers(plausibility.months ?? plausibility.season_months);
  if (months.length > 0 && !months.includes(month)) {
    reasons.push('Species outside known season');
  }

  return reasons;
}

export async function createFlag(
  client: SupabaseClient,
  recordType: string,
  recordId: string,
  reason: string,
  flaggedBy: string,
): Promise<void> {
  const { error } = await client
    .from('flags')
    .insert({
      record_type: recordType,
      record_id: recordId,
      reason,
      flagged_by: flaggedBy,
      outcome: 'pending',
    });
  if (error) throw error;
}

export async function maybeFlagAccuracy(
  client: SupabaseClient,
  recordType: string,
  recordId: string,
  accuracyM: number,
  userId: string,
): Promise<void> {
  if (accuracyM <= 25) return;
  await createFlag(client, recordType, recordId, `GPS accuracy exceeds 25m (${accuracyM}m)`, userId);
}

export async function maybeFlagPlausibility(
  client: SupabaseClient,
  recordType: string,
  recordId: string,
  reasons: string[],
  userId: string,
): Promise<boolean> {
  if (reasons.length === 0) return false;
  await createFlag(client, recordType, recordId, reasons.join('; '), userId);
  return true;
}

function arrayOfStrings(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is string => typeof item === 'string' && item.length > 0);
}

function arrayOfNumbers(value: unknown): number[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is number => Number.isInteger(item));
}
