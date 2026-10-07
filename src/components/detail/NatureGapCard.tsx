'use client';

import { cn } from '@/lib/utils';
import type { CellData } from '@/lib/types';
import {
  OPPORTUNITY_GROUP_NAMES,
  OPPORTUNITY_GROUP_ORDER,
  OPPORTUNITY_LABEL_TEXT,
  formatSpeciesChange,
  opportunityBand,
  type CellOpportunityGroup,
  type OpportunityGapInfo,
  type OpportunityGroupLabel,
} from '@/lib/opportunity-gap';

const LABEL_CLASS: Record<OpportunityGroupLabel, string> = {
  checked: 'bg-[#DDEAD8] text-[#2E6F40]',
  mismatch: 'bg-[#FDF0E4] text-[#9B6A1A]',
  insufficient: 'bg-[#F0F0EE] text-[#667066]',
};

/** The panel header's badge for a place's Room to grow (opportunity gap). */
export function opportunityHeadline(gap: number | null | undefined): { text: string; className: string } {
  switch (opportunityBand(gap)) {
    case 'gain':
      return { text: `${formatSpeciesChange(gap as number)} native species possible`, className: 'bg-[#EEE7F4] text-[#440154]' };
    case 'loss':
      return { text: 'Richer than greener places like it', className: 'bg-[#FCF6CC] text-[#5C5300]' };
    case 'same':
      return { text: 'No clear gain', className: 'bg-[#F0F0EE] text-[#667066]' };
    default:
      return { text: 'Room to grow not computed', className: 'bg-[#F0F0EE] text-[#667066]' };
  }
}

function explanation(gap: number | null, cityName: string, speciesCounted: number | null): string {
  const counted = speciesCounted ? ` of the city's ${speciesCounted} commonly recorded native species` : '';
  switch (opportunityBand(gap)) {
    case 'gain':
      return `Places in ${cityName} like this one — same land use, similar water, traffic, noise and light — but among the greener quarter are expected to hold ${formatSpeciesChange(gap as number).slice(1)} more${counted}.`;
    case 'loss':
      return `Greener places like this one are expected to hold ${formatSpeciesChange(gap as number).slice(1)} fewer of the species expected here. Places like this are often open, rough or wet ground, whose species would lose out to trees.`;
    case 'same':
      return gap === 0
        ? `Already among the greener quarter of places like it in ${cityName}, so there is nothing greener to compare with.`
        : `Greener places like this one are expected to hold about as many of these species.`;
    default:
      return `There are too few greener places of this kind in ${cityName} to compare with.`;
  }
}

function GroupRow({ group, label }: { group: CellOpportunityGroup; label: OpportunityGroupLabel | null }) {
  return (
    <div className="py-3 border-t border-[#E4E7E1] first:border-t-0 first:pt-0">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="text-[12px] font-medium text-[#1F2A1F]">{OPPORTUNITY_GROUP_NAMES[group.group]}</div>
          {label && (
            <span className={cn('mt-1 inline-block text-[10px] font-semibold px-2 py-0.5 rounded-full', LABEL_CLASS[label])}>
              {OPPORTUNITY_LABEL_TEXT[label]}
            </span>
          )}
        </div>
        <div className="text-right flex-shrink-0">
          <div className="text-[13px] font-semibold text-[#1F2A1F]">
            {group.gap != null ? formatSpeciesChange(group.gap) : '—'}
          </div>
          <div className="text-[10px] text-[#A8B4A8]">
            {group.expected != null ? `${group.expected.toFixed(1)} expected` : ''}
          </div>
        </div>
      </div>
      {group.top.length > 0 && (
        <p className="text-[11px] text-[#667066] mt-1.5 leading-snug">
          Would gain most: <span className="italic">{group.top.join(', ')}</span>
        </p>
      )}
    </div>
  );
}

interface NatureGapCardProps {
  cell: CellData;
  info: OpportunityGapInfo | null;
  cityName: string;
  /** A park's figures are means over its cells and carry no groups. */
  isPark: boolean;
  detailLoading: boolean;
  onSeeActions: () => void;
  onViewInsidePark?: () => void;
}

export default function NatureGapCard({
  cell,
  info,
  cityName,
  isPark,
  detailLoading,
  onSeeActions,
  onViewInsidePark,
}: NatureGapCardProps) {
  const opportunity = cell.opportunity;
  if (!opportunity) return null;
  const { expected, gap, gapChecked, groups, rare } = opportunity;
  const band = opportunityBand(gap);
  const anyChecked = Object.values(info?.groups ?? {}).some((group) => group?.label === 'checked');
  const orderedGroups = OPPORTUNITY_GROUP_ORDER
    .map((id) => groups.find((group) => group.group === id))
    .filter((group): group is CellOpportunityGroup => Boolean(group));

  return (
    <div
      className="bg-white rounded-2xl border border-[#E4E7E1] p-6"
      style={{ boxShadow: '0 1px 2px rgba(0,0,0,0.03)' }}
    >
      <h3 className="text-[15px] font-semibold text-[#1F2A1F] mb-1">Room to grow</h3>
      <p className="text-[11px] text-[#667066] uppercase tracking-widest mb-4">
        Compared with greener places like it
      </p>

      <div className="grid grid-cols-2 gap-3 mb-3">
        <div className="bg-[#F7F8F5] rounded-xl p-4">
          <div className="text-[32px] font-semibold text-[#1F2A1F] leading-none">
            {expected != null ? expected.toFixed(0) : '—'}
          </div>
          <div className="text-[11px] text-[#667066] mt-1.5">Native species expected here</div>
        </div>
        <div className={cn('rounded-xl p-4', band === 'loss' ? 'bg-[#FCF6CC]' : band === 'gain' ? 'bg-[#EEE7F4]' : 'bg-[#F7F8F5]')}>
          <div className={cn(
            'text-[32px] font-semibold leading-none',
            band === 'loss' ? 'text-[#5C5300]' : band === 'gain' ? 'text-[#440154]' : 'text-[#1F2A1F]',
          )}>
            {gap != null ? formatSpeciesChange(gap) : '—'}
          </div>
          <div className="text-[11px] text-[#667066] mt-1.5">In greener places like it</div>
        </div>
      </div>

      <p className="text-[12px] text-[#667066] leading-relaxed">
        {explanation(gap, cityName, info?.speciesCounted ?? null)}
        {isPark && ' Averages over this park’s cells.'}
      </p>
      {(band === 'gain' || band === 'loss') && gapChecked != null && anyChecked && (
        <p className="text-[12px] text-[#667066] leading-relaxed mt-2">
          Of that, {formatSpeciesChange(gapChecked)} is in species groups whose predictions matched {cityName}&apos;s records.
        </p>
      )}

      {orderedGroups.length > 0 && (
        <div className="mt-4 pt-4 border-t border-[#E4E7E1]">
          <p className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest mb-3">By species group</p>
          {orderedGroups.map((group) => (
            <GroupRow
              key={group.group}
              group={group}
              label={group.label ?? info?.groups[group.group]?.label ?? null}
            />
          ))}
        </div>
      )}
      {orderedGroups.length === 0 && !isPark && detailLoading && (
        <p className="text-[11px] text-[#A8B4A8] mt-3">Loading species groups…</p>
      )}

      {rare && rare.count > 0 && (
        <div className="mt-4 pt-4 border-t border-[#E4E7E1]">
          <p className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest mb-2">
            Rare species recorded within 125 m · {rare.count}
          </p>
          <p className="text-[12px] text-[#1F2A1F] leading-relaxed italic">
            {rare.species.join(', ')}{rare.count > rare.species.length ? ', …' : ''}
          </p>
          <p className="text-[11px] text-[#A8B4A8] mt-1.5 leading-snug">
            Too rarely recorded to model, so listed as found, rarest first — not predicted.
          </p>
        </div>
      )}

      <p className="text-[11px] text-[#A8B4A8] mt-4 leading-snug">
        Expected species are summed chances of occurring, not a count. Every species group counts;
        each is labelled by how well its predictions matched what people recorded in {cityName}.
      </p>

      <div className="mt-4 flex gap-2">
        <button
          type="button"
          onClick={onSeeActions}
          className="flex-1 rounded-lg bg-[#2E6F40] px-3 py-2 text-[12px] font-semibold text-white"
        >
          See what you can do here
        </button>
        {onViewInsidePark && (
          <button
            type="button"
            onClick={onViewInsidePark}
            className="flex-1 rounded-lg border border-[#D1D8CE] px-3 py-2 text-[12px] font-semibold text-[#1F2A1F]"
          >
            View inside this park
          </button>
        )}
      </div>
    </div>
  );
}
