import Link from 'next/link';
import { Leaf } from 'lucide-react';

const NAV_LINKS = ['Explore', 'Take Action', 'Community', 'About'];

export default function Navbar() {
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
        {NAV_LINKS.map((item, i) => (
          <Link
            key={item}
            href="#"
            className={
              i === 0
                ? 'text-sm text-[#1a1a1a] font-medium border-b border-[#3d6b2f] pb-px'
                : 'text-sm text-neutral-400 hover:text-neutral-700 transition-colors'
            }
          >
            {item}
          </Link>
        ))}
      </nav>

      <div className="ml-auto">
        <button className="text-sm bg-[#3d6b2f] text-white px-4 py-1.5 rounded-full hover:bg-[#2d5222] transition-colors font-medium">
          Sign in
        </button>
      </div>
    </header>
  );
}
