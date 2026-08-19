'use client';

import { useState } from 'react';
import { X, ArrowLeft, Calendar, MapPin, Users, TreePine, Flower2, Leaf, Zap, type LucideIcon } from 'lucide-react';
import { cn } from '@/lib/utils';
import { cityMeta } from '@/lib/config';
import type { CellData } from '@/lib/types';
import type { HexLayerId } from '@/lib/layer-styles';
import type { CommunityEvent, TakeAction } from '@/lib/data';
import ScoreGauge from './ScoreGauge';
import InterventionCard from './InterventionCard';

type Tab = 'overview' | 'biodiversity' | 'habitat' | 'actions' | 'community';

const TABS: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'biodiversity', label: 'Biodiversity' },
  { id: 'habitat', label: 'Habitat' },
  { id: 'actions', label: 'Actions' },
  { id: 'community', label: 'Community' },
];

const EVENT_TYPE_COLOR: Record<string, string> = {
  'Guided walk':     'text-[#2E6F40] bg-[#DDEAD8]',
  'Citizen science': 'text-[#3A6A8A] bg-[#E3EDF5]',
  'Restoration':     'text-[#9B6A1A] bg-[#FDF0DC]',
  'Event':           'text-[#667066] bg-[#F0F2EE]',
};

const ACTION_ICON_MAP: Record<string, LucideIcon> = {
  Flower2,
  TreePine,
  Leaf,
  Zap,
};

const ACTION_IMPACT_COLOR: Record<string, string> = {
  'High impact':             'text-[#2E6F40] bg-[#DDEAD8]',
  'High impact (long-term)': 'text-[#2E6F40] bg-[#DDEAD8]',
  'Medium impact':           'text-[#9B6A1A] bg-[#FDF0DC]',
};

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
  /** True while species, interventions, and other Storage-backed fields are loading. */
  detailLoading?: boolean;
  /** Community events — unfiltered, same list regardless of which park/cell is selected. */
  events?: CommunityEvent[];
  /** Generic conservation actions — unfiltered, same list regardless of which park/cell is selected. */
  actions?: TakeAction[];
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

function SpeciesGroupList({
  species,
  coordinates,
}: {
  species: CellData['species'];
  coordinates: [number, number];
}) {
  const groups = species.filter((s) => s.count > 0);
  if (groups.length === 0) return null;

  const [lng, lat] = coordinates;
  const inatUrl = `https://www.inaturalist.org/observations?lat=${lat}&lng=${lng}&radius=0.15`;

  return (
    <div className="flex flex-col gap-4">
      {groups.map((s) => (
        <div key={s.type} className="flex items-baseline justify-between">
          <span className="text-[12px] font-medium text-[#1F2A1F]">
            {SPECIES_LABELS[s.type]}
          </span>
          <span className="text-[11px] text-[#667066]">
            {s.count} {s.count === 1 ? 'species' : 'species'}
          </span>
        </div>
      ))}
      <a
        href={inatUrl}
        target="_blank"
        rel="noopener noreferrer"
        className="text-[12px] text-[#2E6F40] underline underline-offset-2 hover:text-[#1F2A1F] mt-1"
      >
        See individual sightings on iNaturalist →
      </a>
    </div>
  );
}

function ecologicalStatus(score: number): string {
  if (score > 5) return 'Under pressure';
  if (score < -15) return 'Potential refuge';
  return 'Performing as expected';
}

const UNSAMPLED_MESSAGE = 'Not enough observation data yet';

function hasRawObservations(cell: CellData): boolean {
  return cell.nObs > 0
    || cell.speciesRichnessRaw > 0
    || cell.species.some((species) => species.count > 0);
}

/**
 * An unsampled cell has two distinct causes: no records at all, or records that
 * cannot be effort-corrected because the hex has too little accessible OSM
 * pedestrian path (is_unsampled is set from path_local_m < MIN_PATH_M, not from
 * observation count).
 * Naming the wrong one contradicts the Biodiversity tab, which reports records.
 */
function unsampledDetail(cell: CellData, noRecords: string, noPath: string): string {
  return hasRawObservations(cell) ? noPath : noRecords;
}

/**
 * Distinct "no data" state for observation-dependent metrics (Nature Gap,
 * Ecological Residual, Observed Biodiversity, Intervention Priority) so an
 * unsampled cell never reads as a genuinely neutral score.
 */
function UnsampledNotice({ detail }: { detail?: string }) {
  return (
    <div className="bg-[#F0F0EE] rounded-xl p-4 border border-dashed border-[#D1D8CE]">
      <p className="text-[12px] font-semibold text-[#667066]">{UNSAMPLED_MESSAGE}</p>
      {detail && (
        <p className="text-[11px] text-[#A8B4A8] mt-1 leading-relaxed">{detail}</p>
      )}
    </div>
  );
}

function NoHexObservationsNotice() {
  return (
    <div className="bg-[#F7F8F5] rounded-xl p-4 border border-[#E4E7E1]">
      <p className="text-[12px] font-semibold text-[#667066]">No observations in this hex</p>
      <p className="text-[11px] text-[#A8B4A8] mt-1 leading-relaxed">
        This 20m cell has no recorded species yet. Shaded neighbouring hexes may have observations.
      </p>
    </div>
  );
}

function ExpectedRichnessExplainer({ cell }: { cell: CellData }) {
  const hqPct = (cell.habitatQualityIndex * 100).toFixed(1);
  return (
    <div className="mt-4 pt-4 border-t border-[#E4E7E1] flex flex-col gap-3">
      <p className="text-[12px] font-medium text-[#1F2A1F]">
        Why is expected richness {formatMetric(cell.expectedRichness, 2)}?
      </p>
      <p className="text-[12px] text-[#667066] leading-relaxed">
        Expected richness is what this city&apos;s fitted model predicts for the same quantity that
        was actually measured here — effort-corrected richness — given the cell&apos;s habitat,
        corridor importance, and path accessibility. It is not a field survey and not a species
        count:
      </p>
      <div className="bg-[#F7F8F5] rounded-xl p-4 font-mono text-[12px] text-[#1F2A1F] leading-relaxed">
        expected = fitted(effort-corrected richness ~ habitat + corridor + access)
        <br />
        = {formatMetric(cell.expectedRichness, 2)} species per effort unit
      </div>
      <ul className="text-[12px] text-[#667066] leading-relaxed flex flex-col gap-2 list-disc pl-4">
        <li>
          Habitat quality ({hqPct}%) comes from satellite land cover (WorldCover tree/shrub/grass
          fractions and impervious surface).
        </li>
        <li>
          The model is fitted on this city&apos;s sampled cells only, so expected richness is a
          within-city benchmark and is not comparable between cities.
        </li>
        <li>
          Because the fit is in-sample, the residual below is centred on zero by construction. It
          measures shortfall the habitat model could not explain — not absolute ecological deficit.
        </li>
      </ul>
      <p className="text-[12px] text-[#667066] leading-relaxed">
        Ecological residual = expected richness ({formatMetric(cell.expectedRichness, 2)}) −
        effort-corrected richness ({formatMetric(cell.observedRichness, 2)}) =
        {' '}{formatMetric(cell.ecologicalResidual, 2)}.
        {' '}Positive values mean fewer species are recorded than the model predicts.
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
  detailLoading = false,
  events = [],
  actions = [],
  onClose,
  onViewInsidePark,
}: CellDetailPanelProps) {
  const [tab, setTab] = useState<Tab>('overview');
  const isUnder = cell.impactScore > 5;
  const speciesTotal = cell.species.reduce((s, sp) => s + sp.count, 0);
  const showResidualSummary = activeLayer === 'residual';

  return (
    <div className="h-full bg-[#F7F8F5] flex flex-col overflow-hidden">
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
              {cell.nameJa} · {cityMeta(cell.cityId).name}
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
              cell.isUnsampled
                ? 'bg-[#F0F0EE] text-[#667066]'
                : isUnder
                  ? 'bg-[#FDF0E4] text-[#C97A2A]'
                  : 'bg-[#DDEAD8] text-[#2E6F40]',
            )}
          >
            {cell.isUnsampled ? 'Not enough data yet' : ecologicalStatus(cell.impactScore)}
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

      {detailLoading && (
        <div className="px-6 py-2 bg-[#FDF6E4] border-b border-[#F0E4C8] text-[12px] text-[#9B6A1A] flex-shrink-0">
          Loading species and actions…
        </div>
      )}

      <div className="flex-1 overflow-y-auto">
        {tab === 'overview' && (
          <div className="p-5 flex flex-col gap-4">
            {showResidualSummary ? (
              <Card>
                <CardTitle>Ecological residual</CardTitle>
                <CardSubtitle>Biodiversity-specific metric</CardSubtitle>
                {cell.isUnsampled ? (
                  <UnsampledNotice
                    detail={unsampledDetail(
                      cell,
                      "Ecological residual compares observed to expected richness — it can't be computed until this cell has recorded observations.",
                      "Ecological residual compares observed to expected richness — records exist here, but this hex has under 50m of OSM pedestrian path within 40m, so corrected richness and the residual can't be computed.",
                    )}
                  />
                ) : (
                  <>
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
                      Ecological residual is expected richness minus corrected richness. Positive
                      values indicate fewer species than expected; negative values indicate more.
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
                  </>
                )}
              </Card>
            ) : (
              <Card>
                <CardTitle>Nature Gap</CardTitle>
                <CardSubtitle>Composite ecological condition</CardSubtitle>
                {cell.isUnsampled ? (
                  <UnsampledNotice
                    detail={unsampledDetail(
                      cell,
                      'Nature Gap combines biodiversity residual, habitat quality, and corridor connectivity — the biodiversity component needs recorded observations first.',
                      'Nature Gap combines biodiversity residual, habitat quality, and corridor connectivity — records exist here, but this hex has under 50m of OSM pedestrian path within 40m, so the biodiversity component cannot be effort-corrected.',
                    )}
                  />
                ) : (
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
                )}
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
                <div className={cn('rounded-xl p-4', cell.isUnsampled ? 'bg-[#F0F0EE]' : 'bg-[#F7F8F5]')}>
                  <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">
                    {cell.isUnsampled ? '—' : formatMetric(cell.observedRichness)}
                  </div>
                  <div className="text-[11px] text-[#667066] mt-1.5">Observed (corrected)</div>
                  <div className="text-[10px] text-[#A8B4A8] mt-1">
                    {cell.isUnsampled
                      ? (hasRawObservations(cell)
                        ? `${cell.speciesRichnessRaw} raw taxa · ${cell.nObs} records (unsampled)`
                        : UNSAMPLED_MESSAGE)
                      : `${cell.speciesRichnessRaw} raw taxa`}
                  </div>
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
              {cell.isUnsampled && !hasRawObservations(cell) ? (
                <UnsampledNotice detail="Under 50m of pedestrian path within 40m, and no recorded observations yet — this cell is marked unsampled rather than zero-richness." />
              ) : !hasRawObservations(cell) ? (
                <NoHexObservationsNotice />
              ) : (
                <>
                  {cell.isUnsampled && (
                    <UnsampledNotice detail="Records exist here, but this hex has under 50m of OSM pedestrian path within 40m — effort-corrected richness is unavailable and the cell is excluded from residual inference." />
                  )}
                  <div className="grid grid-cols-2 gap-3 mb-2">
                    <div className={cn('rounded-xl p-4', cell.isUnsampled ? 'bg-[#F0F0EE]' : 'bg-[#F7F8F5]')}>
                      <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">
                        {cell.isUnsampled ? '—' : formatMetric(cell.observedRichness)}
                      </div>
                      <div className="text-[11px] text-[#667066] mt-1.5">Effort-corrected index</div>
                    </div>
                    <div className="bg-[#F7F8F5] rounded-xl p-4">
                      <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">{cell.nObs}</div>
                      <div className="text-[11px] text-[#667066] mt-1.5">Total records</div>
                    </div>
                  </div>
                  {!cell.isUnsampled && <ObservedRichnessExplainer cell={cell} />}
                </>
              )}
            </Card>

            <Card>
              <CardTitle>Expected richness</CardTitle>
              <CardSubtitle>Fitted benchmark (per effort unit)</CardSubtitle>
              <div className="bg-[#F7F8F5] rounded-xl p-4 mb-2">
                <div className="text-[36px] font-semibold text-[#1F2A1F] leading-none">
                  {formatMetric(cell.expectedRichness, 2)}
                </div>
                <div className="text-[11px] text-[#667066] mt-1.5">
                  Fitted from habitat {cell.habitatQualityIndex.toFixed(3)}, corridor, and access
                </div>
              </div>
              <ExpectedRichnessExplainer cell={cell} />
            </Card>

            {speciesTotal > 0 && (
              <Card>
                <CardTitle>Taxonomic breakdown</CardTitle>
                <CardSubtitle>{speciesTotal} distinct taxa by group</CardSubtitle>
                <div className="flex flex-col gap-3 mb-5">
                  {cell.species.filter((s) => s.count > 0).map((s) => (
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
                <SpeciesGroupList species={cell.species} coordinates={cell.coordinates} />
              </Card>
            )}

            <Card>
              <CardTitle>Diversity indices</CardTitle>
              <CardSubtitle>From pipeline observation layer</CardSubtitle>
              {cell.isUnsampled ? (
                <UnsampledNotice />
              ) : (
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
              )}
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
          <div className="p-5 flex flex-col gap-6">
            <div>
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

            <div>
              <p className="text-[18px] font-semibold text-[#1F2A1F] mb-1">Ways to help</p>
              <p className="text-[12px] text-[#667066] mb-4">
                Ranked by ecological impact — the same list everywhere on the map.
              </p>
              <div className="flex flex-col gap-3">
                {actions.length === 0 && (
                  <p className="text-[13px] text-[#667066] leading-relaxed">
                    No recommended actions are loaded yet. Configure Supabase or run the pipeline export.
                  </p>
                )}
                {actions.map(({ id, icon, title, description, impact, time }) => {
                  const Icon = ACTION_ICON_MAP[icon] ?? Leaf;
                  return (
                    <Card key={id}>
                      <div className="flex items-start gap-4">
                        <div className="w-9 h-9 bg-[#F7F8F5] rounded-xl flex items-center justify-center flex-shrink-0">
                          <Icon size={16} className="text-[#2E6F40]" strokeWidth={1.5} />
                        </div>
                        <div className="flex-1 min-w-0">
                          <div className="flex items-center gap-2 mb-1.5 flex-wrap">
                            <h4 className="text-[13px] font-semibold text-[#1F2A1F]">{title}</h4>
                            <span
                              className={cn(
                                'text-[10px] font-semibold px-2.5 py-0.5 rounded-full',
                                ACTION_IMPACT_COLOR[impact] ?? 'text-[#667066] bg-[#F0F2EE]',
                              )}
                            >
                              {impact}
                            </span>
                          </div>
                          <p className="text-[12px] text-[#667066] leading-relaxed mb-2">{description}</p>
                          <span className="text-[11px] text-[#A8B4A8]">{time}</span>
                        </div>
                      </div>
                    </Card>
                  );
                })}
              </div>
            </div>
          </div>
        )}

        {tab === 'community' && (
          <div className="p-5">
            <p className="text-[18px] font-semibold text-[#1F2A1F] mb-1">Community</p>
            <p className="text-[12px] text-[#667066] mb-4">
              Local events and citizen science opportunities — the same list everywhere on the map.
            </p>
            <div className="flex flex-col gap-3">
              {events.length === 0 && (
                <p className="text-[13px] text-[#667066] leading-relaxed">
                  No community events are scheduled yet. Check back soon.
                </p>
              )}
              {events.map(({ id, title, date, location, attendees, type }) => (
                <Card key={id}>
                  <div className="flex items-start justify-between gap-3 mb-3">
                    <h4 className="text-[13px] font-semibold text-[#1F2A1F] leading-snug">{title}</h4>
                    <span
                      className={cn(
                        'text-[10px] font-semibold px-2.5 py-0.5 rounded-full flex-shrink-0',
                        EVENT_TYPE_COLOR[type] ?? 'text-[#667066] bg-[#F0F2EE]',
                      )}
                    >
                      {type}
                    </span>
                  </div>
                  <div className="flex flex-col gap-1">
                    <div className="flex items-center gap-2 text-[12px] text-[#667066]">
                      <Calendar size={11} className="text-[#A8B4A8]" />
                      {date}
                    </div>
                    <div className="flex items-center gap-2 text-[12px] text-[#667066]">
                      <MapPin size={11} className="text-[#A8B4A8]" />
                      {location}
                    </div>
                    <div className="flex items-center gap-2 text-[12px] text-[#667066]">
                      <Users size={11} className="text-[#A8B4A8]" />
                      {attendees} registered
                    </div>
                  </div>
                </Card>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}