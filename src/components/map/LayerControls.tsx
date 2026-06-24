'use client';

import { useState, useMemo, useRef, useEffect } from 'react';
import { cn, formatNumber } from '@/lib/utils';
import { Layers, Info, MapPin, Search, TreePine, Map } from 'lucide-react';
import { getGlobalStats, getWards } from '@/lib/data';
import { GREEN_SPACES } from '@/lib/green-spaces';
import { CITY } from '@/lib/config';
import type { MapLayer } from '@/lib/types';
import type { WardFeature } from '@/lib/types';
import type { GreenSpace } from '@/lib/green-spaces';

interface LayerControlsProps {
  layers: MapLayer[];
  onToggle: (id: string) => void;
  onParkSelect?: (park: GreenSpace) => void;
  onWardSelect?: (ward: WardFeature) => void;
}

type SearchResult =
  | { kind: 'park'; park: GreenSpace }
  | { kind: 'ward'; ward: WardFeature };

const LAYER_DESCRIPTIONS: Record<string, string> = {
  impact: 'Observed vs expected biodiversity, corrected for observer effort.',
};

export default function LayerControls({ layers, onToggle, onParkSelect, onWardSelect }: LayerControlsProps) {
  const [query, setQuery] = useState('');
  const [open, setOpen] = useState(false);
  const wrapperRef = useRef<HTMLDivElement>(null);

  const results = useMemo<SearchResult[]>(() => {
    const q = query.trim().toLowerCase();
    if (!q) return [];

    const parks: SearchResult[] = GREEN_SPACES
      .filter((p) =>
        p.name.toLowerCase().includes(q) ||
        p.nameJa.includes(q) ||
        p.wardId.toLowerCase().includes(q),
      )
      .slice(0, 5)
      .map((park) => ({ kind: 'park', park }));

    const wards: SearchResult[] = getWards()
      .filter((w) =>
        w.name.toLowerCase().includes(q) ||
        w.nameJa.includes(q),
      )
      .slice(0, 5)
      .map((ward) => ({ kind: 'ward', ward }));

    return [...parks, ...wards];
  }, [query]);

  // Close dropdown when clicking outside
  useEffect(() => {
    function handlePointerDown(e: PointerEvent) {
      if (wrapperRef.current && !wrapperRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener('pointerdown', handlePointerDown);
    return () => document.removeEventListener('pointerdown', handlePointerDown);
  }, []);

  function handleSelect(result: SearchResult) {
    setQuery('');
    setOpen(false);
    if (result.kind === 'park') onParkSelect?.(result.park);
    else onWardSelect?.(result.ward);
  }

  return (
    <aside className="w-80 flex-shrink-0 bg-white border-r border-[#E4E7E1] flex flex-col overflow-y-auto">
      {/* Search */}
      <div className="px-5 pt-5 pb-4 border-b border-[#E4E7E1]" ref={wrapperRef}>
        <div className="relative">
          <Search
            size={13}
            className="absolute left-3 top-1/2 -translate-y-1/2 text-[#A8B4A8] pointer-events-none"
            strokeWidth={1.5}
          />
          <input
            type="text"
            placeholder="Search parks and wards…"
            value={query}
            onChange={(e) => { setQuery(e.target.value); setOpen(true); }}
            onFocus={() => { if (query) setOpen(true); }}
            onKeyDown={(e) => { if (e.key === 'Escape') { setQuery(''); setOpen(false); } }}
            className="w-full bg-[#F7F8F5] border border-[#E4E7E1] rounded-xl pl-8 pr-3 py-2.5 text-[13px] text-[#1F2A1F] placeholder:text-[#A8B4A8] outline-none focus:border-[#2E6F40] transition-colors"
          />

          {/* Results dropdown */}
          {open && results.length > 0 && (
            <div className="absolute left-0 right-0 top-full mt-1.5 bg-white rounded-xl border border-[#E4E7E1] shadow-lg overflow-hidden z-50"
                 style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.08), 0 1px 4px rgba(0,0,0,0.04)' }}>
              {results.map((result, i) => {
                const key = result.kind === 'park' ? `park-${result.park.id}` : `ward-${result.ward.id}`;
                const label = result.kind === 'park' ? result.park.name : `${result.ward.name} Ward`;
                const sub   = result.kind === 'park' ? result.park.nameJa : result.ward.nameJa;
                const Icon  = result.kind === 'park' ? TreePine : Map;
                return (
                  <button
                    key={key}
                    type="button"
                    onClick={() => handleSelect(result)}
                    className={cn(
                      'w-full flex items-center gap-3 px-4 py-3 text-left hover:bg-[#F7F8F5] transition-colors',
                      i > 0 && 'border-t border-[#F0F2EE]',
                    )}
                  >
                    <div className="w-6 h-6 rounded-lg bg-[#DDEAD8] flex items-center justify-center flex-shrink-0">
                      <Icon size={11} className="text-[#2E6F40]" strokeWidth={1.5} />
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="text-[13px] font-medium text-[#1F2A1F] truncate">{label}</div>
                      <div className="text-[10px] text-[#A8B4A8]">{sub}</div>
                    </div>
                    <span className="text-[10px] text-[#A8B4A8] flex-shrink-0 capitalize">{result.kind}</span>
                  </button>
                );
              })}
            </div>
          )}

          {/* No results hint */}
          {open && query.trim().length > 0 && results.length === 0 && (
            <div className="absolute left-0 right-0 top-full mt-1.5 bg-white rounded-xl border border-[#E4E7E1] shadow-lg px-4 py-3 z-50">
              <p className="text-[12px] text-[#A8B4A8]">No parks or wards match "{query}"</p>
            </div>
          )}
        </div>
      </div>

      {/* Section header */}
      <div className="px-6 pt-4 pb-3">
        <div className="flex items-center gap-2">
          <Layers size={13} className="text-[#667066]" strokeWidth={1.5} />
          <span className="text-[10px] font-semibold text-[#667066] uppercase tracking-widest">
            Data Layers
          </span>
        </div>
      </div>

      {/* Layer list */}
      <div className="flex flex-col gap-1.5 p-4 flex-1">
        {layers.map((layer) => (
          <button
            key={layer.id}
            type="button"
            role="switch"
            aria-checked={layer.enabled}
            aria-label={`${layer.enabled ? 'Hide' : 'Show'} ${layer.label}`}
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
            {CITY.name}, {CITY.country}
          </span>
        </div>
        <div className="flex flex-col gap-2.5">
          {((): { label: string; value: string }[] => {
            const s = getGlobalStats();
            return [
              { label: 'Observations today', value: formatNumber(s.observationsToday) },
              { label: 'Species observed',   value: formatNumber(s.speciesObserved) },
              { label: 'Areas improving',    value: String(s.areasImproving) },
            ];
          })().map(({ label, value }) => (
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
