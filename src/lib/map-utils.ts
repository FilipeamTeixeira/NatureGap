'use client';

/**
 * Standalone helpers extracted from MapView.tsx (step 1 of the MapView split).
 * No logic changes from the original module-scope functions — this is a pure
 * relocation. Layer-paint/visibility functions moved to lib/map-layers.ts
 * (step 2); popup/marker functions moved to lib/map-markers.ts (step 3).
 */

import maplibregl from 'maplibre-gl';
import { Protocol } from 'pmtiles';
import { getParks, getParkStats } from '@/lib/green-spaces';
import { fetchPipelineJson, mergeFeatureCollections } from '@/lib/storage-fetch';
import type { RenderCellProperties } from '@/lib/cell-detail';

const PMTILES_PROTOCOL_KEY = '__naturegap_pmtiles_protocol__';

export function registerPmtilesProtocol(): Protocol {
  const globalState = globalThis as typeof globalThis & {
    [PMTILES_PROTOCOL_KEY]?: Protocol;
  };
  if (globalState[PMTILES_PROTOCOL_KEY]) return globalState[PMTILES_PROTOCOL_KEY];

  const protocol = new Protocol();
  maplibregl.addProtocol('pmtiles', protocol.tile);
  globalState[PMTILES_PROTOCOL_KEY] = protocol;
  return protocol;
}

export type ParkStats = ReturnType<typeof getParkStats>[string];

export function finiteNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

export function statsProperties(stats: ParkStats | undefined) {
  return {
    impactScore: finiteNumber(stats?.impactScore),
    natureGapScore: finiteNumber(stats?.natureGapScore),
    expectedRichness: finiteNumber(stats?.expectedRichness),
    ecologicalResidual: finiteNumber(stats?.ecologicalResidual),
    ecologicalResidualNormalized: finiteNumber(stats?.ecologicalResidualNormalized),
    dataAvailabilityRatio: finiteNumber(stats?.dataAvailabilityRatio),
    isUnsampled: stats?.isUnsampled === true,
    habitatQuality: finiteNumber(stats?.habitatQuality),
    habitatQualityIndex: finiteNumber(stats?.habitatQualityIndex),
    observedRichness: finiteNumber(stats?.observedRichness),
    effortCorrectedRichness: finiteNumber(stats?.effortCorrectedRichness ?? stats?.observedRichness),
    taxonomicDiversity: finiteNumber(stats?.taxonomicDiversity),
    corridorImportance: finiteNumber(stats?.corridorImportance),
    betweennessCentrality: finiteNumber(stats?.betweennessCentrality ?? stats?.corridorImportance),
    treeCover: finiteNumber(stats?.treeCover),
    treeCoverNorm: finiteNumber(stats?.treeCoverNorm),
    canopyHeightIdx: finiteNumber(stats?.canopyHeightIdx),
    heatExposure: finiteNumber(stats?.heatExposure),
    meanLst: finiteNumber(stats?.meanLst ?? stats?.heatExposure),
    lstIdx: finiteNumber(stats?.lstIdx ?? stats?.heatExposure),
    landUseGreen: finiteNumber(stats?.landUseGreen),
    landUseClass: stats?.landUseClass ?? 'unknown',
    interventionRank: finiteNumber(stats?.interventionRank),
    habitatQualityNorm: finiteNumber(stats?.habitatQualityNorm),
    effortCorrectedRichnessNorm: finiteNumber(stats?.effortCorrectedRichnessNorm),
    expectedRichnessNorm: finiteNumber(stats?.expectedRichnessNorm),
    corridorImportanceNorm: finiteNumber(stats?.corridorImportanceNorm),
    meanLstNorm: finiteNumber(stats?.meanLstNorm),
    lstNorm: finiteNumber(stats?.lstNorm ?? stats?.meanLstNorm),
    ecologicalResidualNorm: finiteNumber(stats?.ecologicalResidualNorm),
    natureGapScoreNorm: finiteNumber(stats?.natureGapScoreNorm),
    interventionRankNorm: finiteNumber(stats?.interventionRankNorm),
    nObs: Number(stats?.nObs ?? 0),
  };
}

export function primaryRing(geometry: GeoJSON.Polygon | GeoJSON.MultiPolygon): [number, number][] {
  return geometry.type === 'Polygon'
    ? geometry.coordinates[0] as [number, number][]
    : geometry.coordinates[0]?.[0] as [number, number][] ?? [];
}

export function polygonCentroid(ring: [number, number][]): [number, number] {
  const points = ring.length > 1 ? ring.slice(0, -1) : ring;
  let twiceArea = 0;
  let cx = 0;
  let cy = 0;

  for (let i = 0; i < points.length; i += 1) {
    const current = points[i];
    const next = points[(i + 1) % points.length];
    const cross = current[0] * next[1] - next[0] * current[1];
    twiceArea += cross;
    cx += (current[0] + next[0]) * cross;
    cy += (current[1] + next[1]) * cross;
  }

  if (Math.abs(twiceArea) > 1e-12) {
    return [cx / (3 * twiceArea), cy / (3 * twiceArea)];
  }

  const sum = points.reduce(
    (acc, point) => [acc[0] + point[0], acc[1] + point[1]] as [number, number],
    [0, 0] as [number, number],
  );
  return [sum[0] / Math.max(points.length, 1), sum[1] / Math.max(points.length, 1)];
}

/** Build a GeoJSON FeatureCollection from parks for patch-level rendering. */
export function parkPolygonsGeoJSON() {
  const statsByPark = getParkStats();
  return {
    type: 'FeatureCollection' as const,
    features: getParks().map((p) => ({
      type: 'Feature' as const,
      properties: {
        parkId: p.id,
        parkName: p.name,
        wardId: p.wardId,
        cityId: p.cityId,
        ...statsProperties(statsByPark[p.id]),
      },
      geometry: p.geometry,
    })),
  };
}

export function parkCentroidsGeoJSON() {
  const statsByPark = getParkStats();
  return {
    type: 'FeatureCollection' as const,
    features: getParks().map((p) => ({
      type: 'Feature' as const,
      properties: {
        parkId: p.id,
        parkName: p.name,
        wardId: p.wardId,
        cityId: p.cityId,
        ...statsProperties(statsByPark[p.id]),
      },
      geometry: { type: 'Point' as const, coordinates: polygonCentroid(primaryRing(p.geometry)) },
    })),
  };
}

export function emptyFeatureCollection(): GeoJSON.FeatureCollection {
  return { type: 'FeatureCollection', features: [] };
}

export function mergeFeatureCollectionChunks(parts: unknown[]): GeoJSON.FeatureCollection {
  return mergeFeatureCollections(parts);
}

export function isFeatureCollection(value: unknown): value is GeoJSON.FeatureCollection {
  return (
    typeof value === 'object' &&
    value !== null &&
    (value as GeoJSON.FeatureCollection).type === 'FeatureCollection' &&
    Array.isArray((value as GeoJSON.FeatureCollection).features)
  );
}

export async function fetchConnectivityNetworkEdges(): Promise<GeoJSON.FeatureCollection> {
  const data = await fetchPipelineJson(
    'connectivity-network-edges.geojson',
    'connectivity-network-edges.manifest.json',
    mergeFeatureCollectionChunks,
  );
  return isFeatureCollection(data) ? data : emptyFeatureCollection();
}

export async function fetchConnectivityNetworkNodes(): Promise<GeoJSON.FeatureCollection> {
  const data = await fetchPipelineJson(
    'connectivity-network-nodes.geojson',
    'connectivity-network-nodes.manifest.json',
    mergeFeatureCollectionChunks,
  );
  return isFeatureCollection(data) ? data : emptyFeatureCollection();
}

export function safeColor(color: unknown) {
  return typeof color === 'string' && /^#[0-9a-f]{6}$/i.test(color) ? color : '#3d6b2f';
}

export function scoreColor(score: number | undefined) {
  if (typeof score !== 'number' || !Number.isFinite(score)) return '#B8C9AE';
  if (score < -20) return '#C95B4B';
  if (score < -10) return '#E8A44C';
  if (score < 5) return '#B8C9AE';
  if (score < 15) return '#73A56D';
  return '#2E6F40';
}

/**
 * Normalized tile attributes as 0–1 (or −1–1) numbers.
 *
 * export.R packs them as 0–100 / −100–100 integers to keep hexgrid.pmtiles
 * under the Storage upload cap; archives published before that change carry
 * 0–1 floats. Magnitude decides, exactly as normUnit() does in layer-styles.ts
 * — |v| > 1 can only be an integer, and the pipeline never emits ±1.
 *
 * Only the click preview reads these: page.tsx replaces it with the
 * full-precision Storage record as soon as fetchCellDetail() resolves.
 */
function unitNumber(value: unknown): number | null {
  if (value == null) return null;
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  return Math.abs(n) > 1 ? n / 100 : n;
}

export function renderCellProperties(properties: maplibregl.GeoJSONFeature['properties']): RenderCellProperties | null {
  if (!properties) return null;
  const cellId = String(properties.cellId ?? '');
  if (!cellId) return null;

  return {
    cellId,
    cityId: properties.cityId != null ? String(properties.cityId) : undefined,
    parkId: properties.parkId != null ? String(properties.parkId) : undefined,
    parkName: properties.parkName != null ? String(properties.parkName) : undefined,
    impactScore: Number(properties.impactScore ?? 0),
    natureGapScore: properties.natureGapScore == null ? null : Number(properties.natureGapScore),
    expectedRichness: properties.expectedRichness == null ? null : Number(properties.expectedRichness),
    ecologicalResidual: properties.ecologicalResidual == null ? null : Number(properties.ecologicalResidual),
    ecologicalResidualNormalized: properties.ecologicalResidualNormalized == null ? null : Number(properties.ecologicalResidualNormalized),
    habitatQuality: properties.habitatQuality == null ? null : Number(properties.habitatQuality),
    observedRichness: properties.observedRichness == null ? null : Number(properties.observedRichness),
    corridorImportance: properties.corridorImportance == null ? null : Number(properties.corridorImportance),
    betweennessCentrality: properties.betweennessCentrality == null ? null : Number(properties.betweennessCentrality),
    treeCover: properties.treeCover == null ? null : Number(properties.treeCover),
    treeCoverNorm: unitNumber(properties.treeCoverNorm),
    canopyHeightIdx: unitNumber(properties.canopyHeightIdx),
    heatExposure: properties.heatExposure == null ? null : Number(properties.heatExposure),
    meanLst: properties.meanLst == null ? null : Number(properties.meanLst),
    lstIdx: properties.lstIdx == null ? null : Number(properties.lstIdx),
    landUseGreen: properties.landUseGreen == null ? null : Number(properties.landUseGreen),
    landUseClass: typeof properties.landUseClass === 'string'
      ? properties.landUseClass as RenderCellProperties['landUseClass']
      : undefined,
    ndviNorm: unitNumber(properties.ndviNorm),
    lstNorm: unitNumber(properties.lstNorm),
    disturbanceNorm: unitNumber(properties.disturbanceNorm),
    betweennessNorm: unitNumber(properties.betweennessNorm),
    expectedNorm: unitNumber(properties.expectedNorm),
    habitatQualityNorm: unitNumber(properties.habitatQualityNorm),
    residualNorm: unitNumber(properties.residualNorm),
    natureGapScoreNorm: unitNumber(properties.natureGapScoreNorm),
    interventionRank: properties.interventionRank == null ? null : Number(properties.interventionRank),
    interventionRankNorm: unitNumber(properties.interventionRankNorm),
    nObs: properties.nObs == null ? undefined : Number(properties.nObs),
    isUnsampled: properties.isUnsampled == null ? undefined : properties.isUnsampled === true,
  };
}
