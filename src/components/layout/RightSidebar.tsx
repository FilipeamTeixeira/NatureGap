'use client';

import { useEffect, useState } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { cn } from '@/lib/utils';

interface RightSidebarProps {
  label: string;
  /** When this becomes a new selection id, the sidebar expands so the panel is visible. */
  expandKey?: string | null;
  children: React.ReactNode;
}

export default function RightSidebar({ label, expandKey, children }: RightSidebarProps) {
  const [collapsed, setCollapsed] = useState(true);
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      setCollapsed(window.localStorage.getItem('naturegap.right-sidebar.collapsed') !== 'false');
      setHydrated(true);
    });
    return () => window.cancelAnimationFrame(frame);
  }, []);

  useEffect(() => {
    if (!hydrated) return;
    window.localStorage.setItem('naturegap.right-sidebar.collapsed', String(collapsed));
  }, [collapsed, hydrated]);

  useEffect(() => {
    if (expandKey) setCollapsed(false);
  }, [expandKey]);

  return (
    <aside
      className={cn(
        'flex-shrink-0 bg-white border-l border-[#E4E7E1] flex flex-col overflow-hidden transition-[width] duration-200',
        collapsed ? 'w-16' : 'w-[440px]',
      )}
    >
      <div className={cn('border-b border-[#E4E7E1] flex items-center', collapsed ? 'justify-center p-3' : 'justify-between px-5 py-3')}>
        <span className={cn('text-[10px] font-semibold text-[#667066] uppercase tracking-widest', collapsed && 'hidden')}>
          {label}
        </span>
        <button
          type="button"
          onClick={() => setCollapsed((value) => !value)}
          aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          className="w-8 h-8 rounded-lg border border-[#E4E7E1] flex items-center justify-center text-[#667066] hover:bg-[#F7F8F5]"
        >
          {collapsed ? <ChevronLeft size={14} strokeWidth={1.8} /> : <ChevronRight size={14} strokeWidth={1.8} />}
        </button>
      </div>

      <div className={cn('flex-1 min-h-0 overflow-hidden', collapsed && 'hidden')}>
        {children}
      </div>
    </aside>
  );
}
