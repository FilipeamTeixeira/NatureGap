import { handleOptions, errorResponse, jsonResponse } from '../_shared/cors.ts';
import { assertRole, requireAuth } from '../_shared/auth.ts';
import {
  optionalObject,
  optionalUuid,
  readJson,
  requiredEnum,
  requiredString,
  TAXON_GROUPS,
} from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== 'POST') return errorResponse('Method not allowed', 405);

  try {
    const auth = await requireAuth(req);
    assertRole(auth.role, ['taxonomist']);

    const body = await readJson(req);
    const id = optionalUuid(body, 'id');
    const taxonGroup = requiredEnum(body, 'taxon_group', TAXON_GROUPS);
    const commonName = requiredString(body, 'common_name');
    const scientificName = requiredString(body, 'scientific_name');
    const regionPlausibility = optionalObject(body, 'region_plausibility');
    const requiresPhoto = body.requires_photo_on_first_record === true;

    const payload = {
      taxon_group: taxonGroup,
      common_name: commonName,
      scientific_name: scientificName,
      region_plausibility: regionPlausibility,
      requires_photo_on_first_record: requiresPhoto,
    };

    const result = id
      ? await auth.userClient
        .from('species_reference')
        .update(payload)
        .eq('id', id)
        .select('id, taxon_group, common_name, scientific_name, region_plausibility, requires_photo_on_first_record')
        .single()
      : await auth.userClient
        .from('species_reference')
        .insert(payload)
        .select('id, taxon_group, common_name, scientific_name, region_plausibility, requires_photo_on_first_record')
        .single();

    if (result.error) throw result.error;
    return jsonResponse({ species_reference: result.data });
  } catch (error) {
    const status = error instanceof Error && 'status' in error ? Number(error.status) : 500;
    return errorResponse(error instanceof Error ? error.message : 'Unexpected error', status);
  }
});
