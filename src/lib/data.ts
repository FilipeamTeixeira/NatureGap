/**
 * Live business data from Supabase. Returns empty values when not configured.
 */

import type { WardFeature } from './types';
import { supabase } from './supabase';

export interface GlobalStats {
  observationsToday: number;
  speciesObserved:   number;
  areasImproving:    number;
}

export interface CommunityEvent {
  id:        string;
  title:     string;
  date:      string;
  location:  string;
  attendees: number;
  type:      string;
}

export interface TakeAction {
  id:          string;
  icon:        string;
  title:       string;
  description: string;
  impact:      string;
  time:        string;
}

const EMPTY_GLOBAL_STATS: GlobalStats = {
  observationsToday: 0,
  speciesObserved:   0,
  areasImproving:    0,
};

let _globalStats: GlobalStats = EMPTY_GLOBAL_STATS;
let _wards: WardFeature[] = [];
let _initDone = false;

export function getGlobalStats(): GlobalStats { return _globalStats; }
export function getWards(): WardFeature[] { return _wards; }

export function wardCentroidsGeoJSON(wards: WardFeature[] = _wards) {
  return {
    type: 'FeatureCollection' as const,
    features: wards.map((w) => ({
      type: 'Feature' as const,
      properties: { id: w.id, name: w.name, nameJa: w.nameJa, score: w.score },
      geometry: { type: 'Point' as const, coordinates: w.coordinates },
    })),
  };
}

export async function initData(): Promise<void> {
  if (_initDone || !supabase) return;
  _initDone = true;

  await Promise.allSettled([
    (async () => {
      const { data, error } = await supabase
        .from('global_stats')
        .select('observations_today, species_observed, areas_improving')
        .maybeSingle();
      if (error || !data) return;
      _globalStats = {
        observationsToday: data.observations_today,
        speciesObserved:   data.species_observed,
        areasImproving:    data.areas_improving,
      };
    })(),
    (async () => {
      const { data, error } = await supabase
        .from('wards')
        .select('id, name, name_ja, lng, lat, score');
      if (error || !data || data.length === 0) return;
      _wards = data.map((r) => ({
        id:          r.id,
        name:        r.name,
        nameJa:      r.name_ja,
        coordinates: [r.lng, r.lat] as [number, number],
        score:       r.score,
      }));
    })(),
  ]);
}

export async function fetchEvents(): Promise<CommunityEvent[]> {
  if (!supabase) return [];
  try {
    const { data, error } = await supabase
      .from('community_events')
      .select('id, title, date, location, attendees, type')
      .order('date', { ascending: true });
    if (error || !data) return [];
    return data as CommunityEvent[];
  } catch {
    return [];
  }
}

export async function fetchActions(): Promise<TakeAction[]> {
  if (!supabase) return [];
  try {
    const { data, error } = await supabase
      .from('conservation_actions')
      .select('id, name, description, impact_type, effort_level')
      .order('name', { ascending: true });
    if (error || !data) return [];
    return data.map((r) => ({
      id: r.id,
      icon: String(r.impact_type ?? 'canopy'),
      title: r.name,
      description: r.description,
      impact: String(r.impact_type ?? '').replaceAll('_', ' '),
      time: String(r.effort_level ?? '').replaceAll('_', ' '),
    })) as TakeAction[];
  } catch {
    return [];
  }
}
