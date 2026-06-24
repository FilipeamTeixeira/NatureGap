import type { MapLayer } from './types';

/**
 * Static UI layer definitions — the only data that belongs here.
 * All live business data (stats, wards, events, actions) lives in data.ts.
 */
export const MAP_LAYERS: MapLayer[] = [
  { id: 'impact',       label: 'Nature Impact (gap)',     enabled: true,  color: '#427033' },
  { id: 'habitat',      label: 'Habitat Quality',         enabled: false, color: '#2E6F40' },
  { id: 'treecover',    label: 'Tree Cover',              enabled: false, color: '#388e3c' },
  { id: 'biodiversity', label: 'Biodiversity (observed)', enabled: false, color: '#1976d2' },
  { id: 'connectivity', label: 'Connectivity',            enabled: false, color: '#7b1fa2' },
  { id: 'heat',         label: 'Heat Exposure',           enabled: false, color: '#E8A44C' },
  { id: 'landuse',      label: 'Land Use',                enabled: false, color: '#558b2f' },
];
