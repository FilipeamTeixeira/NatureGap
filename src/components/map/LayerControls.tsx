'use client';

import { cn, formatNumber } from '@/lib/utils';
import { Layers, Info, MapPin } from 'lucide-react';
import { GLOBAL_STATS } from '@/lib/mock-data';
import type { MapLayer } from '@/lib/types';

interface LayerControlsProps {
  layers: MapLayer[];
  onToggle: (id: string) => void;
}

const LAYER_DESCRIPTIONS: Record<string, string> = {
  impact: 'Observed vs expected biodiversity, corrected for observer effort.',
};

export default function LayerControls({ layers, onToggle }: LayerControlsProps) {
  return (
    <aside className="w-80 flex-shrink-0 bg-white border-r border-[#E4E7E1] flex flex-col overflow-y-auto">
      {/* Section header */}
      <div className="px-6 pt-5 pb-4 border-b border-[#E4E7E1]">
        <div className="flex items-center gap-2 mb-2">
          <Layers size={13} className="text-[#667066]" strokeWidth={1.5} />
          <span className="text-[10px] font-semibold text-[#667066] uppercase tracking-widest">
            Data Layers
          </span>
        </div>
        <p className="text-[12px] text-[#667066] leading-relaxed">
          Toggle ecological layers to explore different dimensions of urban nature.
        </p>
      </div>

      {/* Layer list */}
      <div className="flex flex-col gap-1.5 p-4 flex-1">
        {layers.map((layer) => (
          <button
            key={layer.id}
            onClick={() => onToggle(layer.id)}
            className={cn(
              'flex items-start gap-3 px-4 py-3.5 rounded-xl text-left transition-all',
              layer.enabled
                ? 'bg-[#F7F8F5] border border-[#E4E7E1]'
                : 'border border-transparent hover:bg-[#F7F8F5] hover:border-[#E4E7E1]',
            )}
          >
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2 mb-1">
                <span
                  className="w-2 h-2 rounded-full flex-shrink-0 transition-opacity"
                  style={{
                    backgroundColor: layer.color,
                    opacity: layer.enabled ? 1 : 0.3,
                  }}
                />
                <span
                  className={cn(
                    'text-[13px] leading-tight font-medium',
                    layer.enabled ? 'text-[#1F2A1F]' : 'text-[#667066]',
                  )}
                >
                  {layer.label}
                </span>
              </div>
              {LAYER_DESCRIPTIONS[layer.id] && (
                <p className={cn(
                  'text-[11px] leading-relaxed pl-4',
                  layer.enabled ? 'text-[#667066]' : 'text-[#9ca3af]',
                )}>
                  {LAYER_DESCRIPTIONS[layer.id]}
                </p>
              )}
            </div>

            {/* Toggle switch */}
            <div
              className={cn(
                'w-9 h-5 rounded-full transition-colors flex items-center px-[3px] flex-shrink-0 mt-0.5',
                layer.enabled ? 'bg-[#2E6F40]' : 'bg-[#D1D8CE]',
              )}
            >
              <div
                className={cn(
                  'w-3.5 h-3.5 rounded-full bg-white transition-transform shadow-sm',
                  layer.enabled ? 'translate-x-4' : 'translate-x-0',
                )}
              />
            </div>
          </button>
        ))}
      </div>

      {/* Location info */}
      <div className="px-6 py-4 border-t border-[#E4E7E1]">
        <div className="flex items-center gap-2 mb-3">
          <MapPin size={11} className="text-[#667066] flex-shrink-0" strokeWidth={1.5} />
          <span className="text-[10px] font-semibold text-[#667066] uppercase tracking-widest">
            Yokohama, Japan
          </span>
        </div>
        <div className="flex flex-col gap-2.5">
          {[
            { label: 'Observations today', value: formatNumber(GLOBAL_STATS.observationsToday) },
            { label: 'Species observed',   value: formatNumber(GLOBAL_STATS.speciesObserved) },
            { label: 'Areas improving',    value: String(GLOBAL_STATS.areasImproving) },
          ].map(({ label, value }) => (
            <div key={label} className="flex items-baseline justify-between">
              <span className="text-[11px] text-[#667066]">{label}</span>
              <span className="text-[12px] font-semibold text-[#1F2A1F]">{value}</span>
            </div>
          ))}
        </div>
      </div>

      {/* Pipeline note */}
      <div className="px-6 py-4 border-t border-[#E4E7E1]">
        <div className="flex items-start gap-2">
          <Info size={11} className="text-[#A8B4A8] mt-0.5 flex-shrink-0" strokeWidth={1.5} />
          <p className="text-[11px] text-[#A8B4A8] leading-relaxed">
            Habitat, heat exposure, and connectivity layers will appear once the data pipeline export is complete.
          </p>
        </div>
      </div>
    </aside>
  );
}
