'use client';

import { useState } from 'react';
import dynamic from 'next/dynamic';
import Navbar from '@/components/layout/Navbar';
import LayerControls from '@/components/map/LayerControls';
import CellDetailPanel from '@/components/detail/CellDetailPanel';
import { MAP_LAYERS } from '@/lib/mock-data';
import { GREEN_SPACES } from '@/lib/green-spaces';
import { parkToCellData } from '@/lib/park-data';
import type { CellData, MapLayer } from '@/lib/types';

const MapView = dynamic(() => import('@/components/map/MapView'), { ssr: false });

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

        {selectedCell && (
          <CellDetailPanel cell={selectedCell} onClose={() => setSelectedCell(null)} />
        )}
      </div>
    </div>
  );
}
