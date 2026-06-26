import type { MapLayer } from './types';

/**
 * Static UI layer definitions — the only data that belongs here.
 * All live business data (stats, wards, events, actions) lives in data.ts.
 */
export const MAP_LAYERS: MapLayer[] = [
  { id: 'impact',       label: 'Nature Impact (gap)',     enabled: true,  color: '#427033' },
  { id: 'expected',     label: 'Expected Richness',        enabled: false, color: '#0d47a1' },
  { id: 'residual',     label: 'Ecological Residual',      enabled: false, color: '#C95B4B' },
  { id: 'intervention', label: 'Intervention Ranking',     enabled: false, color: '#7b1fa2' },
  { id: 'habitat',      label: 'Habitat Quality',         enabled: false, color: '#2E6F40' },
  { id: 'treecover',    label: 'Tree Cover',              enabled: false, color: '#388e3c' },
  { id: 'biodiversity', label: 'Biodiversity (observed)', enabled: false, color: '#1976d2' },
  { id: 'connectivity', label: 'Connectivity',            enabled: false, color: '#7b1fa2' },
  { id: 'heat',         label: 'Heat Exposure',           enabled: false, color: '#E8A44C' },
  { id: 'landuse',      label: 'Land Use',                enabled: false, color: '#558b2f' },
  { id: 'cell-grid',    label: 'Cell Grid',                enabled: true,  color: '#5a6b5a' },
  { id: 'survey-points', label: 'Survey Points',           enabled: true,  color: '#1F2A1F' },
  { id: 'quick-sightings', label: 'Quick Sightings',       enabled: true,  color: '#E8A44C' },
  { id: 'structured-surveys', label: 'Structured Surveys', enabled: true,  color: '#2E6F40' },
];
