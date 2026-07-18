import { supabase } from './supabase';

const PHOTO_BUCKET = process.env.NEXT_PUBLIC_CITIZEN_PHOTO_BUCKET ?? 'citizen-photos';

export type AppRole = 'contributor' | 'surveyor' | 'taxonomist' | 'admin';
export type TaxonGroup = 'bird' | 'insect' | 'plant' | 'amphibian' | 'other';
export type SuggestionType = 'species' | 'action' | 'survey_point' | 'habitat_photo' | 'local_note';
export type HabitatChoice =
  | 'uniform mown'
  | 'mixed'
  | 'tall grass'
  | 'scrub'
  | 'none'
  | 'sparse'
  | 'moderate'
  | 'dense'
  | 'low'
  | 'medium'
  | 'high'
  | 'puddle'
  | 'ditch'
  | 'stream'
  | 'pond';

export interface SpeciesReferenceOption {
  id: string;
  taxon_group: TaxonGroup;
  common_name: string;
  scientific_name: string;
  requires_photo_on_first_record: boolean;
}

export interface SurveyPointFeature {
  id: string;
  status: 'pending' | 'approved' | 'rejected';
  coordinates: [number, number];
}

export interface StructuredSurveyFeature {
  id: string;
  status: string;
  survey_point_id: string;
  cell_id: string | null;
  started_at: string;
  submitted_at: string | null;
  coordinates: [number, number];
}

export interface ObservationHistoryItem {
  id: string;
  kind: 'structured_survey';
  label: string;
  status: string;
  created_at: string;
  detail: string;
}

export type ReviewStatus =
  | 'submitted'
  | 'pending_verification'
  | 'verified'
  | 'approved'
  | 'rejected'
  | 'flagged_review';

export type SurveyReviewDecision = 'advance' | 'reject';
export type SuggestionDecision = 'approved' | 'rejected' | 'needs_revision';

export interface ReviewSurveyRecord {
  id: string;
  taxon_group: TaxonGroup;
  species_label: string | null;
  count: number;
  notes: string | null;
}

export interface ReviewSurveyItem {
  id: string;
  status: ReviewStatus;
  survey_point_id: string;
  cell_id: string | null;
  started_at: string;
  submitted_at: string | null;
  duration_seconds: number;
  habitat_indicators: Record<string, unknown>;
  records: ReviewSurveyRecord[];
  flags: { reason: string; outcome: string }[];
}

export interface PendingSurveyPoint {
  id: string;
  coordinates: [number, number];
  created_at: string;
}

export interface PendingSuggestion {
  id: string;
  type: SuggestionType;
  payload: Record<string, unknown>;
  created_at: string;
}

export interface HabitatIndicators {
  vegetation_height_variation: 'uniform mown' | 'mixed' | 'tall grass' | 'scrub';
  canopy_cover: 'none' | 'sparse' | 'moderate' | 'dense';
  flower_richness: number;
  dead_wood: boolean;
  litter_disturbance: 'low' | 'medium' | 'high';
  invasive_species_presence: boolean;
  invasive_species_photo_url?: string;
  water_presence: 'none' | 'puddle' | 'ditch' | 'stream' | 'pond';
  light_pollution: 'none' | 'low' | 'moderate' | 'high';
}

export interface SurveyRecordInput {
  survey_id: string;
  taxon_group: TaxonGroup;
  species_id?: string | null;
  count: number;
  notes?: string | null;
}

export interface SuggestionInput {
  type: SuggestionType;
  payload: Record<string, unknown>;
}

function parsePoint(value: unknown): [number, number] | null {
  if (
    typeof value === 'object' &&
    value !== null &&
    (value as { type?: unknown }).type === 'Point' &&
    Array.isArray((value as { coordinates?: unknown }).coordinates)
  ) {
    const coords = (value as { coordinates: unknown[] }).coordinates;
    if (typeof coords[0] === 'number' && typeof coords[1] === 'number') {
      return [coords[0], coords[1]];
    }
  }

  if (typeof value === 'string') {
    const match = value.match(/POINT\s*\(([-0-9.]+)\s+([-0-9.]+)\)/i);
    if (match) return [Number(match[1]), Number(match[2])];
  }

  return null;
}

async function invokeFunction<T>(name: string, body: Record<string, unknown>): Promise<T> {
  if (!supabase) throw new Error('Supabase is not configured');
  const { data, error } = await supabase.functions.invoke<T>(name, { body });
  if (error) throw error;
  if (!data) throw new Error('Empty function response');
  if (typeof data === 'object' && data && 'error' in data) {
    throw new Error(String((data as { error: unknown }).error));
  }
  return data;
}

export async function fetchCurrentRole(): Promise<AppRole | null> {
  if (!supabase) return null;
  const { data: userData } = await supabase.auth.getUser();
  const user = userData.user;
  if (!user) return null;

  const { data, error } = await supabase
    .from('user_roles')
    .select('role')
    .eq('user_id', user.id)
    .maybeSingle();
  if (error) return null;
  return (data?.role as AppRole | undefined) ?? 'contributor';
}

export async function fetchSpeciesReference(): Promise<SpeciesReferenceOption[]> {
  if (!supabase) return [];
  const { data, error } = await supabase
    .from('species_reference')
    .select('id, taxon_group, common_name, scientific_name, requires_photo_on_first_record')
    .order('common_name', { ascending: true });
  if (error || !data) return [];
  return data as SpeciesReferenceOption[];
}

export async function fetchSurveyPoints(): Promise<SurveyPointFeature[]> {
  if (!supabase) return [];
  const { data, error } = await supabase
    .from('survey_points')
    .select('id, status, geometry')
    .eq('status', 'approved');
  if (error || !data) return [];
  return data.flatMap((row) => {
    const coordinates = parsePoint(row.geometry);
    return coordinates ? [{ id: row.id, status: row.status, coordinates }] : [];
  }) as SurveyPointFeature[];
}

export async function fetchStructuredSurveys(
  surveyPoints: SurveyPointFeature[],
): Promise<StructuredSurveyFeature[]> {
  if (!supabase) return [];
  const pointById = new Map(surveyPoints.map((p) => [p.id, p]));
  const { data, error } = await supabase
    .from('structured_surveys')
    .select('id, survey_point_id, cell_id, started_at, submitted_at, status')
    .limit(1000);
  if (error || !data) return [];
  return data.flatMap((row) => {
    const point = pointById.get(row.survey_point_id);
    return point ? [{ ...row, coordinates: point.coordinates }] : [];
  }) as StructuredSurveyFeature[];
}

export async function fetchObservationHistory(): Promise<ObservationHistoryItem[]> {
  if (!supabase) return [];
  const { data: userData } = await supabase.auth.getUser();
  const user = userData.user;
  if (!user) return [];

  const { data } = await supabase
    .from('structured_surveys')
    .select('id, status, duration_seconds, started_at, submitted_at, created_at')
    .eq('user_id', user.id)
    .order('created_at', { ascending: false })
    .limit(20);

  const surveys = (data ?? []).map((row) => ({
    id: row.id,
    kind: 'structured_survey' as const,
    label: 'Structured survey',
    status: row.status,
    created_at: row.created_at ?? row.started_at,
    detail: row.submitted_at ? `${Math.round(Number(row.duration_seconds) / 60)} min` : 'In progress',
  }));

  return surveys
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))
    .slice(0, 20);
}

export async function uploadCitizenPhoto(file: File, folder: string): Promise<string> {
  if (!supabase) throw new Error('Supabase is not configured');
  const { data: userData } = await supabase.auth.getUser();
  const userId = userData.user?.id ?? 'anonymous';
  const ext = file.name.split('.').pop()?.toLowerCase() || 'jpg';
  const safeFolder = folder.replace(/[^a-z0-9-]/gi, '-').toLowerCase();
  const path = `${safeFolder}/${userId}/${crypto.randomUUID()}.${ext}`;

  const { error } = await supabase.storage
    .from(PHOTO_BUCKET)
    .upload(path, file, { upsert: false, contentType: file.type || undefined });
  if (error) throw error;

  const { data } = supabase.storage.from(PHOTO_BUCKET).getPublicUrl(path);
  return data.publicUrl;
}

export async function startStructuredSurvey(surveyPointId: string) {
  return invokeFunction<{
    structured_survey: { id: string; survey_point_id: string; cell_id: string; started_at: string; duration_seconds: number; status: string };
    minimum_duration_seconds: number;
    nominal_duration_seconds: number;
  }>('start-structured-survey', { survey_point_id: surveyPointId });
}

export async function submitStructuredSurvey(
  surveyId: string,
  habitatIndicators: HabitatIndicators,
  observerMetadata: Record<string, unknown> = {},
) {
  return invokeFunction<{ structured_survey: { id: string; duration_seconds: number; status: string } }>(
    'submit-structured-survey',
    { survey_id: surveyId, habitat_indicators: habitatIndicators, observer_metadata: observerMetadata },
  );
}

export async function addSurveyRecord(input: SurveyRecordInput) {
  return invokeFunction<{ survey_record: { id: string } }>('add-survey-record', { ...input });
}

export async function submitSuggestion(input: SuggestionInput) {
  return invokeFunction<{ suggestion: { id: string; type: SuggestionType; status: string } }>(
    'submit-suggestion',
    { type: input.type, payload: input.payload },
  );
}

// ── Survey point registration (surveyor) ────────────────────────────────────

export async function registerSurveyPoint(lng: number, lat: number, cityId?: string) {
  if (!supabase) throw new Error('Supabase is not configured');
  const { data: userData } = await supabase.auth.getUser();
  const user = userData.user;
  if (!user) throw new Error('Sign in to register a survey point');

  const payload: Record<string, unknown> = {
    geometry: `SRID=4326;POINT(${lng} ${lat})`,
    status: 'pending',
    suggested_by: user.id,
  };
  if (cityId) payload.city_id = cityId;

  const { data, error } = await supabase
    .from('survey_points')
    .insert(payload)
    .select('id, status')
    .single();
  if (error) throw error;
  return data as { id: string; status: string };
}

// ── Review queue (verifier + approver) ──────────────────────────────────────

function speciesLabel(reference: unknown): string | null {
  if (!reference || typeof reference !== 'object') return null;
  const ref = reference as { common_name?: string; scientific_name?: string };
  if (ref.common_name && ref.scientific_name) return `${ref.common_name} (${ref.scientific_name})`;
  return ref.scientific_name ?? ref.common_name ?? null;
}

export async function fetchSurveysForReview(
  status: 'pending_verification' | 'verified',
): Promise<ReviewSurveyItem[]> {
  if (!supabase) return [];
  const { data, error } = await supabase
    .from('structured_surveys')
    .select(
      'id, status, survey_point_id, cell_id, started_at, submitted_at, duration_seconds, habitat_indicators, ' +
        'survey_records(id, taxon_group, count, notes, species_reference(common_name, scientific_name))',
    )
    .eq('status', status)
    .order('submitted_at', { ascending: true })
    .limit(200);
  if (error || !data) return [];

  // The nested relational select is not statically typed by supabase-js, so the
  // rows come back untyped and are normalised explicitly below.
  const rows = data as unknown as Record<string, unknown>[];
  const ids = rows.map((row) => row.id as string);
  const flagsByRecord = new Map<string, { reason: string; outcome: string }[]>();
  if (ids.length > 0) {
    const { data: flagRows } = await supabase
      .from('flags')
      .select('record_id, reason, outcome')
      .eq('record_type', 'structured_survey')
      .in('record_id', ids);
    for (const flag of flagRows ?? []) {
      const list = flagsByRecord.get(flag.record_id) ?? [];
      list.push({ reason: flag.reason, outcome: flag.outcome });
      flagsByRecord.set(flag.record_id, list);
    }
  }

  return rows.map((row) => ({
    id: row.id as string,
    status: row.status as ReviewStatus,
    survey_point_id: row.survey_point_id as string,
    cell_id: (row.cell_id as string | null) ?? null,
    started_at: row.started_at as string,
    submitted_at: (row.submitted_at as string | null) ?? null,
    duration_seconds: Number(row.duration_seconds ?? 0),
    habitat_indicators: (row.habitat_indicators ?? {}) as Record<string, unknown>,
    records: ((row.survey_records ?? []) as Record<string, unknown>[]).map((record) => ({
      id: record.id as string,
      taxon_group: record.taxon_group as TaxonGroup,
      species_label: speciesLabel(record.species_reference),
      count: Number(record.count ?? 0),
      notes: (record.notes as string | null) ?? null,
    })),
    flags: flagsByRecord.get(row.id as string) ?? [],
  }));
}

export async function fetchPendingSurveyPoints(): Promise<PendingSurveyPoint[]> {
  if (!supabase) return [];
  const { data, error } = await supabase
    .from('survey_points')
    .select('id, geometry, created_at')
    .eq('status', 'pending')
    .limit(200);
  if (error || !data) return [];
  return data.flatMap((row) => {
    const coordinates = parsePoint(row.geometry);
    return coordinates ? [{ id: row.id, coordinates, created_at: row.created_at }] : [];
  }) as PendingSurveyPoint[];
}

export async function fetchPendingSuggestions(): Promise<PendingSuggestion[]> {
  if (!supabase) return [];
  const { data, error } = await supabase
    .from('suggestions')
    .select('id, type, payload, created_at')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
    .limit(200);
  if (error || !data) return [];
  return data as PendingSuggestion[];
}

export async function reviewSurvey(surveyId: string, decision: SurveyReviewDecision, note?: string) {
  return invokeFunction<{ structured_survey: { id: string; status: string }; stage: string }>(
    'review-survey',
    { survey_id: surveyId, decision, ...(note ? { note } : {}) },
  );
}

export async function reviewSuggestion(suggestionId: string, status: SuggestionDecision) {
  return invokeFunction<{ suggestion: { id: string; status: string } }>(
    'review-suggestion',
    { suggestion_id: suggestionId, status },
  );
}

export async function reviewSurveyPoint(pointId: string, decision: SurveyReviewDecision) {
  if (!supabase) throw new Error('Supabase is not configured');
  const { data: userData } = await supabase.auth.getUser();
  const user = userData.user;
  if (!user) throw new Error('Sign in to review survey points');

  const patch =
    decision === 'advance'
      ? { status: 'approved', approved_by: user.id }
      : { status: 'rejected' };
  const { error } = await supabase.from('survey_points').update(patch).eq('id', pointId);
  if (error) throw error;
}

export function surveyPointsGeoJSON(points: SurveyPointFeature[]): GeoJSON.FeatureCollection {
  return {
    type: 'FeatureCollection',
    features: points.map((point) => ({
      type: 'Feature',
      properties: { id: point.id, status: point.status },
      geometry: { type: 'Point', coordinates: point.coordinates },
    })),
  };
}

export function structuredSurveysGeoJSON(points: StructuredSurveyFeature[]): GeoJSON.FeatureCollection {
  return {
    type: 'FeatureCollection',
    features: points.map((point) => ({
      type: 'Feature',
      properties: {
        id: point.id,
        status: point.status,
        surveyPointId: point.survey_point_id,
        submitted: point.submitted_at != null,
      },
      geometry: { type: 'Point', coordinates: point.coordinates },
    })),
  };
}
