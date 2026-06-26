import { supabase } from './supabase';

const PHOTO_BUCKET = process.env.NEXT_PUBLIC_CITIZEN_PHOTO_BUCKET ?? 'citizen-photos';

export type AppRole = 'contributor' | 'surveyor' | 'taxonomist' | 'admin';
export type TaxonGroup = 'bird' | 'insect' | 'plant' | 'amphibian' | 'other';
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

export interface QuickSightingFeature {
  id: string;
  taxon_group: TaxonGroup;
  status: string;
  gps_accuracy_m: number;
  coordinates: [number, number];
}

export interface StructuredSurveyFeature {
  id: string;
  status: string;
  survey_point_id: string;
  started_at: string;
  submitted_at: string | null;
  coordinates: [number, number];
}

export interface QuickSightingInput {
  taxon_group: TaxonGroup;
  species_id?: string | null;
  photo_url?: string | null;
  lng: number;
  lat: number;
  gps_accuracy_m: number;
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

export async function fetchQuickSightings(): Promise<QuickSightingFeature[]> {
  if (!supabase) return [];
  const { data, error } = await supabase
    .from('quick_sightings')
    .select('id, taxon_group, status, gps_accuracy_m, geometry')
    .limit(1000);
  if (error || !data) return [];
  return data.flatMap((row) => {
    const coordinates = parsePoint(row.geometry);
    return coordinates ? [{
      id: row.id,
      taxon_group: row.taxon_group,
      status: row.status,
      gps_accuracy_m: Number(row.gps_accuracy_m),
      coordinates,
    }] : [];
  }) as QuickSightingFeature[];
}

export async function fetchStructuredSurveys(
  surveyPoints: SurveyPointFeature[],
): Promise<StructuredSurveyFeature[]> {
  if (!supabase) return [];
  const pointById = new Map(surveyPoints.map((p) => [p.id, p]));
  const { data, error } = await supabase
    .from('structured_surveys')
    .select('id, survey_point_id, started_at, submitted_at, status')
    .limit(1000);
  if (error || !data) return [];
  return data.flatMap((row) => {
    const point = pointById.get(row.survey_point_id);
    return point ? [{ ...row, coordinates: point.coordinates }] : [];
  }) as StructuredSurveyFeature[];
}

export async function submitQuickSighting(input: QuickSightingInput) {
  return invokeFunction<{ quick_sighting: { id: string; status: string; cell_id: string | null } }>(
    'submit-quick-sighting',
    { ...input, timestamp: new Date().toISOString() },
  );
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
    structured_survey: { id: string; survey_point_id: string; started_at: string; duration_seconds: number; status: string };
    minimum_duration_seconds: number;
    nominal_duration_seconds: number;
  }>('start-structured-survey', { survey_point_id: surveyPointId });
}

export async function submitStructuredSurvey(surveyId: string, habitatIndicators: HabitatIndicators) {
  return invokeFunction<{ structured_survey: { id: string; duration_seconds: number; status: string } }>(
    'submit-structured-survey',
    { survey_id: surveyId, habitat_indicators: habitatIndicators },
  );
}

export async function addSurveyRecord(input: SurveyRecordInput) {
  return invokeFunction<{ survey_record: { id: string } }>('add-survey-record', { ...input });
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

export function quickSightingsGeoJSON(points: QuickSightingFeature[]): GeoJSON.FeatureCollection {
  return {
    type: 'FeatureCollection',
    features: points.map((point) => ({
      type: 'Feature',
      properties: {
        id: point.id,
        taxonGroup: point.taxon_group,
        status: point.status,
        gpsAccuracy: point.gps_accuracy_m,
      },
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
