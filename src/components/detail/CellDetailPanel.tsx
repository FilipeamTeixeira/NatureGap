'use client';

import { useState } from 'react';
import { X, ArrowLeft, TrendingUp, TrendingDown, Minus } from 'lucide-react';
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

function Card({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <div
      className={cn('bg-white rounded-2xl border border-[#E4E7E1] p-5', className)}
      style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}
    >
      {children}
    </div>
  );
}

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <p className="text-[10px] font-semibold text-[#667066] uppercase tracking-widest mb-3">
      {children}
    </p>
  );
}

export default function CellDetailPanel({ cell, onClose }: CellDetailPanelProps) {
  const [tab, setTab] = useState<Tab>('overview');
  const isUnder = cell.impactScore < -5;

  const trendDir =
    cell.trendData.length >= 2
      ? cell.trendData[cell.trendData.length - 1] - cell.trendData[0]
      : 0;

  return (
    <div className="w-[440px] flex-shrink-0 bg-[#F7F8F5] border-l border-[#E4E7E1] flex flex-col overflow-hidden">
      {/* Panel header */}
      <div className="px-6 pt-5 pb-0 flex-shrink-0 bg-white border-b border-[#E4E7E1]">
        <button
          onClick={onClose}
          className="flex items-center gap-1.5 text-[11px] text-[#667066] hover:text-[#1F2A1F] transition-colors mb-4"
        >
          <ArrowLeft size={11} strokeWidth={2} />
          Back to map
        </button>

        <div className="flex items-start justify-between mb-4">
          <div className="flex-1 min-w-0 pr-3">
            <h2 className="font-semibold text-[#1F2A1F] text-[16px] leading-tight">{cell.name}</h2>
            <p className="text-[12px] text-[#667066] mt-0.5">
              {cell.nameJa} · Yokohama
            </p>
          </div>
          <button
            onClick={onClose}
            className="text-[#D1D8CE] hover:text-[#667066] transition-colors mt-0.5 flex-shrink-0"
            aria-label="Close panel"
          >
            <X size={16} strokeWidth={1.5} />
          </button>
        </div>

        {/* Status badge row */}
        <div className="flex items-center gap-2 mb-4">
          <span
            className={cn(
              'text-[11px] font-semibold px-3 py-1 rounded-full inline-block',
              isUnder
                ? 'bg-[#FDF0E4] text-[#C97A2A]'
                : 'bg-[#DDEAD8] text-[#2E6F40]',
            )}
          >
            {getScoreLabel(cell.impactScore)}
          </span>
          <span
            className={cn(
              'text-[11px] font-medium px-2.5 py-1 rounded-full',
              cell.habitatPotential === 'high'
                ? 'bg-[#DDEAD8] text-[#2E6F40]'
                : cell.habitatPotential === 'moderate'
                  ? 'bg-[#FDF6E4] text-[#B07A2A]'
                  : 'bg-[#F0F0EE] text-[#667066]',
            )}
          >
            {cell.habitatPotential.charAt(0).toUpperCase() + cell.habitatPotential.slice(1)} potential
          </span>
        </div>

        {/* Tabs */}
        <div className="flex -mx-6 px-6 overflow-x-auto">
          {TABS.map((t) => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={cn(
                'text-[12px] py-2.5 px-3 -mb-px border-b-2 transition-colors font-medium whitespace-nowrap flex-shrink-0',
                tab === t.id
                  ? 'border-[#2E6F40] text-[#2E6F40]'
                  : 'border-transparent text-[#667066] hover:text-[#1F2A1F]',
              )}
            >
              {t.label}
            </button>
          ))}
        </div>
      </div>

      {/* Scrollable content */}
      <div className="flex-1 overflow-y-auto">
        {/* ─── OVERVIEW ─────────────────────────────────────────────────── */}
        {tab === 'overview' && (
          <div className="p-5 flex flex-col gap-4">
            {/* Ecological diagnosis card */}
            <Card>
              <SectionLabel>Ecological Diagnosis</SectionLabel>
              <div className="flex items-center gap-5">
                <ScoreGauge score={cell.impactScore} />
                <div className="flex-1">
                  <p className="text-[11px] text-[#667066] leading-relaxed">
                    {cell.habitatPotential === 'high'
                      ? 'This landscape could support high biodiversity.'
                      : cell.habitatPotential === 'moderate'
                        ? 'Moderate habitat capacity based on land cover.'
                        : 'Limited habitat capacity based on land cover.'}
                  </p>
                  {cell.pressures.length > 0 && (
                    <div className="mt-3 flex flex-col gap-1.5">
                      {cell.pressures.slice(0, 2).map((p) => (
                        <div key={p} className="flex items-start gap-2 text-[11px] text-[#667066]">
                          <div className="w-1.5 h-1.5 rounded-full bg-[#E8A44C] mt-1.5 flex-shrink-0" />
                          {p}
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            </Card>

            {/* Biodiversity KPI card */}
            <Card>
              <SectionLabel>Biodiversity</SectionLabel>
              <div className="grid grid-cols-2 gap-3 mb-4">
                <div className="bg-[#F7F8F5] rounded-xl p-3">
                  <div className="text-[28px] font-semibold text-[#1F2A1F] leading-none">
                    {cell.observedRichness}
                  </div>
                  <div className="text-[11px] text-[#667066] mt-1">Species observed</div>
                </div>
                <div className="bg-[#F7F8F5] rounded-xl p-3">
                  <div className="text-[28px] font-semibold text-[#1F2A1F] leading-none">
                    {cell.expectedRichness}
                  </div>
                  <div className="text-[11px] text-[#667066] mt-1">Species expected</div>
                </div>
              </div>

              <div className="flex gap-4 pt-3 border-t border-[#E4E7E1]">
                {cell.species.map((s) => (
                  <div key={s.type} className="flex flex-col items-center gap-0.5">
                    <span className="text-[13px] font-semibold text-[#1F2A1F]">{s.count}</span>
                    <span className="text-[9px] text-[#667066] uppercase tracking-wide">{SPECIES_LABELS[s.type]}</span>
                  </div>
                ))}
              </div>
            </Card>

            {/* Habitat metrics card */}
            <Card>
              <SectionLabel>Habitat Metrics</SectionLabel>
              <div className="flex flex-col gap-3.5">
                {[
                  { label: 'Habitat quality', value: cell.habitatQuality, inverted: false },
                  { label: 'Corridor importance', value: cell.corridorImportance, inverted: false },
                  { label: 'Fragmentation index', value: cell.fragmentationIndex, inverted: true },
                ].map(({ label, value, inverted }) => (
                  <div key={label}>
                    <div className="flex items-center justify-between mb-1.5">
                      <span className="text-[12px] text-[#667066]">{label}</span>
                      <span className="text-[12px] font-semibold text-[#1F2A1F]">{value}</span>
                    </div>
                    <div className="h-1.5 bg-[#E4E7E1] rounded-full overflow-hidden">
                      <div
                        className="h-full rounded-full transition-all"
                        style={{
                          width: `${value}%`,
                          backgroundColor: inverted ? '#E8A44C' : '#73A56D',
                        }}
                      />
                    </div>
                  </div>
                ))}
              </div>
            </Card>

            {/* Trend card */}
            <Card>
              <div className="flex items-center justify-between mb-3">
                <SectionLabel>Impact Trend · 12 months</SectionLabel>
                <div className="flex items-center gap-1 text-[11px] font-medium mb-3">
                  {trendDir > 0 ? (
                    <><TrendingUp size={12} className="text-[#2E6F40]" /><span className="text-[#2E6F40]">Improving</span></>
                  ) : trendDir < 0 ? (
                    <><TrendingDown size={12} className="text-[#C95B4B]" /><span className="text-[#C95B4B]">Declining</span></>
                  ) : (
                    <><Minus size={12} className="text-[#667066]" /><span className="text-[#667066]">Stable</span></>
                  )}
                </div>
              </div>
              <TrendChart data={cell.trendData} />
            </Card>

            {/* Actions preview */}
            {cell.interventions.length > 0 && (
              <Card>
                <div className="flex items-center justify-between mb-1">
                  <SectionLabel>Top Recommended Actions</SectionLabel>
                  <button
                    onClick={() => setTab('actions')}
                    className="text-[11px] text-[#2E6F40] font-medium hover:underline mb-3"
                  >
                    See all →
                  </button>
                </div>
                {cell.interventions.slice(0, 2).map((iv) => (
                  <InterventionCard key={iv.id} intervention={iv} />
                ))}
              </Card>
            )}
          </div>
        )}

        {/* ─── BIODIVERSITY ─────────────────────────────────────────────── */}
        {tab === 'biodiversity' && (
          <div className="p-5 flex flex-col gap-4">
            <Card>
              <SectionLabel>Species breakdown</SectionLabel>
              <div className="grid grid-cols-2 gap-3 mb-5">
                <div className="bg-[#F7F8F5] rounded-xl p-3">
                  <div className="text-[32px] font-semibold text-[#1F2A1F] leading-none">{cell.observedRichness}</div>
                  <div className="text-[11px] text-[#667066] mt-1.5">Observed species</div>
                </div>
                <div className="bg-[#F7F8F5] rounded-xl p-3">
                  <div className="text-[32px] font-semibold text-[#1F2A1F] leading-none">{cell.expectedRichness}</div>
                  <div className="text-[11px] text-[#667066] mt-1.5">Expected species</div>
                </div>
              </div>

              <div className="flex flex-col gap-3">
                {cell.species.map((s) => (
                  <div key={s.type} className="flex items-center gap-3">
                    <div className="w-20 text-[12px] text-[#667066]">{SPECIES_LABELS[s.type]}</div>
                    <div className="flex-1 h-1.5 bg-[#E4E7E1] rounded-full overflow-hidden">
                      <div
                        className="h-full rounded-full transition-all"
                        style={{
                          width: `${(s.count / Math.max(cell.observedRichness, 1)) * 100}%`,
                          backgroundColor: '#73A56D',
                        }}
                      />
                    </div>
                    <div className="w-7 text-[12px] font-semibold text-[#1F2A1F] text-right">{s.count}</div>
                  </div>
                ))}
              </div>
            </Card>

            <Card>
              <SectionLabel>Diversity indices</SectionLabel>
              <div className="grid grid-cols-2 gap-3">
                <div className="bg-[#F7F8F5] rounded-xl p-4">
                  <div className="text-[28px] font-semibold text-[#1F2A1F] leading-none">{cell.taxonomicDiversity.toFixed(1)}</div>
                  <div className="text-[11px] text-[#667066] mt-1.5">Shannon diversity</div>
                </div>
                <div className="bg-[#F7F8F5] rounded-xl p-4">
                  <div className="text-[28px] font-semibold text-[#1F2A1F] leading-none">{cell.observerEffortScore.toFixed(1)}</div>
                  <div className="text-[11px] text-[#667066] mt-1.5">obs / km effort</div>
                </div>
              </div>
            </Card>
          </div>
        )}

        {/* ─── HABITAT ──────────────────────────────────────────────────── */}
        {tab === 'habitat' && (
          <div className="p-5 flex flex-col gap-4">
            <Card>
              <SectionLabel>Habitat metrics</SectionLabel>
              <div className="flex flex-col gap-5">
                {[
                  { label: 'Habitat quality', value: cell.habitatQuality, inverted: false },
                  { label: 'Corridor importance', value: cell.corridorImportance, inverted: false },
                  { label: 'Fragmentation index', value: cell.fragmentationIndex, inverted: true },
                ].map(({ label, value, inverted }) => (
                  <div key={label}>
                    <div className="flex items-center justify-between mb-2">
                      <span className="text-[13px] text-[#1F2A1F] font-medium">{label}</span>
                      <span className="text-[13px] font-semibold text-[#1F2A1F]">{value}</span>
                    </div>
                    <div className="h-2 bg-[#E4E7E1] rounded-full overflow-hidden">
                      <div
                        className="h-full rounded-full transition-all"
                        style={{
                          width: `${value}%`,
                          backgroundColor: inverted ? '#E8A44C' : '#73A56D',
                        }}
                      />
                    </div>
                    {inverted && (
                      <p className="text-[10px] text-[#9ca3af] mt-1.5">
                        Higher fragmentation → more isolated patches
                      </p>
                    )}
                  </div>
                ))}
              </div>
            </Card>
          </div>
        )}

        {/* ─── TRENDS ───────────────────────────────────────────────────── */}
        {tab === 'trends' && (
          <div className="p-5 flex flex-col gap-4">
            <Card>
              <SectionLabel>Impact trend · 12 months</SectionLabel>
              <TrendChart data={cell.trendData} />
              <p className="text-[11px] text-[#667066] leading-relaxed mt-4">
                The nature impact score tracks the gap between expected and observed biodiversity,
                corrected for observer effort. Values near zero indicate nature is performing as
                expected for the habitat type.
              </p>
            </Card>

            <div className="grid grid-cols-3 gap-3">
              {[
                { label: '12-month high', value: Math.max(...cell.trendData) },
                { label: '12-month low', value: Math.min(...cell.trendData) },
                { label: 'Average', value: parseFloat((cell.trendData.reduce((a, b) => a + b, 0) / cell.trendData.length).toFixed(1)) },
              ].map(({ label, value }) => (
                <Card key={label} className="!p-4">
                  <div className="text-[22px] font-semibold text-[#1F2A1F] leading-none">{value}</div>
                  <div className="text-[10px] text-[#667066] mt-1.5">{label}</div>
                </Card>
              ))}
            </div>
          </div>
        )}

        {/* ─── ACTIONS ──────────────────────────────────────────────────── */}
        {tab === 'actions' && (
          <div className="p-5">
            <p className="text-[10px] font-semibold text-[#667066] uppercase tracking-widest mb-4">
              Recommended actions · ranked by impact
            </p>
            <Card className="!p-0 !overflow-hidden">
              {cell.interventions.map((iv) => (
                <InterventionCard key={iv.id} intervention={iv} />
              ))}
              {cell.interventions.length === 0 && (
                <p className="text-[12px] text-[#667066] leading-relaxed p-5">
                  No ranked interventions are available for this area yet.
                </p>
              )}
            </Card>
          </div>
        )}
      </div>
    </div>
  );
}
