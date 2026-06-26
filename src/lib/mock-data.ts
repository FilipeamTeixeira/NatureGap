import type { MapLayer } from './types';

/**
 * Static UI layer definitions — the only data that belongs here.
 * All live business data (stats, wards, events, actions) lives in data.ts.
 */
export const MAP_LAYERS: MapLayer[] = [
  { id: 'impact',       label: 'Nature gap',              enabled: true,  color: '#427033' },
  { id: 'expected',     label: 'Expected richness',       enabled: false, color: '#0d47a1' },
  { id: 'residual',     label: 'Ecological residual',     enabled: false, color: '#C95B4B' },
  { id: 'intervention', label: 'Intervention priority',   enabled: false, color: '#7b1fa2' },
  { id: 'habitat',      label: 'Habitat quality',         enabled: false, color: '#2E6F40' },
  { id: 'treecover',    label: 'Tree cover',              enabled: false, color: '#388e3c' },
  { id: 'biodiversity', label: 'Observed biodiversity',   enabled: false, color: '#1976d2' },
  { id: 'connectivity', label: 'Connectivity',            enabled: false, color: '#7b1fa2' },
  { id: 'heat',         label: 'Heat exposure',           enabled: false, color: '#E8A44C' },
  { id: 'landuse',      label: 'Land use',                enabled: false, color: '#558b2f' },
  { id: 'cell-grid',    label: '20m hex grid',            enabled: true,  color: '#5a6b5a' },
  { id: 'survey-points', label: 'Survey points',          enabled: true,  color: '#1F2A1F' },
  { id: 'quick-sightings', label: 'Quick sightings',      enabled: true,  color: '#E8A44C' },
  { id: 'structured-surveys', label: 'Structured surveys', enabled: true,  color: '#2E6F40' },
];
