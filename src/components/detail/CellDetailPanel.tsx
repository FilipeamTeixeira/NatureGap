'use client';

import { useState } from 'react';
import { X, ArrowLeft } from 'lucide-react';
import { cn } from '@/lib/utils';
import { SCORE_THRESHOLDS, CITY, MAX_EXPECTED_RICHNESS } from '@/lib/config';
import type { CellData } from '@/lib/types';
import type { HexLayerId } from '@/lib/layer-styles';
import ScoreGauge from './ScoreGauge';
import InterventionCard from './InterventionCard';

type Tab = 'overview' | 'biodiversity' | 'habitat' | 'actions';

const TABS: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'biodiversity', label: 'Biodiversity' },
  { id: 'habitat', label: 'Habitat' },
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
  activeLayer: HexLayerId;
  onClose: () => void;
  onViewInsidePark?: () => void;
}

function formatMetric(value: number | null | undefined, digits = 1): string {
  return typeof value === 'number' && Number.isFinite(value) ? value.toFixed(digits) : 'Unsampled';
}

function Card({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <div
      className={cn('bg-white rounded-2xl border border-[#E4E7E1] p-6', className)}
      style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}
    >
      {children}
    </div>
  );
}

function CardTitle({ children }: { children: React.ReactNode }) {
  return (
    <h3 className="text-[15px] font-semibold text-[#1F2A1F] mb-1">
      {children}
    </h3>
  );
}

function CardSubtitle({ children }: { children: React.ReactNode }) {
  return (
    <p className="text-[11px] text-[#667066] uppercase tracking-widest mb-4">
      {children}
    </p>
  );
}

function SpeciesGroupList({ species }: { species: CellData['species'] }) {
  const groups = species.filter((s) => s.count > 0);
  if (groups.length === 0) return null;

  return (
    <div className="flex flex-col gap-4">
      {groups.map((s) => (
        <div key={s.type}>
          <div className="flex items-baseline justify-between mb-2">
            <span className="text-[12px] font-medium text-[#1F2A1F]">
              {SPECIES_LABELS[s.type]}
            </span>
            <span className="text-[11px] text-[#667066]">
              {s.count} {s.count === 1 ? 'species' : 'species'}
            </span>
          </div>
          {s.names && s.names.length > 0 ? (
            <ul className="flex flex-col gap-1 pl-3 border-l-2 border-[#DDEAD8]">
              {s.names.map((name) => (
                <li key={name} className="text-[12px] text-[#667066] leading-snug">
                  {name}
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-[11px] text-[#A8B4A8] italic pl-3">
              Species names will appear after the next pipeline export.
            </p>
          )}
        </div>
      ))}
    </div>
  );
}

function ecologicalStatus(score: number): string {
  if (score < SCORE_THRESHOLDS.BADGE_UNDERPERFORMING) return 'Under pressure';
  if (score > SCORE_THRESHOLDS.BETTER) return 'Potential refuge';
  return 'Performing as expected';
}

function ExpectedRichnessExplainer({ cell }: { cell: CellData }) {
  const hqPct = (cell.habitatQualityIndex * 100).toFixed(1);
  return (
    <div className="mt-4 pt-4 border-t border-[#E4E7E1] flex flex-col gap-3">
      <p className="text-[12px] font-medium text-[#1F2A1F]">Why is expected richness {cell.expectedRichness}?</p>
      <p className="text-[12px] text-[#667066] leading-relaxed">
        Expected richness is a habitat-based index, not a field survey. The pipeline estimates
        how many species a cell could support given its land-cover quality:
      </p>
      <div className="bg-[#F7F8F5] rounded-xl p-4 font-mono text-[12px] text-[#1F2A1F] leading-relaxed">
        expected = habitat quality ({cell.habitatQualityIndex.toFixed(3)}) × {cell.maxExpectedRichness}
        <br />
        = {cell.expectedRichness.toFixed(1)} species
      </div>
      <ul className="text-[12px] text-[#667066] leading-relaxed flex flex-col gap-2 list-disc pl-4">
        <li>
          Habitat quality ({hqPct}%) comes from satellite land cover (WorldCover tree/shrub/grass
          fractions and impervious surface).
        </li>
        <li>
          {cell.maxExpectedRichness} is the study-area upper bound for a fully vegetated cell
          (configured in the pipeline as MAX_EXPECTED_RICHNESS).
        </li>
        <li>
          This is a simple index for comparison across cells — not a calibrated species
          distribution model.
        </li>
      </ul>
      <p className="text-[12px] text-[#667066] leading-relaxed">
        Ecological residual = expected richness ({cell.expectedRichness.toFixed(1)}) −
        effort-corrected richness ({formatMetric(cell.observedRichness)}) =
        {formatMetric(cell.ecologicalResidual)}.
        {' '}Positive values mean fewer species are recorded than the habitat suggests.
      </p>
    </div>
  );
}

function ObservedRichnessExplainer({ cell }: { cell: CellData }) {
  return (
    <div className="mt-4 pt-4 border-t border-[#E4E7E1] flex flex-col gap-3">
      <p className="text-[12px] font-medium text-[#1F2A1F]">How observed richness is calculated</p>
      <div className="grid grid-cols-2 gap-3">
        <div className="bg-[#F7F8F5] rounded-xl p-4">
          <div className="text-[28px] font-semibold text-[#1F2A1F] leading-none">{cell.speciesRichnessRaw}</div>
          <div className="text-[11px] text-[#667066] mt-1.5">Raw distinct taxa</div>
        </div>
        <div className="bg-[#F7F8F5] rounded-xl p-4">
          <div className="text-[28px] font-semibold text-[#1F2A1F] leading-none">{cell.nSurveyDates}</div>
          <div className="text-[11px] text-[#667066] mt-1.5">Survey dates</div>
        </div>
      </div>
      <p className="text-[12px] text-[#667066] leading-relaxed">
        {cell.nObs} iNaturalist and GBIF records in this 20m hex ({cell.speciesRichnessRaw} distinct
        scientific names). The headline observed value ({formatMetric(cell.observedRichness)}) is
        effort-corrected: raw richness ÷ log(1 + accessible path km). Hexes with no accessible
        pedestrian path length are marked unsampled rather than treated as zero-richness cells.
      </p>
      <p className="text-[12px] text-[#667066] leading-relaxed">
        Taxonomic breakdown counts distinct taxa per group (plants, birds, insects, mammals,
        fungi) from iNaturalist iconic taxon and GBIF class fields.
      </p>
    </div>
  );
}

export default function CellDetailPanel({
  cell,
  activeLayer,
  onClose,
  onViewInsidePark,
}: CellDetailPanelProps) {
  const [tab, setTab] = useState<Tab>('overview');
  const isUnder = cell.impactScore < SCORE_THRESHOLDS.BADGE_UNDERPERFORMING;
  const speciesTotal = cell.species.reduce((s, sp) => s + sp.count, 0);
  const showResidualSummary = activeLayer === 'residual';

  return (
    <div className="w-[440px] flex-shrink-0 bg-[#F7F8F5] border-l border-[#E4E7E1] flex flex-col overflow-hidden">
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
            <h2 className="font-semibold text-[#1F2A1F] text-[18px] leading-tight">{cell.name}</h2>
            <p className="text-[13px] text-[#667066] mt-0.5">
              {cell.nameJa} · {CITY.name}
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

        <div className="flex items-center gap-2 mb-4">
          <span
            className={cn(
              'text-[11px] font-semibold px-3 py-1 rounded-full inline-block',
              isUnder
                ? 'bg-[#FDF0E4] text-[#C97A2A]'
                : 'bg-[#DDEAD8] text-[#2E6F40]',
            )}
          >
            {ecologicalStatus(cell.impactScore)}
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

        <div className="flex -mx-6 px-6 overflow-x-auto">
          {TABS.map((t) => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={cn(
                'text-[13px] py-2.5 px-3 -mb-px border-b-2 transition-colors font-medium whitespace-nowrap flex-shrink-0',
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

      <div className="flex-1 overflow-y-auto">
        {tab === 'overview' && (
          <div className="p-5 flex flex-col gap-4">
            {showResidualSummary ? (
              <Card>
                <CardTitle>Ecological residual</CardTitle>
                <CardSubtitle>Biodiversity-specific metric</CardSubtitle>
                <div className="grid grid-cols-2 gap-3 mb-4">
                  <div className="bg-[#F7F8F5] rounded-xl p-4">
                    <div className="text-[32px] font-semibold text-[#1F2A1F] leading-none">
                      {formatMetric(cell.ecologicalResidual)}
                    </div>
                    <div className="text-[11px] text-[#667066] mt-1.5">Residual</div>
                  </div>
                  <div className="bg-[#F7F8F5] rounded-xl p-4">
                    <div className="text-[32px] font-semibold text-[#1F2A1F] leading-none">
                      {cell.nSurveyDates}
                    </div>
                    <div className="text-[11px] text-[#667066] mt-1.5">Survey visits</div>
                  </div>
                </div>
                <p className="text-[12px] text-[#667066] leading-relaxed">
                  Ecological residual is corrected richness minus expected richness. Positive
                  values indicate more species than expected; negative values indicate fewer.
                </p>
                <div className="mt-4 grid grid-cols-2 gap-3">
                  <div className="bg-[#F7F8F5] rounded-xl p-3">
                    <div className="text-[18px] font-semibold text-[#1F2A1F]">{cell.expectedRichness.toFixed(1)}</div>
                    <div className="text-[10px] text-[#667066]">Expected richness</div>
                  </div>
                  <div className="bg-[#F7F8F5] rounded-xl p-3">
                    <div className="text-[18px] font-semibold text-[#1F2A1F]">{formatMetric(cell.effortCorrectedRichness ?? cell.observedRichness)}</div>
                    <div className="text-[10px] text-[#667066]">Corrected richness</div>
                  </div>
                </div>
              </Card>
            ) : (
              <Card>
                <CardTitle>Nature Gap</CardTitle>
                <CardSubtitle>Composite ecological condition</CardSubtitle>
                <div className="flex items-center gap-5">
                  <ScoreGauge score={cell.impactScore} />
                  <div className="flex-1">
                    <p className="text-[12px] text-[#667066] leading-relaxed">
                      Nature Gap combines biodiversity residual, habitat quality, and corridor
                      connectivity into the public headline score.
                    </p>
                    <div className="mt-4 grid grid-cols-2 gap-2">
                      <div className="bg-[#F7F8F5] rounded-xl p-3">
                        <div className="text-[16px] font-semibold text-[#1F2A1F]">{cell.expectedRichness.toFixed(0)}</div>
                        <div className="text-[10px] text-[#667066]">Expected richness</div>
                      </div>
                      <div className="bg-[#F7F8F5] rounded-xl p-3">
                        <div className="text-[16px] font-semibold text-[#1F2A1F]">{formatMetric(cell.observedRichness)}</div>
                        <div className="text-[10px] text-[#667066]">Observed richness</div>
                      </div>
                    </div>
                    <div className="mt-3 text-[11px] text-[#667066]">
                      Intervention priority {cell.interventionRank ?? 'unranked'}
                    </div>
                  </div>
                </div>
                <div className="mt-4 flex gap-2">
                  <button
                    type="button"
                    onClick={() => setTab('actions')}
                    className="flex-1 rounded-lg bg-[#2E6F40] px-3 py-2 text-[12px] font-semibold text-white"
                  >
                    See what you can do here
                  </button>
                  <button
                    type="button"
                    onClick={onViewInsidePark}
                    className="flex-1 rounded-lg border border-[#D1D8CE] px-3 py-2 text-[12px] font-semibold text-[#1F2A1F]"
                  >
                    View inside this park
                  </button>
                </div>
              </Card>
            )}

            <Card>
              <CardTitle>Biodiversity</CardTitle>
              <CardSubtitle>Observed vs expected (effort-corrected index)</CardSubtitle>
              <div className="grid grid-cols-2 gap-3 mb-4">
                <div className="bg-[#F7F8F5] rounded-xl p-4">
                  <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">
                    {formatMetric(cell.observedRichness)}
                  </div>
                  <div className="text-[11px] text-[#667066] mt-1.5">Observed (corrected)</div>
                  <div className="text-[10px] text-[#A8B4A8] mt-1">{cell.speciesRichnessRaw} raw taxa</div>
                </div>
                <div className="bg-[#F7F8F5] rounded-xl p-4">
                  <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">
                    {cell.expectedRichness.toFixed(0)}
                  </div>
                  <div className="text-[11px] text-[#667066] mt-1.5">Expected (habitat index)</div>
                  <div className="text-[10px] text-[#A8B4A8] mt-1">HQ {cell.habitatQuality}%</div>
                </div>
              </div>

              {speciesTotal > 0 && (
                <div className="flex gap-4 pt-4 border-t border-[#E4E7E1]">
                  {cell.species.filter((s) => s.count > 0).map((s) => (
                    <div key={s.type} className="flex flex-col items-center gap-0.5">
                      <span className="text-[14px] font-semibold text-[#1F2A1F]">{s.count}</span>
                      <span className="text-[9px] text-[#667066] uppercase tracking-wide">{SPECIES_LABELS[s.type]}</span>
                    </div>
                  ))}
                </div>
              )}
            </Card>

            <Card>
              <CardTitle>Habitat metrics</CardTitle>
              <CardSubtitle>From pipeline land cover and connectivity</CardSubtitle>
              <div className="flex flex-col gap-4">
                {[
                  { label: 'Habitat quality', value: cell.habitatQuality, inverted: false },
                  { label: 'Corridor importance', value: cell.corridorImportance, inverted: false },
                  { label: 'Fragmentation index', value: cell.fragmentationIndex, inverted: true },
                ].map(({ label, value, inverted }) => (
                  <div key={label}>
                    <div className="flex items-center justify-between mb-2">
                      <span className="text-[13px] text-[#667066]">{label}</span>
                      <span className="text-[13px] font-semibold text-[#1F2A1F]">{value}</span>
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

            {cell.interventions.length > 0 && (
              <Card>
                <div className="flex items-start justify-between mb-1">
                  <div>
                    <CardTitle>Recommended actions</CardTitle>
                    <CardSubtitle>From pipeline intervention ranking</CardSubtitle>
                  </div>
                  <button
                    onClick={() => setTab('actions')}
                    className="text-[12px] text-[#2E6F40] font-medium hover:underline mt-0.5 flex-shrink-0"
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

        {tab === 'biodiversity' && (
          <div className="p-5 flex flex-col gap-4">
            <Card>
              <CardTitle>Observed richness</CardTitle>
              <CardSubtitle>From iNaturalist + GBIF records in this cell</CardSubtitle>
              <div className="grid grid-cols-2 gap-3 mb-2">
                <div className="bg-[#F7F8F5] rounded-xl p-4">
                  <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">
                    {formatMetric(cell.observedRichness)}
                  </div>
                  <div className="text-[11px] text-[#667066] mt-1.5">Effort-corrected index</div>
                </div>
                <div className="bg-[#F7F8F5] rounded-xl p-4">
                  <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">{cell.nObs}</div>
                  <div className="text-[11px] text-[#667066] mt-1.5">Total records</div>
                </div>
              </div>
              <ObservedRichnessExplainer cell={cell} />
            </Card>

            <Card>
              <CardTitle>Expected richness</CardTitle>
              <CardSubtitle>Habitat-based benchmark (index)</CardSubtitle>
              <div className="bg-[#F7F8F5] rounded-xl p-4 mb-2">
                <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">
                  {cell.expectedRichness.toFixed(1)}
                </div>
                <div className="text-[11px] text-[#667066] mt-1.5">
                  At habitat quality {cell.habitatQualityIndex.toFixed(3)} × max {MAX_EXPECTED_RICHNESS}
                </div>
              </div>
              <ExpectedRichnessExplainer cell={cell} />
            </Card>

            {speciesTotal > 0 && (
              <Card>
                <CardTitle>Taxonomic breakdown</CardTitle>
                <CardSubtitle>{speciesTotal} distinct taxa by group</CardSubtitle>
                <div className="flex flex-col gap-3 mb-5">
                  {cell.species.map((s) => (
                    <div key={s.type} className="flex items-center gap-3">
                      <div className="w-20 text-[12px] text-[#667066]">{SPECIES_LABELS[s.type]}</div>
                      <div className="flex-1 h-1.5 bg-[#E4E7E1] rounded-full overflow-hidden">
                        <div
                          className="h-full rounded-full transition-all"
                          style={{
                            width: `${(s.count / Math.max(speciesTotal, 1)) * 100}%`,
                            backgroundColor: '#73A56D',
                          }}
                        />
                      </div>
                      <div className="w-7 text-[12px] font-semibold text-[#1F2A1F] text-right">{s.count}</div>
                    </div>
                  ))}
                </div>
                <SpeciesGroupList species={cell.species} />
              </Card>
            )}

            <Card>
              <CardTitle>Diversity indices</CardTitle>
              <CardSubtitle>From pipeline observation layer</CardSubtitle>
              <div className="grid grid-cols-2 gap-3">
                <div className="bg-[#F7F8F5] rounded-xl p-4">
                  <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">
                    {cell.taxonomicDiversity.toFixed(1)}
                  </div>
                  <div className="text-[11px] text-[#667066] mt-1.5">Shannon diversity</div>
                </div>
                <div className="bg-[#F7F8F5] rounded-xl p-4">
                  <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">
                    {cell.observerEffortScore.toFixed(1)}
                  </div>
                  <div className="text-[11px] text-[#667066] mt-1.5">Records / km path</div>
                </div>
              </div>
            </Card>
          </div>
        )}

        {tab === 'habitat' && (
          <div className="p-5 flex flex-col gap-4">
            <Card>
              <CardTitle>Habitat metrics</CardTitle>
              <CardSubtitle>Land cover and connectivity from pipeline</CardSubtitle>
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
                      <p className="text-[10px] text-[#A8B4A8] mt-1.5">
                        Higher fragmentation → more isolated patches
                      </p>
                    )}
                  </div>
                ))}
              </div>
            </Card>
          </div>
        )}

        {tab === 'actions' && (
          <div className="p-5">
            <p className="text-[18px] font-semibold text-[#1F2A1F] mb-1">Recommended actions</p>
            <p className="text-[12px] text-[#667066] mb-4">Ranked by pipeline composite intervention score</p>
            <Card className="!p-0 !overflow-hidden">
              {cell.interventions.map((iv) => (
                <InterventionCard key={iv.id} intervention={iv} />
              ))}
              {cell.interventions.length === 0 && (
                <p className="text-[13px] text-[#667066] leading-relaxed p-6">
                  No ranked interventions are available for this area. Actions are assigned only
                  to cells in the pipeline&apos;s top intervention list.
                </p>
              )}
            </Card>
          </div>
        )}
      </div>
    </div>
  );
}
