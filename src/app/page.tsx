'use client';

import { useState, useEffect } from 'react';
import dynamic from 'next/dynamic';
import { MousePointerClick } from 'lucide-react';
import Navbar from '@/components/layout/Navbar';
import LayerControls from '@/components/map/LayerControls';
import CellDetailPanel from '@/components/detail/CellDetailPanel';
import WardSummaryPanel from '@/components/detail/WardSummaryPanel';
import { MAP_LAYERS } from '@/lib/mock-data';
import { GREEN_SPACES } from '@/lib/green-spaces';
import { parkToCellData, initParkStats } from '@/lib/park-data';
import { initData } from '@/lib/data';
import { medianScoreForPark, initHexGrid } from '@/lib/hex-grid';
import { IMPACT_LEGEND } from '@/lib/utils';
import type { CellData, MapLayer, WardFeature } from '@/lib/types';
import type { GreenSpace } from '@/lib/green-spaces';

const MapView = dynamic(() => import('@/components/map/MapView'), { ssr: false });

function centroid(ring: [number, number][]): [number, number] {
  const pts = ring.slice(0, -1);
  const lng = pts.reduce((s, p) => s + p[0], 0) / pts.length;
  const lat = pts.reduce((s, p) => s + p[1], 0) / pts.length;
  return [lng, lat];
}

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

      <div className="p-5 flex flex-col gap-3">
        {IMPACT_LEGEND.map(({ color, label }) => (
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
  const [selectedWard, setSelectedWard] = useState<WardFeature | null>(null);
  const [layers, setLayers] = useState<MapLayer[]>(MAP_LAYERS);
  const [flyToTarget, setFlyToTarget] = useState<{ center: [number, number]; zoom: number } | null>(null);
  const [dataRevision, setDataRevision] = useState(0);

  useEffect(() => {
    let cancelled = false;
    Promise.allSettled([initParkStats(), initData(), initHexGrid()]).finally(() => {
      if (!cancelled) setDataRevision((r) => r + 1);
    });
    return () => { cancelled = true; };
  }, []);

  const toggleLayer = (id: string) => {
    setLayers((prev) => prev.map((l) => (l.id === id ? { ...l, enabled: !l.enabled } : l)));
  };

  const handleHexClick = (parkId: string, cellId: string, score: number) => {
    const park = GREEN_SPACES.find((p) => p.id === parkId) ?? {
      id: parkId,
      name: 'Yokohama',
      nameJa: '横浜市',
      wardId: '',
      ring: [] as [number, number][],
    };
    setSelectedCell(parkToCellData(park, score, cellId));
    setSelectedWard(null);
  };

  const handleParkSelect = (park: GreenSpace) => {
    const score = medianScoreForPark(park.id);
    setSelectedCell(parkToCellData(park, score, park.id));
    setSelectedWard(null);
    setFlyToTarget({ center: centroid(park.ring), zoom: 17 });
  };

  const handleWardSelect = (ward: WardFeature) => {
    setSelectedWard(ward);
    setSelectedCell(null);
    setFlyToTarget({ center: ward.coordinates, zoom: 13 });
  };

  const handleClosePanel = () => {
    setSelectedCell(null);
    setSelectedWard(null);
  };

  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/" />

      <div className="flex flex-1 min-h-0">
        <LayerControls
          layers={layers}
          onToggle={toggleLayer}
          onParkSelect={handleParkSelect}
          onWardSelect={handleWardSelect}
        />

        <div className="flex-1 relative min-w-0">
          <MapView
            layers={layers}
            selectedCellId={selectedCell?.id ?? null}
            onHexClick={handleHexClick}
            flyToTarget={flyToTarget}
            dataRevision={dataRevision}
          />
        </div>

        {selectedCell ? (
          <CellDetailPanel cell={selectedCell} onClose={handleClosePanel} />
        ) : selectedWard ? (
          <WardSummaryPanel ward={selectedWard} onClose={handleClosePanel} />
        ) : (
          <InsightPanelEmpty />
        )}
      </div>
    </div>
  );
}
