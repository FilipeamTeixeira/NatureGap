/**
 * Per-park statistics — stand-in for the JSON produced by the R pipeline
 * (pipeline/05_residuals → data/export/park-stats.json).
 *
 * initParkStats() fetches fresh data from Supabase Storage if available;
 * parkToCellData() always falls back to the bundled local JSON.
 */

import type { CellData, HabitatPotential, ImpactStatus, Species } from './types';
import type { GreenSpace } from './green-spaces';
import parkStatsData from '@/data/park-stats.json';
import { parseParkStats } from './data-validation';
import { supabase } from './supabase';
import { SCORE_THRESHOLDS, STORAGE } from './config';

/** Centroid of a closed polygon ring. */
function centroid(ring: [number, number][]): [number, number] {
  const pts = ring.slice(0, -1);
  if (pts.length === 0) return [0, 0];
  const lng = pts.reduce((s, p) => s + p[0], 0) / pts.length;
  const lat = pts.reduce((s, p) => s + p[1], 0) / pts.length;
  return [lng, lat];
}

type ParkStatsMap = ReturnType<typeof parseParkStats>;

// Bundled local JSON — safe fallback, never throws at module load
let localStats: ParkStatsMap = {};
try {
  localStats = parseParkStats(parkStatsData);
} catch (e) {
  console.error('[park-data] Invalid bundled park-stats.json:', e);
}

// Runtime stats — replaced by Supabase fetch when available
let runtimeStats: ParkStatsMap = localStats;

/**
 * Fetch the latest park-stats.json from Supabase Storage and update the
 * in-memory cache. Safe to call multiple times — subsequent calls are no-ops
 * once a successful fetch has completed.
 *
 * Call once at app boot (e.g. in a root useEffect).
 */
let initCalled = false;
export async function initParkStats(): Promise<void> {
  if (initCalled || !supabase) return;
  initCalled = true;

  try {
    const { data, error } = await supabase.storage
      .from(STORAGE.PIPELINE_BUCKET)
      .download(STORAGE.PARK_STATS_KEY);

    if (error || !data) return;

    const text = await data.text();
    const parsed = parseParkStats(JSON.parse(text));
    runtimeStats = parsed;
  } catch (e) {
    console.warn('[park-data] Supabase fetch failed, using local data:', e);
  }
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function statusFromScore(score: number): ImpactStatus {
  const t = SCORE_THRESHOLDS;
  if (score < t.MUCH_WORSE)  return 'much-worse';
  if (score < t.WORSE)       return 'worse';
  if (score < t.AS_EXPECTED) return 'as-expected';
  if (score < t.BETTER)      return 'better';
  return 'much-better';
}

function habitatPotentialFromScore(score: number): HabitatPotential {
  if (score >= 10)  return 'high';
  if (score >= -12) return 'moderate';
  return 'low';
}

function speciesFromObserved(observed: number): Species[] {
  return [
    { type: 'plant',  count: Math.max(0, Math.round(observed * 0.38)) },
    { type: 'bird',   count: Math.max(0, Math.round(observed * 0.30)) },
    { type: 'insect', count: Math.max(0, Math.round(observed * 0.18)) },
    { type: 'mammal', count: Math.max(0, Math.round(observed * 0.08)) },
    { type: 'fungi',  count: Math.max(0, Math.round(observed * 0.06)) },
  ];
}

function scoreDrivenFields(score: number) {
  const habitatQuality    = Math.round(clamp(58 + score * 1.2, 8, 96));
  const expectedRichness  = Math.round(clamp(habitatQuality * 2.0, 18, 180));
  const observedRichness  = Math.round(clamp(expectedRichness + score * 1.6, 6, 220));

  return {
    impactScore:       score,
    habitatQuality,
    observedRichness,
    expectedRichness,
    status:            statusFromScore(score),
    habitatPotential:  habitatPotentialFromScore(score),
    taxonomicDiversity: Number(clamp(2.1 + score / 35, 0.7, 4.2).toFixed(1)),
    species:           speciesFromObserved(observedRichness),
    corridorImportance: Math.round(clamp(71 + score * 0.8, 15, 95)),
    fragmentationIndex: Math.round(clamp(75 - score * 0.9, 5, 95)),
    trendData: Array.from({ length: 12 }, (_, i) =>
      Math.round(score - 3 + i * 0.25 + Math.sin(i * 0.9) * 1.5),
    ),
  };
}

/**
 * Return full CellData for a park.
 * Uses the latest fetched or bundled pipeline stats, with the clicked hex
 * score driving the cell-level biodiversity values.
 */
export function parkToCellData(park: GreenSpace, score: number, cellId = park.id): CellData {
  const base = runtimeStats[park.id];
  if (base) {
    return {
      id: cellId,
      name: park.name,
      nameJa: park.nameJa,
      coordinates: centroid(park.ring),
      ...base,
      ...scoreDrivenFields(score),
    };
  }

  // Generic fallback — for any park not yet in the pipeline output
  const hq       = clamp(50 + score, 0, 100);
  const expected = Math.round(hq * 2.8);
  const observed = Math.max(0, Math.round(expected + score * 1.4));
  return {
    id: cellId,
    name: park.name,
    nameJa: park.nameJa,
    coordinates: centroid(park.ring),
    impactScore:        score,
    habitatQuality:     hq,
    observedRichness:   observed,
    expectedRichness:   expected,
    status:             statusFromScore(score),
    habitatPotential:   habitatPotentialFromScore(score),
    observerEffortScore: 3.1,
    taxonomicDiversity:  2.0,
    species:            speciesFromObserved(observed),
    corridorImportance: clamp(60 + score, 10, 95),
    fragmentationIndex: clamp(55 - score, 5, 95),
    pressures: score < 0 ? ['Low native plant diversity', 'Below-average observer effort'] : [],
    trendData: Array.from({ length: 12 }, (_, i) =>
      Math.round(score + Math.sin(i * 0.8) * 2),
    ),
    interventions: [
      {
        id: 'i1',
        title: 'Increase native plant cover',
        description: 'Replace ornamental ground cover with species native to the Kanto region.',
        impact: 'high',
        category: 'pollinator',
      },
      {
        id: 'i2',
        title: 'Reduce mowing frequency',
        description: 'Switch to biannual mowing to allow wildflower and insect establishment.',
        impact: 'medium',
        category: 'ground',
      },
    ],
  };
}
