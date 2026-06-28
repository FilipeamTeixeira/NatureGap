'use client';

import { useState, useMemo, useRef, useEffect } from 'react';
import { cn, formatNumber } from '@/lib/utils';
import { ChevronLeft, ChevronRight, Layers, Info, MapPin, Search, Map as MapIcon } from 'lucide-react';
import { getGlobalStats } from '@/lib/data';
import { CITY } from '@/lib/config';
import { THEMATIC_LAYER_GROUPS, LAYER_STYLE_SPECS, type HexLayerId } from '@/lib/layer-styles';
import type { MapLayer } from '@/lib/types';
import type { GeocodingSearchResult } from '@/lib/map-search';

interface LayerControlsProps {
  layers: MapLayer[];
  onToggle: (id: string) => void;
  onPlaceSelect?: (center: [number, number]) => void;
}

type SearchResult =
  | { kind: 'geocode'; result: GeocodingSearchResult };

const LAYER_DESCRIPTIONS: Record<string, string> = {
  impact:       'How much nature is this park missing?',
  residual:     'Are more or fewer species being recorded here than the habitat suggests?',
  intervention: 'Cells ranked for restoration action.',
  expected:     'Modelled richness from habitat and connectivity.',
  biodiversity: 'Effort-corrected observed species richness.',
  habitat:      'Combined habitat quality.',
  treecover:    'Estimated canopy cover.',
  connectivity: 'Corridor importance between habitat cells.',
  heat:         'Relative land-surface heat exposure.',
  landuse:      'Vegetated and built-up land cover.',
  'cell-grid': 'Show the 20m hex grid.',
  'survey-points': 'Approved places for structured surveys.',
  'quick-sightings': 'Recent quick observations.',
  'structured-surveys': 'Protocol survey submissions.',
};

const OVERLAY_LAYER_IDS = ['cell-grid', 'survey-points', 'quick-sightings', 'structured-surveys'] as const;

function layerSwatchColor(layerId: string, fallback: string): string {
  const spec = LAYER_STYLE_SPECS[layerId as HexLayerId];
  const legend = spec?.legend;
  if (!legend?.length) return fallback;
  return legend[Math.min(2, legend.length - 1)]?.color ?? fallback;
}

export default function LayerControls({
  layers,
  onToggle,
  onPlaceSelect,
}: LayerControlsProps) {
  const [query, setQuery] = useState('');
  const [open, setOpen] = useState(false);
  const [geocodingResults, setGeocodingResults] = useState<GeocodingSearchResult[]>([]);
  const [collapsed, setCollapsed] = useState(false);
  const [hydrated, setHydrated] = useState(false);
  const wrapperRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      setCollapsed(window.localStorage.getItem('naturegap.sidebar.collapsed') === 'true');
      setHydrated(true);
    });
    return () => window.cancelAnimationFrame(frame);
  }, []);

  useEffect(() => {
    if (!hydrated) return;
    window.localStorage.setItem('naturegap.sidebar.collapsed', String(collapsed));
  }, [collapsed, hydrated]);

  useEffect(() => {
    const q = query.trim();
    if (q.length < 2) return;

    const controller = new AbortController();
    const timeout = window.setTimeout(() => {
      fetch(`/api/search-places?q=${encodeURIComponent(q)}`, { signal: controller.signal })
        .then((res) => (res.ok ? res.json() : { results: [] }))
        .then((data: { results?: GeocodingSearchResult[] }) => {
          setGeocodingResults(data.results ?? []);
        })
        .catch(() => {
          if (!controller.signal.aborted) setGeocodingResults([]);
        });
    }, 200);

    return () => {
      window.clearTimeout(timeout);
      controller.abort();
    };
  }, [query]);

  const results = useMemo<SearchResult[]>(() => {
    if (query.trim().length < 2) return [];
    return geocodingResults.map((result) => ({ kind: 'geocode' as const, result }));
  }, [geocodingResults, query]);

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
    onPlaceSelect?.(result.result.center);
  }

  const layersById = useMemo(() => new Map(layers.map((layer) => [layer.id, layer])), [layers]);

  function renderThematicButton(layer: MapLayer) {
    const swatchColor = layerSwatchColor(layer.id, layer.color);
    return (
      <button
        key={layer.id}
        type="button"
        aria-pressed={layer.enabled}
        aria-label={`Show ${layer.label}`}
        onClick={() => onToggle(layer.id)}
        className={cn(
          'w-full flex items-center gap-3 rounded-lg text-left transition-all px-3 py-2.5',
          layer.enabled
            ? 'bg-[#2E6F40] text-white shadow-sm'
            : 'border border-transparent hover:bg-[#F7F8F5] hover:border-[#E4E7E1] text-[#1F2A1F]',
          collapsed && 'justify-center px-2',
        )}
      >
        <span
          className={cn(
            'rounded-[2px] flex-shrink-0',
            layer.enabled && 'ring-2 ring-white',
          )}
          style={{
            width: 12,
            height: 12,
            minWidth: 12,
            minHeight: 12,
            backgroundColor: swatchColor,
            opacity: layer.enabled ? 1 : 0.7,
          }}
        />
        <span className={cn(
          'flex-1 min-w-0 text-[13px] font-medium leading-tight',
          layer.enabled && 'text-white',
          collapsed && 'hidden',
        )}>
          {layer.label}
        </span>
      </button>
    );
  }

  function renderOverlayButton(layer: MapLayer) {
    return (
      <button
        key={layer.id}
        type="button"
        role="switch"
        aria-checked={layer.enabled}
        aria-label={`${layer.enabled ? 'Hide' : 'Show'} ${layer.label}`}
        onClick={() => onToggle(layer.id)}
        className={cn(
          'flex items-start gap-3 rounded-lg text-left transition-all',
          collapsed ? 'justify-center px-2 py-2.5' : 'px-3 py-2.5',
          layer.enabled
            ? 'bg-[#F7F8F5] border border-[#E4E7E1]'
            : 'border border-transparent hover:bg-[#F7F8F5] hover:border-[#E4E7E1]',
        )}
      >
        <span
          className="w-2 h-2 rounded-full flex-shrink-0 mt-1.5 transition-opacity"
          style={{
            backgroundColor: layer.color,
            opacity: layer.enabled ? 1 : 0.3,
          }}
        />
        <div className={cn('flex-1 min-w-0', collapsed && 'hidden')}>
          <span
            className={cn(
              'block text-[13px] leading-tight font-medium',
              layer.enabled ? 'text-[#1F2A1F]' : 'text-[#667066]',
            )}
          >
            {layer.label}
          </span>
          {LAYER_DESCRIPTIONS[layer.id] && (
            <span
              className={cn(
                'block text-[11px] leading-snug mt-1',
                layer.enabled ? 'text-[#667066]' : 'text-[#9ca3af]',
              )}
            >
              {LAYER_DESCRIPTIONS[layer.id]}
            </span>
          )}
        </div>

        <span
          className={cn(
            'w-8 h-4 rounded-full transition-colors items-center px-[2px] flex-shrink-0 mt-0.5',
            collapsed ? 'hidden' : 'flex',
            layer.enabled ? 'bg-[#2E6F40]' : 'bg-[#D1D8CE]',
          )}
        >
          <span
            className={cn(
              'w-3 h-3 rounded-full bg-white transition-transform shadow-sm',
              layer.enabled ? 'translate-x-4' : 'translate-x-0',
            )}
          />
        </span>
      </button>
    );
  }

  return (
    <aside className={cn(
      'flex-shrink-0 bg-white border-r border-[#E4E7E1] flex flex-col overflow-y-auto transition-[width] duration-200',
      collapsed ? 'w-16' : 'w-80',
    )}>
      <div className={cn('border-b border-[#E4E7E1] flex items-center', collapsed ? 'justify-center p-3' : 'justify-between px-5 py-3')}>
        <div className={cn('flex items-center gap-2', collapsed && 'hidden')}>
          <Layers size={13} className="text-[#667066]" strokeWidth={1.5} />
          <span className="text-[10px] font-semibold text-[#667066] uppercase tracking-widest">Controls</span>
        </div>
        <button
          type="button"
          onClick={() => setCollapsed((value) => !value)}
          aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          className="w-8 h-8 rounded-lg border border-[#E4E7E1] flex items-center justify-center text-[#667066] hover:bg-[#F7F8F5]"
        >
          {collapsed ? <ChevronRight size={14} strokeWidth={1.8} /> : <ChevronLeft size={14} strokeWidth={1.8} />}
        </button>
      </div>

      <div className={cn('px-5 pt-5 pb-4 border-b border-[#E4E7E1]', collapsed && 'hidden')} ref={wrapperRef}>
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

          {open && results.length > 0 && (
            <div className="absolute left-0 right-0 top-full mt-1.5 bg-white rounded-xl border border-[#E4E7E1] shadow-lg overflow-hidden z-50"
                 style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.08), 0 1px 4px rgba(0,0,0,0.04)' }}>
              {results.map((result, i) => {
                const key = `geocode-${result.result.id}`;
                const label = result.result.label;
                const sub = result.result.sub;
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
                      <MapIcon size={11} className="text-[#2E6F40]" strokeWidth={1.5} />
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="text-[13px] font-medium text-[#1F2A1F] truncate">{label}</div>
                      <div className="text-[10px] text-[#A8B4A8]">{sub}</div>
                    </div>
                    <span className="text-[10px] text-[#A8B4A8] flex-shrink-0 capitalize">place</span>
                  </button>
                );
              })}
            </div>
          )}

          {open && query.trim().length > 0 && results.length === 0 && (
            <div className="absolute left-0 right-0 top-full mt-1.5 bg-white rounded-xl border border-[#E4E7E1] shadow-lg px-4 py-3 z-50">
              <p className="text-[12px] text-[#A8B4A8]">No parks or wards match &quot;{query}&quot;</p>
            </div>
          )}
        </div>
      </div>

      <div className={cn('pt-4 pb-3', collapsed ? 'px-0 flex justify-center' : 'px-6')}>
        <div className="flex items-center gap-2">
          <Layers size={13} className="text-[#667066]" strokeWidth={1.5} />
          <span className={cn('text-[10px] font-semibold text-[#667066] uppercase tracking-widest', collapsed && 'hidden')}>
            Data Layers
          </span>
        </div>
      </div>

      <div className={cn('flex flex-col flex-1', collapsed ? 'gap-1 p-2' : 'gap-4 p-4')}>
        {THEMATIC_LAYER_GROUPS.map((group) => {
          const groupLayers = group.ids
            .map((id) => layersById.get(id))
            .filter((layer): layer is MapLayer => Boolean(layer));
          if (groupLayers.length === 0) return null;

          return (
            <section key={group.title} className="flex flex-col gap-2">
              <div className={cn('px-1', collapsed && 'hidden')}>
                <h3 className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest">
                  {group.title}
                </h3>
              </div>
              <div className="flex flex-col gap-1">
                {groupLayers.map(renderThematicButton)}
              </div>
            </section>
          );
        })}

        <section className="flex flex-col gap-2">
          <div className={cn('px-1', collapsed && 'hidden')}>
            <h3 className="text-[11px] font-semibold text-[#667066] uppercase tracking-widest">
              Overlays
            </h3>
          </div>
          <div className="flex flex-col gap-1">
            {OVERLAY_LAYER_IDS
              .map((id) => layersById.get(id))
              .filter((layer): layer is MapLayer => Boolean(layer))
              .map(renderOverlayButton)}
          </div>
        </section>
      </div>

      <div className={cn('px-6 py-4 border-t border-[#E4E7E1]', collapsed && 'hidden')}>
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

      <div className={cn('px-6 py-4 border-t border-[#E4E7E1]', collapsed && 'hidden')}>
        <div className="flex items-start gap-2">
          <Info size={11} className="text-[#A8B4A8] mt-0.5 flex-shrink-0" strokeWidth={1.5} />
          <p className="text-[11px] text-[#A8B4A8] leading-relaxed">
            Showing the current ecology model and submitted citizen-science records.
          </p>
        </div>
      </div>
    </aside>
  );
}
