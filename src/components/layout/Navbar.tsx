'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useEffect, useRef, useState } from 'react';
import { ChevronDown, Leaf, LogOut, User } from 'lucide-react';
import { CITY } from '@/lib/config';
import { useAuth } from '@/components/auth/AuthProvider';

const NAV_LINKS = [
  { label: 'Explore',     href: '/' },
  { label: 'Take Action', href: '/take-action' },
  { label: 'Community',   href: '/community' },
  { label: 'About',       href: '/about' },
];

interface NavbarProps {
  activePath: string;
}

export default function Navbar({ activePath }: NavbarProps) {
  const { profile, user, loading, signOut } = useAuth();
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const router = useRouter();

  useEffect(() => {
    function handlePointerDown(event: PointerEvent) {
      if (menuRef.current && !menuRef.current.contains(event.target as Node)) {
        setMenuOpen(false);
      }
    }
    document.addEventListener('pointerdown', handlePointerDown);
    return () => document.removeEventListener('pointerdown', handlePointerDown);
  }, []);

  async function handleSignOut() {
    await signOut();
    setMenuOpen(false);
    router.push('/');
  }

  return (
    <header className="h-14 bg-white border-b border-[#E4E7E1] flex items-center px-6 gap-6 flex-shrink-0 z-10">
      <Link
        href="/"
        className="flex items-center gap-2.5 font-semibold text-[#1F2A1F] text-[15px] tracking-tight flex-shrink-0"
      >
        <div className="w-7 h-7 bg-[#2E6F40] rounded-lg flex items-center justify-center">
          <Leaf size={13} strokeWidth={2.5} className="text-white" />
        </div>
        <span>NatureGap</span>
      </Link>

      <nav className="flex items-center gap-1 flex-1">
        {NAV_LINKS.map(({ label, href }) => (
          <Link
            key={href}
            href={href}
            className={
              activePath === href
                ? 'text-[13px] font-medium text-[#1F2A1F] bg-[#F7F8F5] px-3 py-1.5 rounded-lg transition-colors'
                : 'text-[13px] text-[#667066] hover:text-[#1F2A1F] hover:bg-[#F7F8F5] px-3 py-1.5 rounded-lg transition-colors'
            }
          >
            {label}
          </Link>
        ))}
      </nav>

      <div className="flex items-center gap-3 flex-shrink-0">
        <span className="text-[11px] font-medium text-[#2E6F40] bg-[#DDEAD8] px-2.5 py-1 rounded-full">
          {CITY.badge}
        </span>
        {!loading && !user ? (
          <Link
            href="/login"
            className={
              activePath === '/login'
                ? 'text-[13px] font-medium text-[#1F2A1F] bg-[#F7F8F5] px-3 py-1.5 rounded-lg transition-colors'
                : 'text-[13px] text-[#667066] hover:text-[#1F2A1F] hover:bg-[#F7F8F5] px-3 py-1.5 rounded-lg transition-colors'
            }
          >
            Sign in
          </Link>
        ) : null}
        {user ? (
          <div className="relative" ref={menuRef}>
            <button
              type="button"
              onClick={() => setMenuOpen((open) => !open)}
              className="h-8 flex items-center gap-2 rounded-lg border border-[#E4E7E1] bg-white px-2.5 text-[13px] font-medium text-[#1F2A1F] hover:bg-[#F7F8F5]"
            >
              <User size={13} strokeWidth={1.8} className="text-[#667066]" />
              <span className="max-w-36 truncate">{profile?.displayName ?? user.email ?? 'Account'}</span>
              <ChevronDown size={13} strokeWidth={1.8} className="text-[#A8B4A8]" />
            </button>

            {menuOpen ? (
              <div className="absolute right-0 top-full mt-1.5 w-44 rounded-lg border border-[#E4E7E1] bg-white py-1.5 shadow-lg z-50">
                <Link
                  href="/profile"
                  onClick={() => setMenuOpen(false)}
                  className="flex items-center gap-2 px-3 py-2 text-[13px] text-[#1F2A1F] hover:bg-[#F7F8F5]"
                >
                  <User size={13} strokeWidth={1.8} />
                  Profile
                </Link>
                <button
                  type="button"
                  onClick={handleSignOut}
                  className="w-full flex items-center gap-2 px-3 py-2 text-left text-[13px] text-[#667066] hover:bg-[#F7F8F5]"
                >
                  <LogOut size={13} strokeWidth={1.8} />
                  Sign out
                </button>
              </div>
            ) : null}
          </div>
        ) : null}
      </div>
    </header>
  );
}
