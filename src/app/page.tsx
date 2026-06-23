'use client';

import { useState } from 'react';
import dynamic from 'next/dynamic';
import Navbar from '@/components/layout/Navbar';
import LayerControls from '@/components/map/LayerControls';
import CellDetailPanel from '@/components/detail/CellDetailPanel';
import WardSummaryPanel from '@/components/detail/WardSummaryPanel';
import { YOKOHAMA_CELLS, MAP_LAYERS, ALL_WARDS } from '@/lib/mock-data';
import type { CellData, MapLayer, WardFeature } from '@/lib/types';

// MapLibre must be loaded client-side only
const MapView = dynamic(() => import('@/components/map/MapView'), { ssr: false });

type Selection =
  | { kind: 'full'; cell: CellData }
  | { kind: 'summary'; ward: WardFeature }
  | null;

export default function Page() {
  const [selection, setSelection] = useState<Selection>(null);
  const [layers, setLayers] = useState<MapLayer[]>(MAP_LAYERS);

  const toggleLayer = (id: string) => {
    setLayers((prev) =>
      prev.map((l) => (l.id === id ? { ...l, enabled: !l.enabled } : l)),
    );
  };

  const handleCellClick = (id: string) => {
    const cell = YOKOHAMA_CELLS.find((c) => c.id === id);
    if (cell) {
      setSelection({ kind: 'full', cell });
      return;
    }
    const ward = ALL_WARDS.find((w) => w.id === id);
    if (ward) {
      setSelection({ kind: 'summary', ward });
    }
  };

  const selectedId =
    selection?.kind === 'full'
      ? selection.cell.id
      : selection?.kind === 'summary'
        ? selection.ward.id
        : null;

  return (
    <div className="h-full flex flex-col">
      <Navbar />

      <div className="flex flex-1 min-h-0">
        <LayerControls layers={layers} onToggle={toggleLayer} />

        <div className="flex-1 relative min-w-0">
          <MapView selectedCellId={selectedId} onCellClick={handleCellClick} />
        </div>

        {selection?.kind === 'full' && (
          <CellDetailPanel cell={selection.cell} onClose={() => setSelection(null)} />
        )}
        {selection?.kind === 'summary' && (
          <WardSummaryPanel ward={selection.ward} onClose={() => setSelection(null)} />
        )}
      </div>
    </div>
  );
}
