export type LayerId =
  | 'impact'
  | 'expected'
  | 'residual'
  | 'intervention'
  | 'habitat'
  | 'treecover'
  | 'biodiversity'
  | 'connectivity'
  | 'heat'
  | 'landuse'
  | 'survey-points'
  | 'quick-sightings'
  | 'structured-surveys'
  | 'cell-grid';

export interface MapLayer {
  id: LayerId;
  label: string;
  enabled: boolean;
  color: string;
}

export type ImpactStatus = 'much-worse' | 'worse' | 'as-expected' | 'better' | 'much-better';
export type HabitatPotential = 'low' | 'moderate' | 'high';
export type InterventionCategory = 'canopy' | 'corridor' | 'pollinator' | 'water' | 'ground';
export type InterventionImpact = 'high' | 'medium' | 'low';
export type SpeciesType = 'plant' | 'bird' | 'insect' | 'mammal' | 'fungi';

export interface Species {
  type: SpeciesType;
  count: number;
  /** Distinct taxon labels (common name + scientific name when available). */
  names?: string[];
}

export interface Intervention {
  id: string;
  title: string;
  description: string;
  impact: InterventionImpact;
  category: InterventionCategory;
  connectivityGain?: number;
}

/** Pipeline-derived stats shared by cells and park aggregates. */
export interface CellStatsFields {
  impactScore: number;
  habitatQuality: number;
  habitatQualityIndex: number;
  speciesRichnessRaw: number;
  observedRichness: number | null;
  effortCorrectedRichness?: number | null;
  expectedRichness: number;
  maxExpectedRichness: number;
  ecologicalResidual: number | null;
  isUnsampled?: boolean;
  temporalBiasFlag?: boolean;
  pathKm?: number;
  nObs: number;
  nSurveyDates: number;
  status: ImpactStatus;
  habitatPotential: HabitatPotential;
  observerEffortScore: number;
  taxonomicDiversity: number;
  species: Species[];
  corridorImportance: number;
  fragmentationIndex: number;
  /** 0–100 tree canopy fraction (from pipeline WorldCover). */
  treeCover?: number;
  /** 0–100 heat exposure rank (from Landsat LST when available). */
  heatExposure?: number;
  /** 0–100 vegetated land-cover fraction. */
  landUseGreen?: number;
  /** Dominant categorical land-cover class used for map fills. */
  landUseClass?: 'tree' | 'shrub' | 'grass' | 'water' | 'built' | 'bare' | 'mixed' | 'unknown';
  /** 1-based intervention priority rank when exported for rendering. */
  interventionRank?: number;
  pressures: string[];
  interventions: Intervention[];
}

export interface CellData extends CellStatsFields {
  id: string;
  name: string;
  nameJa: string;
  coordinates: [number, number];
}

export interface WardFeature {
  id: string;
  name: string;
  nameJa: string;
  coordinates: [number, number];
  score: number;
}
