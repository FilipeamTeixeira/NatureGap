import { handleOptions, errorResponse, jsonResponse } from '../_shared/cors.ts';
import { requireAuth } from '../_shared/auth.ts';
import { FLAG_RECORD_TYPES, readJson, requiredEnum, requiredString } from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== 'POST') return errorResponse('Method not allowed', 405);

  try {
    const auth = await requireAuth(req);
    const body = await readJson(req);
    const recordType = requiredEnum(body, 'record_type', FLAG_RECORD_TYPES);
    const recordId = requiredString(body, 'record_id');
    const reason = requiredString(body, 'reason');

    const { data, error } = await auth.userClient
      .from('flags')
      .insert({
        record_type: recordType,
        record_id: recordId,
        reason,
        flagged_by: auth.user.id,
        outcome: 'pending',
      })
      .select('id, record_type, record_id, reason, flagged_by, outcome, created_at')
      .single();

    if (error) throw error;
    return jsonResponse({ flag: data });
  } catch (error) {
    const status = error instanceof Error && 'status' in error ? Number(error.status) : 500;
    return errorResponse(error instanceof Error ? error.message : 'Unexpected error', status);
  }
});
