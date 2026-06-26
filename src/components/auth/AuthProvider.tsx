'use client';

import { createContext, useContext, useEffect, useMemo, useState } from 'react';
import type { User } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';

export interface AuthProfile {
  displayName: string;
  email: string;
  role: string;
  metadata: Record<string, unknown>;
}

interface AuthContextValue {
  user: User | null;
  profile: AuthProfile | null;
  loading: boolean;
  refreshProfile: () => Promise<void>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | null>(null);

function authDisplayName(user: User): string {
  const metadata = user.user_metadata ?? {};
  return (
    String(metadata.display_name ?? metadata.full_name ?? metadata.name ?? '').trim() ||
    user.email?.split('@')[0] ||
    'Account'
  );
}

async function loadProfile(user: User): Promise<AuthProfile> {
  let profileRow: { display_name?: string | null; full_name?: string | null; name?: string | null } | null = null;
  let role: string | null = null;

  if (supabase) {
    const profileResult = await supabase
      .from('profiles')
      .select('display_name, full_name, name')
      .eq('id', user.id)
      .maybeSingle();
    if (!profileResult.error) profileRow = profileResult.data;

    const roleResult = await supabase
      .from('user_roles')
      .select('role')
      .eq('user_id', user.id)
      .maybeSingle();
    if (!roleResult.error) role = roleResult.data?.role ?? null;
  }

  const metadata = user.user_metadata ?? {};
  const displayName =
    profileRow?.display_name?.trim() ||
    profileRow?.full_name?.trim() ||
    profileRow?.name?.trim() ||
    authDisplayName(user);

  return {
    displayName,
    email: user.email ?? '',
    role: role ?? String(metadata.role ?? 'contributor'),
    metadata,
  };
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [profile, setProfile] = useState<AuthProfile | null>(null);
  const [loading, setLoading] = useState(() => Boolean(supabase));

  async function refreshProfile(nextUser = user) {
    if (!nextUser) {
      setProfile(null);
      return;
    }
    setProfile(await loadProfile(nextUser));
  }

  useEffect(() => {
    if (!supabase) return;

    let cancelled = false;
    supabase.auth.getUser().then(async ({ data }) => {
      if (cancelled) return;
      setUser(data.user ?? null);
      if (data.user) await refreshProfile(data.user);
      setLoading(false);
    });

    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      const nextUser = session?.user ?? null;
      setUser(nextUser);
      if (nextUser) void refreshProfile(nextUser);
      else setProfile(null);
      setLoading(false);
    });

    return () => {
      cancelled = true;
      listener.subscription.unsubscribe();
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function signOut() {
    if (!supabase) return;
    await supabase.auth.signOut();
    setUser(null);
    setProfile(null);
  }

  const value = useMemo<AuthContextValue>(() => ({
    user,
    profile,
    loading,
    refreshProfile: () => refreshProfile(),
    signOut,
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }), [loading, profile, user]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const value = useContext(AuthContext);
  if (!value) throw new Error('useAuth must be used within AuthProvider');
  return value;
}
