import { AlertTriangle, CheckCircle2 } from 'lucide-react';
import { cn } from '@/lib/utils';

export function FieldLabel({ children }: { children: React.ReactNode }) {
  return (
    <label className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest">{children}</label>
  );
}

export function StatusMessage({
  kind,
  children,
}: {
  kind: 'success' | 'warning' | 'error';
  children: React.ReactNode;
}) {
  const Icon = kind === 'success' ? CheckCircle2 : AlertTriangle;
  return (
    <div
      className={cn(
        'flex items-start gap-2 rounded-lg border px-3 py-2 text-[12px] leading-relaxed',
        kind === 'success' && 'bg-[#F2F8EF] border-[#CFE3C8] text-[#2E6F40]',
        kind === 'warning' && 'bg-[#FFF8E8] border-[#F2D49B] text-[#8A5B12]',
        kind === 'error' && 'bg-[#FDF0E4] border-[#E8B48E] text-[#9B4A1A]',
      )}
    >
      <Icon size={14} className="mt-0.5 flex-shrink-0" strokeWidth={1.8} />
      <span>{children}</span>
    </div>
  );
}

export function Select({
  value,
  onChange,
  children,
}: {
  value: string;
  onChange: (value: string) => void;
  children: React.ReactNode;
}) {
  return (
    <select
      value={value}
      onChange={(event) => onChange(event.target.value)}
      className="w-full rounded-lg border border-[#E4E7E1] bg-white px-3 py-2 text-[13px] text-[#1F2A1F] outline-none focus:border-[#2E6F40]"
    >
      {children}
    </select>
  );
}

export function formatTime(seconds: number): string {
  const mm = Math.floor(seconds / 60).toString().padStart(2, '0');
  const ss = Math.max(0, seconds % 60).toString().padStart(2, '0');
  return `${mm}:${ss}`;
}
