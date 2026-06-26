import { createClient, type SupabaseClient, type User } from 'https://esm.sh/@supabase/supabase-js@2.108.2';

export type AppRole = 'contributor' | 'surveyor' | 'taxonomist' | 'admin';

export interface AuthContext {
  user: User;
  role: AppRole;
  token: string;
  serviceClient: SupabaseClient;
  userClient: SupabaseClient;
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable: ${name}`);
  return value;
}

export function serviceClient(): SupabaseClient {
  return createClient(
    requiredEnv('SUPABASE_URL'),
    requiredEnv('SUPABASE_SERVICE_ROLE_KEY'),
    { auth: { persistSession: false } },
  );
}

export function userClient(token: string): SupabaseClient {
  return createClient(
    requiredEnv('SUPABASE_URL'),
    requiredEnv('SUPABASE_ANON_KEY'),
    {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    },
  );
}

export async function requireAuth(req: Request): Promise<AuthContext> {
  const header = req.headers.get('Authorization') ?? '';
  const token = header.replace(/^Bearer\s+/i, '').trim();
  if (!token) throw Object.assign(new Error('Missing bearer token'), { status: 401 });

  const service = serviceClient();
  const { data, error } = await service.auth.getUser(token);
  if (error || !data.user) {
    throw Object.assign(new Error('Invalid bearer token'), { status: 401 });
  }

  const { data: roleRow, error: roleError } = await service
    .from('user_roles')
    .select('role')
    .eq('user_id', data.user.id)
    .maybeSingle();

  if (roleError) throw roleError;

  return {
    user: data.user,
    role: (roleRow?.role ?? 'contributor') as AppRole,
    token,
    serviceClient: service,
    userClient: userClient(token),
  };
}

export function assertRole(role: AppRole, allowed: AppRole[]): void {
  if (role === 'admin') return;
  if (!allowed.includes(role)) {
    throw Object.assign(new Error('Insufficient permissions'), { status: 403 });
  }
}
