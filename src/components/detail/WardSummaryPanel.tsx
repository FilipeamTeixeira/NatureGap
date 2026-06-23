'use client';

import { ArrowLeft, X } from 'lucide-react';
import { cn, getScoreLabel, getScoreColor, formatScore } from '@/lib/utils';
import type { WardFeature } from '@/lib/types';
import ScoreGauge from './ScoreGauge';

interface WardSummaryPanelProps {
  ward: WardFeature;
  onClose: () => void;
}

export default function WardSummaryPanel({ ward, onClose }: WardSummaryPanelProps) {
  const color = getScoreColor(ward.score);
  const isUnder = ward.score < -5;

  return (
    <div className="w-[320px] flex-shrink-0 bg-white border-l border-[#e4e7e3] flex flex-col overflow-hidden">
      <div className="px-5 pt-4 pb-5 flex-1">
        <button
          onClick={onClose}
          className="flex items-center gap-1.5 text-xs text-neutral-400 hover:text-neutral-600 transition-colors mb-3"
        >
          <ArrowLeft size={11} />
          Back to map
        </button>

        <div className="flex items-start justify-between mb-6">
          <div>
            <h2 className="font-semibold text-neutral-900 text-[15px] leading-tight">{ward.name} Ward</h2>
            <p className="text-xs text-neutral-400 mt-0.5">{ward.nameJa} · Yokohama</p>
          </div>
          <button onClick={onClose} className="text-neutral-300 hover:text-neutral-500 mt-0.5">
            <X size={15} />
          </button>
        </div>

        <div className="flex flex-col items-center py-4">
          <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest mb-2">
            Nature impact (gap)
          </p>
          <span
            className={cn(
              'text-[11px] font-semibold px-2.5 py-0.5 rounded-full inline-block mb-4',
              isUnder ? 'bg-orange-50 text-orange-700' : 'bg-green-50 text-green-700',
            )}
          >
            {getScoreLabel(ward.score)}
          </span>
          <ScoreGauge score={ward.score} />
        </div>

        <div className="mt-6 p-4 bg-[#f7f8f6] rounded-xl text-center">
          <p className="text-[11px] text-neutral-500 leading-relaxed">
            Detailed analysis — biodiversity breakdown, habitat metrics, and intervention recommendations — is not yet available for this ward.
          </p>
          <button className="mt-3 text-xs font-medium text-[#3d6b2f] hover:underline">
            Contribute observations on iNaturalist →
          </button>
        </div>
      </div>
    </div>
  );
}
