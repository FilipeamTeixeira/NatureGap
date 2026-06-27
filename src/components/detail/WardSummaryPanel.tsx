'use client';

import { ArrowLeft, X } from 'lucide-react';
import { cn, getScoreLabel } from '@/lib/utils';
import { SCORE_THRESHOLDS, CITY } from '@/lib/config';
import type { WardFeature } from '@/lib/types';
import ScoreGauge from './ScoreGauge';

interface WardSummaryPanelProps {
  ward: WardFeature;
  onClose: () => void;
}

export default function WardSummaryPanel({ ward, onClose }: WardSummaryPanelProps) {
  const isUnder = ward.score < SCORE_THRESHOLDS.BADGE_UNDERPERFORMING;

  return (
    <div className="w-[320px] flex-shrink-0 bg-white border-l border-[#E4E7E1] flex flex-col overflow-hidden">
      <div className="px-5 pt-4 pb-5 flex-1">
        <button
          onClick={onClose}
          className="flex items-center gap-1.5 text-[11px] text-[#667066] hover:text-[#1F2A1F] transition-colors mb-3"
        >
          <ArrowLeft size={11} strokeWidth={2} />
          Back to map
        </button>

        <div className="flex items-start justify-between mb-6">
          <div>
            <h2 className="font-semibold text-[#1F2A1F] text-[15px] leading-tight">{ward.name} Ward</h2>
            <p className="text-[12px] text-[#667066] mt-0.5">{ward.nameJa} · {CITY.name}</p>
          </div>
          <button
            onClick={onClose}
            className="text-[#D1D8CE] hover:text-[#667066] transition-colors mt-0.5"
            aria-label="Close panel"
          >
            <X size={15} strokeWidth={1.5} />
          </button>
        </div>

        <div className="flex flex-col items-center py-4">
          <p className="text-[10px] font-semibold text-[#667066] uppercase tracking-widest mb-2">
            Nature Gap
          </p>
          <span
            className={cn(
              'text-[11px] font-semibold px-3 py-1 rounded-full inline-block mb-4',
              isUnder ? 'bg-[#FDF0E4] text-[#C97A2A]' : 'bg-[#DDEAD8] text-[#2E6F40]',
            )}
          >
            {getScoreLabel(ward.score)}
          </span>
          <ScoreGauge score={ward.score} />
        </div>

        <div className="mt-6 p-4 bg-[#F7F8F5] rounded-xl border border-[#E4E7E1]">
          <p className="text-[11px] text-[#667066] leading-relaxed">
            Detailed analysis — biodiversity breakdown, habitat metrics, and intervention
            recommendations — is not yet available for this ward.
          </p>
          <button className="mt-3 text-[11px] font-medium text-[#2E6F40] hover:underline">
            Contribute observations on iNaturalist →
          </button>
        </div>
      </div>
    </div>
  );
}
