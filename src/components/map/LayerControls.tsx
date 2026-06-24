'use client';

import { cn } from '@/lib/utils';
import type { MapLayer } from '@/lib/types';

interface LayerControlsProps {
  layers: MapLayer[];
  onToggle: (id: string) => void;
}

export default function LayerControls({ layers, onToggle }: LayerControlsProps) {
  return (
    <aside className="w-56 flex-shrink-0 bg-white border-r border-[#e4e7e3] flex flex-col overflow-y-auto">
      <div className="px-4 pt-4 pb-2">
        <span className="text-[10px] font-semibold text-neutral-400 uppercase tracking-widest">
          Map layers
        </span>
      </div>

      <div className="flex flex-col gap-0.5 px-2 flex-1">
        {layers.map((layer) => (
          <button
            key={layer.id}
            onClick={() => onToggle(layer.id)}
            className={cn(
              'flex items-center gap-3 px-2 py-2.5 rounded-lg text-left transition-colors group',
              layer.enabled ? 'bg-[#f7f8f6]' : 'hover:bg-[#f7f8f6]',
            )}
          >
            <span
              className="w-2.5 h-2.5 rounded-full flex-shrink-0 transition-opacity"
              style={{
                backgroundColor: layer.color,
                opacity: layer.enabled ? 1 : 0.3,
              }}
            />
            <span
              className={cn(
                'text-sm flex-1 leading-tight',
                layer.enabled ? 'text-neutral-800 font-medium' : 'text-neutral-400',
              )}
            >
              {layer.label}
            </span>

            {/* Toggle switch */}
            <div
              className={cn(
                'w-7 h-4 rounded-full transition-colors flex items-center px-0.5 flex-shrink-0',
                layer.enabled ? 'bg-[#3d6b2f]' : 'bg-neutral-200',
              )}
            >
              <div
                className={cn(
                  'w-3 h-3 rounded-full bg-white transition-transform shadow-sm',
                  layer.enabled ? 'translate-x-3' : 'translate-x-0',
                )}
              />
            </div>
          </button>
        ))}
      </div>

      <div className="px-4 py-3 border-t border-[#e4e7e3] mt-2">
        <p className="text-[11px] text-neutral-400 leading-relaxed">
          Additional habitat, heat, and connectivity layers will appear here once exported data is available.
        </p>
      </div>
    </aside>
  );
}
