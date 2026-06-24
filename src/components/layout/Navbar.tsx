import Link from 'next/link';
import { Leaf } from 'lucide-react';
import { CITY } from '@/lib/config';

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
      </div>
    </header>
  );
}
