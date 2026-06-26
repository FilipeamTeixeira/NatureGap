'use client';

import Link from 'next/link';
import Navbar from '@/components/layout/Navbar';
import { useAuth } from '@/components/auth/AuthProvider';
import { CalendarDays, ClipboardList, Settings, User, Binoculars } from 'lucide-react';

const PLACEHOLDERS = [
  { title: 'Activity history', body: 'Recent account activity will appear here.', icon: CalendarDays },
  { title: 'Observations submitted', body: 'Quick sightings and reviewed observations will appear here.', icon: Binoculars },
  { title: 'Survey participation', body: 'Structured survey sessions and assigned points will appear here.', icon: ClipboardList },
  { title: 'Settings', body: 'Notification and account settings will appear here.', icon: Settings },
];

function formatMetadata(metadata: Record<string, unknown>) {
  return Object.entries(metadata)
    .filter(([, value]) => value != null && typeof value !== 'object')
    .slice(0, 6);
}

export default function ProfilePage() {
  const { profile, user, loading } = useAuth();
  const metadata = formatMetadata(profile?.metadata ?? user?.user_metadata ?? {});

  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/profile" />

      <main className="flex-1 overflow-y-auto bg-[#F7F8F5]">
        <div className="max-w-3xl mx-auto px-6 py-10">
          <div className="mb-6">
            <h1 className="text-[30px] font-semibold text-[#1F2A1F] tracking-tight">Profile</h1>
            <p className="text-[13px] text-[#667066] mt-2">
              Account details and contribution history.
            </p>
          </div>

          {loading ? (
            <div className="bg-white border border-[#E4E7E1] rounded-lg p-6 text-[13px] text-[#667066]">
              Loading profile...
            </div>
          ) : !user ? (
            <div className="bg-white border border-[#E4E7E1] rounded-lg p-6">
              <p className="text-[14px] text-[#1F2A1F] font-medium">You are not signed in.</p>
              <Link
                href="/login"
                className="inline-flex mt-4 h-10 items-center rounded-lg bg-[#2E6F40] px-4 text-[13px] font-semibold text-white"
              >
                Sign in
              </Link>
            </div>
          ) : (
            <div className="flex flex-col gap-4">
              <section className="bg-white border border-[#E4E7E1] rounded-lg p-6">
                <div className="flex items-start gap-4">
                  <div className="w-10 h-10 rounded-lg bg-[#DDEAD8] flex items-center justify-center flex-shrink-0">
                    <User size={17} className="text-[#2E6F40]" strokeWidth={1.8} />
                  </div>
                  <div className="min-w-0 flex-1">
                    <h2 className="text-[18px] font-semibold text-[#1F2A1F] truncate">
                      {profile?.displayName ?? user.email}
                    </h2>
                    <p className="text-[13px] text-[#667066] mt-1">{profile?.email ?? user.email}</p>
                    <span className="inline-flex mt-3 rounded-full bg-[#F0F2EE] px-2.5 py-1 text-[11px] font-semibold text-[#667066] capitalize">
                      {profile?.role ?? 'contributor'}
                    </span>
                  </div>
                </div>

                <div className="mt-6 border-t border-[#E4E7E1] pt-4">
                  <h3 className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest mb-3">
                    Account metadata
                  </h3>
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                    <div className="rounded-lg bg-[#F7F8F5] px-3 py-2">
                      <div className="text-[10px] text-[#8A958A] uppercase tracking-widest">User ID</div>
                      <div className="text-[12px] text-[#1F2A1F] truncate mt-1">{user.id}</div>
                    </div>
                    <div className="rounded-lg bg-[#F7F8F5] px-3 py-2">
                      <div className="text-[10px] text-[#8A958A] uppercase tracking-widest">Created</div>
                      <div className="text-[12px] text-[#1F2A1F] truncate mt-1">
                        {user.created_at ? new Date(user.created_at).toLocaleDateString() : 'Unknown'}
                      </div>
                    </div>
                    {metadata.map(([key, value]) => (
                      <div key={key} className="rounded-lg bg-[#F7F8F5] px-3 py-2">
                        <div className="text-[10px] text-[#8A958A] uppercase tracking-widest">{key}</div>
                        <div className="text-[12px] text-[#1F2A1F] truncate mt-1">{String(value)}</div>
                      </div>
                    ))}
                  </div>
                </div>
              </section>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                {PLACEHOLDERS.map(({ title, body, icon: Icon }) => (
                  <section key={title} className="bg-white border border-[#E4E7E1] rounded-lg p-5">
                    <div className="flex items-center gap-3 mb-3">
                      <div className="w-8 h-8 rounded-lg bg-[#F7F8F5] flex items-center justify-center">
                        <Icon size={14} className="text-[#2E6F40]" strokeWidth={1.7} />
                      </div>
                      <h2 className="text-[13px] font-semibold text-[#1F2A1F]">{title}</h2>
                    </div>
                    <p className="text-[12px] leading-relaxed text-[#667066]">{body}</p>
                  </section>
                ))}
              </div>
            </div>
          )}
        </div>
      </main>
    </div>
  );
}
