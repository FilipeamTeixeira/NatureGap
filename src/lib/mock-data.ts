import type { CellData, MapLayer, WardFeature } from './types';
import { getScoreColor } from './utils';

export const MAP_LAYERS: MapLayer[] = [
  { id: 'habitat', label: 'Habitat quality', enabled: true, color: '#6a9044' },
  { id: 'trees', label: 'Tree cover', enabled: false, color: '#3d6b2f' },
  { id: 'biodiversity', label: 'Biodiversity (observed)', enabled: false, color: '#a6b544' },
  { id: 'impact', label: 'Nature impact (gap)', enabled: true, color: '#427033' },
  { id: 'connectivity', label: 'Connectivity', enabled: false, color: '#a5c4e8' },
  { id: 'heat', label: 'Heat exposure', enabled: false, color: '#f4c207' },
  { id: 'landuse', label: 'Land use', enabled: false, color: '#8b6031' },
];

export const GLOBAL_STATS = {
  observationsToday: 12305,
  speciesObserved: 3248,
  areasImproving: 87,
};

export const ALL_WARDS: WardFeature[] = [
  { id: 'tsurumi', name: 'Tsurumi', nameJa: '鶴見区', coordinates: [139.672, 35.508], score: -15 },
  { id: 'kanagawa', name: 'Kanagawa', nameJa: '神奈川区', coordinates: [139.621, 35.500], score: -20 },
  { id: 'nishi', name: 'Nishi', nameJa: '西区', coordinates: [139.621, 35.466], score: -32 },
  { id: 'naka', name: 'Naka', nameJa: '中区', coordinates: [139.648, 35.443], score: -18 },
  { id: 'minami', name: 'Minami', nameJa: '南区', coordinates: [139.610, 35.433], score: -12 },
  { id: 'isogo', name: 'Isogo', nameJa: '磯子区', coordinates: [139.637, 35.400], score: -22 },
  { id: 'kanazawa', name: 'Kanazawa', nameJa: '金沢区', coordinates: [139.625, 35.348], score: -8 },
  { id: 'konan', name: 'Konan', nameJa: '港南区', coordinates: [139.588, 35.403], score: -5 },
  { id: 'hodogaya', name: 'Hodogaya', nameJa: '保土ケ谷区', coordinates: [139.567, 35.455], score: -8 },
  { id: 'kohoku', name: 'Kohoku', nameJa: '港北区', coordinates: [139.628, 35.527], score: -10 },
  { id: 'totsuka', name: 'Totsuka', nameJa: '戸塚区', coordinates: [139.533, 35.403], score: -3 },
  { id: 'asahi', name: 'Asahi', nameJa: '旭区', coordinates: [139.535, 35.465], score: 2 },
  { id: 'midori', name: 'Midori', nameJa: '緑区', coordinates: [139.548, 35.518], score: 5 },
  { id: 'tsuzuki', name: 'Tsuzuki', nameJa: '都筑区', coordinates: [139.572, 35.545], score: 8 },
  { id: 'aoba', name: 'Aoba', nameJa: '青葉区', coordinates: [139.523, 35.570], score: 18 },
  { id: 'sakae', name: 'Sakae', nameJa: '栄区', coordinates: [139.568, 35.380], score: 2 },
  { id: 'izumi', name: 'Izumi', nameJa: '泉区', coordinates: [139.503, 35.422], score: 5 },
  { id: 'seya', name: 'Seya', nameJa: '瀬谷区', coordinates: [139.490, 35.466], score: 10 },
];

export const WARD_GEOJSON = {
  type: 'FeatureCollection' as const,
  features: ALL_WARDS.map((ward) => ({
    type: 'Feature' as const,
    properties: {
      id: ward.id,
      name: ward.name,
      nameJa: ward.nameJa,
      score: ward.score,
      color: getScoreColor(ward.score),
    },
    geometry: {
      type: 'Point' as const,
      coordinates: ward.coordinates,
    },
  })),
};

export const YOKOHAMA_CELLS: CellData[] = [
  {
    id: 'nishi',
    name: 'Nishi Ward',
    nameJa: '西区',
    coordinates: [139.621, 35.466],
    impactScore: -32,
    habitatQuality: 28,
    observedRichness: 128,
    expectedRichness: 210,
    status: 'worse',
    habitatPotential: 'high',
    observerEffortScore: 3.2,
    taxonomicDiversity: 1.8,
    species: [
      { type: 'plant', count: 42 },
      { type: 'bird', count: 56 },
      { type: 'insect', count: 18 },
      { type: 'mammal', count: 7 },
      { type: 'fungi', count: 5 },
    ],
    corridorImportance: 78,
    fragmentationIndex: 82,
    pressures: [
      'Low native plant diversity',
      'High heat exposure',
      'Disconnected green spaces',
      'Low observer effort',
    ],
    trendData: [-28, -30, -31, -33, -35, -34, -32, -30, -31, -32, -33, -32],
    interventions: [
      {
        id: 'i1',
        title: 'Plant native species',
        description:
          'Increase native plant diversity. Focus on understorey shrubs and ground cover species native to the Kanto region.',
        impact: 'high',
        category: 'pollinator',
      },
      {
        id: 'i2',
        title: 'Create pollinator corridors',
        description:
          'Connect fragmented green patches. Planting verges along Takashima-dori reconnects two isolated patches currently separated by 400m.',
        impact: 'high',
        category: 'corridor',
        connectivityGain: 14,
      },
      {
        id: 'i3',
        title: 'Reduce mowing frequency',
        description:
          'Let more areas grow wild. Monthly mowing cycles prevent wildflower establishment and ground-nesting insects.',
        impact: 'medium',
        category: 'ground',
      },
      {
        id: 'i4',
        title: 'Add shade trees',
        description:
          'Improve canopy and reduce heat island effect. Zelkova or Hackberry planting reduces surface temperature by ~2°C.',
        impact: 'medium',
        category: 'canopy',
        connectivityGain: 8,
      },
    ],
  },
  {
    id: 'aoba',
    name: 'Aoba Ward',
    nameJa: '青葉区',
    coordinates: [139.523, 35.570],
    impactScore: 18,
    habitatQuality: 74,
    observedRichness: 312,
    expectedRichness: 290,
    status: 'better',
    habitatPotential: 'high',
    observerEffortScore: 7.1,
    taxonomicDiversity: 3.2,
    species: [
      { type: 'plant', count: 98 },
      { type: 'bird', count: 124 },
      { type: 'insect', count: 61 },
      { type: 'mammal', count: 18 },
      { type: 'fungi', count: 11 },
    ],
    corridorImportance: 45,
    fragmentationIndex: 34,
    pressures: [],
    trendData: [12, 14, 16, 17, 15, 18, 20, 19, 18, 17, 18, 18],
    interventions: [
      {
        id: 'i1',
        title: 'Maintain corridor integrity',
        description:
          'Protect the Tsurumi river riparian corridor. Any encroachment would disconnect two currently linked forest patches.',
        impact: 'high',
        category: 'corridor',
      },
      {
        id: 'i2',
        title: 'Expand community monitoring',
        description:
          'Observation effort is already high — this area could mentor neighbouring wards on recording methods.',
        impact: 'medium',
        category: 'ground',
      },
    ],
  },
  {
    id: 'kanazawa',
    name: 'Kanazawa Ward',
    nameJa: '金沢区',
    coordinates: [139.625, 35.348],
    impactScore: -8,
    habitatQuality: 61,
    observedRichness: 198,
    expectedRichness: 218,
    status: 'worse',
    habitatPotential: 'high',
    observerEffortScore: 4.4,
    taxonomicDiversity: 2.6,
    species: [
      { type: 'plant', count: 67 },
      { type: 'bird', count: 89 },
      { type: 'insect', count: 29 },
      { type: 'mammal', count: 9 },
      { type: 'fungi', count: 4 },
    ],
    corridorImportance: 62,
    fragmentationIndex: 51,
    pressures: [
      'Coastal development pressure',
      'Invasive species encroachment',
      'Tidal flat disturbance',
    ],
    trendData: [-5, -6, -7, -8, -9, -10, -9, -8, -7, -8, -8, -8],
    interventions: [
      {
        id: 'i1',
        title: 'Remove invasive species',
        description:
          'Target Sasa bamboo and Kudzu vine in coastal margins. Manual removal is preferred over herbicide near tidal flats.',
        impact: 'high',
        category: 'ground',
      },
      {
        id: 'i2',
        title: 'Restore tidal flat buffer',
        description:
          'A 50m buffer strip along the coast would reconnect two seabird nesting areas currently isolated by development.',
        impact: 'high',
        category: 'corridor',
        connectivityGain: 22,
      },
      {
        id: 'i3',
        title: 'Establish seagrass monitoring',
        description:
          'Coordinate with local dive clubs to survey subtidal meadows. Seagrass extent is currently unknown.',
        impact: 'medium',
        category: 'water',
      },
    ],
  },
];
