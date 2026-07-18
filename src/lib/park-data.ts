/**
 * Pipeline cell and park statistics.
 *
 * Data sources (in priority order):
 *   1. Supabase Storage — cells.json + park-stats.json
 *   2. Bundled public assets — /pipeline/<CITY_ID>/cells.json
 *   3. Bundled src/data/park-stats.json (park aggregates only)
 */

import type { CellData, CellStatsFields } from './types';
import type { GreenSpace } from './green-spaces';
import parkStatsData from '@/data/park-stats.json';
import { parseCellsJson, parseParkStats } from './data-validation';
import { supabase } from './supabase';
import { STORAGE } from './config';
import {
  fetchPipelineJson,
  mergeCellChunks,
} from './storage-fetch';

function centroid(ring: [number, number][]): [number, number] {
  const pts = ring.slice(0, -1);
  if (pts.length === 0) return [0, 0];
  const lng = pts.reduce((s, p) => s + p[0], 0) / pts.length;
  const lat = pts.reduce((s, p) => s + p[1], 0) / pts.length;
  return [lng, lat];
}

let localParkStats: Record<string, CellStatsFields> = {};
try {
  localParkStats = parseParkStats(parkStatsData);
} catch (e) {
  console.error('[park-data] Invalid bundled park-stats.json:', e);
}

let runtimeParkStats: Record<string, CellStatsFields> = localParkStats;
let runtimeCellStats: Record<string, CellStatsFields> = {};
let initCalled = false;

async function fetchJsonFromStorage(path: string): Promise<unknown | null> {
  if (!supabase) return null;
  const { data, error } = await supabase.storage
    .from(STORAGE.PIPELINE_BUCKET)
    .download(`${STORAGE.CITY_ID}/${path}`);
  if (error || !data) return null;
  return JSON.parse(await data.text());
}

/**
 * Load cells.json and park-stats.json from Supabase or bundled public assets.
 * cells.json may be split into chunks listed in cells.manifest.json.
 */
export async function initParkStats(): Promise<void> {
  if (initCalled) return;
  initCalled = true;

  try {
    const [cellsRaw, parksRaw] = await Promise.all([
      fetchPipelineJson(
        STORAGE.CELLS_KEY,
        STORAGE.CELLS_MANIFEST_KEY,
        mergeCellChunks,
      ),
      fetchJsonFromStorage(STORAGE.PARK_STATS_KEY),
    ]);

    const parsedCells = parseCellsJson(cellsRaw ?? {});
    if (Object.keys(parsedCells).length > 0) {
      runtimeCellStats = parsedCells;
      console.info(`[park-data] Loaded ${Object.keys(parsedCells).length} cells`);
    }

    if (parksRaw) {
      runtimeParkStats = parseParkStats(parksRaw);
      console.info(`[park-data] Loaded ${Object.keys(runtimeParkStats).length} park aggregates`);
    }
  } catch (e) {
    console.warn('[park-data] Remote fetch failed, using bundled data:', e);
  }
}

function statsForCell(cellId: string, parkId: string): CellStatsFields | null {
  return runtimeCellStats[cellId] ?? runtimeParkStats[parkId] ?? null;
}

/**
 * Build CellData from a hex click — does not require a matching parks.geojson entry.
 */
export function cellToCellData(
  cellId: string,
  parkId: string,
  parkName: string,
  coordinates: [number, number],
): CellData | null {
  const stats = statsForCell(cellId, parkId);
  if (!stats) return null;

  const displayName =
    parkName && parkName !== 'city-green'
      ? parkName
      : parkId === 'city-green'
        ? 'Green area'
        : parkName || parkId;

  return {
    id: cellId,
    name: displayName,
    nameJa: displayName,
    coordinates,
    ...stats,
  };
}

/**
 * Build CellData for a map cell or park selection using pipeline stats only.
 * Returns null when no pipeline data exists for the selection.
 */
export function parkToCellData(
  park: GreenSpace,
  cellId: string,
  coordinates?: [number, number],
): CellData | null {
  const stats = statsForCell(cellId, park.id);
  if (!stats) return null;

  return {
    id: cellId,
    name: park.name,
    nameJa: park.nameJa,
    coordinates: coordinates ?? centroid(park.ring),
    ...stats,
  };
}

export function hasCellStats(cellId: string): boolean {
  return cellId in runtimeCellStats;
}

export function getLoadedCellCount(): number {
  return Object.keys(runtimeCellStats).length;
}

/** Cell stats keyed by cellId — used to paint hex layers. */
export function getCellStats(): Record<string, CellStatsFields> {
  return runtimeCellStats;
}
