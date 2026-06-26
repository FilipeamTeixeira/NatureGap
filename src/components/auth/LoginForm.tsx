'use client';

import Link from 'next/link';
import { useState } from 'react';
import { AlertTriangle, CheckCircle2, LogIn, LogOut, UserPlus } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { cn } from '@/lib/utils';
import { useAuth } from '@/components/auth/AuthProvider';

type Mode = 'sign-in' | 'sign-up';

export default function LoginForm() {
  const [mode, setMode] = useState<Mode>('sign-in');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ kind: 'success' | 'error'; text: string } | null>(null);
  const { profile, user, refreshProfile, signOut } = useAuth();

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!supabase) {
      setMessage({ kind: 'error', text: 'Supabase is not configured for this deployment.' });
      return;
    }

    setBusy(true);
    setMessage(null);

    try {
      const result = mode === 'sign-in'
        ? await supabase.auth.signInWithPassword({ email, password })
        : await supabase.auth.signUp({ email, password });

      if (result.error) throw result.error;

      if (result.data.user) await refreshProfile();
      setMessage({
        kind: 'success',
        text: mode === 'sign-in'
          ? 'You are signed in.'
          : 'Account created. Check your email if confirmation is enabled.',
      });
      setPassword('');
    } catch (error) {
      setMessage({ kind: 'error', text: error instanceof Error ? error.message : 'Authentication failed.' });
    } finally {
      setBusy(false);
    }
  }

  async function handleSignOut() {
    setBusy(true);
    await signOut();
    setMessage({ kind: 'success', text: 'You are signed out.' });
    setBusy(false);
  }

  return (
    <div className="w-full max-w-md bg-white border border-[#E4E7E1] rounded-lg p-6">
      <div className="mb-6">
        <h1 className="text-[24px] font-semibold text-[#1F2A1F] tracking-tight">Sign in</h1>
        <p className="text-[13px] text-[#667066] mt-2 leading-relaxed">
          Use your NatureGap account to submit observations and surveys.
        </p>
      </div>

      {user ? (
        <div className="flex flex-col gap-4">
          <div className="rounded-lg border border-[#CFE3C8] bg-[#F2F8EF] px-4 py-3">
            <p className="text-[12px] font-medium text-[#2E6F40]">Signed in as</p>
            <p className="text-[14px] text-[#1F2A1F] mt-1">{profile?.displayName ?? user.email}</p>
            {user.email ? <p className="text-[12px] text-[#667066] mt-1">{user.email}</p> : null}
          </div>
          <div className="flex gap-2">
            <Link
              href="/profile"
              className="h-10 flex-1 rounded-lg bg-[#2E6F40] text-white text-[13px] font-semibold flex items-center justify-center"
            >
              Profile
            </Link>
            <button
              type="button"
              onClick={handleSignOut}
              disabled={busy}
              className="h-10 rounded-lg border border-[#E4E7E1] px-4 text-[13px] font-semibold text-[#667066] disabled:opacity-60 flex items-center gap-2"
            >
              <LogOut size={14} strokeWidth={1.8} />
              Sign out
            </button>
          </div>
        </div>
      ) : (
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex rounded-lg border border-[#E4E7E1] bg-[#F7F8F5] p-1">
            {([
              ['sign-in', 'Sign in'],
              ['sign-up', 'Create account'],
            ] as const).map(([value, label]) => (
              <button
                key={value}
                type="button"
                onClick={() => setMode(value)}
                className={cn(
                  'flex-1 rounded-md px-3 py-2 text-[12px] font-medium',
                  mode === value ? 'bg-white text-[#1F2A1F] shadow-sm' : 'text-[#667066]',
                )}
              >
                {label}
              </button>
            ))}
          </div>

          <label className="flex flex-col gap-2">
            <span className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest">Email</span>
            <input
              type="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              required
              autoComplete="email"
              className="h-10 rounded-lg border border-[#E4E7E1] px-3 text-[13px] outline-none focus:border-[#2E6F40]"
            />
          </label>

          <label className="flex flex-col gap-2">
            <span className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest">Password</span>
            <input
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              required
              minLength={6}
              autoComplete={mode === 'sign-in' ? 'current-password' : 'new-password'}
              className="h-10 rounded-lg border border-[#E4E7E1] px-3 text-[13px] outline-none focus:border-[#2E6F40]"
            />
          </label>

          {message && (
            <div
              className={cn(
                'flex items-start gap-2 rounded-lg border px-3 py-2 text-[12px] leading-relaxed',
                message.kind === 'success' && 'bg-[#F2F8EF] border-[#CFE3C8] text-[#2E6F40]',
                message.kind === 'error' && 'bg-[#FDF0E4] border-[#E8B48E] text-[#9B4A1A]',
              )}
            >
              {message.kind === 'success'
                ? <CheckCircle2 size={14} className="mt-0.5 flex-shrink-0" strokeWidth={1.8} />
                : <AlertTriangle size={14} className="mt-0.5 flex-shrink-0" strokeWidth={1.8} />}
              <span>{message.text}</span>
            </div>
          )}

          <button
            type="submit"
            disabled={busy}
            className="h-10 rounded-lg bg-[#2E6F40] text-white text-[13px] font-semibold disabled:bg-[#D1D8CE] flex items-center justify-center gap-2"
          >
            {mode === 'sign-in' ? <LogIn size={14} strokeWidth={1.8} /> : <UserPlus size={14} strokeWidth={1.8} />}
            {busy ? 'Please wait...' : mode === 'sign-in' ? 'Sign in' : 'Create account'}
          </button>
        </form>
      )}
    </div>
  );
}
