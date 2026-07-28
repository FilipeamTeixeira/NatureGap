'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import dynamic from 'next/dynamic';
import Navbar from '@/components/layout/Navbar';
import LayerControls from '@/components/map/LayerControls';
import CellDetailPanel from '@/components/detail/CellDetailPanel';
import WardSummaryPanel from '@/components/detail/WardSummaryPanel';
import CitizenSciencePanel from '@/components/citizen-science/CitizenSciencePanel';
import { MAP_LAYERS } from '@/lib/mock-data';
import { initParks } from '@/lib/green-spaces';
import { initData, fetchEvents, fetchActions, type CommunityEvent, type TakeAction } from '@/lib/data';
import {
  cellDetailFromRender,
  fetchCellDetail,
  fetchParkDetail,
  type RenderCellProperties,
} from '@/lib/cell-detail';
import { THEMATIC_LAYER_IDS, type HexLayerId } from '@/lib/layer-styles';
import { CITY } from '@/lib/config';
import type { CellData, MapLayer, WardFeature } from '@/lib/types';
import {
  fetchCurrentRole,
  fetchSpeciesReference,
  fetchStructuredSurveys,
  fetchSurveyPoints,
  structuredSurveysGeoJSON,
  surveyPointsGeoJSON,
  type AppRole,
  type SpeciesReferenceOption,
  type StructuredSurveyFeature,
  type SurveyPointFeature,
} from '@/lib/citizen-science';

const MapView = dynamic(() => import('@/components/map/MapView'), { ssr: false });

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
  const [structuredSurveys, setStructuredSurveys] = useState<StructuredSurveyFeature[]>([]);
  const [events, setEvents] = useState<CommunityEvent[]>([]);
  const [actions, setActions] = useState<TakeAction[]>([]);
  const [cellDetailLoading, setCellDetailLoading] = useState(false);
  const cellClickGenerationRef = useRef(0);

  const surveyPointsFc = useMemo(() => surveyPointsGeoJSON(surveyPoints), [surveyPoints]);
  const structuredSurveysFc = useMemo(() => structuredSurveysGeoJSON(structuredSurveys), [structuredSurveys]);
  const activeLayer = useMemo<HexLayerId>(
    () => THEMATIC_LAYER_IDS.find((id) => layers.some((layer) => layer.id === id && layer.enabled)) ?? 'impact',
    [layers],
  );
  const currentCityId = selectedCell?.cityId ?? selectedWard?.cityId ?? CITY.id;

  useEffect(() => {
    let cancelled = false;
    Promise.allSettled([initData(), initParks()]).finally(() => {
      if (!cancelled) {
        setDataRevision((r) => r + 1);
      }
    });
    Promise.all([fetchEvents(), fetchActions()]).then(([eventData, actionData]) => {
      if (!cancelled) {
        setEvents(eventData);
        setActions(actionData);
      }
    });
    return () => { cancelled = true; };
  }, []);

  const refreshCitizenData = useCallback(async () => {
    const [roleData, speciesData, surveyPointData] = await Promise.all([
      fetchCurrentRole(),
      fetchSpeciesReference(),
      fetchSurveyPoints(),
    ]);
    const structuredData = await fetchStructuredSurveys(surveyPointData);
    setRole(roleData);
    setSpecies(speciesData);
    setSurveyPoints(surveyPointData);
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
    const isThematic = (THEMATIC_LAYER_IDS as readonly string[]).includes(id);
    setLayers((prev) => prev.map((layer) => {
      if (isThematic && (THEMATIC_LAYER_IDS as readonly string[]).includes(layer.id)) {
        return { ...layer, enabled: layer.id === id };
      }
      return layer.id === id ? { ...layer, enabled: !layer.enabled } : layer;
    }));
  };

  const handleHexClick = (
    renderCell: RenderCellProperties,
    coordinates: [number, number],
  ) => {
    const preview = cellDetailFromRender(renderCell, coordinates);
    if (!preview) return;

    const clickId = ++cellClickGenerationRef.current;
    setSelectedCell(preview);
    setCellDetailLoading(true);
    setSelectedWard(null);
    setSelectedSurveyPoint(null);

    void fetchCellDetail(renderCell, coordinates).then((cell) => {
      if (clickId !== cellClickGenerationRef.current) return;
      if (cell) setSelectedCell(cell);
      setCellDetailLoading(false);
    });
  };

  const handleParkClick = async (parkId: string, coordinates: [number, number]) => {
    const cell = await fetchParkDetail(parkId, coordinates);
    if (cell) {
      setSelectedCell(cell);
      setSelectedWard(null);
      setSelectedSurveyPoint(null);
    }
  };

  const handlePlaceSelect = (center: [number, number]) => {
    cellClickGenerationRef.current += 1;
    setCellDetailLoading(false);
    setSelectedWard(null);
    setSelectedCell(null);
    setSelectedSurveyPoint(null);
    setFlyToTarget({ center, zoom: 13 });
  };

  const handleClosePanel = () => {
    cellClickGenerationRef.current += 1;
    setCellDetailLoading(false);
    setSelectedCell(null);
    setSelectedWard(null);
  };

  const handleSurveyPointSelect = (id: string, coordinates: [number, number]) => {
    const point = surveyPoints.find((item) => item.id === id);
    if (point) {
      cellClickGenerationRef.current += 1;
      setCellDetailLoading(false);
      setSelectedSurveyPoint(point);
      setSelectedCell(null);
      setSelectedWard(null);
      setFlyToTarget({ center: coordinates, zoom: 18 });
    }
  };

  const handleLocateMe = (center: [number, number]) => {
    setFlyToTarget({ center, zoom: 15 });
  };

  return (
    <div className="h-full flex flex-col">
      <Navbar activePath="/" cityId={currentCityId} />

      <div className="flex flex-1 min-h-0">
        <LayerControls
          layers={layers}
          onToggle={toggleLayer}
          onPlaceSelect={handlePlaceSelect}
          onLocateMe={handleLocateMe}
          cityId={currentCityId}
        />

        <div className="flex-1 relative min-w-0">
          <MapView
            layers={layers}
            selectedCellId={selectedCell?.id ?? null}
            displayCityId={currentCityId}
            onHexClick={handleHexClick}
            onParkClick={handleParkClick}
            flyToTarget={flyToTarget}
            dataRevision={dataRevision}
            structuredSurveysGeoJSON={structuredSurveysFc}
            surveyPointsGeoJSON={surveyPointsFc}
            selectedSurveyPointId={selectedSurveyPoint?.id ?? null}
            onSurveyPointSelect={handleSurveyPointSelect}
          />
        </div>

        {selectedCell ? (
          <CellDetailPanel
            cell={selectedCell}
            activeLayer={activeLayer}
            detailLoading={cellDetailLoading}
            events={events}
            actions={actions}
            onClose={handleClosePanel}
            onViewInsidePark={() => setFlyToTarget({ center: selectedCell.coordinates, zoom: 16 })}
          />
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
            cityId={currentCityId}
          />
        )}
      </div>
    </div>
  );
}
