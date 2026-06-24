export type LayerId = 'impact';

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

export interface CellData {
  id: string;
  name: string;
  nameJa: string;
  coordinates: [number, number];
  impactScore: number;
  habitatQuality: number;
  observedRichness: number;
  expectedRichness: number;
  status: ImpactStatus;
  habitatPotential: HabitatPotential;
  observerEffortScore: number;
  taxonomicDiversity: number;
  species: Species[];
  corridorImportance: number;
  fragmentationIndex: number;
  pressures: string[];
  trendData: number[];
  interventions: Intervention[];
}

export interface WardFeature {
  id: string;
  name: string;
  nameJa: string;
  coordinates: [number, number];
  score: number;
}
