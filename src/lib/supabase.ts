import { createClient } from '@supabase/supabase-js';

const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? '';
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '';

/**
 * Supabase client — null when env vars are absent (local / CI without Supabase).
 * All callers must guard missing clients and avoid local production-data fallbacks.
 */
export const supabase = url && key ? createClient(url, key) : null;
