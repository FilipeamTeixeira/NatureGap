import type { MapLayer } from './types';

/**
 * Static UI layer definitions — the only data that belongs here.
 * All live business data (stats, wards, events, actions) lives in data.ts.
 */
export const MAP_LAYERS: MapLayer[] = [
  { id: 'impact', label: 'Nature impact (gap)', enabled: true, color: '#427033' },
  { id: 'habitat', label: 'Habitat quality', enabled: false, color: '#2E6F40' },
  { id: 'ndvi', label: 'Vegetation (NDVI)', enabled: false, color: '#73A56D' },
  { id: 'lst', label: 'Heat exposure (LST)', enabled: false, color: '#E8A44C' },
];
