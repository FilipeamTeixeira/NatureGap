import Link from 'next/link';
import { Leaf } from 'lucide-react';

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
    <header className="h-12 bg-white border-b border-[#e4e7e3] flex items-center px-5 gap-8 flex-shrink-0 z-10">
      <Link
        href="/"
        className="flex items-center gap-2 font-semibold text-[#3d6b2f] text-sm tracking-tight"
      >
        <Leaf size={15} strokeWidth={2.5} />
        <span>NatureGap</span>
      </Link>

      <nav className="flex gap-5">
        {NAV_LINKS.map(({ label, href }) => (
          <Link
            key={href}
            href={href}
            className={
              activePath === href
                ? 'text-sm text-[#1a1a1a] font-medium border-b border-[#3d6b2f] pb-px'
                : 'text-sm text-neutral-400 hover:text-neutral-700 transition-colors'
            }
          >
            {label}
          </Link>
        ))}
      </nav>
    </header>
  );
}
