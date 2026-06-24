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
  high:   'text-[#2E6F40] bg-[#DDEAD8]',
  medium: 'text-[#9B6A1A] bg-[#FDF0DC]',
  low:    'text-[#667066] bg-[#F0F2EE]',
};

interface InterventionCardProps {
  intervention: Intervention;
}

export default function InterventionCard({ intervention }: InterventionCardProps) {
  const Icon = CATEGORY_ICONS[intervention.category];

  return (
    <div className="flex gap-3 py-3.5 border-b border-[#E4E7E1] last:border-0 px-1">
      <div className="flex-shrink-0 w-7 h-7 bg-[#F7F8F5] rounded-lg flex items-center justify-center mt-0.5">
        <Icon size={13} className="text-[#667066]" strokeWidth={1.5} />
      </div>

      <div className="flex-1 min-w-0">
        <div className="flex items-start gap-2 justify-between mb-0.5">
          <span className="text-[13px] font-medium text-[#1F2A1F] leading-snug">{intervention.title}</span>
          <span
            className={cn(
              'text-[10px] font-semibold px-2 py-0.5 rounded-full flex-shrink-0 capitalize',
              IMPACT_STYLES[intervention.impact],
            )}
          >
            {intervention.impact}
          </span>
        </div>
        <p className="text-[11px] text-[#667066] leading-relaxed">{intervention.description}</p>
        {intervention.connectivityGain && (
          <div className="mt-1.5 text-[10px] font-semibold text-[#3A6A8A] bg-[#E3EDF5] px-2 py-0.5 rounded-full inline-block">
            +{intervention.connectivityGain}% network connectivity
          </div>
        )}
      </div>
    </div>
  );
}
