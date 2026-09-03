'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useEffect, useRef, useState } from 'react';
import { ChevronDown, LogOut, User } from 'lucide-react';
import { CITY, cityMeta, isRegisteredCityId, listCities } from '@/lib/config';
import { useAuth } from '@/components/auth/AuthProvider';
import { LogoMark } from '@/components/layout/Logo';

const NAV_LINKS = [
  { label: 'Explore', href: '/' },
  { label: 'About',   href: '/about' },
];

const AVAILABLE_CITIES = listCities();

interface NavbarProps {
  activePath: string;
  /** cityId of whatever's currently selected/displayed — drives the badge label. */
  cityId?: string;
  /** When set, city picks stay on this page (map). Otherwise they open Explore. */
  onCitySelect?: (cityId: string) => void;
}

export default function Navbar({ activePath, cityId, onCitySelect }: NavbarProps) {
  const { profile, user, loading, signOut } = useAuth();
  const city = cityMeta(cityId);
  const selectedCityId = isRegisteredCityId(cityId) ? cityId : CITY.id;
  const [menuOpen, setMenuOpen] = useState(false);
  const [cityMenuOpen, setCityMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const cityMenuRef = useRef<HTMLDivElement>(null);
  const router = useRouter();

  useEffect(() => {
    function handlePointerDown(event: PointerEvent) {
      const target = event.target as Node;
      if (menuRef.current && !menuRef.current.contains(target)) {
        setMenuOpen(false);
      }
      if (cityMenuRef.current && !cityMenuRef.current.contains(target)) {
        setCityMenuOpen(false);
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

  function handleCitySelect(nextCityId: string) {
    setCityMenuOpen(false);
    if (onCitySelect) {
      onCitySelect(nextCityId);
      return;
    }
    router.push(`/?city=${encodeURIComponent(nextCityId)}`);
  }

  return (
    <header className="h-14 bg-white border-b border-[#E4E7E1] flex items-center px-6 gap-6 flex-shrink-0 z-10">
      <Link
        href="/"
        className="flex items-center gap-2.5 font-semibold text-[#1F2A1F] text-[15px] tracking-tight flex-shrink-0"
      >
        <LogoMark size={26} />
        <span>NatureGap</span>
      </Link>

      <nav className="flex items-center gap-1 flex-1">
        {NAV_LINKS.map(({ label, href }) => (
          <Link
            key={href}
            href={href}
            className={
              activePath === href || (href !== '/' && activePath.startsWith(href))
                ? 'text-[13px] font-medium text-[#1F2A1F] bg-[#F7F8F5] px-3 py-1.5 rounded-lg transition-colors'
                : 'text-[13px] text-[#667066] hover:text-[#1F2A1F] hover:bg-[#F7F8F5] px-3 py-1.5 rounded-lg transition-colors'
            }
          >
            {label}
          </Link>
        ))}
      </nav>

      <div className="flex items-center gap-3 flex-shrink-0">
        <div className="relative" ref={cityMenuRef}>
          <button
            type="button"
            onClick={() => setCityMenuOpen((open) => !open)}
            aria-haspopup="listbox"
            aria-expanded={cityMenuOpen}
            aria-label="Select city"
            className="h-7 flex items-center gap-1 text-[11px] font-medium text-[#2E6F40] bg-[#DDEAD8] pl-2.5 pr-1.5 rounded-full hover:bg-[#CDE3C8]"
          >
            {city.badge}
            <ChevronDown size={12} strokeWidth={2} className="text-[#2E6F40]" />
          </button>

          {cityMenuOpen ? (
            <div
              role="listbox"
              aria-label="Available cities"
              className="absolute right-0 top-full mt-1.5 w-52 rounded-lg border border-[#E4E7E1] bg-white py-1.5 shadow-lg z-50"
            >
              {AVAILABLE_CITIES.map((option) => {
                const isCurrent = option.id === selectedCityId;
                return (
                  <button
                    key={option.id}
                    type="button"
                    role="option"
                    aria-selected={isCurrent}
                    onClick={() => handleCitySelect(option.id)}
                    className={
                      isCurrent
                        ? 'w-full flex flex-col items-start px-3 py-2 text-left bg-[#F7F8F5]'
                        : 'w-full flex flex-col items-start px-3 py-2 text-left hover:bg-[#F7F8F5]'
                    }
                  >
                    <span className="text-[13px] font-medium text-[#1F2A1F]">{option.name}</span>
                    <span className="text-[11px] text-[#667066]">
                      {option.nameJa !== option.name ? `${option.nameJa} · ${option.country}` : option.country}
                    </span>
                  </button>
                );
              })}
            </div>
          ) : null}
        </div>
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
