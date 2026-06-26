import { handleOptions, errorResponse, jsonResponse } from '../_shared/cors.ts';
import { assertRole, requireAuth } from '../_shared/auth.ts';
import {
  optionalString,
  optionalUuid,
  readJson,
  requiredEnum,
  requiredInteger,
  requiredUuid,
  TAXON_GROUPS,
} from '../_shared/validation.ts';
import {
  assertSpeciesTaxonGroup,
  createFlag,
  findSurveyPointCellId,
  loadSpeciesReference,
  maybeFlagPlausibility,
  plausibilityReasons,
} from '../_shared/domain.ts';

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== 'POST') return errorResponse('Method not allowed', 405);

  try {
    const auth = await requireAuth(req);
    assertRole(auth.role, ['surveyor']);

    const body = await readJson(req);
    const surveyId = requiredUuid(body, 'survey_id');
    const taxonGroup = requiredEnum(body, 'taxon_group', TAXON_GROUPS);
    const speciesId = optionalUuid(body, 'species_id');
    const count = requiredInteger(body, 'count');
    const notes = optionalString(body, 'notes');

    if (count < 0) throw Object.assign(new Error('count must be non-negative'), { status: 400 });

    const { data: survey, error: surveyError } = await auth.serviceClient
      .from('structured_surveys')
      .select('id, user_id, survey_point_id, cell_id, started_at')
      .eq('id', surveyId)
      .maybeSingle();

    if (surveyError) throw surveyError;
    if (!survey) throw Object.assign(new Error('survey_id does not exist'), { status: 400 });
    if (auth.role !== 'admin' && survey.user_id !== auth.user.id) {
      throw Object.assign(new Error('Cannot add records to another user survey'), { status: 403 });
    }

    const species = await loadSpeciesReference(auth.serviceClient, speciesId);
    assertSpeciesTaxonGroup(species, taxonGroup);

    const { data, error } = await auth.userClient
      .from('survey_records')
      .insert({
        survey_id: surveyId,
        taxon_group: taxonGroup,
        species_id: speciesId,
        count,
        notes,
      })
      .select('id, survey_id, taxon_group, species_id, count, notes, created_at')
      .single();

    if (error) throw error;

    const flags: string[] = [];
    const cellId = survey.cell_id ?? await findSurveyPointCellId(auth.serviceClient, survey.survey_point_id);
    const reasons = plausibilityReasons(species, cellId, new Date(survey.started_at));
    if (await maybeFlagPlausibility(auth.serviceClient, 'survey_record', data.id, reasons, auth.user.id)) {
      flags.push(...reasons);
    }

    if (speciesId) {
      const startedAt = new Date(survey.started_at).toISOString();
      const windowStart = new Date(new Date(startedAt).getTime() - 30 * 60 * 1000).toISOString();
      const windowEnd = new Date(new Date(startedAt).getTime() + 30 * 60 * 1000).toISOString();

      const { data: duplicates, error: duplicateError } = await auth.serviceClient
        .from('survey_records')
        .select('id, structured_surveys!inner(cell_id, started_at)')
        .eq('species_id', speciesId)
        .eq('structured_surveys.cell_id', cellId)
        .gte('structured_surveys.started_at', windowStart)
        .lte('structured_surveys.started_at', windowEnd)
        .neq('id', data.id)
        .limit(1);

      if (duplicateError) throw duplicateError;
      if (duplicates && duplicates.length > 0) {
        const reason = 'Duplicate detection: same species and 20m hex cell within 30 minutes';
        await createFlag(auth.serviceClient, 'survey_record', data.id, reason, auth.user.id);
        flags.push(reason);
      }
    }

    return jsonResponse({ survey_record: data, flags_created: flags });
  } catch (error) {
    const status = error instanceof Error && 'status' in error ? Number(error.status) : 500;
    return errorResponse(error instanceof Error ? error.message : 'Unexpected error', status);
  }
});
