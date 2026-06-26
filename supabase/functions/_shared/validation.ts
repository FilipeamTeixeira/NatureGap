export const TAXON_GROUPS = ['bird', 'insect', 'plant', 'amphibian', 'other'] as const;
export const SUGGESTION_TYPES = ['species', 'action', 'survey_point', 'habitat_photo', 'local_note'] as const;
export const SUGGESTION_STATUSES = ['approved', 'rejected', 'needs_revision'] as const;
export const FLAG_OUTCOMES = ['confirmed', 'dismissed', 'reversed'] as const;
export const FLAG_RECORD_TYPES = [
  'quick_sighting',
  'structured_survey',
  'survey_record',
  'survey_point',
  'suggestion',
  'species_reference',
  'conservation_action',
  'cell_attribute',
] as const;

export type TaxonGroup = typeof TAXON_GROUPS[number];
export type SuggestionType = typeof SUGGESTION_TYPES[number];

export function asRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw Object.assign(new Error('Expected JSON object body'), { status: 400 });
  }
  return value as Record<string, unknown>;
}

export async function readJson(req: Request): Promise<Record<string, unknown>> {
  try {
    return asRecord(await req.json());
  } catch (error) {
    if (error instanceof Error && 'status' in error) throw error;
    throw Object.assign(new Error('Invalid JSON body'), { status: 400 });
  }
}

export function requiredString(body: Record<string, unknown>, key: string): string {
  const value = body[key];
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw Object.assign(new Error(`Missing or invalid ${key}`), { status: 400 });
  }
  return value.trim();
}

export function optionalString(body: Record<string, unknown>, key: string): string | null {
  const value = body[key];
  if (value == null || value === '') return null;
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw Object.assign(new Error(`Invalid ${key}`), { status: 400 });
  }
  return value.trim();
}

export function requiredNumber(body: Record<string, unknown>, key: string): number {
  const value = body[key];
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw Object.assign(new Error(`Missing or invalid ${key}`), { status: 400 });
  }
  return value;
}

export function optionalNumber(body: Record<string, unknown>, key: string): number | null {
  const value = body[key];
  if (value == null) return null;
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw Object.assign(new Error(`Invalid ${key}`), { status: 400 });
  }
  return value;
}

export function requiredInteger(body: Record<string, unknown>, key: string): number {
  const value = requiredNumber(body, key);
  if (!Number.isInteger(value)) {
    throw Object.assign(new Error(`Invalid ${key}: expected integer`), { status: 400 });
  }
  return value;
}

export function requiredEnum<T extends readonly string[]>(
  body: Record<string, unknown>,
  key: string,
  allowed: T,
): T[number] {
  const value = requiredString(body, key);
  if (!allowed.includes(value)) {
    throw Object.assign(new Error(`Invalid ${key}`), { status: 400, allowed });
  }
  return value as T[number];
}

export function optionalUuid(body: Record<string, unknown>, key: string): string | null {
  const value = optionalString(body, key);
  if (value == null) return null;
  assertUuid(value, key);
  return value;
}

export function requiredUuid(body: Record<string, unknown>, key: string): string {
  const value = requiredString(body, key);
  assertUuid(value, key);
  return value;
}

export function assertUuid(value: string, key = 'id'): void {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw Object.assign(new Error(`Invalid ${key}`), { status: 400 });
  }
}

export function requiredObject(body: Record<string, unknown>, key: string): Record<string, unknown> {
  const value = body[key];
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw Object.assign(new Error(`Missing or invalid ${key}`), { status: 400 });
  }
  return value as Record<string, unknown>;
}

export function optionalObject(body: Record<string, unknown>, key: string): Record<string, unknown> {
  const value = body[key];
  if (value == null) return {};
  if (typeof value !== 'object' || Array.isArray(value)) {
    throw Object.assign(new Error(`Invalid ${key}`), { status: 400 });
  }
  return value as Record<string, unknown>;
}

export function validateLngLat(lng: number, lat: number): void {
  if (lng < -180 || lng > 180 || lat < -90 || lat > 90) {
    throw Object.assign(new Error('Invalid longitude/latitude'), { status: 400 });
  }
}

export function validatePhotoUrl(photoUrl: string | null): void {
  if (photoUrl == null) return;
  try {
    const parsed = new URL(photoUrl);
    if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error();
  } catch {
    throw Object.assign(new Error('Invalid photo_url'), { status: 400 });
  }
}

export function validateHabitatIndicators(value: Record<string, unknown>): Record<string, unknown> {
  const required = [
    'vegetation_height_variation',
    'canopy_cover',
    'flower_richness',
    'dead_wood',
    'litter_disturbance',
    'invasive_species_presence',
    'water_presence',
    'light_pollution',
  ];

  for (const key of required) {
    if (!(key in value)) {
      throw Object.assign(new Error(`Missing habitat_indicators.${key}`), { status: 400 });
    }
  }

  if (value.invasive_species_presence === true) {
    const photoUrl = typeof value.invasive_species_photo_url === 'string'
      ? value.invasive_species_photo_url
      : null;
    validatePhotoUrl(photoUrl);
    if (!photoUrl) {
      throw Object.assign(
        new Error('Invasive species presence requires habitat_indicators.invasive_species_photo_url'),
        { status: 400 },
      );
    }
  }

  return value;
}
