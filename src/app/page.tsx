'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import dynamic from 'next/dynamic';
import Navbar from '@/components/layout/Navbar';
import LayerControls from '@/components/map/LayerControls';
import CellDetailPanel from '@/components/detail/CellDetailPanel';
import WardSummaryPanel from '@/components/detail/WardSummaryPanel';
import CitizenSciencePanel from '@/components/citizen-science/CitizenSciencePanel';
import { MAP_LAYERS } from '@/lib/mock-data';
import { getParks, initParks, type GreenSpace } from '@/lib/green-spaces';
import { parkToCellData, cellToCellData, initParkStats } from '@/lib/park-data';
import { initData } from '@/lib/data';
import { initHexGrid, filterHexGridToParks, enrichHexGridWithCellStats } from '@/lib/hex-grid';
import type { CellData, MapLayer, WardFeature } from '@/lib/types';
import {
  fetchCurrentRole,
  fetchQuickSightings,
  fetchSpeciesReference,
  fetchStructuredSurveys,
  fetchSurveyPoints,
  quickSightingsGeoJSON,
  structuredSurveysGeoJSON,
  surveyPointsGeoJSON,
  type AppRole,
  type QuickSightingFeature,
  type SpeciesReferenceOption,
  type StructuredSurveyFeature,
  type SurveyPointFeature,
} from '@/lib/citizen-science';

const MapView = dynamic(() => import('@/components/map/MapView'), { ssr: false });

function centroid(ring: [number, number][]): [number, number] {
  const pts = ring.slice(0, -1);
  const lng = pts.reduce((s, p) => s + p[0], 0) / pts.length;
  const lat = pts.reduce((s, p) => s + p[1], 0) / pts.length;
  return [lng, lat];
}

export default function Page() {
  const [selectedCell, setSelectedCell] = useState<CellData | null>(null);
  const [selectedWard, setSelectedWard] = useState<WardFeature | null>(null);
  const [selectedSurveyPoint, setSelectedSurveyPoint] = useState<SurveyPointFeature | null>(null);
  const [layers, setLayers] = useState<MapLayer[]>(MAP_LAYERS);
  const [flyToTarget, setFlyToTarget] = useState<{ center: [number, number]; zoom: number } | null>(null);
  const [dataRevision, setDataRevision] = useState(0);
  const [role, setRole] = useState<AppRole | null>(null);
  const [species, setSpecies] = useState<SpeciesReferenceOption[]>([]);
  const [surveyPoints, setSurveyPoints] = useState<SurveyPointFeature[]>([]);
  const [quickSightings, setQuickSightings] = useState<QuickSightingFeature[]>([]);
  const [structuredSurveys, setStructuredSurveys] = useState<StructuredSurveyFeature[]>([]);

  const quickSightingsFc = useMemo(() => quickSightingsGeoJSON(quickSightings), [quickSightings]);
  const surveyPointsFc = useMemo(() => surveyPointsGeoJSON(surveyPoints), [surveyPoints]);
  const structuredSurveysFc = useMemo(() => structuredSurveysGeoJSON(structuredSurveys), [structuredSurveys]);

  useEffect(() => {
    let cancelled = false;
    Promise.allSettled([initParkStats(), initData(), initHexGrid(), initParks()]).finally(() => {
      if (!cancelled) {
        // Clip runtime hexgrid to park polygons and re-assign parkId for cells
        // that the pipeline left as "city-green". Must run after both initHexGrid
        // and initParks have settled so park polygons are available.
        filterHexGridToParks();
        enrichHexGridWithCellStats();
        setDataRevision((r) => r + 1);
      }
    });
    return () => { cancelled = true; };
  }, []);

  const refreshCitizenData = useCallback(async () => {
    const [roleData, speciesData, surveyPointData, quickData] = await Promise.all([
      fetchCurrentRole(),
      fetchSpeciesReference(),
      fetchSurveyPoints(),
      fetchQuickSightings(),
    ]);
    const structuredData = await fetchStructuredSurveys(surveyPointData);
    setRole(roleData);
    setSpecies(speciesData);
    setSurveyPoints(surveyPointData);
    setQuickSightings(quickData);
    setStructuredSurveys(structuredData);
  }, []);

  useEffect(() => {
    let cancelled = false;
    const timeout = window.setTimeout(() => {
      refreshCitizenData().catch(() => {
        if (!cancelled) {
          setRole(null);
          setSpecies([]);
          setSurveyPoints([]);
          setQuickSightings([]);
          setStructuredSurveys([]);
        }
      });
    }, 0);
    return () => {
      cancelled = true;
      window.clearTimeout(timeout);
    };
  }, [refreshCitizenData]);

  const toggleLayer = (id: string) => {
    setLayers((prev) => prev.map((l) => (l.id === id ? { ...l, enabled: !l.enabled } : l)));
  };

  const handleHexClick = (
    parkId: string,
    cellId: string,
    coordinates: [number, number],
    parkName?: string,
  ) => {
    const cell =
      cellToCellData(cellId, parkId, parkName ?? parkId, coordinates) ??
      (() => {
        const park = getParks().find((p) => p.id === parkId);
        return park ? parkToCellData(park, cellId, coordinates) : null;
      })();

    if (cell) {
      setSelectedCell(cell);
      setSelectedWard(null);
      setSelectedSurveyPoint(null);
    }
  };

  const handleParkSelect = (park: GreenSpace) => {
    const cell = parkToCellData(park, park.id, centroid(park.ring));
    if (cell) {
      setSelectedCell(cell);
      setSelectedWard(null);
      setSelectedSurveyPoint(null);
      setFlyToTarget({ center: centroid(park.ring), zoom: 17 });
    }
  };

  const handleWardSelect = (ward: WardFeature) => {
    setSelectedWard(ward);
    setSelectedCell(null);
    setSelectedSurveyPoint(null);
    setFlyToTarget({ center: ward.coordinates, zoom: 13 });
  };

  const handleClosePanel = () => {
    setSelectedCell(null);
    setSelectedWard(null);
  };

  const handleSurveyPointSelect = (id: string, coordinates: [number, number]) => {
    const point = surveyPoints.find((item) => item.id === id);
    if (point) {
      setSelectedSurveyPoint(point);
      setSelectedCell(null);
      setSelectedWard(null);
      setFlyToTarget({ center: coordinates, zoom: 18 });
    }
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
            quickSightingsGeoJSON={quickSightingsFc}
            structuredSurveysGeoJSON={structuredSurveysFc}
            surveyPointsGeoJSON={surveyPointsFc}
            selectedSurveyPointId={selectedSurveyPoint?.id ?? null}
            onSurveyPointSelect={handleSurveyPointSelect}
          />
        </div>

        {selectedCell ? (
          <CellDetailPanel cell={selectedCell} onClose={handleClosePanel} />
        ) : selectedWard ? (
          <WardSummaryPanel ward={selectedWard} onClose={handleClosePanel} />
        ) : (
          <CitizenSciencePanel
            role={role}
            species={species}
            surveyPoints={surveyPoints}
            selectedSurveyPoint={selectedSurveyPoint}
            onSelectSurveyPoint={setSelectedSurveyPoint}
            onRefreshMapData={refreshCitizenData}
          />
        )}
      </div>
    </div>
  );
}
