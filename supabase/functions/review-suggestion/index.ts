import { handleOptions, errorResponse, jsonResponse } from '../_shared/cors.ts';
import { assertRole, requireAuth } from '../_shared/auth.ts';
import { readJson, requiredEnum, requiredUuid, SUGGESTION_STATUSES } from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== 'POST') return errorResponse('Method not allowed', 405);

  try {
    const auth = await requireAuth(req);
    assertRole(auth.role, ['admin']);

    const body = await readJson(req);
    const suggestionId = requiredUuid(body, 'suggestion_id');
    const status = requiredEnum(body, 'status', SUGGESTION_STATUSES);

    const { data, error } = await auth.userClient
      .from('suggestions')
      .update({
        status,
        reviewed_by: auth.user.id,
        reviewed_at: new Date().toISOString(),
      })
      .eq('id', suggestionId)
      .select('id, type, status, submitted_by, reviewed_by, reviewed_at')
      .single();

    if (error) throw error;
    return jsonResponse({ suggestion: data });
  } catch (error) {
    const status = error instanceof Error && 'status' in error ? Number(error.status) : 500;
    return errorResponse(error instanceof Error ? error.message : 'Unexpected error', status);
  }
});
