import { TreePine, Zap, Flower2, Droplets, Leaf } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { Intervention } from '@/lib/types';

const CATEGORY_ICONS = {
  canopy: TreePine,
  corridor: Zap,
  pollinator: Flower2,
  water: Droplets,
  ground: Leaf,
};

const IMPACT_STYLES: Record<string, string> = {
  high: 'text-[#3d6b2f] bg-[#3d6b2f]/8',
  medium: 'text-amber-700 bg-amber-50',
  low: 'text-neutral-500 bg-neutral-100',
};

interface InterventionCardProps {
  intervention: Intervention;
}

export default function InterventionCard({ intervention }: InterventionCardProps) {
  const Icon = CATEGORY_ICONS[intervention.category];

  return (
    <div className="flex gap-3 py-3 border-b border-[#e4e7e3] last:border-0">
      <div className="flex-shrink-0 w-7 h-7 bg-[#f7f8f6] rounded-md flex items-center justify-center mt-0.5">
        <Icon size={13} className="text-neutral-400" />
      </div>

      <div className="flex-1 min-w-0">
        <div className="flex items-start gap-2 justify-between">
          <span className="text-sm font-medium text-neutral-800 leading-snug">{intervention.title}</span>
          <span
            className={cn(
              'text-[10px] font-semibold px-2 py-0.5 rounded-full flex-shrink-0 capitalize',
              IMPACT_STYLES[intervention.impact],
            )}
          >
            {intervention.impact}
          </span>
        </div>
        <p className="text-[11px] text-neutral-400 mt-0.5 leading-relaxed">{intervention.description}</p>
        {intervention.connectivityGain && (
          <div className="mt-1.5 text-[10px] font-semibold text-sky-700 bg-sky-50 px-2 py-0.5 rounded-full inline-block">
            +{intervention.connectivityGain}% network connectivity
          </div>
        )}
      </div>
    </div>
  );
}
