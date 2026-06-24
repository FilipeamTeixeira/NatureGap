import type { MapLayer } from './types';

/**
 * Static UI layer definitions — the only data that belongs here.
 * All live business data (stats, wards, events, actions) lives in data.ts.
 */
export const MAP_LAYERS: MapLayer[] = [
  { id: 'impact', label: 'Nature impact (gap)', enabled: true, color: '#427033' },
];
