import { handleOptions, errorResponse, jsonResponse } from '../_shared/cors.ts';
import { assertRole, requireAuth } from '../_shared/auth.ts';
import { readJson, requiredUuid } from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== 'POST') return errorResponse('Method not allowed', 405);

  try {
    const auth = await requireAuth(req);
    assertRole(auth.role, ['surveyor']);

    const body = await readJson(req);
    const surveyPointId = requiredUuid(body, 'survey_point_id');

    const { data: point, error: pointError } = await auth.serviceClient
      .from('survey_points')
      .select('id, status')
      .eq('id', surveyPointId)
      .maybeSingle();

    if (pointError) throw pointError;
    if (!point) throw Object.assign(new Error('survey_point_id does not exist'), { status: 400 });
    if (point.status !== 'approved') {
      throw Object.assign(new Error('Structured surveys must use an approved survey point'), { status: 400 });
    }

    const startedAt = new Date().toISOString();
    const { data, error } = await auth.userClient
      .from('structured_surveys')
      .insert({
        survey_point_id: surveyPointId,
        user_id: auth.user.id,
        started_at: startedAt,
        duration_seconds: 0,
        habitat_indicators: {},
        status: 'submitted',
      })
      .select('id, survey_point_id, started_at, duration_seconds, status')
      .single();

    if (error) throw error;

    return jsonResponse({
      structured_survey: data,
      minimum_duration_seconds: 720,
      nominal_duration_seconds: 900,
    });
  } catch (error) {
    const status = error instanceof Error && 'status' in error ? Number(error.status) : 500;
    return errorResponse(error instanceof Error ? error.message : 'Unexpected error', status);
  }
});
