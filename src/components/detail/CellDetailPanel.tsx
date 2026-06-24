'use client';

import { useState } from 'react';
import { X, ArrowLeft } from 'lucide-react';
import { cn, getScoreLabel } from '@/lib/utils';
import type { CellData } from '@/lib/types';
import ScoreGauge from './ScoreGauge';
import TrendChart from './TrendChart';
import InterventionCard from './InterventionCard';

type Tab = 'overview' | 'biodiversity' | 'habitat' | 'trends' | 'actions';

const TABS: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'biodiversity', label: 'Biodiversity' },
  { id: 'habitat', label: 'Habitat' },
  { id: 'trends', label: 'Trends' },
  { id: 'actions', label: 'Actions' },
];

const SPECIES_LABELS: Record<string, string> = {
  plant: 'Plants',
  bird: 'Birds',
  insect: 'Insects',
  mammal: 'Mammals',
  fungi: 'Fungi',
};

interface CellDetailPanelProps {
  cell: CellData;
  onClose: () => void;
}

export default function CellDetailPanel({ cell, onClose }: CellDetailPanelProps) {
  const [tab, setTab] = useState<Tab>('overview');
  const isUnder = cell.impactScore < -5;

  return (
    <div className="w-[320px] flex-shrink-0 bg-white border-l border-[#e4e7e3] flex flex-col overflow-hidden">
      <div className="px-5 pt-4 flex-shrink-0">
        <button
          onClick={onClose}
          className="flex items-center gap-1.5 text-xs text-neutral-400 hover:text-neutral-600 transition-colors mb-3"
        >
          <ArrowLeft size={11} />
          Back to map
        </button>

        <div className="flex items-start justify-between mb-4">
          <div>
            <h2 className="font-semibold text-neutral-900 text-[15px] leading-tight">{cell.name}</h2>
            <p className="text-xs text-neutral-400 mt-0.5">
              {cell.nameJa} · Yokohama
            </p>
          </div>
          <button
            onClick={onClose}
            className="text-neutral-300 hover:text-neutral-500 transition-colors mt-0.5"
          >
            <X size={15} />
          </button>
        </div>

        <div className="flex -mx-5 px-5 border-b border-[#e4e7e3] overflow-x-auto">
          {TABS.map((t) => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={cn(
                'text-[11px] py-2 px-2.5 -mb-px border-b-2 transition-colors font-medium whitespace-nowrap flex-shrink-0',
                tab === t.id
                  ? 'border-[#3d6b2f] text-[#3d6b2f]'
                  : 'border-transparent text-neutral-400 hover:text-neutral-600',
              )}
            >
              {t.label}
            </button>
          ))}
        </div>
      </div>

      <div className="flex-1 overflow-y-auto">
        {tab === 'overview' && (
          <div className="p-5 flex flex-col gap-5">
            <div>
              <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest mb-1">
                Nature impact (gap)
              </p>
              <span
                className={cn(
                  'text-[11px] font-semibold px-2.5 py-0.5 rounded-full inline-block mb-3',
                  isUnder ? 'bg-orange-50 text-orange-700' : 'bg-green-50 text-green-700',
                )}
              >
                {getScoreLabel(cell.impactScore)}
              </span>

              <div className="flex items-start gap-4">
                <ScoreGauge score={cell.impactScore} />

                <div className="pt-1 flex-1">
                  <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest mb-1">
                    Habitat potential
                  </p>
                  <span
                    className={cn(
                      'text-[11px] font-semibold px-2.5 py-0.5 rounded-full inline-block mb-2',
                      cell.habitatPotential === 'high'
                        ? 'bg-green-50 text-green-700'
                        : cell.habitatPotential === 'moderate'
                          ? 'bg-yellow-50 text-yellow-700'
                          : 'bg-neutral-100 text-neutral-500',
                    )}
                  >
                    {cell.habitatPotential.charAt(0).toUpperCase() + cell.habitatPotential.slice(1)}
                  </span>
                  <p className="text-[11px] text-neutral-400 leading-snug">
                    {cell.habitatPotential === 'high'
                      ? 'This landscape could support high biodiversity.'
                      : cell.habitatPotential === 'moderate'
                        ? 'Moderate habitat capacity based on land cover.'
                        : 'Limited habitat capacity based on land cover.'}
                  </p>
                </div>
              </div>
            </div>

            {cell.pressures.length > 0 && (
              <div>
                <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest mb-2">
                  Why this area is underperforming
                </p>
                <div className="flex flex-col gap-1.5">
                  {cell.pressures.map((p) => (
                    <div key={p} className="flex items-start gap-2 text-xs text-neutral-600">
                      <div className="w-1.5 h-1.5 rounded-full bg-orange-400 mt-1.5 flex-shrink-0" />
                      {p}
                    </div>
                  ))}
                </div>
              </div>
            )}

            <div>
              <div className="flex items-center justify-between mb-2">
                <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest">
                  Observed biodiversity
                </p>
                <span
                  className={cn(
                    'text-[10px] font-semibold px-2 py-0.5 rounded-full',
                    cell.observedRichness >= cell.expectedRichness * 0.95
                      ? 'bg-green-50 text-green-700'
                      : 'bg-orange-50 text-orange-700',
                  )}
                >
                  {cell.observedRichness >= cell.expectedRichness * 0.95 ? 'Good' : 'Moderate'}
                </span>
              </div>

              <div className="text-2xl font-bold text-neutral-900 leading-none">
                {cell.observedRichness}
              </div>
              <div className="text-[11px] text-neutral-400 mt-0.5 mb-3">
                vs. {cell.expectedRichness} expected
              </div>

              <div className="flex gap-4">
                {cell.species.map((s) => (
                  <div key={s.type} className="flex flex-col items-center gap-0.5">
                    <span className="text-sm font-semibold text-neutral-800">{s.count}</span>
                    <span className="text-[9px] text-neutral-400">{SPECIES_LABELS[s.type]}</span>
                  </div>
                ))}
              </div>
            </div>

            <div>
              <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest mb-2">
                Impact trend (12 months)
              </p>
              <TrendChart data={cell.trendData} />
            </div>

            {cell.interventions.length > 0 && (
              <div>
                <div className="flex items-center justify-between mb-1">
                  <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest">
                    Top actions for this area
                  </p>
                  <button
                    onClick={() => setTab('actions')}
                    className="text-[10px] text-[#3d6b2f] font-medium hover:underline"
                  >
                    See all →
                  </button>
                </div>
                {cell.interventions.slice(0, 2).map((iv) => (
                  <InterventionCard key={iv.id} intervention={iv} />
                ))}
              </div>
            )}
          </div>
        )}

        {tab === 'actions' && (
          <div className="p-5">
            <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest mb-4">
              Recommended actions · ranked by impact
            </p>
            {cell.interventions.map((iv) => (
              <InterventionCard key={iv.id} intervention={iv} />
            ))}
            {cell.interventions.length === 0 && (
              <p className="text-xs text-neutral-400 leading-relaxed">
                No ranked interventions are available for this area yet.
              </p>
            )}
          </div>
        )}

        {tab === 'biodiversity' && (
          <div className="p-5 flex flex-col gap-5">
            <div>
              <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest mb-3">
                Species breakdown
              </p>
              <div className="text-2xl font-bold text-neutral-900 leading-none">{cell.observedRichness}</div>
              <div className="text-[11px] text-neutral-400 mt-0.5 mb-4">
                species observed · {cell.expectedRichness} expected
              </div>

              <div className="flex flex-col gap-3">
                {cell.species.map((s) => (
                  <div key={s.type} className="flex items-center gap-3">
                    <div className="w-16 text-[11px] text-neutral-500">{SPECIES_LABELS[s.type]}</div>
                    <div className="flex-1 h-1.5 bg-[#f0f0ee] rounded-full overflow-hidden">
                      <div
                        className="h-full bg-[#6a9044] rounded-full transition-all"
                        style={{ width: `${(s.count / Math.max(cell.observedRichness, 1)) * 100}%` }}
                      />
                    </div>
                    <div className="w-6 text-xs font-semibold text-neutral-700 text-right">{s.count}</div>
                  </div>
                ))}
              </div>
            </div>

            <div className="pt-4 border-t border-[#e4e7e3]">
              <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest mb-3">
                Diversity indices
              </p>
              <div className="flex gap-6">
                <div>
                  <div className="text-xl font-bold text-neutral-900">{cell.taxonomicDiversity.toFixed(1)}</div>
                  <div className="text-[10px] text-neutral-400 mt-0.5">Shannon diversity</div>
                </div>
                <div>
                  <div className="text-xl font-bold text-neutral-900">{cell.observerEffortScore.toFixed(1)}</div>
                  <div className="text-[10px] text-neutral-400 mt-0.5">obs / km effort</div>
                </div>
              </div>
            </div>
          </div>
        )}

        {tab === 'habitat' && (
          <div className="p-5 flex flex-col gap-5">
            <div>
              <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest mb-4">
                Habitat metrics
              </p>
              <div className="flex flex-col gap-4">
                {[
                  { label: 'Habitat quality', value: cell.habitatQuality, inverted: false },
                  { label: 'Corridor importance', value: cell.corridorImportance, inverted: false },
                  { label: 'Fragmentation index', value: cell.fragmentationIndex, inverted: true },
                ].map(({ label, value, inverted }) => (
                  <div key={label}>
                    <div className="flex items-center justify-between mb-1.5">
                      <span className="text-xs text-neutral-600">{label}</span>
                      <span className="text-xs font-semibold text-neutral-800">{value}</span>
                    </div>
                    <div className="h-1.5 bg-[#f0f0ee] rounded-full overflow-hidden">
                      <div
                        className={cn('h-full rounded-full transition-all', inverted ? 'bg-orange-400' : 'bg-[#6a9044]')}
                        style={{ width: `${value}%` }}
                      />
                    </div>
                    {inverted && (
                      <p className="text-[10px] text-neutral-400 mt-1">
                        Higher fragmentation = more isolated patches
                      </p>
                    )}
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}

        {tab === 'trends' && (
          <div className="p-5 flex flex-col gap-4">
            <div>
              <p className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest mb-3">
                Impact trend (12 months)
              </p>
              <TrendChart data={cell.trendData} />
            </div>
            <p className="text-[11px] text-neutral-400 leading-relaxed">
              The nature impact score tracks the gap between expected and observed biodiversity, corrected for
              observer effort. Values near zero indicate nature is performing as expected for the habitat type.
            </p>
            <div className="pt-3 border-t border-[#e4e7e3] flex gap-6">
              <div>
                <div className="text-lg font-bold text-neutral-900">
                  {Math.max(...cell.trendData)}
                </div>
                <div className="text-[10px] text-neutral-400 mt-0.5">12-month high</div>
              </div>
              <div>
                <div className="text-lg font-bold text-neutral-900">
                  {Math.min(...cell.trendData)}
                </div>
                <div className="text-[10px] text-neutral-400 mt-0.5">12-month low</div>
              </div>
              <div>
                <div className="text-lg font-bold text-neutral-900">
                  {(cell.trendData.reduce((a, b) => a + b, 0) / cell.trendData.length).toFixed(1)}
                </div>
                <div className="text-[10px] text-neutral-400 mt-0.5">Average</div>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
