import { handleOptions, errorResponse, jsonResponse } from '../_shared/cors.ts';
import { assertRole, requireAuth } from '../_shared/auth.ts';
import {
  optionalString,
  optionalUuid,
  readJson,
  requiredEnum,
  requiredNumber,
  TAXON_GROUPS,
  validateLngLat,
  validatePhotoUrl,
} from '../_shared/validation.ts';
import {
  assertSpeciesTaxonGroup,
  findCellId,
  loadSpeciesReference,
  maybeFlagAccuracy,
  maybeFlagPlausibility,
  plausibilityReasons,
} from '../_shared/domain.ts';

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== 'POST') return errorResponse('Method not allowed', 405);

  try {
    const auth = await requireAuth(req);
    assertRole(auth.role, ['contributor']);

    const body = await readJson(req);
    const taxonGroup = requiredEnum(body, 'taxon_group', TAXON_GROUPS);
    const speciesId = optionalUuid(body, 'species_id');
    const photoUrl = optionalString(body, 'photo_url');
    const gpsAccuracyM = requiredNumber(body, 'gps_accuracy_m');
    const lng = requiredNumber(body, 'lng');
    const lat = requiredNumber(body, 'lat');
    const timestamp = optionalString(body, 'timestamp') ?? new Date().toISOString();

    validateLngLat(lng, lat);
    validatePhotoUrl(photoUrl);
    if (gpsAccuracyM < 0) throw Object.assign(new Error('gps_accuracy_m must be non-negative'), { status: 400 });

    const observedAt = new Date(timestamp);
    if (Number.isNaN(observedAt.getTime())) {
      throw Object.assign(new Error('Invalid timestamp'), { status: 400 });
    }

    const species = await loadSpeciesReference(auth.serviceClient, speciesId);
    assertSpeciesTaxonGroup(species, taxonGroup);

    const cellId = await findCellId(auth.serviceClient, lng, lat);
    const reasons = plausibilityReasons(species, cellId, observedAt);
    const status = reasons.length > 0 || gpsAccuracyM > 25 ? 'flagged_review' : 'submitted';

    const { data, error } = await auth.userClient
      .from('quick_sightings')
      .insert({
        user_id: auth.user.id,
        taxon_group: taxonGroup,
        species_id: speciesId,
        photo_url: photoUrl,
        gps_accuracy_m: gpsAccuracyM,
        timestamp: observedAt.toISOString(),
        status,
        cell_id: cellId,
        geometry: `POINT(${lng} ${lat})`,
      })
      .select('id, status, cell_id')
      .single();

    if (error) throw error;

    await maybeFlagAccuracy(auth.serviceClient, 'quick_sighting', data.id, gpsAccuracyM, auth.user.id);
    await maybeFlagPlausibility(
      auth.serviceClient,
      'quick_sighting',
      data.id,
      reasons,
      auth.user.id,
    );

    return jsonResponse({ quick_sighting: data, flags_created: reasons.length + (gpsAccuracyM > 25 ? 1 : 0) });
  } catch (error) {
    const status = error instanceof Error && 'status' in error ? Number(error.status) : 500;
    return errorResponse(error instanceof Error ? error.message : 'Unexpected error', status);
  }
});
