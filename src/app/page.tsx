'use client';

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import dynamic from 'next/dynamic';
import { useRouter } from 'next/navigation';
import Navbar from '@/components/layout/Navbar';
import RightSidebar from '@/components/layout/RightSidebar';
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
import { CITY, isRegisteredCityId } from '@/lib/config';
import type { OpportunityGapInfo } from '@/lib/opportunity-gap';
import type { ResidualWindow } from '@/lib/residual-window';
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

type FlyToTarget =
  | { center: [number, number]; zoom: number }
  | { cityId: string };

function cityIdFromLocation(): string | null {
  if (typeof window === 'undefined') return null;
  const value = new URLSearchParams(window.location.search).get('city');
  return isRegisteredCityId(value) ? value : null;
}

export default function Page() {
  const [selectedCell, setSelectedCell] = useState<CellData | null>(null);
  const [selectedWard, setSelectedWard] = useState<WardFeature | null>(null);
  const [selectedSurveyPoint, setSelectedSurveyPoint] = useState<SurveyPointFeature | null>(null);
  const [layers, setLayers] = useState<MapLayer[]>(MAP_LAYERS);
  const [flyToTarget, setFlyToTarget] = useState<FlyToTarget | null>(null);
  const [dataRevision, setDataRevision] = useState(0);
  const [role, setRole] = useState<AppRole | null>(null);
  const [species, setSpecies] = useState<SpeciesReferenceOption[]>([]);
  const [surveyPoints, setSurveyPoints] = useState<SurveyPointFeature[]>([]);
  const [structuredSurveys, setStructuredSurveys] = useState<StructuredSurveyFeature[]>([]);
  const [events, setEvents] = useState<CommunityEvent[]>([]);
  const [actions, setActions] = useState<TakeAction[]>([]);
  const [cellDetailLoading, setCellDetailLoading] = useState(false);
  const [viewCityId, setViewCityId] = useState<string | null>(null);
  // Residual-window verdicts per city (lib/residual-window.ts), set once the
  // map's datasets load; null until then.
  const [residualWindows, setResidualWindows] = useState<Record<string, ResidualWindow | null> | null>(null);
  // Each city's Nature gap from its manifest (lib/opportunity-gap.ts); null until loaded.
  const [opportunityInfo, setOpportunityInfo] = useState<Record<string, OpportunityGapInfo | null> | null>(null);
  // Which verdict the open panel uses: a hex cell or a whole park.
  const [selectedScale, setSelectedScale] = useState<'hex' | 'patch'>('hex');
  // An explicit thematic choice is never overridden by the default below, and
  // the default only undoes a switch it made itself.
  const userPickedLayerRef = useRef(false);
  const autoHabitatRef = useRef(false);
  const cellClickGenerationRef = useRef(0);

  const surveyPointsFc = useMemo(() => surveyPointsGeoJSON(surveyPoints), [surveyPoints]);
  const structuredSurveysFc = useMemo(() => structuredSurveysGeoJSON(structuredSurveys), [structuredSurveys]);
  const activeLayer = useMemo<HexLayerId>(
    () => THEMATIC_LAYER_IDS.find((id) => layers.some((layer) => layer.id === id && layer.enabled)) ?? 'opportunity',
    [layers],
  );
  // Selection wins; otherwise follow the map, so panning to another city
  // relabels the badge and sidebar instead of leaving them on the default.
  const currentCityId = selectedCell?.cityId ?? selectedWard?.cityId ?? viewCityId ?? CITY.id;
  const router = useRouter();

  // Where a city's export has no Nature gap (methodology §15), that layer is
  // all grey, so open on Habitat quality instead — a measured layer that covers
  // every cell. Initial state stays MAP_LAYERS so the server render matches;
  // this runs when the manifests arrive and whenever the city in view changes,
  // from those events rather than from an effect.
  const opportunityInfoRef = useRef<Record<string, OpportunityGapInfo | null> | null>(null);
  const viewCityIdRef = useRef<string | null>(null);
  const applyDefaultLayer = useCallback((cityId: string) => {
    const info = opportunityInfoRef.current;
    if (!info || userPickedLayerRef.current) return;
    const unsupported = !info[cityId];
    const target: HexLayerId | null = unsupported
      ? 'habitat'
      : autoHabitatRef.current ? 'opportunity' : null;
    if (!target) return;
    autoHabitatRef.current = unsupported;
    setLayers((prev) => {
      if (prev.some((layer) => layer.id === target && layer.enabled)) return prev;
      return prev.map((layer) => (THEMATIC_LAYER_IDS as readonly string[]).includes(layer.id)
        ? { ...layer, enabled: layer.id === target }
        : layer);
    });
  }, []);

  const handleViewCityChange = useCallback((cityId: string | undefined) => {
    viewCityIdRef.current = cityId ?? null;
    setViewCityId(cityId ?? null);
    applyDefaultLayer(cityId ?? CITY.id);
  }, [applyDefaultLayer]);

  const handleResidualWindows = useCallback((windows: Record<string, ResidualWindow | null>) => {
    setResidualWindows(windows);
  }, []);

  const handleOpportunityInfo = useCallback((info: Record<string, OpportunityGapInfo | null>) => {
    opportunityInfoRef.current = info;
    setOpportunityInfo(info);
    applyDefaultLayer(viewCityIdRef.current ?? CITY.id);
  }, [applyDefaultLayer]);

  const handleCitySelect = useCallback((cityId: string) => {
    cellClickGenerationRef.current += 1;
    setCellDetailLoading(false);
    setSelectedCell(null);
    setSelectedWard(null);
    setSelectedSurveyPoint(null);
    viewCityIdRef.current = cityId;
    setViewCityId(cityId);
    // The default layer follows the map, not the menu: MapView reports the city
    // actually on screen once the flight lands (handleViewCityChange), which
    // keeps it in step with the legend and paint if the flight is interrupted.
    setFlyToTarget({ cityId });
    router.replace(`/?city=${encodeURIComponent(cityId)}`, { scroll: false });
  }, [router]);

  useLayoutEffect(() => {
    const cityId = cityIdFromLocation();
    if (!cityId) return;
    viewCityIdRef.current = cityId;
    setViewCityId(cityId);
    setFlyToTarget({ cityId });
  }, []);

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
    if (isThematic) userPickedLayerRef.current = true;
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
    setSelectedScale('hex');
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
    // Supersede any hex detail still loading, as the other selection handlers
    // do: otherwise it lands after this park and is shown with the park's
    // (patch) residual verdict instead of its own.
    const clickId = ++cellClickGenerationRef.current;
    setCellDetailLoading(false);
    const cell = await fetchParkDetail(parkId, coordinates);
    if (clickId !== cellClickGenerationRef.current) return;
    if (cell) {
      setSelectedCell(cell);
      setSelectedScale('patch');
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
      <Navbar activePath="/" cityId={currentCityId} onCitySelect={handleCitySelect} />

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
            onViewCityChange={handleViewCityChange}
            onResidualWindows={handleResidualWindows}
            onOpportunityInfo={handleOpportunityInfo}
          />
        </div>

        <RightSidebar
          label={selectedCell ? 'Place' : selectedWard ? 'Ward' : 'Citizen science'}
          expandKey={selectedCell?.id ?? selectedWard?.id ?? selectedSurveyPoint?.id ?? null}
        >
          {selectedCell ? (
            <CellDetailPanel
              cell={selectedCell}
              residualWindow={residualWindows?.[selectedCell.cityId]?.[selectedScale] ?? null}
              opportunityInfo={opportunityInfo?.[selectedCell.cityId] ?? null}
              scale={selectedScale}
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
        </RightSidebar>
      </div>
    </div>
  );
}
