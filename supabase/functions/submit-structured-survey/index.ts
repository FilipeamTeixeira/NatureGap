import { handleOptions, errorResponse, jsonResponse } from '../_shared/cors.ts';
import { assertRole, requireAuth } from '../_shared/auth.ts';
import { optionalObject, readJson, requiredObject, requiredUuid, validateHabitatIndicators } from '../_shared/validation.ts';

const MINIMUM_DURATION_SECONDS = 15 * 60;
const NOMINAL_DURATION_SECONDS = 15 * 60;

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== 'POST') return errorResponse('Method not allowed', 405);

  try {
    const auth = await requireAuth(req);
    assertRole(auth.role, ['surveyor']);

    const body = await readJson(req);
    const surveyId = requiredUuid(body, 'survey_id');
    const habitatIndicators = validateHabitatIndicators(requiredObject(body, 'habitat_indicators'));
    const observerMetadata = optionalObject(body, 'observer_metadata');

    const { data: survey, error: surveyError } = await auth.serviceClient
      .from('structured_surveys')
      .select('id, user_id, started_at, submitted_at')
      .eq('id', surveyId)
      .maybeSingle();

    if (surveyError) throw surveyError;
    if (!survey) throw Object.assign(new Error('survey_id does not exist'), { status: 400 });
    if (auth.role !== 'admin' && survey.user_id !== auth.user.id) {
      throw Object.assign(new Error('Cannot submit another user survey'), { status: 403 });
    }
    if (survey.submitted_at) {
      throw Object.assign(new Error('Survey has already been submitted'), { status: 409 });
    }

    const submittedAt = new Date();
    const startedAt = new Date(survey.started_at);
    const durationSeconds = Math.floor((submittedAt.getTime() - startedAt.getTime()) / 1000);

    if (durationSeconds < MINIMUM_DURATION_SECONDS) {
      throw Object.assign(
        new Error('Survey submission blocked before 15 minutes'),
        { status: 400, minimum_duration_seconds: MINIMUM_DURATION_SECONDS, duration_seconds: durationSeconds },
      );
    }

    const status = durationSeconds < NOMINAL_DURATION_SECONDS ? 'flagged_review' : 'submitted';

    const { data, error } = await auth.serviceClient
      .from('structured_surveys')
      .update({
        submitted_at: submittedAt.toISOString(),
        duration_seconds: durationSeconds,
        habitat_indicators: habitatIndicators,
        observer_metadata: observerMetadata,
        status,
      })
      .eq('id', surveyId)
      .select('id, survey_point_id, cell_id, started_at, submitted_at, duration_seconds, status, habitat_indicators')
      .single();

    if (error) throw error;

    return jsonResponse({
      structured_survey: data,
      minimum_duration_seconds: MINIMUM_DURATION_SECONDS,
      nominal_duration_seconds: NOMINAL_DURATION_SECONDS,
    });
  } catch (error) {
    const status = error instanceof Error && 'status' in error ? Number(error.status) : 500;
    return errorResponse(error instanceof Error ? error.message : 'Unexpected error', status);
  }
});
