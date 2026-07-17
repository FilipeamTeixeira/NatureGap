import { handleOptions, errorResponse, jsonResponse } from '../_shared/cors.ts';
import { assertRole, requireAuth } from '../_shared/auth.ts';
import { createFlag } from '../_shared/domain.ts';
import { optionalString, readJson, requiredEnum, requiredUuid } from '../_shared/validation.ts';

const DECISIONS = ['advance', 'reject'] as const;

// One review pipeline, two human transitions:
//   pending_verification --(verifier or admin)--> verified | rejected
//   verified             --(admin)-------------->  approved | rejected
// The next state is derived from the survey's current status and the caller's
// role, so a single queue can drive both the verify and approve steps.
function resolveTransition(
  status: string,
  role: string,
  decision: 'advance' | 'reject',
): { next: string; stage: 'verify' | 'approve' } {
  if (status === 'pending_verification') {
    if (role !== 'taxonomist' && role !== 'admin') {
      throw Object.assign(new Error('Only verifiers or admins can verify a survey'), { status: 403 });
    }
    return { next: decision === 'advance' ? 'verified' : 'rejected', stage: 'verify' };
  }

  if (status === 'verified') {
    if (role !== 'admin') {
      throw Object.assign(new Error('Only admins can approve a verified survey'), { status: 403 });
    }
    return { next: decision === 'advance' ? 'approved' : 'rejected', stage: 'approve' };
  }

  throw Object.assign(
    new Error(`Survey in status "${status}" is not awaiting review`),
    { status: 409 },
  );
}

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== 'POST') return errorResponse('Method not allowed', 405);

  try {
    const auth = await requireAuth(req);
    assertRole(auth.role, ['taxonomist', 'admin']);

    const body = await readJson(req);
    const surveyId = requiredUuid(body, 'survey_id');
    const decision = requiredEnum(body, 'decision', DECISIONS);
    const note = optionalString(body, 'note');

    const { data: survey, error: surveyError } = await auth.serviceClient
      .from('structured_surveys')
      .select('id, status, observer_metadata')
      .eq('id', surveyId)
      .maybeSingle();

    if (surveyError) throw surveyError;
    if (!survey) throw Object.assign(new Error('survey_id does not exist'), { status: 400 });

    const { next, stage } = resolveTransition(survey.status, auth.role, decision);

    // Preserve an auditable review trail on the survey without a hard delete.
    const existingMetadata =
      survey.observer_metadata && typeof survey.observer_metadata === 'object'
        ? survey.observer_metadata as Record<string, unknown>
        : {};
    const reviewTrail = Array.isArray(existingMetadata.review_trail)
      ? existingMetadata.review_trail as unknown[]
      : [];
    reviewTrail.push({
      stage,
      decision,
      note: note ?? null,
      reviewer_id: auth.user.id,
      reviewer_role: auth.role,
      from_status: survey.status,
      to_status: next,
      reviewed_at: new Date().toISOString(),
    });

    const { data, error } = await auth.userClient
      .from('structured_surveys')
      .update({
        status: next,
        observer_metadata: { ...existingMetadata, review_trail: reviewTrail },
      })
      .eq('id', surveyId)
      .select('id, survey_point_id, cell_id, status, duration_seconds, submitted_at')
      .single();

    if (error) throw error;

    if (decision === 'reject') {
      await createFlag(
        auth.serviceClient,
        'structured_survey',
        surveyId,
        note ?? `Survey rejected at ${stage} stage`,
        auth.user.id,
      );
    }

    return jsonResponse({ structured_survey: data, stage });
  } catch (error) {
    const status = error instanceof Error && 'status' in error ? Number(error.status) : 500;
    return errorResponse(error instanceof Error ? error.message : 'Unexpected error', status);
  }
});
