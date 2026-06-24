export type LayerId = 'impact' | 'habitat' | 'ndvi' | 'lst';

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
  observedRichness: number;
  expectedRichness: number;
  maxExpectedRichness: number;
  ecologicalResidual: number;
  nObs: number;
  nSurveyDates: number;
  status: ImpactStatus;
  habitatPotential: HabitatPotential;
  observerEffortScore: number;
  taxonomicDiversity: number;
  species: Species[];
  corridorImportance: number;
  fragmentationIndex: number;
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
