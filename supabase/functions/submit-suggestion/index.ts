import { handleOptions, errorResponse, jsonResponse } from '../_shared/cors.ts';
import { assertRole, requireAuth } from '../_shared/auth.ts';
import { optionalObject, readJson, requiredEnum, SUGGESTION_TYPES } from '../_shared/validation.ts';

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== 'POST') return errorResponse('Method not allowed', 405);

  try {
    const auth = await requireAuth(req);
    assertRole(auth.role, ['contributor']);

    const body = await readJson(req);
    const type = requiredEnum(body, 'type', SUGGESTION_TYPES);
    const payload = optionalObject(body, 'payload');

    const { data, error } = await auth.userClient
      .from('suggestions')
      .insert({
        type,
        payload,
        status: 'pending',
        submitted_by: auth.user.id,
      })
      .select('id, type, payload, status, submitted_by, created_at')
      .single();

    if (error) throw error;
    return jsonResponse({ suggestion: data });
  } catch (error) {
    const status = error instanceof Error && 'status' in error ? Number(error.status) : 500;
    return errorResponse(error instanceof Error ? error.message : 'Unexpected error', status);
  }
});
