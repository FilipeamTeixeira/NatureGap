import type { MapLayer } from './types';

/**
 * Static UI layer definitions — the only data that belongs here.
 * All live business data (stats, wards, events, actions) lives in data.ts.
 */
// 'impact' (the record-based Nature Gap score) and 'residual' are left out:
// every city's residual window is observation-dominated, so both draw grey
// everywhere (lib/residual-window.ts). Their styles stay in layer-styles.ts;
// adding the two rows back here and to THEMATIC_LAYER_GROUPS restores them.
export const MAP_LAYERS: MapLayer[] = [
  { id: 'opportunity',  label: 'Nature gap',              enabled: true,  color: '#4F9E57' },
  { id: 'expected',     label: 'Expected richness',       enabled: false, color: '#0d47a1' },
  { id: 'intervention', label: 'Where to look next',      enabled: false, color: '#7b1fa2' },
  { id: 'habitat',      label: 'Habitat quality',         enabled: false, color: '#2E6F40' },
  { id: 'treecover',    label: 'Tree cover',              enabled: false, color: '#388e3c' },
  { id: 'vegetation',   label: 'Vegetation (0.5 m)',      enabled: false, color: '#78c679' },
  { id: 'biodiversity', label: 'Observed biodiversity',   enabled: false, color: '#1976d2' },
  { id: 'connectivity', label: 'Connectivity',            enabled: false, color: '#7b1fa2' },
  { id: 'heat',         label: 'Heat exposure',           enabled: false, color: '#E8A44C' },
  { id: 'traffic',      label: 'Traffic exposure',        enabled: false, color: '#8f5d2e' },
  { id: 'landuse',      label: 'Land use',                enabled: false, color: '#558b2f' },
  { id: 'cell-grid',    label: '20m hex grid',            enabled: false, color: '#5a6b5a' },
  { id: 'survey-points', label: 'Survey points',          enabled: true,  color: '#1F2A1F' },
  { id: 'structured-surveys', label: 'Structured surveys', enabled: true,  color: '#2E6F40' },
];
