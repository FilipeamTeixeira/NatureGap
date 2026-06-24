'use client';

import { useState } from 'react';
import dynamic from 'next/dynamic';
import { MousePointerClick } from 'lucide-react';
import Navbar from '@/components/layout/Navbar';
import LayerControls from '@/components/map/LayerControls';
import CellDetailPanel from '@/components/detail/CellDetailPanel';
import { MAP_LAYERS } from '@/lib/mock-data';
import { GREEN_SPACES } from '@/lib/green-spaces';
import { parkToCellData } from '@/lib/park-data';
import type { CellData, MapLayer } from '@/lib/types';

const MapView = dynamic(() => import('@/components/map/MapView'), { ssr: false });

function InsightPanelEmpty() {
  return (
    <div className="w-[440px] flex-shrink-0 bg-[#F7F8F5] border-l border-[#E4E7E1] flex flex-col">
      <div className="flex-1 flex flex-col items-center justify-center px-8 text-center">
        <div className="w-12 h-12 bg-[#DDEAD8] rounded-2xl flex items-center justify-center mb-4">
          <MousePointerClick size={20} className="text-[#2E6F40]" strokeWidth={1.5} />
        </div>
        <h3 className="text-[16px] font-semibold text-[#1F2A1F] mb-2">Select a location</h3>
        <p className="text-[13px] text-[#667066] leading-relaxed max-w-[260px]">
          Click any park or green space on the map to see its ecological diagnosis,
          biodiversity metrics, and restoration recommendations.
        </p>
      </div>

      {/* Hint cards */}
      <div className="p-5 flex flex-col gap-3">
        {[
          { color: '#2E6F40', label: 'Much better than expected' },
          { color: '#73A56D', label: 'Better than expected' },
          { color: '#B8C9AE', label: 'As expected' },
          { color: '#E8A44C', label: 'Worse than expected' },
          { color: '#C95B4B', label: 'Much worse than expected' },
        ].map(({ color, label }) => (
          <div key={label} className="flex items-center gap-3">
            <div
              className="w-3 h-3 rounded-[3px] flex-shrink-0"
              style={{ backgroundColor: color }}
            />
            <span className="text-[12px] text-[#667066]">{label}</span>
          </div>
        ))}
        <p className="text-[10px] text-[#A8B4A8] mt-1 uppercase tracking-widest">
          Nature impact scale
        </p>
      </div>
    </div>
  );
}

export default function Page() {
  const [selectedCell, setSelectedCell] = useState<CellData | null>(null);
  const [layers, setLayers] = useState<MapLayer[]>(MAP_LAYERS);

  const toggleLayer = (id: string) => {
    setLayers((prev) => prev.map((l) => (l.id === id ? { ...l, enabled: !l.enabled } : l)));
  };

  const handleHexClick = (parkId: string, cellId: string, score: number) => {
    const park = GREEN_SPACES.find((p) => p.id === parkId);
    if (!park) return;
    setSelectedCell(parkToCellData(park, score, cellId));
  };

  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/" />

      <div className="flex flex-1 min-h-0">
        <LayerControls layers={layers} onToggle={toggleLayer} />

        <div className="flex-1 relative min-w-0">
          <MapView
            layers={layers}
            selectedCellId={selectedCell?.id ?? null}
            onHexClick={handleHexClick}
          />
        </div>

        {selectedCell ? (
          <CellDetailPanel cell={selectedCell} onClose={() => setSelectedCell(null)} />
        ) : (
          <InsightPanelEmpty />
        )}
      </div>
    </div>
  );
}
