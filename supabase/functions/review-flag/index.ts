import { handleOptions, errorResponse, jsonResponse } from '../_shared/cors.ts';
import { assertRole, requireAuth } from '../_shared/auth.ts';
import { FLAG_OUTCOMES, readJson, requiredEnum, requiredUuid } from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== 'POST') return errorResponse('Method not allowed', 405);

  try {
    const auth = await requireAuth(req);
    assertRole(auth.role, ['admin', 'taxonomist']);

    const body = await readJson(req);
    const flagId = requiredUuid(body, 'flag_id');
    const outcome = requiredEnum(body, 'outcome', FLAG_OUTCOMES);

    const { data, error } = await auth.userClient
      .from('flags')
      .update({
        outcome,
        reviewed_by: auth.user.id,
        reviewed_at: new Date().toISOString(),
      })
      .eq('id', flagId)
      .select('id, record_type, record_id, reason, outcome, reviewed_by, reviewed_at')
      .single();

    if (error) throw error;
    return jsonResponse({ flag: data });
  } catch (error) {
    const status = error instanceof Error && 'status' in error ? Number(error.status) : 500;
    return errorResponse(error instanceof Error ? error.message : 'Unexpected error', status);
  }
});
