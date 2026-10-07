'use client';

import { cn } from '@/lib/utils';
import {
  FOCUS_CLASS_TEXT,
  FOCUS_HINT_TEXT,
  focusReasons,
  type CellFocus,
  type FocusClass,
} from '@/lib/green-focus';

// Literal class strings so Tailwind keeps them; colours match FOCUS_COLORS.
const BADGE_CLASS: Record<FocusClass, string> = {
  focus: 'bg-[#EFE4F4] text-[#5A1F6E]',
  link: 'bg-[#FCE9DA] text-[#A34400]',
  protect: 'bg-[#DDEAD8] text-[#1B5E2E]',
  green: 'bg-[#F0F4EE] text-[#4F6B4F]',
};

const PANEL_CLASS: Record<FocusClass, string> = {
  focus: 'bg-[#F6EFF9] border-[#D9C2E4]',
  link: 'bg-[#FDF3EA] border-[#F2CFB0]',
  protect: 'bg-[#EEF5EB] border-[#C6DDBE]',
  green: 'bg-[#F7F8F5] border-[#E4E7E1]',
};

/** The panel header's badge for a green place's Nature gap class. */
export function focusHeadline(focus: CellFocus): { text: string; className: string } {
  return { text: FOCUS_CLASS_TEXT[focus.focusClass].label, className: BADGE_CLASS[focus.focusClass] };
}

export default function GreenFocusCard({
  focus,
  detailLoading,
  speciesRadiusM = 50,
}: {
  focus: CellFocus;
  detailLoading?: boolean;
  speciesRadiusM?: number | null;
}) {
  const reasons = focusReasons(focus, speciesRadiusM);
  const text = FOCUS_CLASS_TEXT[focus.focusClass];

  return (
    <div
      className="bg-white rounded-2xl border border-[#E4E7E1] p-6"
      style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}
    >
      <h3 className="text-[15px] font-semibold text-[#1F2A1F] mb-1">Nature gap</h3>
      <p className="text-[11px] text-[#667066] uppercase tracking-widest mb-4">
        Where to focus among green places
      </p>

      <div className={cn('rounded-xl border p-4 mb-3', PANEL_CLASS[focus.focusClass])}>
        <span className={cn('text-[11px] font-semibold px-3 py-1 rounded-full inline-block mb-2', BADGE_CLASS[focus.focusClass])}>
          {text.label}
        </span>
        <div className="text-[14px] font-semibold text-[#1F2A1F] leading-snug">{text.headline}</div>
        {focus.hint && (
          <div className="text-[12px] text-[#667066] mt-1">{FOCUS_HINT_TEXT[focus.hint]}</div>
        )}
      </div>

      {reasons.length > 0 && (
        <ul className="space-y-1.5 mb-3">
          {reasons.map((reason) => (
            <li key={reason} className="text-[12px] text-[#1F2A1F] leading-snug flex gap-2">
              <span className="text-[#9AA59A]">•</span>
              <span>{reason}</span>
            </li>
          ))}
        </ul>
      )}
      {detailLoading && !focus.roles && (
        <div className="text-[11px] text-[#9AA59A] mb-3">Loading the reasons…</div>
      )}

      <p className="text-[11px] text-[#667066] leading-relaxed">
        Built from measured green cover, wildlife routes and species records — it does not predict
        species. Records follow where people look, so &ldquo;none recorded yet&rdquo; is a reason to
        survey, not an absence.
      </p>
    </div>
  );
}
