/**
 * All live business data — fetched from Supabase when available,
 * falling back to the bundled local seed when not.
 *
 * Client components: call initData() once at app boot (page.tsx useEffect),
 *   then read from getGlobalStats() / getWards().
 *
 * Server components: call fetchEvents() / fetchActions() directly (async).
 */

import type { WardFeature } from './types';
import { supabase } from './supabase';

// ── Types ────────────────────────────────────────────────────────────────────

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
  /** Maps to a lucide-react icon name (e.g. 'Flower2'). */
  icon:        string;
  title:       string;
  description: string;
  impact:      string;
  time:        string;
}

// ── Local seed data (fallbacks) ───────────────────────────────────────────────
// These are the values to use when Supabase is unreachable or not configured.

const SEED_GLOBAL_STATS: GlobalStats = {
  observationsToday: 12305,
  speciesObserved:   3248,
  areasImproving:    87,
};

const SEED_WARDS: WardFeature[] = [
  { id: 'tsurumi',  name: 'Tsurumi',  nameJa: '鶴見区',   coordinates: [139.672, 35.508], score: -15 },
  { id: 'kanagawa', name: 'Kanagawa', nameJa: '神奈川区', coordinates: [139.621, 35.500], score: -20 },
  { id: 'nishi',    name: 'Nishi',    nameJa: '西区',     coordinates: [139.621, 35.466], score: -32 },
  { id: 'naka',     name: 'Naka',     nameJa: '中区',     coordinates: [139.648, 35.443], score: -18 },
  { id: 'minami',   name: 'Minami',   nameJa: '南区',     coordinates: [139.610, 35.433], score: -12 },
  { id: 'isogo',    name: 'Isogo',    nameJa: '磯子区',   coordinates: [139.637, 35.400], score: -22 },
  { id: 'kanazawa', name: 'Kanazawa', nameJa: '金沢区',   coordinates: [139.625, 35.348], score:  -8 },
  { id: 'konan',    name: 'Konan',    nameJa: '港南区',   coordinates: [139.588, 35.403], score:  -5 },
  { id: 'hodogaya', name: 'Hodogaya', nameJa: '保土ケ谷区', coordinates: [139.567, 35.455], score: -8 },
  { id: 'kohoku',   name: 'Kohoku',   nameJa: '港北区',   coordinates: [139.628, 35.527], score: -10 },
  { id: 'totsuka',  name: 'Totsuka',  nameJa: '戸塚区',   coordinates: [139.533, 35.403], score:  -3 },
  { id: 'asahi',    name: 'Asahi',    nameJa: '旭区',     coordinates: [139.535, 35.465], score:   2 },
  { id: 'midori',   name: 'Midori',   nameJa: '緑区',     coordinates: [139.548, 35.518], score:   5 },
  { id: 'tsuzuki',  name: 'Tsuzuki',  nameJa: '都筑区',   coordinates: [139.572, 35.545], score:   8 },
  { id: 'aoba',     name: 'Aoba',     nameJa: '青葉区',   coordinates: [139.523, 35.570], score:  18 },
  { id: 'sakae',    name: 'Sakae',    nameJa: '栄区',     coordinates: [139.568, 35.380], score:   2 },
  { id: 'izumi',    name: 'Izumi',    nameJa: '泉区',     coordinates: [139.503, 35.422], score:   5 },
  { id: 'seya',     name: 'Seya',     nameJa: '瀬谷区',   coordinates: [139.490, 35.466], score:  10 },
];

const SEED_EVENTS: CommunityEvent[] = [
  { id: 'e1', title: 'Satoyama walk — Yokohama',   date: 'Sat 5 Jul 2025 · 09:00', location: 'Sankei-en, Naka Ward',         attendees: 14, type: 'Guided walk'    },
  { id: 'e2', title: 'iNaturalist bioblitz',        date: 'Sun 6 Jul 2025 · all day', location: 'Kohoku Ward green belt',      attendees: 31, type: 'Citizen science' },
  { id: 'e3', title: 'Pollinator corridor planting',date: 'Sat 12 Jul 2025 · 10:00', location: 'Honmoku Futo, Naka Ward',     attendees:  8, type: 'Restoration'     },
  { id: 'e4', title: 'Urban ecology talk',          date: 'Thu 17 Jul 2025 · 19:00', location: 'Kanagawa University',         attendees: 55, type: 'Event'           },
];

const SEED_ACTIONS: TakeAction[] = [
  {
    id: 'a1',
    icon: 'Flower2',
    title: 'Plant for pollinators',
    description:
      'Native flowering plants in your garden, balcony, or street verge directly increase local insect diversity. Focus on species that bloom across the full season.',
    impact: 'High impact',
    time: '1–2 hours',
  },
  {
    id: 'a2',
    icon: 'TreePine',
    title: 'Join a tree-planting day',
    description:
      "Yokohama's urban forestry programme runs quarterly planting events. Each tree planted in a fragmentation gap measurably increases corridor connectivity.",
    impact: 'High impact',
    time: 'Half day',
  },
  {
    id: 'a3',
    icon: 'Leaf',
    title: 'Record a sighting on iNaturalist',
    description:
      'Every observation strengthens the biodiversity baseline used to calculate the nature impact score. Research-grade records count directly in the pipeline.',
    impact: 'Medium impact',
    time: '5 minutes',
  },
  {
    id: 'a4',
    icon: 'Zap',
    title: 'Advocate for a corridor',
    description:
      'Use the map to identify fragmentation bottlenecks in your ward, then raise the issue with your local council. The intervention ranking gives you the data to make the case.',
    impact: 'High impact (long-term)',
    time: 'Ongoing',
  },
];

// ── Module-level cache (for client components) ────────────────────────────────

let _globalStats: GlobalStats = SEED_GLOBAL_STATS;
let _wards: WardFeature[] = SEED_WARDS;
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

/**
 * Fetch live global stats and ward scores from Supabase and update the
 * module-level cache. Safe to call multiple times — subsequent calls are no-ops.
 * Call once at app boot; client components read from getGlobalStats() / getWards().
 */
export async function initData(): Promise<void> {
  if (_initDone || !supabase) return;
  _initDone = true;

  await Promise.allSettled([
    (async () => {
      const { data, error } = await supabase
        .from('global_stats')
        .select('observations_today, species_observed, areas_improving')
        .single();
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

// ── Server-component fetchers ─────────────────────────────────────────────────
// These are async and can be awaited directly in server components.

export async function fetchEvents(): Promise<CommunityEvent[]> {
  if (!supabase) return SEED_EVENTS;
  try {
    const { data, error } = await supabase
      .from('community_events')
      .select('id, title, date, location, attendees, type')
      .order('date', { ascending: true });
    if (error || !data || data.length === 0) return SEED_EVENTS;
    return data as CommunityEvent[];
  } catch {
    return SEED_EVENTS;
  }
}

export async function fetchActions(): Promise<TakeAction[]> {
  if (!supabase) return SEED_ACTIONS;
  try {
    const { data, error } = await supabase
      .from('recommended_actions')
      .select('id, icon, title, description, impact, time_estimate')
      .order('id', { ascending: true });
    if (error || !data || data.length === 0) return SEED_ACTIONS;
    return data.map((r) => ({ ...r, time: r.time_estimate })) as TakeAction[];
  } catch {
    return SEED_ACTIONS;
  }
}
