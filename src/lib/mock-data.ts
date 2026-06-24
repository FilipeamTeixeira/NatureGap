import type { MapLayer, WardFeature } from './types';

export const MAP_LAYERS: MapLayer[] = [
  { id: 'impact', label: 'Nature impact (gap)', enabled: true, color: '#427033' },
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

// Ward centroids — used for labels and nearest-ward lookup only
export const WARD_CENTROIDS_GEOJSON = {
  type: 'FeatureCollection' as const,
  features: ALL_WARDS.map((ward) => ({
    type: 'Feature' as const,
    properties: {
      id: ward.id,
      name: ward.name,
      nameJa: ward.nameJa,
      score: ward.score,
    },
    geometry: {
      type: 'Point' as const,
      coordinates: ward.coordinates,
    },
  })),
};
